package ai.arce.app.settings

import ai.arce.core.chat.GenerationSettings
import ai.arce.core.model.KvCacheType
import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

enum class GpuOffload { AUTO, CPU_ONLY, GPU_PRIORITY, MAX_GPU }
enum class ThemeMode { SYSTEM, LIGHT, DARK }

/** Every user setting (spec §8, §26). Basic ones first, developer ones after. */
data class AppSettings(
    // basic
    val thinking: Boolean = true,
    val searchEnabled: Boolean = true,
    val searxngUrl: String = "",
    val tone: String = "",
    val maxChars: Int = 0,
    val speedAccuracy: Float = 0.5f,
    val hyperLoad: Boolean = false,
    val notifications: Boolean = true,
    val backgroundGeneration: Boolean = true,
    val theme: ThemeMode = ThemeMode.SYSTEM,
    val agentOverride: String = "",
    val aiAgentSelection: Boolean = true,
    val lastModelPath: String = "",
    // developer
    val contextLength: Int = 4096,
    val threads: Int = 0,
    val batchSize: Int = 0,
    val gpuOffload: GpuOffload = GpuOffload.AUTO,
    val kvCache: KvCacheType = KvCacheType.F16,
    val maxTokens: Int = 2048,
    val retryLimit: Int = 2,
    val maxToolRounds: Int = 4,
    val forceExecution: Boolean = false,
    // updates
    val updateRepo: String = "keusidan/arce.ai",
    val updateIntervalHours: Int = 12,
    val updateWifiOnly: Boolean = true,
) {
    fun toGeneration(modelParamsB: Double?) = GenerationSettings(
        tone = tone.ifBlank { null },
        maxChars = maxChars,
        maxTokens = maxTokens,
        searchEnabled = searchEnabled,
        retryLimit = retryLimit,
        maxToolRounds = maxToolRounds,
        speedAccuracy = speedAccuracy,
        modelParamsB = modelParamsB,
        agentOverride = agentOverride.ifBlank { null },
        aiAgentSelection = aiAgentSelection,
    )

    /** Threads: explicit value, else all cores under HyperLoad, else half (spec §4 HyperLoad). */
    fun effectiveThreads(cores: Int): Int = when {
        threads > 0 -> threads
        hyperLoad -> cores.coerceAtLeast(1)
        else -> (cores / 2).coerceIn(2, 6)
    }

    fun gpuLayers(gpuAvailable: Boolean): Int = when (gpuOffload) {
        GpuOffload.CPU_ONLY -> 0
        GpuOffload.GPU_PRIORITY -> if (gpuAvailable) 999 else 0
        GpuOffload.MAX_GPU -> 999
        GpuOffload.AUTO -> if (gpuAvailable && hyperLoad) 999 else if (gpuAvailable) 20 else 0
    }
}

private val Context.store by preferencesDataStore(name = "settings")

class SettingsRepository(private val context: Context) {
    private object K {
        val thinking = booleanPreferencesKey("thinking")
        val search = booleanPreferencesKey("search")
        val searxng = stringPreferencesKey("searxng_url")
        val tone = stringPreferencesKey("tone")
        val maxChars = intPreferencesKey("max_chars")
        val speed = floatPreferencesKey("speed_accuracy")
        val hyper = booleanPreferencesKey("hyperload")
        val notify = booleanPreferencesKey("notifications")
        val background = booleanPreferencesKey("background")
        val theme = stringPreferencesKey("theme")
        val agent = stringPreferencesKey("agent")
        val aiAgent = booleanPreferencesKey("ai_agent_selection")
        val lastModel = stringPreferencesKey("last_model")
        val ctx = intPreferencesKey("context_length")
        val threads = intPreferencesKey("threads")
        val batch = intPreferencesKey("batch")
        val gpu = stringPreferencesKey("gpu_offload")
        val kv = stringPreferencesKey("kv_cache")
        val maxTokens = intPreferencesKey("max_tokens")
        val retries = intPreferencesKey("retries")
        val toolRounds = intPreferencesKey("tool_rounds")
        val force = booleanPreferencesKey("force_execution")
        val repo = stringPreferencesKey("update_repo")
        val interval = intPreferencesKey("update_interval")
        val wifi = booleanPreferencesKey("update_wifi_only")
    }

    val settings: Flow<AppSettings> = context.store.data.map { p -> read(p) }

    private fun read(p: Preferences): AppSettings {
        val d = AppSettings()
        return AppSettings(
            thinking = p[K.thinking] ?: d.thinking,
            searchEnabled = p[K.search] ?: d.searchEnabled,
            searxngUrl = p[K.searxng] ?: d.searxngUrl,
            tone = p[K.tone] ?: d.tone,
            maxChars = p[K.maxChars] ?: d.maxChars,
            speedAccuracy = p[K.speed] ?: d.speedAccuracy,
            hyperLoad = p[K.hyper] ?: d.hyperLoad,
            notifications = p[K.notify] ?: d.notifications,
            backgroundGeneration = p[K.background] ?: d.backgroundGeneration,
            theme = p[K.theme]?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() } ?: d.theme,
            agentOverride = p[K.agent] ?: d.agentOverride,
            aiAgentSelection = p[K.aiAgent] ?: d.aiAgentSelection,
            lastModelPath = p[K.lastModel] ?: d.lastModelPath,
            contextLength = p[K.ctx] ?: d.contextLength,
            threads = p[K.threads] ?: d.threads,
            batchSize = p[K.batch] ?: d.batchSize,
            gpuOffload = p[K.gpu]?.let { runCatching { GpuOffload.valueOf(it) }.getOrNull() } ?: d.gpuOffload,
            kvCache = p[K.kv]?.let { runCatching { KvCacheType.valueOf(it) }.getOrNull() } ?: d.kvCache,
            maxTokens = p[K.maxTokens] ?: d.maxTokens,
            retryLimit = p[K.retries] ?: d.retryLimit,
            maxToolRounds = p[K.toolRounds] ?: d.maxToolRounds,
            forceExecution = p[K.force] ?: d.forceExecution,
            updateRepo = p[K.repo] ?: d.updateRepo,
            updateIntervalHours = p[K.interval] ?: d.updateIntervalHours,
            updateWifiOnly = p[K.wifi] ?: d.updateWifiOnly,
        )
    }

    suspend fun update(change: (AppSettings) -> AppSettings) {
        context.store.edit { p ->
            val s = change(read(p))
            p[K.thinking] = s.thinking
            p[K.search] = s.searchEnabled
            p[K.searxng] = s.searxngUrl
            p[K.tone] = s.tone
            p[K.maxChars] = s.maxChars
            p[K.speed] = s.speedAccuracy
            p[K.hyper] = s.hyperLoad
            p[K.notify] = s.notifications
            p[K.background] = s.backgroundGeneration
            p[K.theme] = s.theme.name
            p[K.agent] = s.agentOverride
            p[K.aiAgent] = s.aiAgentSelection
            p[K.lastModel] = s.lastModelPath
            p[K.ctx] = s.contextLength
            p[K.threads] = s.threads
            p[K.batch] = s.batchSize
            p[K.gpu] = s.gpuOffload.name
            p[K.kv] = s.kvCache.name
            p[K.maxTokens] = s.maxTokens
            p[K.retries] = s.retryLimit
            p[K.toolRounds] = s.maxToolRounds
            p[K.force] = s.forceExecution
            p[K.repo] = s.updateRepo
            p[K.interval] = s.updateIntervalHours
            p[K.wifi] = s.updateWifiOnly
        }
    }
}
