package io.github.mybugga.litewallpaper

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * Draws a wallpaper into a Surface on its own thread: the live wallpaper's, or the app's preview.
 * Frames are paced to the frame-rate setting on the display's vsync, drawn at the resolution setting
 * and scaled up; nothing at all is drawn while it's hidden.
 *
 * Phones' GPUs differ hugely, so every frame's GPU time is measured, and a shader that takes more than
 * a small share of the GPU is drawn at a lower resolution until it fits (and goes back up when there's
 * room, never above the setting). That keeps the launcher's own animations smooth over any wallpaper.
 * When the phone reports it's getting hot, the frame rate drops too.
 */
class GlRenderer(context: Context, private val tag: String) {
    private val app = context.applicationContext
    private val prefs = Prefs(app)
    private val thread = HandlerThread("LiteWallpaper GL $tag").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val power = app.getSystemService(PowerManager::class.java)
    @Volatile private var thermal = 0
    private val thermalListener: Any? = if (Build.VERSION.SDK_INT >= 29) {
        PowerManager.OnThermalStatusChangedListener { thermal = it }.also { power?.addThermalStatusListener({ handler.post(it) }, it) }
    } else null

    // Adaptive resolution (GL thread only): a share of the resolution setting, per wallpaper.
    private var autoScale = 1f
    private var gpuMs = -1f
    private var measured = 0
    private var skipMeasure = 0
    private var sampleFrames = 0
    private var lastPanDraw = 0L
    private var requestedRate = -1f
    private val debuggable = app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0

    /** Called on the main thread with a wallpaper's id once its first frame is on the surface. */
    @Volatile var onFirstFrame: ((String) -> Unit)? = null
    private var firstFramePending = false

    // Everything below is only touched on the GL thread.
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var config: EGLConfig? = null
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var idleSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var surface: Surface? = null
    private var width = 0
    private var height = 0
    private var visible = false
    private var wallpaper: Wallpaper? = null
    private var scene: Scene? = null
    private var sceneFailed = false
    private var vao = 0
    private var fbo = 0
    private var fboTex = 0
    private var fboW = 0
    private var fboH = 0
    private var time = 0.0
    private var lastDraw = 0L
    private var scheduled = false
    private var pagePan = -1f
    private var pixelDensity = app.resources.displayMetrics.density
    private val frameCallback = Choreographer.FrameCallback { onFrame(it) }

    fun setSurface(s: Surface) = handler.post {
        surface = s
        requestedRate = -1f
        makeWindowSurface()
        schedule()
    }

    fun setSize(w: Int, h: Int) = handler.post {
        width = w
        height = h
        lastDraw = 0
        schedule()
    }

    /** Must finish before the Surface goes away, so this waits for the GL thread (unless it has ended). */
    fun surfaceGone() {
        val done = CountDownLatch(1)
        val queued = handler.post {
            destroyWindowSurface()
            surface = null
            done.countDown()
        }
        if (queued) done.await(2, TimeUnit.SECONDS)
    }

    fun setVisible(v: Boolean) = handler.post {
        visible = v
        lastDraw = 0
        if (v) schedule()
    }

    fun setWallpaper(wp: Wallpaper) = handler.post {
        if (wp.id == wallpaper?.id && (scene != null || sceneFailed)) return@post
        wallpaper = wp
        releaseScene()
        time = 0.0
        lastDraw = 0
        firstFramePending = true
        autoScale = learnedScale[wp.id] ?: 1f
        gpuMs = -1f
        skipMeasure = 3
        schedule()
    }

    /** Where across a wide picture to look (0-1), from the home screen pages; < 0 = centre on its subject. */
    fun setPagePan(pan: Float) = handler.post {
        if (pan == pagePan) return@post
        pagePan = pan
        // Follow the finger, but at most 60 times a second: the launcher needs the GPU while you swipe.
        val now = System.nanoTime()
        if (visible && now - lastPanDraw >= 16_000_000L) {
            lastPanDraw = now
            drawNow()
        }
    }

    fun touch(x: Float, y: Float, down: Boolean, held: Boolean) = handler.post {
        val k = renderScale()
        scene?.touch(x * k, y * k, down, held)
    }

