package ai.arce.app.sandbox

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/** Sends one run request to a sandbox service and waits for its reply. */
class SandboxClient(private val context: Context) {

    suspend fun runPython(code: String, timeoutMs: Long = SandboxService.DEFAULT_TIMEOUT_MS): RunResult =
        run(PythonSandboxService::class.java, timeoutMs, Bundle().apply { putString(PythonSandboxService.KEY_CODE, code) })

    suspend fun runDex(dex: ByteArray, mainClass: String, timeoutMs: Long = SandboxService.DEFAULT_TIMEOUT_MS): RunResult =
        run(JavaSandboxService::class.java, timeoutMs, Bundle().apply {
            putByteArray(JavaSandboxService.KEY_DEX, dex)
            putString(JavaSandboxService.KEY_MAIN, mainClass)
        })

    private suspend fun run(service: Class<out SandboxService>, timeoutMs: Long, data: Bundle): RunResult {
        data.putLong(SandboxService.KEY_TIMEOUT, timeoutMs)
        // The service enforces the limit itself; this margin covers process start-up (Python's is slow the first time).
        return withTimeoutOrNull(timeoutMs + 60_000) { exchange(service, data) }
            ?: RunResult(false, "サンドボックスが応答しませんでした", timedOut = true)
    }

    private suspend fun exchange(service: Class<out SandboxService>, data: Bundle): RunResult =
        suspendCancellableCoroutine { cont ->
            var connection: ServiceConnection? = null
            fun finish(result: RunResult) {
                connection?.let { runCatching { context.unbindService(it) } }
                connection = null
                if (cont.isActive) cont.resume(result)
            }
            val replies = Messenger(Handler(Looper.getMainLooper()) { msg ->
                if (msg.what == SandboxService.MSG_RESULT) {
                    val d = msg.data
                    finish(RunResult(d.getBoolean(SandboxService.KEY_OK), d.getString(SandboxService.KEY_OUTPUT).orEmpty(), d.getBoolean(SandboxService.KEY_TIMED_OUT)))
                }
                true
            })
            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder) {
                    val msg = Message.obtain(null, SandboxService.MSG_RUN).apply {
                        this.data = data
                        replyTo = replies
                    }
                    runCatching { Messenger(binder).send(msg) }.onFailure { finish(RunResult(false, "送信に失敗しました: ${it.message}")) }
                }
                override fun onServiceDisconnected(name: ComponentName?) {
                    // Expected after a run (the process exits); only an error when no reply came.
                    finish(RunResult(false, "サンドボックスのプロセスが終了しました（メモリ不足やクラッシュの可能性）"))
                }
            }
            connection = conn
            if (!context.bindService(Intent(context, service), conn, Context.BIND_AUTO_CREATE)) {
                finish(RunResult(false, "サンドボックスを起動できませんでした"))
            }
            cont.invokeOnCancellation { Handler(Looper.getMainLooper()).post { connection?.let { runCatching { context.unbindService(it) } } } }
        }
}
