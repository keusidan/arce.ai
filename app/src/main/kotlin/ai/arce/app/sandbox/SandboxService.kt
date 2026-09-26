package ai.arce.app.sandbox

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Result of running generated code in a sandbox process. */
data class RunResult(val ok: Boolean, val output: String, val timedOut: Boolean = false)

/**
 * Runs generated code in a separate process, one request at a time, and replies with what it
 * printed. When the time limit passes, it replies and then kills its own process, which is the
 * only reliable way to stop code stuck in a loop.
 */
abstract class SandboxService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var messenger: Messenger

    /** Runs the request on a worker thread; returns (success, output). */
    protected abstract fun execute(data: Bundle): Pair<Boolean, String>

    override fun onCreate() {
        super.onCreate()
        thread = HandlerThread("sandbox").apply { start() }
        messenger = Messenger(Handler(thread.looper) { msg -> handle(msg); true })
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun handle(msg: Message) {
        if (msg.what != MSG_RUN) return
        val replyTo = msg.replyTo ?: return
        val data = msg.data
        val timeoutMs = data.getLong(KEY_TIMEOUT, DEFAULT_TIMEOUT_MS)

        val done = CountDownLatch(1)
        var result: Pair<Boolean, String> = false to ""
        val worker = Thread({
            result = try {
                execute(data)
            } catch (t: Throwable) {
                false to (t.stackTraceToString().take(8000))
            }
            done.countDown()
        }, "sandbox-run")
        worker.isDaemon = true
        worker.start()

        val finished = done.await(timeoutMs, TimeUnit.MILLISECONDS)
        val reply = Message.obtain(null, MSG_RESULT).apply {
            this.data = Bundle().apply {
                putBoolean(KEY_OK, finished && result.first)
                putString(KEY_OUTPUT, if (finished) result.second else "${timeoutMs / 1000}秒の制限時間を超えたため停止しました")
                putBoolean(KEY_TIMED_OUT, !finished)
            }
        }
        try {
            replyTo.send(reply)
        } catch (_: RemoteException) {
            // the app went away; nothing to report to
        }
        // Stray threads, System.setOut and loaded classes must not leak into the next run.
        thread.looper.queue.addIdleHandler {
            Handler(thread.looper).postDelayed({ Process.killProcess(Process.myPid()) }, 200)
            false
        }
    }

    companion object {
        const val MSG_RUN = 1
        const val MSG_RESULT = 2
        const val KEY_TIMEOUT = "timeoutMs"
        const val KEY_OK = "ok"
        const val KEY_OUTPUT = "output"
        const val KEY_TIMED_OUT = "timedOut"
        const val DEFAULT_TIMEOUT_MS = 20_000L
        const val MAX_OUTPUT = 64 * 1024
    }
}
