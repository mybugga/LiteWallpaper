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
class ShaderScene(context: Context, private val wallpaper: Wallpaper, private val prefs: Prefs) : Scene {
    private val program: Int
    private val textures: List<Texture>
    private val locRes: Int
    private val locTime: Int
    private val locFrame: Int
    private val locUv: Int
    private val locAdjust: Int
    private val locView: Int
    private val locTex = IntArray(2)
    private var time = 0.0
    private var frames = 0

    init {
        val source = context.assets.open(wallpaper.file).bufferedReader().use { it.readText() }
        program = Gl.program(Gl.FULLSCREEN_VS, source)
        locRes = GLES30.glGetUniformLocation(program, "G.iResolution")
        locTime = GLES30.glGetUniformLocation(program, "G.iTime")
        locFrame = GLES30.glGetUniformLocation(program, "G.iFrame")
        locUv = GLES30.glGetUniformLocation(program, "G._uvXform")
        locAdjust = GLES30.glGetUniformLocation(program, "G._adjust")
        locView = GLES30.glGetUniformLocation(program, "V._view")
        locTex[0] = GLES30.glGetUniformLocation(program, "iChannel0")
        locTex[1] = GLES30.glGetUniformLocation(program, "iChannel1")
        textures = wallpaper.textures.take(2).map { path ->
            val bmp = Gl.bitmap(context, path, MAX_TEXTURE)
            Gl.texture(bmp).also { bmp.recycle() }
        }
    }

    override fun draw(frame: Frame) {
        val id = wallpaper.id
        time += frame.dt * prefs.speed(id)
        frames++
        val w = frame.width.toFloat()
        val h = frame.height.toFloat()
        // The whole picture, as wide as its own shape at this height; this screen is a window onto it.
        val wide = maxOf(w, h * wallpaper.aspect)
        val spare = wide - w
        val offset = if (frame.pagePan >= 0f) frame.pagePan * spare else (wallpaper.focus * wide - w / 2).coerceIn(0f, spare)

        GLES30.glUseProgram(program)
        GLES30.glUniform2f(locRes, wide, h)
        GLES30.glUniform1f(locTime, time.toFloat())
        GLES30.glUniform1f(locFrame, frames.toFloat())
        GLES30.glUniform4f(locUv, 1f, 1f, 0f, 0f)
        GLES30.glUniform4f(locAdjust, Math.toRadians(prefs.hue(id).toDouble()).toFloat(), prefs.saturation(id), prefs.brightness(id), 0f)
        GLES30.glUniform4f(locView, offset, 0f, 0f, 0f)
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
