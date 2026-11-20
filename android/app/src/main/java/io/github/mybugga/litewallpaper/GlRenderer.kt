package io.github.mybugga.litewallpaper

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Draws a wallpaper into a Surface on its own thread: the live wallpaper's, or the app's preview.
 * Frames are paced to the frame-rate setting on the display's vsync, drawn at the resolution setting
 * and scaled up; nothing at all is drawn while it's hidden.
 */
class GlRenderer(context: Context, private val tag: String) {
    private val app = context.applicationContext
    private val prefs = Prefs(app)
    private val thread = HandlerThread("LiteWallpaper GL $tag").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())

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
        schedule()
    }

    /** Where across a wide picture to look (0-1), from the home screen pages; < 0 = centre on its subject. */
    fun setPagePan(pan: Float) = handler.post {
        if (pan == pagePan) return@post
        pagePan = pan
        if (visible) drawNow()
    }

    fun touch(x: Float, y: Float, down: Boolean, held: Boolean) = handler.post {
        val k = renderScale()
        scene?.touch(x * k, y * k, down, held)
    }

    fun release() = handler.post {
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

    private fun renderScale() = prefs.resolution.coerceIn(0.3f, 1f)

    private fun schedule() {
        if (scheduled || !visible || windowSurface == EGL14.EGL_NO_SURFACE || width <= 0) return
        scheduled = true
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun onFrame(nanos: Long) {
        scheduled = false
        if (!visible || windowSurface == EGL14.EGL_NO_SURFACE) return
        val interval = 1e9 / prefs.fps.coerceIn(5, 120)
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
    }
}