    fun release() = handler.post {
        if (Build.VERSION.SDK_INT >= 29) {
            (thermalListener as? PowerManager.OnThermalStatusChangedListener)?.let { power?.removeThermalStatusListener(it) }
        }
        releaseScene()
        destroyWindowSurface()
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (idleSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, idleSurface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        thread.quitSafely()
    }

    // ---------------------------------------------------------------- GL thread

    private fun initEgl(): Boolean {
        if (context != EGL14.EGL_NO_CONTEXT) return true
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] == 0) return false
        config = configs[0]
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (context == EGL14.EGL_NO_CONTEXT) return false
        // A tiny surface to keep the context current while there's no window (to free things).
        idleSurface = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        EGL14.eglMakeCurrent(display, idleSurface, idleSurface, context)
        val ids = IntArray(1)
        GLES30.glGenVertexArrays(1, ids, 0)
        vao = ids[0]
        return true
    }

    private fun makeWindowSurface() {
        val s = surface ?: return
        if (!initEgl()) {
            Log.e(TAG, "OpenGL ES 3.0 isn't available")
            return
        }
        destroyWindowSurface()
        windowSurface = EGL14.eglCreateWindowSurface(display, config, s, intArrayOf(EGL14.EGL_NONE), 0)
        if (windowSurface == EGL14.EGL_NO_SURFACE) Log.e(TAG, "Couldn't draw on the surface: ${EGL14.eglGetError()}")
        else EGL14.eglMakeCurrent(display, windowSurface, windowSurface, context)
    }

    private fun destroyWindowSurface() {
        if (windowSurface == EGL14.EGL_NO_SURFACE) return
        EGL14.eglMakeCurrent(display, idleSurface, idleSurface, context)
        EGL14.eglDestroySurface(display, windowSurface)
        windowSurface = EGL14.EGL_NO_SURFACE
    }

    private fun releaseScene() {
        if (context == EGL14.EGL_NO_CONTEXT) return
        scene?.release()
        scene = null
        sceneFailed = false
    }

    /**
     * The share of the screen's pixels drawn: the setting, lowered for a shader this GPU finds heavy.
     * (Particle effects are cheap to draw, and their simulation restarts when the size changes.)
     */
    private fun renderScale(): Float {
        val setting = prefs.resolution.coerceIn(0.3f, 1f)
        return if (wallpaper?.kind == Wallpaper.Kind.Particles) setting else (setting * autoScale).coerceAtLeast(MIN_SCALE)
    }

    /** The frame-rate setting, lowered while the phone is hot. */
    private fun fps(): Int {
        val fps = prefs.fps.coerceIn(5, 240)
        return when {
            thermal >= PowerManager.THERMAL_STATUS_SEVERE -> minOf(fps, 10)
            thermal >= PowerManager.THERMAL_STATUS_MODERATE -> minOf(fps, maxOf(10, fps / 2))
            else -> fps
        }
    }

    private fun schedule() {
        if (scheduled || !visible || windowSurface == EGL14.EGL_NO_SURFACE || width <= 0) return
        scheduled = true
        // Sleep until about a vsync before the next frame is due, rather than waking up on every
        // vsync (up to 120 times a second) only to find it isn't time yet.
        val waitMs = if (lastDraw == 0L) 0L else (lastDraw + 1_000_000_000L / fps() - System.nanoTime()) / 1_000_000L - 12
        if (waitMs > 0) Choreographer.getInstance().postFrameCallbackDelayed(frameCallback, waitMs)
        else Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    /**
     * Above 60 fps, asks Android to run the screen that fast while the wallpaper shows (90, 120, 144 Hz
     * screens); otherwise leaves the refresh rate to the system, which saves battery.
     */
    private fun requestRefreshRate(fps: Int) {
        val want = if (fps > 60) fps.toFloat() else 0f
        if (want == requestedRate || Build.VERSION.SDK_INT < 30) return
        requestedRate = want
        runCatching { surface?.setFrameRate(want, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
    }

    private fun onFrame(nanos: Long) {
        scheduled = false
        if (!visible || windowSurface == EGL14.EGL_NO_SURFACE) return
        requestRefreshRate(fps())
        val interval = 1e9 / fps()
        if (lastDraw != 0L && nanos - lastDraw < interval * 0.9) {  // not time yet: wait for a later vsync
            schedule()
            return
        }
        val dt = if (lastDraw == 0L) 0f else ((nanos - lastDraw) / 1e9).toFloat().coerceAtMost(0.1f)
        lastDraw = nanos
        draw(dt)
        schedule()
    }

    private fun drawNow() {
        if (windowSurface != EGL14.EGL_NO_SURFACE && width > 0) draw(0f)
    }

    private fun draw(dt: Float) {
        val wp = wallpaper ?: return
        if (scene == null && !sceneFailed) {
            scene = try {
                if (wp.kind == Wallpaper.Kind.Particles) ParticleScene(app, wp) else ShaderScene(app, wp, prefs)
            } catch (e: Exception) {
                Log.e(TAG, "Couldn't load ${wp.id}", e)
                sceneFailed = true
                null
            }
        }
        time += dt
        val start = System.nanoTime()
        val k = renderScale()
        val rw = (width * k).toInt().coerceAtLeast(1)
        val rh = (height * k).toInt().coerceAtLeast(1)
        val scaled = rw != width || rh != height
        if (scaled) {
            ensureFbo(rw, rh)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
        } else {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        }
        GLES30.glViewport(0, 0, rw, rh)
        GLES30.glBindVertexArray(vao)
        val s = scene
        if (s == null) {
            GLES30.glClearColor(0f, 0f, 0f, 1f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        } else {
            s.draw(Frame(rw, rh, dt, time, pagePan, pixelDensity * k))
        }
        if (scaled) {
            GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, fbo)
            GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0)
            GLES30.glBlitFramebuffer(0, 0, rw, rh, 0, 0, width, height, GLES30.GL_COLOR_BUFFER_BIT, GLES30.GL_LINEAR)
        }
        if (s != null && wp.kind == Wallpaper.Kind.Shader) fitGpuBudget(wp.id, start)
        if (!EGL14.eglSwapBuffers(display, windowSurface)) {
            val err = EGL14.eglGetError()
            if (err == EGL14.EGL_BAD_SURFACE || err == EGL14.EGL_BAD_NATIVE_WINDOW) destroyWindowSurface()
            else if (err == EGL14.EGL_CONTEXT_LOST) contextLost()
        } else if (firstFramePending && s != null) {
            firstFramePending = false
            val id = wp.id
            main.post { onFirstFrame?.invoke(id) }
        }
    }

    /**
     * On every 10th frame, waits for the frame to finish on the GPU (a fence; it's our own thread, and
     * there's a whole frame interval to spare), and adjusts the resolution so a frame stays within the
     * budget: at most 8 ms, or 30% of the frame interval at high frame rates. Only every 10th, because
     * some drivers wait by spinning the CPU. Pixel count goes with the square of the scale, hence the
     * square root.
     */
    private fun fitGpuBudget(id: String, start: Long) {
        if (++sampleFrames % 10 != 0) return
        val sync = GLES30.glFenceSync(GLES30.GL_SYNC_GPU_COMMANDS_COMPLETE, 0)
        if (sync == 0L) return
        val result = GLES30.glClientWaitSync(sync, GLES30.GL_SYNC_FLUSH_COMMANDS_BIT, 100_000_000L)
        GLES30.glDeleteSync(sync)
        if (result == GLES30.GL_WAIT_FAILED) return
        if (skipMeasure > 0) {  // first frames of a wallpaper or a new size: uploads, not representative
            skipMeasure--
            return
        }
        val ms = (System.nanoTime() - start) / 1e6f
        gpuMs = if (gpuMs < 0f) ms else gpuMs * 0.6f + ms * 0.4f
        if (++measured % 3 != 0) return
        if (debuggable && measured % 30 == 0) Log.d(TAG, "$tag: $id %.1f ms on the GPU at %d%%".format(gpuMs, (renderScale() * 100).toInt()))
        val budget = minOf(8f, 300f / fps())
        val setting = prefs.resolution.coerceIn(0.3f, 1f)
        val before = autoScale
        if (gpuMs > budget) {
            autoScale = (autoScale * sqrt(budget / gpuMs).coerceIn(0.7f, 0.95f)).coerceAtLeast(MIN_SCALE / setting)
        } else if (gpuMs < budget * 0.45f && autoScale < 1f) {
            autoScale = minOf(1f, autoScale * 1.08f)
        }
        if (autoScale != before) {
            learnedScale[id] = autoScale
            skipMeasure = 3
            Log.i(TAG, "$tag: $id took %.1f ms on the GPU; drawing at %d%% of the screen".format(gpuMs, (renderScale() * 100).toInt()))
        }
    }

    private fun ensureFbo(w: Int, h: Int) {
        if (fbo != 0 && fboW == w && fboH == h) return
        val ids = IntArray(1)
        if (fbo == 0) {
            GLES30.glGenFramebuffers(1, ids, 0)
            fbo = ids[0]
        }
        if (fboTex != 0) GLES30.glDeleteTextures(1, intArrayOf(fboTex), 0)
        GLES30.glGenTextures(1, ids, 0)
        fboTex = ids[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTex)
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, w, h)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, fboTex, 0)
        fboW = w
        fboH = h
    }

    /** The GPU dropped everything (rare): start again from scratch. */
    private fun contextLost() {
        scene = null
        sceneFailed = false
        fbo = 0
        fboTex = 0
        destroyWindowSurface()
        EGL14.eglDestroyContext(display, context)
        context = EGL14.EGL_NO_CONTEXT
        makeWindowSurface()
    }

    companion object {
        private const val TAG = "LiteWallpaper"
        private const val MIN_SCALE = 0.3f

        /** What each wallpaper settled at on this phone, shared by the wallpaper and the app's preview. */
        private val learnedScale = java.util.concurrent.ConcurrentHashMap<String, Float>()
    }
}
