package io.github.mybugga.litewallpaper

import android.app.WallpaperColors
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.service.wallpaper.WallpaperService
import android.view.MotionEvent
import android.view.SurfaceHolder
import androidx.core.content.ContextCompat

/**
 * The live wallpaper. Android only shows it on the home (and lock) screen, and tells it when it's
 * hidden, by an app or a game, so it draws nothing at all then. It also stops while battery saver is
 * on (by default), pans with the home screen pages, and lets you play with the particle effects.
 */
class LiteWallpaperService : WallpaperService() {
    override fun onCreateEngine(): Engine = LiteEngine()

    inner class LiteEngine : Engine(), SharedPreferences.OnSharedPreferenceChangeListener {
        private val prefs = Prefs(this@LiteWallpaperService)
        private val renderer = GlRenderer(this@LiteWallpaperService, "wallpaper")
        private val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        private var shown = false
        private var current = Catalog.find(this@LiteWallpaperService, prefs.wallpaper)
        private var touching = false

        private val saverReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = updateVisible()
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            setTouchEventsEnabled(true)
            setOffsetNotificationsEnabled(true)
            renderer.setWallpaper(current)
            prefs.sp.registerOnSharedPreferenceChangeListener(this)
            ContextCompat.registerReceiver(this@LiteWallpaperService, saverReceiver,
                IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        }

        override fun onDestroy() {
            prefs.sp.unregisterOnSharedPreferenceChangeListener(this)
            runCatching { unregisterReceiver(saverReceiver) }
            renderer.release()
            super.onDestroy()
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            renderer.setSurface(holder.surface)
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            super.onSurfaceChanged(holder, format, width, height)
            renderer.setSize(width, height)
        }

        // Drawing stops by itself without a surface, and starts again on the next one.
        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            renderer.surfaceGone()
            super.onSurfaceDestroyed(holder)
        }

        override fun onVisibilityChanged(visible: Boolean) {
            shown = visible
            updateVisible()
        }

        private fun updateVisible() {
            val saver = prefs.pauseInBatterySaver && power.isPowerSaveMode && !isPreview
            renderer.setVisible(shown && !saver)
        }

        override fun onOffsetsChanged(xOffset: Float, yOffset: Float, xStep: Float, yStep: Float, xPixels: Int, yPixels: Int) {
            // Launchers that scroll the wallpaper report a step between pages; the rest report 0.5 or nothing.
            val paging = prefs.followPages && xStep > 0f && xStep < 1f
            renderer.setPagePan(if (paging) xOffset else -1f)
        }

        override fun onTouchEvent(event: MotionEvent) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { touching = true; renderer.touch(event.x, event.y, down = true, held = true) }
                MotionEvent.ACTION_MOVE -> renderer.touch(event.x, event.y, down = false, held = true)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { touching = false; renderer.touch(event.x, event.y, down = false, held = false) }
            }
        }

        // Launchers send taps on empty home screen space this way too.
        override fun onCommand(action: String?, x: Int, y: Int, z: Int, extras: Bundle?, resultRequested: Boolean): Bundle? {
            if (action == "android.wallpaper.tap" && !touching) {
                renderer.touch(x.toFloat(), y.toFloat(), down = true, held = false)
            }
            return null
        }

        override fun onSharedPreferenceChanged(sp: SharedPreferences, key: String?) {
            if (key == Prefs.KEY_WALLPAPER) {
                current = Catalog.find(this@LiteWallpaperService, prefs.wallpaper)
                renderer.setWallpaper(current)
                if (Build.VERSION.SDK_INT >= 27) notifyColorsChanged()
            }
            if (key == "pauseInBatterySaver") updateVisible()
        }

        // Android 12+ themes the system (Material You) from these.
        @androidx.annotation.RequiresApi(27)
        override fun onComputeColors(): WallpaperColors? = runCatching {
            assets.open(current.thumbnail).use { BitmapFactory.decodeStream(it) }?.let { WallpaperColors.fromBitmap(it) }
        }.getOrNull()
    }
}
