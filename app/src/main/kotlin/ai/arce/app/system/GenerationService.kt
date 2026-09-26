package ai.arce.app.system

import ai.arce.app.ArceApp
import ai.arce.core.generation.TaskState
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Keeps the process in the foreground while a reply is generated, so switching apps does not
 * kill a long generation (spec §35). Shows progress in a notification and stops itself when
 * the Generation Task leaves the running states.
 */
class GenerationService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(
            this, Notifications.ID_GENERATION, Notifications.generation(this, "生成中…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
        val chat = (application as ArceApp).container.chat
        scope.launch {
            chat.state.collectLatest { state ->
                if (!state.isGenerating) {
                    stopSelf()
                    return@collectLatest
                }
                val label = when (state.task) {
                    TaskState.SEARCH -> "検索中…"
                    TaskState.THINKING -> "Thinking中…"
                    else -> "生成中… ${state.messages.lastOrNull()?.text?.length ?: 0}文字"
                }
                if (Notifications.canPost(this@GenerationService)) {
                    getSystemService(android.app.NotificationManager::class.java)
                        .notify(Notifications.ID_GENERATION, Notifications.generation(this@GenerationService, label))
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) {
            context.startForegroundService(Intent(context, GenerationService::class.java))
        }
    }
}
