package io.github.mybugga.litewallpaper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

/**
 * About once a day, while the phone is online, asks GitHub whether there's a newer release and, if
 * so, shows a notification (once per version). Tapping it opens the app, where the Update button is.
 * Android runs it whenever suits the battery; nothing stays running in between.
 */
class UpdateCheckJob : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onStartJob(params: JobParameters): Boolean {
        scope.launch {
            try {
                runCatching { Updater.check(this@UpdateCheckJob)?.let { notify(this@UpdateCheckJob, it) } }
                    .onFailure { Log.w("LiteWallpaper", "Update check failed", it) }
            } finally {
                jobFinished(params, false)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        scope.coroutineContext.cancelChildren()
        return true  // try again later
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val JOB_ID = 1
        private const val CHANNEL = "updates"
        private const val NOTIFICATION_ID = 1

        /**
         * Schedules or cancels the daily check to match the setting. Cheap, so it's called often. Never
         * throws: a check that can't be scheduled must not take the app or the wallpaper down with it.
         */
        fun sync(context: Context) {
            runCatching {
                val jobs = context.getSystemService(JobScheduler::class.java) ?: return
                if (!Updater.supported(context) || !Prefs(context).updateNotifications) {
                    jobs.cancel(JOB_ID)
                    return
                }
                if (jobs.getPendingJob(JOB_ID) != null) return
                jobs.schedule(
                    JobInfo.Builder(JOB_ID, ComponentName(context, UpdateCheckJob::class.java))
                        .setPeriodic(TimeUnit.HOURS.toMillis(24), TimeUnit.HOURS.toMillis(6))
                        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                        .setPersisted(true)  // survives restarts
                        .build(),
                )
            }.onFailure { Log.w("LiteWallpaper", "Couldn't schedule the update check", it) }
        }

        private fun notify(context: Context, release: Updater.Release) {
            val prefs = Prefs(context)
            val notifications = context.getSystemService(NotificationManager::class.java) ?: return
            if (prefs.notifiedVersion == release.version || !notifications.areNotificationsEnabled()) return
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL, "Updates", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "A new version of LiteWallpaper is available" },
            )
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            notifications.notify(
                NOTIFICATION_ID,
                Notification.Builder(context, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle("LiteWallpaper ${release.version} is available")
                    .setContentText("Tap to open LiteWallpaper and update.")
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .build(),
            )
            prefs.notifiedVersion = release.version
        }

        /** The app is open: its own banner takes over from the notification. */
        fun clear(context: Context) {
            context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        }
    }
}
