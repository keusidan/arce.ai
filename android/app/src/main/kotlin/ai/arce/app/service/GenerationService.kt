package ai.arce.app.service

import ai.arce.app.MainActivity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process (and the HTTP request it is waiting on) alive while a reply is generated
 * or an update is downloaded and the screen is not in front. The notification is the only UI:
 * it says what is running and offers a stop button, which the app treats like its own stop
 * button for a reply.
 */
class GenerationService : Service() {
    companion object {
        const val ACTION_START = "ai.arce.app.action.START_GENERATION"
        const val ACTION_STOP = "ai.arce.app.action.STOP_GENERATION"

        /** What the service is kept alive for: [KIND_UPDATE], [KIND_MODEL] or anything else (a reply). */
        const val EXTRA_KIND = "kind"
        private const val KIND_UPDATE = "update"
        private const val KIND_MODEL = "modelDownload"

        private const val CHANNEL_ID = "generation"
        private const val NOTIFICATION_ID = 4101
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "生成",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "返信の生成中に表示します"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, notification(intent?.getStringExtra(EXTRA_KIND)))
        return START_NOT_STICKY
    }

    private fun notification(kind: String?): Notification {
        val updating = kind == KIND_UPDATE
        val model = kind == KIND_MODEL
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, GenerationService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(
                when {
                    updating -> "ARCE.AI を更新中"
                    model -> "モデルをダウンロード中"
                    else -> "ARCE.AI が生成中"
                },
            )
            .setContentText(
                when {
                    updating -> "他のアプリを開いてもダウンロードを続けます"
                    model -> "他のアプリを開いてもダウンロードを続けます"
                    else -> "画面を閉じても返信を続けます"
                },
            )
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "停止", stop).build())
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
