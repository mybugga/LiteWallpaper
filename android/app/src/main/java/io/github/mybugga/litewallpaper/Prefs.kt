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

    /** Check for a newer version about once a day and show a notification (release builds only). */
    var updateNotifications: Boolean
        get() = sp.getBoolean("updateNotifications", true)
        set(v) = sp.edit { putBoolean("updateNotifications", v) }

    /** The last version a notification was shown for, so each is only announced once. */
    var notifiedVersion: String?
        get() = sp.getString("notifiedVersion", null)
        set(v) = sp.edit { putString("notifiedVersion", v) }

    /** Whether Android 13+'s notification permission has been asked for (asked once, never nagged). */
    var askedNotifications: Boolean
        get() = sp.getBoolean("askedNotifications", false)
        set(v) = sp.edit { putBoolean("askedNotifications", v) }

    // Per-wallpaper tweaks, as in the Windows settings window.
    fun speed(id: String) = sp.getFloat("speed:$id", 1f)
    fun hue(id: String) = sp.getFloat("hue:$id", 0f)
    fun saturation(id: String) = sp.getFloat("saturation:$id", 1f)
    fun brightness(id: String) = sp.getFloat("brightness:$id", 1f)
    fun setTweak(key: String, id: String, value: Float) = sp.edit { putFloat("$key:$id", value) }
    fun resetTweaks(id: String) = sp.edit {
        listOf("speed", "hue", "saturation", "brightness", "rainbow", "rainbowSpeed").forEach { remove("$it:$id") }
    }

    /** RGB rainbow colors, for any wallpaper: 0 off, 1 cycle (every color together), 2 wave (sweeping across). */
    fun rainbow(id: String) = sp.getInt("rainbow:$id", 0)
    fun setRainbow(id: String, mode: Int) = sp.edit { putInt("rainbow:$id", mode) }
    fun rainbowSpeed(id: String) = sp.getFloat("rainbowSpeed:$id", 1f)

    companion object {
        const val KEY_WALLPAPER = "wallpaper"
    }
}
