package io.github.mybugga.litewallpaper

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.GLES30
import android.opengl.GLUtils
import org.json.JSONArray

/** OpenGL ES 3.0 helpers: programs, textures and pictures (still or split-up GIFs). */
object Gl {
    /** A triangle covering the screen; vUv is 0-1 with (0, 0) at the top left, as on Windows. */
    const val FULLSCREEN_VS = """#version 300 es
out vec2 vUv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    vUv = vec2(p.x, 1.0 - p.y);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""

    fun shader(type: Int, source: String): Int {
        val s = GLES30.glCreateShader(type)
        GLES30.glShaderSource(s, source)
        GLES30.glCompileShader(s)
        val ok = IntArray(1)
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES30.glGetShaderInfoLog(s)
            GLES30.glDeleteShader(s)
            throw IllegalStateException("Shader compile failed: $log")
        }
        return s
    }

    fun program(vertex: String, fragment: String): Int {
        val vs = shader(GLES30.GL_VERTEX_SHADER, vertex)
        val fs = shader(GLES30.GL_FRAGMENT_SHADER, fragment)
        val p = GLES30.glCreateProgram()
        GLES30.glAttachShader(p, vs)
        GLES30.glAttachShader(p, fs)
        GLES30.glLinkProgram(p)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES30.glGetProgramInfoLog(p)
            GLES30.glDeleteProgram(p)
            throw IllegalStateException("Shader link failed: $log")
        }
        return p
    }

    /** Decodes a picture from the app's assets, no larger than [maxSide] on its longer side. */
    fun bitmap(context: Context, path: String, maxSide: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.assets.open(path).use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val bmp = context.assets.open(path).use { BitmapFactory.decodeStream(it, null, opts) }
            ?: throw IllegalStateException("Couldn't read $path")
        val longer = maxOf(bmp.width, bmp.height)
        if (longer <= maxSide) return bmp
        val k = maxSide.toFloat() / longer
        return Bitmap.createScaledBitmap(bmp, (bmp.width * k).toInt().coerceAtLeast(1), (bmp.height * k).toInt().coerceAtLeast(1), true)
            .also { if (it !== bmp) bmp.recycle() }
    }

    /** Uploads a bitmap (premultiplied alpha, top row first: (0, 0) samples its top left, as on Windows). */
    fun texture(bitmap: Bitmap, repeat: Boolean = false): Texture {
        val ids = IntArray(1)
        GLES30.glGenTextures(1, ids, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, ids[0])
        val wrap = if (repeat) GLES30.GL_REPEAT else GLES30.GL_CLAMP_TO_EDGE
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, wrap)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, wrap)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
        return Texture(ids[0], bitmap.width, bitmap.height)
    }

    /** A still picture, or a GIF the conversion script split into frames ("<name>.gif.frames/"). */
    fun picture(context: Context, path: String, maxSide: Int, repeat: Boolean = false): Picture {
        if (!path.endsWith(".gif", ignoreCase = true)) {
            val bmp = bitmap(context, path, maxSide)
            return Picture(listOf(texture(bmp, repeat).also { bmp.recycle() }), floatArrayOf(1f))
        }
        val dir = "$path.frames"
        val delays = JSONArray(context.assets.open("$dir/delays.json").bufferedReader().use { it.readText() })
        val frames = (0 until delays.length()).map { i ->
            val bmp = bitmap(context, "$dir/$i.png", maxSide)
            texture(bmp, repeat).also { bmp.recycle() }
        }
        return Picture(frames, FloatArray(delays.length()) { delays.getDouble(it).toFloat() })
    }
}

class Texture(val id: Int, val width: Int, val height: Int) {
    fun release() = GLES30.glDeleteTextures(1, intArrayOf(id), 0)
}

/** One or more frames, each shown for its delay, looping. */
class Picture(private val frames: List<Texture>, private val delays: FloatArray) {
    private val cycle = delays.sum()
    val width get() = frames[0].width
    val height get() = frames[0].height

    fun at(time: Double): Texture {
        if (frames.size == 1 || cycle <= 0f) return frames[0]
        var t = (time % cycle).toFloat()
        for (i in frames.indices) {
            if (t < delays[i]) return frames[i]
            t -= delays[i]
        }
        return frames.last()
    }

    fun release() = frames.forEach { it.release() }
}
