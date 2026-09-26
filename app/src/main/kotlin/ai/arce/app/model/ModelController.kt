package ai.arce.app.model

import ai.arce.app.engine.RoutingEngine
import ai.arce.app.settings.AppSettings
import ai.arce.app.system.DeviceInfo
import ai.arce.app.system.Notifications
import ai.arce.core.engine.LoadParams
import ai.arce.core.model.MemoryEstimator
import ai.arce.core.model.ModelCatalog
import ai.arce.core.model.ModelSpec
import android.content.Context
import android.net.Uri
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Shown instead of loading when the estimate exceeds free RAM (spec §27, §34). */
data class MemoryWarning(val file: File, val estimatedBytes: Long, val availableBytes: Long)

data class ModelState(
    val installed: List<File> = emptyList(),
    val loadedPath: String? = null,
    val loadedName: String? = null,
    val loadedParamsB: Double? = null,
    val busy: String? = null,
    val error: String? = null,
    val memoryWarning: MemoryWarning? = null,
    val downloads: Map<String, DownloadState> = emptyMap(),
    val gpuDevices: List<String> = emptyList(),
    /** "llama.cpp" or "LiteRT-LM (GPU)" */
    val backend: String? = null,
)

class ModelController(
    private val context: Context,
    private val engine: RoutingEngine,
    private val device: DeviceInfo,
    private val settings: StateFlow<AppSettings>,
    private val scope: CoroutineScope,
) {
    val store = ModelStore(context)
    private val downloader = ModelDownloader(store.directory)
    private val jobs = mutableMapOf<String, Job>()

    private val _state = MutableStateFlow(ModelState(installed = store.list()))
    val state: StateFlow<ModelState> = _state.asStateFlow()

    /** NPU builds are offered only on the SoC they were compiled for. */
    val catalog: List<ModelSpec> get() = ModelCatalog.all.filter { spec ->
        spec.npuSoc == null || device.soc().contains(spec.npuSoc, ignoreCase = true)
    }

    val basic: ModelSpec get() = ModelCatalog.basic

    fun refresh() = _state.update { it.copy(installed = store.list(), gpuDevices = gpuDevices()) }

    private fun gpuDevices() = runCatching { engine.llama.devices() }.getOrDefault(emptyList()).filterNot { it.startsWith("CPU") }

    /** Estimated RAM for a file: catalog figures when known, otherwise size plus a KV-cache margin. */
    fun estimateBytes(file: File): Long {
        val s = settings.value
        val spec = ModelCatalog.byFileName(file.name)
        return spec?.let { MemoryEstimator.totalBytes(it, s.contextLength, s.kvCache) }
            ?: (file.length() + file.length() / 5)
    }

    /** Whether a catalog model should be offered (greyed out otherwise, unless Force Execution is on). */
    fun fits(spec: ModelSpec): Boolean =
        MemoryEstimator.fits(spec, settings.value.contextLength, settings.value.kvCache, device.memory().totalBytes)

    fun load(file: File, confirmed: Boolean = false) {
        val s = settings.value
        val estimate = estimateBytes(file)
        val available = device.memory().availableBytes
        if (estimate > available && !confirmed) {
            // Never change the user's settings automatically; explain and let them decide.
            _state.update { it.copy(memoryWarning = MemoryWarning(file, estimate, available)) }
            return
        }
        _state.update { it.copy(memoryWarning = null, busy = "${file.name} を読み込み中…", error = null) }
        scope.launch {
            try {
                val gpu = gpuDevices()
                engine.load(
                    LoadParams(
                        path = file.absolutePath,
                        contextLength = s.contextLength,
                        threads = s.effectiveThreads(device.cores),
                        batchSize = s.batchSize,
                        gpuLayers = s.gpuLayers(gpu.isNotEmpty()),
                        kvCache = s.kvCache,
                    ),
                )
                _state.update {
                    it.copy(
                        loadedPath = file.absolutePath, loadedName = file.nameWithoutExtension,
                        loadedParamsB = ModelCatalog.byFileName(file.name)?.paramsB ?: paramsB(file.name), busy = null, gpuDevices = gpu,
                        backend = engine.activeName,
                    )
                }
                rememberLastModel(file.absolutePath)
            } catch (e: Exception) {
                _state.update { it.copy(loadedPath = null, loadedName = null, busy = null, error = e.message) }
            }
        }
    }

    fun dismissMemoryWarning() = _state.update { it.copy(memoryWarning = null) }

    private var remember: (suspend (String) -> Unit)? = null
    fun onRemember(block: suspend (String) -> Unit) { remember = block }
    private suspend fun rememberLastModel(path: String) = remember?.invoke(path)

    /** Reloads the model used last time, without the memory prompt only when it fits. */
    suspend fun restoreLastModel() {
        refresh()
        val path = settings.value.lastModelPath.ifBlank { return }
        val file = File(path)
        if (file.exists() && estimateBytes(file) <= device.memory().availableBytes) load(file)
    }

    fun import(uri: Uri) = scope.launch {
        try {
            val file = store.import(uri) { copied -> _state.update { it.copy(busy = "コピー中… ${copied / 1_000_000} MB") } }
            _state.update { it.copy(busy = null) }
            refresh()
            load(file)
        } catch (e: Exception) {
            _state.update { it.copy(busy = null, error = e.message) }
        }
    }

    fun delete(file: File) {
        if (file.absolutePath == _state.value.loadedPath) return
        file.delete()
        File(file.path + ".part").delete()
        refresh()
    }

    /**
     * One tap from an empty app to a working chat: downloads the basic model (Qwen3.5-0.8B)
     * if needed and loads it as soon as it is verified.
     */
    fun addBasicModel() {
        val file = fileOf(basic)
        if (file.exists()) load(file) else startDownload(basic, loadWhenDone = true)
    }

    // --- downloads (spec §19: user-driven pause/resume, capacity check, integrity check) ---

    fun startDownload(spec: ModelSpec, loadWhenDone: Boolean = false) {
        if (jobs[spec.id]?.isActive == true) return
        jobs[spec.id] = scope.launch {
            try {
                val remote = downloader.remote(spec)
                val already = downloader.partial(spec).takeIf { it.exists() }?.length() ?: 0L
                val free = device.freeStorageBytes(store.directory)
                if (remote.sizeBytes - already > free) {
                    setDownload(spec, DownloadState.Failed("空き容量が不足しています（必要 ${gb(remote.sizeBytes - already)} / 空き ${gb(free)}）"))
                    return@launch
                }
                setDownload(spec, DownloadState.Running(already, remote.sizeBytes))
                val part = downloader.download(spec, remote) { done, total ->
                    setDownload(spec, DownloadState.Running(done, total))
                    Notifications.post(context, Notifications.ID_DOWNLOAD, Notifications.CHANNEL_DOWNLOADS,
                        "${spec.displayName} をダウンロード中", "${gb(done)} / ${gb(total)}", screen = "models", progress = done to total)
                }
                setDownload(spec, DownloadState.Verifying)
                downloader.install(spec, remote, part)
                setDownload(spec, DownloadState.Installed)
                Notifications.cancel(context, Notifications.ID_DOWNLOAD)
                refresh()
                // Load right away when asked to, or when nothing is loaded yet.
                if (loadWhenDone || _state.value.loadedPath == null) load(downloader.target(spec))
            } catch (e: kotlinx.coroutines.CancellationException) {
                val part = downloader.partial(spec)
                setDownload(spec, DownloadState.Paused(part.length(), spec.fileBytes, null))
                Notifications.cancel(context, Notifications.ID_DOWNLOAD)
                throw e
            } catch (e: Exception) {
                val part = downloader.partial(spec)
                setDownload(
                    spec,
                    if (part.exists()) DownloadState.Paused(part.length(), spec.fileBytes, e.message) else DownloadState.Failed(e.message ?: "error"),
                )
                Notifications.cancel(context, Notifications.ID_DOWNLOAD)
            }
        }
    }

    /** Pausing keeps the partial file; nothing resumes until the user presses Resume. */
    fun pauseDownload(spec: ModelSpec) {
        jobs.remove(spec.id)?.cancel()
    }

    fun verify(spec: ModelSpec) = scope.launch {
        setDownload(spec, DownloadState.Verifying)
        val ok = runCatching { downloader.verify(spec, downloader.remote(spec)) }.getOrDefault(false)
        setDownload(spec, if (ok) DownloadState.Installed else DownloadState.Failed("整合性チェックに失敗（破損の可能性）。削除して再取得してください"))
    }

    fun downloadStateOf(spec: ModelSpec): DownloadState = _state.value.downloads[spec.id]
        ?: when {
            downloader.target(spec).exists() -> DownloadState.Installed
            downloader.partial(spec).exists() -> DownloadState.Paused(downloader.partial(spec).length(), spec.fileBytes, null)
            else -> DownloadState.Idle
        }

    fun fileOf(spec: ModelSpec) = downloader.target(spec)

    private fun setDownload(spec: ModelSpec, state: DownloadState) =
        _state.update { it.copy(downloads = it.downloads + (spec.id to state)) }

    fun environmentJson(s: AppSettings): String = buildJsonObject {
        put("model", _state.value.loadedName)
        put("backend", _state.value.backend)
        put("contextLength", s.contextLength)
        put("threads", s.effectiveThreads(device.cores))
        put("batch", s.batchSize)
        put("gpuOffload", s.gpuOffload.name)
        put("kvCache", s.kvCache.name)
        put("hyperLoad", s.hyperLoad)
        put("speedAccuracy", s.speedAccuracy)
        put("thinking", s.thinking)
        put("schema", ai.arce.core.protocol.Protocol.SCHEMA_VERSION)
    }.toString()

    companion object {
        fun gb(bytes: Long) = "%.2f GB".format(bytes / 1e9)

        /** "Qwen3-8B-Q4_K_M.gguf" -> 8.0 */
        fun paramsB(name: String): Double? =
            Regex("(\\d+(?:\\.\\d+)?)[bB](?![a-zA-Z])").find(name)?.groupValues?.get(1)?.toDoubleOrNull()
    }
}
