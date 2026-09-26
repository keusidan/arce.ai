package ai.arce.app.system

import ai.arce.app.MainActivity
import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

object Notifications {
    const val CHANNEL_GENERATION = "generation"
    const val CHANNEL_UPDATES = "updates"
    const val CHANNEL_DOWNLOADS = "downloads"

    const val ID_GENERATION = 1
    const val ID_UPDATE = 2
    const val ID_DOWNLOAD = 3

    const val EXTRA_SCREEN = "screen"

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(CHANNEL_GENERATION, "生成の進捗", NotificationManager.IMPORTANCE_LOW),
                NotificationChannel(CHANNEL_UPDATES, "アップデート", NotificationManager.IMPORTANCE_DEFAULT),
                NotificationChannel(CHANNEL_DOWNLOADS, "ダウンロード", NotificationManager.IMPORTANCE_LOW),
            ),
        )
    }

    fun openApp(context: Context, screen: String? = null): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply { screen?.let { putExtra(EXTRA_SCREEN, it) } }
        return PendingIntent.getActivity(
            context, screen.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun canPost(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun generation(context: Context, text: String) =
        NotificationCompat.Builder(context, CHANNEL_GENERATION)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("ARCE.AI")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp(context))
            .build()

    fun post(context: Context, id: Int, channel: String, title: String, text: String, screen: String? = null, progress: Pair<Long, Long>? = null) {
        if (!canPost(context)) return
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(progress == null)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp(context, screen))
        progress?.let { (done, total) ->
            val percent = if (total > 0) (done * 100 / total).toInt() else 0
            builder.setProgress(100, percent, total <= 0).setOngoing(true)
        }
        @Suppress("MissingPermission") // checked by canPost
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    fun cancel(context: Context, id: Int) = NotificationManagerCompat.from(context).cancel(id)
}
