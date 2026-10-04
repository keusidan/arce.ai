package ai.arce.app.bridge

import ai.arce.app.update.ApkInstaller
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Device facts and APK installation for the Dart side (`ai.arce.app/system`). */
class SystemBridge(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val installer = ApkInstaller(context)

    init {
        MethodChannel(messenger, "ai.arce.app/system").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "memory" -> {
                    val manager = context.getSystemService(ActivityManager::class.java)
                    val info = ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
                    result.success(mapOf("total" to info.totalMem, "available" to info.availMem, "low" to info.lowMemory))
                }
                "freeStorage" -> {
                    val dir = File(call.argument<String>("path")!!)
                    // the model directory may not exist yet; ask about the closest folder that does
                    var existing: File? = dir
                    while (existing != null && !existing.exists()) existing = existing.parentFile
                    result.success(StatFs((existing ?: context.filesDir).absolutePath).availableBytes)
                }
                "soc" -> result.success("${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")
                "canInstall" -> result.success(installer.canInstall())
                "requestInstall" -> {
                    context.startActivity(installer.permissionIntent())
                    result.success(null)
                }
                "install" -> {
                    installer.install(File(call.argument<String>("path")!!))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("system_error", e.message ?: e.javaClass.simpleName, null)
        }
    }
}
