package com.arce.ai

import android.app.Application
import android.os.Environment
import android.util.Log
import androidx.work.Configuration
import androidx.work.WorkManager
import java.io.File

class ArceApp : Application() {

    val settings by lazy { SettingsStore(this) }
    val history by lazy { HistoryStore(this) }
    val engine by lazy { ChatEngine(this) }
    val previewServer by lazy { LocalPreviewServer(File(generatedDir(), "preview")) }
    val heatMonitor by lazy { HeatMonitor(this) }

    companion object {
        @Volatile
        var instance: ArceApp? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        try {
            WorkManager.initialize(
                this,
                Configuration.Builder().setMinimumLoggingLevel(Log.ERROR).build()
            )
        } catch (_: Throwable) {
        }
        try {
            previewServer.start()
        } catch (_: Throwable) {
        }
    }

    fun generatedDir(): File {
        val base = getExternalFilesDir(null) ?: File(filesDir, "files")
        return File(base, "generated").also { it.mkdirs() }
    }

    fun modelDir(): File {
        val base = getExternalFilesDir(null) ?: File(filesDir, "files")
        return File(base, "models").also { it.mkdirs() }
    }

    fun modelFile(id: String): File = File(modelDir(), "$id.gguf")

    fun dataDirLabel(): String =
        "${Environment.getExternalStorageDirectory().absolutePath}/Android/data/$packageName/files/"
}
