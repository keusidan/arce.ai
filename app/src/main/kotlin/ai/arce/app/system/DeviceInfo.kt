package ai.arce.app.system

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import java.io.File
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

data class MemoryInfo(val totalBytes: Long, val availableBytes: Long, val lowMemory: Boolean)

/** Hardware facts used by the model list, settings and Diagnostics (spec §30). */
class DeviceInfo(private val context: Context) {
    private val activityManager = context.getSystemService(ActivityManager::class.java)
    private val powerManager = context.getSystemService(PowerManager::class.java)

    val cores: Int get() = Runtime.getRuntime().availableProcessors()

    fun memory(): MemoryInfo {
        val info = ActivityManager.MemoryInfo().also { activityManager.getMemoryInfo(it) }
        return MemoryInfo(info.totalMem, info.availMem, info.lowMemory)
    }

    fun freeStorageBytes(dir: File): Long = StatFs(dir.absolutePath).availableBytes

    /** Highest Vulkan version the device declares, e.g. "1.3", or null. */
    fun vulkanVersion(): String? {
        val features = context.packageManager.systemAvailableFeatures
        val v = features.firstOrNull { it.name == PackageManager.FEATURE_VULKAN_HARDWARE_VERSION }?.version ?: return null
        return "${v ushr 22}.${(v ushr 12) and 0x3ff}"
    }

    /** Vendors ship OpenCL as a native library; Android itself does not guarantee it. */
    fun openClLibrary(): String? = listOf(
        "/vendor/lib64/libOpenCL.so", "/system/vendor/lib64/libOpenCL.so", "/system/lib64/libOpenCL.so",
    ).firstOrNull { File(it).exists() }

    fun soc(): String = "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"

    /**
     * Seconds of work at the current load before throttling, as a fraction (1.0 = throttling
     * starts). NaN when the device does not report it.
     */
    fun thermalHeadroom(): Float = powerManager.getThermalHeadroom(10)

    fun thermalStatus(): Int = powerManager.currentThermalStatus

    /** Emits PowerManager.THERMAL_STATUS_* values as they change (spec §28). */
    fun thermalStatusFlow(): Flow<Int> = callbackFlow {
        val listener = PowerManager.OnThermalStatusChangedListener { trySend(it) }
        powerManager.addThermalStatusListener(context.mainExecutor, listener)
        awaitClose { powerManager.removeThermalStatusListener(listener) }
    }

    companion object {
        fun thermalLabel(status: Int): String = when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "正常"
            PowerManager.THERMAL_STATUS_LIGHT -> "やや高温"
            PowerManager.THERMAL_STATUS_MODERATE -> "高温（性能低下の可能性）"
            PowerManager.THERMAL_STATUS_SEVERE -> "かなり高温（性能低下中）"
            PowerManager.THERMAL_STATUS_CRITICAL -> "危険"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "緊急"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "シャットダウン直前"
            else -> "不明"
        }
    }
}
