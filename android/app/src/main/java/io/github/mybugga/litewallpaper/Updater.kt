package io.github.mybugga.litewallpaper

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
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

    class Release(val version: String, val apkUrl: String, val sha256: String?, val size: Long)

    fun currentVersion(context: Context): String =
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "dev"

    fun supported(context: Context) = currentVersion(context) != "dev"

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
            val assets = root.optJSONArray("assets") ?: return@withContext null
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                val name = a.optString("name")
                if (name.startsWith("LiteWallpaper-") && name.endsWith(".apk")) {
                    val digest = a.optString("digest").takeIf { it.startsWith("sha256:") }?.removePrefix("sha256:")?.lowercase()
                    val release = Release(version, a.getString("browser_download_url"), digest, a.optLong("size"))
                    return@withContext if (newer(version, currentVersion(context))) release else null
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

    /** Downloads the release into the app's cache, checking its SHA-256; reports progress 0-1. */
    suspend fun download(context: Context, release: Release, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
        val file = File(dir, "LiteWallpaper-${release.version}.apk")
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

    /** Opens Android's installer for the downloaded update. */
    fun install(context: Context, apk: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
