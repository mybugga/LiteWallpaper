package io.github.mybugga.litewallpaper

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.widget.Toast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Updates from this project's GitHub releases, like the Windows app: finds the newest release's
 * LiteWallpaper-x.y.z.apk, downloads it, checks the SHA-256 GitHub publishes for it, and hands it to
 * Android's installer (which asks you to confirm). Local "dev" builds never offer updates.
 */
object Updater {
    private const val API = "https://api.github.com/repos/mybugga/LiteWallpaper/releases/latest"

    /** MainActivity receives what Android's installer reports with this action. */
    const val ACTION_INSTALL_STATUS = "io.github.mybugga.litewallpaper.INSTALL_STATUS"

    class Release(val version: String, val apkUrl: String, val sha256: String?, val size: Long)

    fun currentVersion(context: Context): String =
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "dev"

    fun supported(context: Context) = currentVersion(context) != "dev"

    private fun updatesDir(context: Context) = File(context.cacheDir, "updates")

    /** The newest release when it's newer than this app, else null. */
    suspend fun check(context: Context): Release? = withContext(Dispatchers.IO) {
        val conn = (URL(API).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 15000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "LiteWallpaper-Android/${currentVersion(context)}")
        }
        try {
            if (conn.responseCode != 200) return@withContext null
            val root = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            val version = root.optString("tag_name").removePrefix("v")
            if (!newer(version, currentVersion(context))) {
                updatesDir(context).deleteRecursively()  // up to date: drop any old download
                return@withContext null
            }
            val assets = root.optJSONArray("assets") ?: return@withContext null
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                val name = a.optString("name")
                if (name.startsWith("LiteWallpaper-") && name.endsWith(".apk")) {
                    val digest = a.optString("digest").takeIf { it.startsWith("sha256:") }?.removePrefix("sha256:")?.lowercase()
                    return@withContext Release(version, a.getString("browser_download_url"), digest, a.optLong("size"))
                }
            }
            null
        } finally {
            conn.disconnect()
        }
    }

    /** "1.3.0" > "1.2.9". */
    fun newer(a: String, b: String): Boolean {
        val x = a.split(".").map { it.toIntOrNull() ?: 0 }
        val y = b.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d > 0
        }
        return false
    }

    private fun sha256(file: File): String {
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                sha.update(buf, 0, n)
            }
        }
        return sha.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Downloads the release into the app's cache, checking its SHA-256; reports progress 0-1. A copy
     * already downloaded and checked (a second try, say after allowing installs) is used again.
     */
    suspend fun download(context: Context, release: Release, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val dir = updatesDir(context)
        val file = File(dir, "LiteWallpaper-${release.version}.apk")
        if (file.exists() && release.sha256 != null && sha256(file) == release.sha256) {
            progress(1f)
            return@withContext file
        }
        dir.deleteRecursively()
        dir.mkdirs()
        val conn = (URL(release.apkUrl).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 30000
            setRequestProperty("User-Agent", "LiteWallpaper-Android/${currentVersion(context)}")
        }
        val sha = MessageDigest.getInstance("SHA-256")
        try {
            if (conn.responseCode != 200) throw IllegalStateException("GitHub replied with HTTP ${conn.responseCode}")
            val total = if (release.size > 0) release.size else conn.contentLengthLong
            conn.inputStream.use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    var done = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        sha.update(buf, 0, n)
                        done += n
                        if (total > 0) progress(done.toFloat() / total)
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
        val hex = sha.digest().joinToString("") { "%02x".format(it) }
        if (release.sha256 != null && hex != release.sha256) {
            file.delete()
            throw IllegalStateException("The download was damaged (its checksum doesn't match).")
        }
        file
    }

    /**
     * Hands the checked download to Android's installer, which asks you to confirm. The APK goes into
     * an install session of our own, so exactly these bytes get installed: Android's installer keeps
     * copies from attempts abandoned at "allow installs", and can otherwise install one of those.
     */
    suspend fun install(context: Context, apk: File) = withContext(Dispatchers.IO) {
        val installer = context.packageManager.packageInstaller
        installer.mySessions.forEach { runCatching { installer.abandonSession(it.sessionId) } }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("base.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out, 256 * 1024) }
                session.fsync(out)
            }
            val status = PendingIntent.getActivity(
                context, id, Intent(context, MainActivity::class.java).setAction(ACTION_INSTALL_STATUS),
                PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
            )
            session.commit(status.intentSender)
        }
    }

    /** What Android's installer reports back: it needs you to confirm, or it failed (and why). */
    fun onInstallStatus(activity: Activity, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.let { runCatching { activity.startActivity(it) } }
            }
            PackageInstaller.STATUS_SUCCESS, PackageInstaller.STATUS_FAILURE_ABORTED -> {}  // updated, or you said no
            else -> Toast.makeText(
                activity, "The update didn't install: " + (intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown error"),
                Toast.LENGTH_LONG,
            ).show()
        }
    }
}
