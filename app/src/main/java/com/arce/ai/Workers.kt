package com.arce.ai

import android.content.Context
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkData
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

object Workers {

    private const val TAG = "arce_dl"

    private fun notifId(key: String): Int = TAG.hashCode() * 31 + key.hashCode()

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel("arce_progress") == null) {
                nm.createNotificationChannel(
                    NotificationChannel("arce_progress", "進捗", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
    }

    fun notifyProgress(ctx: Context, key: String, title: String, text: String, progress: Int?) {
        ensureChannel(ctx)
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = NotificationCompat.Builder(ctx, "arce_progress")
            .setSmallIcon(android.R.drawable.presence_online)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
        if (progress != null) b.setProgress(100, progress, false)
        // NotificationManager.notify(tag: String, id: Int, notification)
        nm.notify(key, notifId(key), b.build())
    }

    fun cancelProgress(ctx: Context, key: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(key, notifId(key))
    }

    fun scheduleDownload(app: ArceApp, model: ModelInfo) {
        val wm = WorkManager.getInstance(app)
        val data = workDataOf("model_id" to model.id)
        val req = OneTimeWorkRequestBuilder<ModelDownloadWorker>()
            .setInputData(data)
            .build()
        wm.enqueueUniqueWork("model_${model.id}", ExistingWorkPolicy.REPLACE, req)
    }
}

class ModelDownloadWorker(
    ctx: Context,
    params: WorkerParameters
) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as ArceApp
        val modelId = inputData.getString("model_id") ?: return Result.failure()
        val model = ModelInfo.byId(modelId) ?: return Result.failure()
        val file = app.modelFile(modelId)
        val tmp = File(file.parentFile, "$modelId.part")
        val key = "progress:$modelId"

        var lastError = ""
        var sameErrorStreak = 0

        for (attempt in 1..3) {
            try {
                Workers.notifyProgress(
                    applicationContext, key, "モデルダウンロード",
                    "${model.name} を取得中… (試行 $attempt/3)", 0
                )
                download(model.url, tmp, model, key)
                if (file.exists()) file.delete()
                if (!tmp.renameTo(file)) {
                    tmp.copyTo(file, overwrite = true)
                    tmp.delete()
                }
                Workers.notifyProgress(
                    applicationContext, key, "モデルダウンロード完了",
                    "${model.name} のインストールが完了しました", 100
                )
                return Result.success(workDataOf("ok" to "1"))
            } catch (e: Exception) {
                val msg = e.message ?: "unknown error"
                sameErrorStreak = if (msg == lastError) sameErrorStreak + 1 else 1
                lastError = msg
                tmp.delete()
                // 助言書準拠: 同一エラーで即停止
                if (sameErrorStreak >= 2 || attempt == 3) {
                    Workers.notifyProgress(
                        applicationContext, key, "モデルダウンロード失敗",
                        "$modelId: $msg", null
                    )
                    return Result.failure(workDataOf("error" to msg))
                }
            }
        }
        return Result.failure(workDataOf("error" to lastError))
    }

    private suspend fun download(url: String, file: File, model: ModelInfo, key: String) =
        withContext(Dispatchers.IO) {
            val conn = URL(url).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 30000
                conn.readTimeout = 60000
                conn.requestMethod = "GET"
                if (conn.responseCode != 200) error("HTTP ${conn.responseCode}")
                val total = conn.contentLength.toLong().coerceAtLeast(model.sizeMB * 1024 * 1024)
                conn.inputStream.use { input ->
                    file.outputStream().use { out ->
                        val buf = ByteArray(8192)
                        var readTotal = 0L
                        var lastPct = -1
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            readTotal += n
                            val pct = (readTotal * 100 / total).toInt().coerceIn(0, 100)
                            if (pct >= lastPct + 2) {
                                lastPct = pct
                                Workers.notifyProgress(
                                    applicationContext, key, "モデルダウンロード",
                                    "${model.name} ${pct}% (${readTotal / 1024 / 1024}MB)", pct
                                )
                            }
                            if (isStopped) error("キャンセルされました")
                        }
                    }
                }
            } finally {
                conn.disconnect()
            }
        }

    override fun getOutputData(): WorkData {
        // unused; results are read via WorkInfo observers in UI
        return Data.EMPTY
    }
}
