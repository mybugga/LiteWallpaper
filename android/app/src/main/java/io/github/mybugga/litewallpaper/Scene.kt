package io.github.mybugga.litewallpaper

import android.content.Context
import android.opengl.GLES30

/** What one frame is drawn with. Sizes are in the pixels being rendered (after the resolution setting). */
class Frame(
    val width: Int,
    val height: Int,
    /** Seconds since the last frame. */
    val dt: Float,
    /** Seconds this wallpaper has been showing (it stops while hidden). */
    val time: Double,
    /** Where across a wide picture this screen sits (0-1), from the home screen pages; < 0 = centre on its subject. */
    val pagePan: Float,
    /** Device pixels per CSS pixel, for particles.js sizes; includes the resolution setting. */
    val pixelRatio: Float,
)

/**
 * The RGB rainbow mode, as on Windows (rainbow.hlsli): 0 off, 1 cycle, 2 wave. Speed 1 goes once
 * round the rainbow every 6 seconds.
 */
object Rainbow {
    /** (hue angle, wave in radians across the screen, on, 0) at this moment. */
    fun at(mode: Int, speed: Float, seconds: Double, out: FloatArray) {
        if (mode == 0) {
            out.fill(0f)
            return
        }
        val turns = seconds * speed / 6.0
        out[0] = ((turns - Math.floor(turns)) * 2 * Math.PI).toFloat()
        out[1] = if (mode == 2) (2 * Math.PI).toFloat() else 0f
        out[2] = 1f
        out[3] = 0f
    }

    /** The same color change for one flat color (the middle of the screen, for the wave). */
    fun apply(rb: FloatArray, c: FloatArray) {
        if (rb[2] == 0f) return
        val a = rb[0] + rb[1] * 0.5f
        val ca = kotlin.math.cos(a)
        val sa = kotlin.math.sin(a)
        val k = 0.57735f
        val kc = k * (c[0] + c[1] + c[2])
        val cross = floatArrayOf(k * (c[2] - c[1]), k * (c[0] - c[2]), k * (c[1] - c[0]))
        val hi = maxOf(c[0], c[1], c[2])
        val lo = minOf(c[0], c[1], c[2])
        val grey = if (hi > 0f) 1f - (hi - lo) / hi else 1f
        val luma = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]
        for (i in 0..2) {
            val r = c[i] * ca + cross[i] * sa + k * kc * (1 - ca)
            val tint = (0.5f + 0.5f * kotlin.math.cos(a + 2.0944f * i)) * luma * 2
            c[i] = (r + (tint - r) * grey * 0.65f).coerceIn(0f, 1f)
        }
    }
}

/** A wallpaper drawn with OpenGL ES into the current framebuffer. */
interface Scene {
    fun draw(frame: Frame)

    /** A finger on the wallpaper (render pixels): down = it just touched, held = still touching. */
    fun touch(x: Float, y: Float, down: Boolean, held: Boolean) {}

    fun release()
}

/**
 * A shader wallpaper: the Windows shader converted to GLSL ES (assets/shaders/<name>.frag). A phone's
 * screen is tall, so it shows a slice of the wide picture: around its subject, or wherever the home
 * screen pages have scrolled to.
 */
class ShaderScene(context: Context, private val wallpaper: Wallpaper, private val prefs: Prefs, tall: Boolean) : Scene {
    /** The version for this screen's shape (a picture made for tall screens, if there is one). */
    val variant = wallpaper.variant(tall)
    private val program: Int
    private val textures: List<Texture>
    private val locRes: Int
    private val locTime: Int
    private val locFrame: Int
    private val locUv: Int
    private val locAdjust: Int
    private val locView: Int
    private val locRainbow: Int
    private val locDate: Int
    private val calendar = java.util.Calendar.getInstance()
    private val rainbow = FloatArray(4)
    private var rainbowTime = 0.0
    private val locTex = IntArray(2)
    private var time = 0.0
    private var frames = 0

    init {
        val source = context.assets.open(variant.file).bufferedReader().use { it.readText() }
        program = Gl.program(Gl.FULLSCREEN_VS, source)
        locRes = GLES30.glGetUniformLocation(program, "G.iResolution")
        locTime = GLES30.glGetUniformLocation(program, "G.iTime")
        locFrame = GLES30.glGetUniformLocation(program, "G.iFrame")
        locUv = GLES30.glGetUniformLocation(program, "G._uvXform")
        locAdjust = GLES30.glGetUniformLocation(program, "G._adjust")
        locView = GLES30.glGetUniformLocation(program, "V._view")
        locRainbow = GLES30.glGetUniformLocation(program, "G._rainbow")
        locDate = GLES30.glGetUniformLocation(program, "G.iDate")
        locTex[0] = GLES30.glGetUniformLocation(program, "iChannel0")
        locTex[1] = GLES30.glGetUniformLocation(program, "iChannel1")
        textures = variant.textures.take(2).map { path ->
            val bmp = Gl.bitmap(context, path, MAX_TEXTURE)
            Gl.texture(bmp).also { bmp.recycle() }
        }
    }

    override fun draw(frame: Frame) {
        val id = wallpaper.id
        time += frame.dt * prefs.speed(id)
        rainbowTime += frame.dt  // the rainbow keeps its own pace, whatever the wallpaper's speed
        frames++
        val w = frame.width.toFloat()
        val h = frame.height.toFloat()
        // The whole picture, as wide as its own shape at this height; this screen is a window onto it.
        val wide = maxOf(w, h * variant.aspect)
        val spare = wide - w
        val offset = if (frame.pagePan >= 0f) frame.pagePan * spare else (variant.focus * wide - w / 2).coerceIn(0f, spare)

        GLES30.glUseProgram(program)
        GLES30.glUniform2f(locRes, wide, h)
        GLES30.glUniform1f(locTime, time.toFloat())
        GLES30.glUniform1f(locFrame, frames.toFloat())
        GLES30.glUniform4f(locUv, 1f, 1f, 0f, 0f)
        GLES30.glUniform4f(locAdjust, Math.toRadians(prefs.hue(id).toDouble()).toFloat(), prefs.saturation(id), prefs.brightness(id), 0f)
        GLES30.glUniform4f(locView, offset, 0f, 0f, 0f)
        Rainbow.at(prefs.rainbow(id), prefs.rainbowSpeed(id), rainbowTime, rainbow)
        GLES30.glUniform4f(locRainbow, rainbow[0], rainbow[1], rainbow[2], rainbow[3])
        if (locDate >= 0) {  // clocks: the local date and time, like Shadertoy's iDate
            calendar.timeInMillis = System.currentTimeMillis()
            val secs = calendar.get(java.util.Calendar.HOUR_OF_DAY) * 3600f + calendar.get(java.util.Calendar.MINUTE) * 60f +
                calendar.get(java.util.Calendar.SECOND) + calendar.get(java.util.Calendar.MILLISECOND) / 1000f
            GLES30.glUniform4f(locDate, calendar.get(java.util.Calendar.YEAR).toFloat(),
                (calendar.get(java.util.Calendar.MONTH) + 1).toFloat(), calendar.get(java.util.Calendar.DAY_OF_MONTH).toFloat(), secs)
        }
        textures.forEachIndexed { i, t ->
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + i)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t.id)
            GLES30.glUniform1i(locTex[i], i)
        }
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
    }

    override fun release() {
        GLES30.glDeleteProgram(program)
        textures.forEach { it.release() }
    }

    companion object {
        /** Big enough for a phone screen's slice of the picture to stay sharp. */
        const val MAX_TEXTURE = 2560
    }
}
