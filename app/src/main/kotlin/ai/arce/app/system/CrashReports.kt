package ai.arce.app.system

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.text.DateFormat
import java.util.Date

/**
 * Explains the last abnormal exit on the next launch, without adb: Java crashes are written by
 * an uncaught-exception handler, and Android's ApplicationExitInfo tells native crashes
 * (llama.cpp), low-memory kills and ANRs apart.
 */
class CrashReports(private val context: Context) {
    private val javaTrace = File(context.filesDir, "last_crash.txt")
    private val prefs = context.getSharedPreferences("crash_reports", Context.MODE_PRIVATE)

    fun install() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                javaTrace.writeText("${System.currentTimeMillis()}\nthread: ${thread.name}\n${error.stackTraceToString()}")
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** A report of the newest abnormal exit not shown yet, or null. */
    fun pending(): String? {
        val seen = prefs.getLong(KEY_SEEN, 0L)
        val exit = context.getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(context.packageName, 0, 10)
            .firstOrNull { it.timestamp > seen && it.reason in ABNORMAL && it.processName == context.packageName }
            ?: return null
        return report(exit)
    }

    /** The most recent abnormal exit, shown or not (for the diagnostics screen). */
    fun latest(): String? = context.getSystemService(ActivityManager::class.java)
        .getHistoricalProcessExitReasons(context.packageName, 0, 10)
        .firstOrNull { it.reason in ABNORMAL }
        ?.let(::report)

    fun markSeen() = prefs.edit().putLong(KEY_SEEN, System.currentTimeMillis()).apply()

    private fun report(exit: ApplicationExitInfo): String = buildString {
        appendLine("時刻: ${DateFormat.getDateTimeInstance().format(Date(exit.timestamp))}")
        appendLine("理由: ${reasonLabel(exit.reason)}")
        if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) appendLine("シグナル: ${exit.status}${signalName(exit.status)}")
        exit.description?.let { appendLine("詳細: $it") }
        appendLine("プロセス: ${exit.processName}  PSS: ${exit.pss / 1024} MB  RSS: ${exit.rss / 1024} MB")
        appendLine("端末: ${Build.MANUFACTURER} ${Build.MODEL} / Android ${Build.VERSION.RELEASE} / ABI ${Build.SUPPORTED_ABIS.joinToString()}")
        when (exit.reason) {
            ApplicationExitInfo.REASON_CRASH -> javaTrace.takeIf { it.exists() }?.readText()?.lines()
                // only the trace written for this exit, not an older one
                ?.takeIf { lines -> lines.first().toLongOrNull()?.let { kotlin.math.abs(it - exit.timestamp) < 60_000 } == true }
                ?.let { lines ->
                    appendLine("--- Java stack ---")
                    append(lines.drop(1).take(60).joinToString("\n"))
                }
            // The native trace is a tombstone protobuf; its readable strings carry the backtrace.
            ApplicationExitInfo.REASON_CRASH_NATIVE -> runCatching { exit.traceInputStream?.use { it.readBytes() } }.getOrNull()?.let { bytes ->
                appendLine("--- native backtrace (抜粋) ---")
                append(readableStrings(bytes).filter { ".so" in it || "(" in it }.distinct().take(40).joinToString("\n"))
            }
            ApplicationExitInfo.REASON_LOW_MEMORY ->
                append("RAM不足でAndroidに終了させられました。小さいモデル、短いContext Length、KV Cache Q8_0を試してください。")
        }
    }.trimEnd()

    companion object {
        private const val KEY_SEEN = "seen_until"
        private val ABNORMAL = setOf(
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
        )

        fun reasonLabel(reason: Int) = when (reason) {
            ApplicationExitInfo.REASON_CRASH -> "Javaの例外（アプリのバグ）"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "ネイティブのクラッシュ（llama.cpp などC++側）"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "メモリ不足による強制終了"
            ApplicationExitInfo.REASON_ANR -> "応答なし（ANR）"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "初期化の失敗"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "リソースの使いすぎ"
            else -> "その他 ($reason)"
        }

        private fun signalName(status: Int) = when (status) {
            4 -> "（SIGILL: CPUが実行できない命令）"
            6 -> "（SIGABRT: 異常終了の呼び出し）"
            7 -> "（SIGBUS）"
            11 -> "（SIGSEGV: 不正なメモリアクセス）"
            else -> ""
        }

        private fun readableStrings(bytes: ByteArray): List<String> {
            val out = mutableListOf<String>()
            val current = StringBuilder()
            for (b in bytes) {
                val c = b.toInt() and 0xFF
                if (c in 0x20..0x7E) current.append(c.toChar()) else {
                    if (current.length >= 6) out += current.toString()
                    current.setLength(0)
                }
            }
            if (current.length >= 6) out += current.toString()
            return out
        }
    }
}
