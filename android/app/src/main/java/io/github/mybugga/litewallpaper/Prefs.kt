package io.github.mybugga.litewallpaper

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/** The user's choices, shared by the app and the wallpaper service (which watches for changes). */
class Prefs(context: Context) {
    val sp: SharedPreferences = context.applicationContext.getSharedPreferences("litewallpaper", Context.MODE_PRIVATE)

    /** The wallpaper in use. */
    var wallpaper: String
        get() = sp.getString(KEY_WALLPAPER, null) ?: Catalog.DEFAULT
        set(v) = sp.edit { putString(KEY_WALLPAPER, v) }

    /** Frames per second. Lower uses less battery. */
    var fps: Int
        get() = sp.getInt("fps", 30)
        set(v) = sp.edit { putInt("fps", v) }

    /** Render resolution (share of the screen's pixels each way). Phones' screens are dense, so less is plenty. */
    var resolution: Float
        get() = sp.getFloat("resolution", 0.75f)
        set(v) = sp.edit { putFloat("resolution", v) }

    /** Stop animating while the phone's battery saver is on. */
    var pauseInBatterySaver: Boolean
        get() = sp.getBoolean("pauseInBatterySaver", true)
        set(v) = sp.edit { putBoolean("pauseInBatterySaver", v) }

    /**
     * Pan across the picture as you swipe between home screen pages (when the launcher reports them).
     * Off by default: launchers put the first page at the picture's left edge, away from its subject.
     */
    var followPages: Boolean
        get() = sp.getBoolean("followPages", false)
        set(v) = sp.edit { putBoolean("followPages", v) }

    // Per-wallpaper tweaks, as in the Windows settings window.
    fun speed(id: String) = sp.getFloat("speed:$id", 1f)
    fun hue(id: String) = sp.getFloat("hue:$id", 0f)
    fun saturation(id: String) = sp.getFloat("saturation:$id", 1f)
    fun brightness(id: String) = sp.getFloat("brightness:$id", 1f)
    fun setTweak(key: String, id: String, value: Float) = sp.edit { putFloat("$key:$id", value) }
    fun resetTweaks(id: String) = sp.edit { listOf("speed", "hue", "saturation", "brightness").forEach { remove("$it:$id") } }

    companion object {
        const val KEY_WALLPAPER = "wallpaper"
    }
}
