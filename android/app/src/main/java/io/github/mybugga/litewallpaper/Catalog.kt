package io.github.mybugga.litewallpaper

import android.content.Context
import org.json.JSONArray

/** One bundled wallpaper, as listed in assets/wallpapers.json (made by scripts/convert-for-android.py). */
data class Wallpaper(
    val id: String,
    val name: String,
    val kind: Kind,
    val file: String,
    val textures: List<String>,
    /** Width / height of the picture (or 16:9 for shaders without one): a phone shows a slice of it. */
    val aspect: Float,
    /** Where across the picture its subject is (0-1); a tall screen centres on it. */
    val focus: Float,
    val description: String,
) {
    enum class Kind { Shader, Particles }

    val thumbnail get() = "thumbs/$id.webp"
}

object Catalog {
    const val DEFAULT = "dragon"

    @Volatile private var cached: List<Wallpaper>? = null

    fun all(context: Context): List<Wallpaper> = cached ?: synchronized(this) {
        cached ?: load(context.applicationContext).also { cached = it }
    }

    fun find(context: Context, id: String?): Wallpaper {
        val list = all(context)
        return list.firstOrNull { it.id == id } ?: list.firstOrNull { it.id == DEFAULT } ?: list.first()
    }

    private fun load(context: Context): List<Wallpaper> {
        val arr = JSONArray(context.assets.open("wallpapers.json").bufferedReader().use { it.readText() })
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Wallpaper(
                id = o.getString("id"),
                name = o.getString("name"),
                kind = if (o.getString("kind") == "particles") Wallpaper.Kind.Particles else Wallpaper.Kind.Shader,
                file = o.getString("file"),
                textures = o.optJSONArray("textures")?.let { t -> (0 until t.length()).map { t.getString(it) } } ?: emptyList(),
                aspect = o.optDouble("aspect", 16.0 / 9).toFloat(),
                focus = o.optDouble("focus", 0.5).toFloat(),
                description = o.optString("description"),
            )
        }
    }
}
