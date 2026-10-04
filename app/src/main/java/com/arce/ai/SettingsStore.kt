package com.arce.ai

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

class SettingsStore(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("arce_settings", Context.MODE_PRIVATE)

    var selectedModelId: String
        get() = prefs.getString("selected_model", "qwen2.5-0.5b-instruct-q4_k_m")!!
        set(v) = prefs.edit().putString("selected_model", v).apply()

    var hyperLoad: Boolean
        get() = prefs.getBoolean("hyper_load", false)
        set(v) = prefs.edit().putBoolean("hyper_load", v).apply()

    var nThreads: Int
        get() = prefs.getInt("threads", 4)
        set(v) = prefs.edit().putInt("threads", v).apply()

    var nGpuLayers: Int
        get() = prefs.getInt("gpu_layers", 99)
        set(v) = prefs.edit().putInt("gpu_layers", v).apply()

    var tempThreshold: Int
        get() = prefs.getInt("temp_threshold", 45)
        set(v) = prefs.edit().putInt("temp_threshold", v).apply()

    var forceTempMonitor: Boolean
        get() = prefs.getBoolean("force_temp_monitor", false)
        set(v) = prefs.edit().putBoolean("force_temp_monitor", v).apply()

    // Capability cache (one probe at startup, then grey-out from cache) 助言書準拠
    var capabilityCache: String?
        get() = prefs.getString("capability_cache", null)
        set(v) = prefs.edit().putString("capability_cache", v).apply()

    fun backends(): List<BackendInfo> {
        val s = capabilityCache ?: return emptyList()
        return try {
            val arr = JSONArray(s)
            (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                BackendInfo(o.getString("name"), o.getString("type"))
            }
        } catch (_: Exception) { emptyList() }
    }

    fun storeBackends(list: List<BackendInfo>) {
        val arr = JSONArray()
        list.forEach { arr.put(JSONObject().put("name", it.name).put("type", it.type)) }
        capabilityCache = arr.toString()
    }

    fun update(block: () -> Unit) { block(); }
}
