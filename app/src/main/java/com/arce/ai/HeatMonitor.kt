package com.arce.ai

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

/**
 * Battery temperature monitor (助言書: 強制モード以外では推論中にのみ監視).
 */
class HeatMonitor(private val app: ArceApp) {

    @Volatile
    var tempC: Int = 0

    @Volatile
    private var active = false

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var job: Job? = null

    fun startIfForced() {
        if (app.settings.forceTempMonitor) start()
    }

    fun start() {
        if (active) return
        active = true
        job = scope.launch {
            while (isActive) {
                poll()
                delay(10_000)
            }
        }
    }

    fun stop() {
        active = false
        job?.cancel()
        job = null
    }

    fun overThreshold(): Boolean = tempC >= app.settings.tempThreshold

    private fun poll() {
        try {
            val intent = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val raw = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0
            tempC = raw / 10
        } catch (_: Exception) {
        }
    }
}
