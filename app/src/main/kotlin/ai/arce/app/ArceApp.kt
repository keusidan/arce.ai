package ai.arce.app

import ai.arce.app.data.ArceDatabase
import ai.arce.app.data.ConversationEntity
import ai.arce.app.data.SecretStore
import ai.arce.app.engine.LlamaCppEngine
import ai.arce.app.model.ModelController
import ai.arce.app.settings.AppSettings
import ai.arce.app.settings.SettingsRepository
import ai.arce.app.system.ConsentManager
import ai.arce.app.system.DeviceInfo
import ai.arce.app.system.GenerationService
import ai.arce.app.system.Notifications
import ai.arce.app.update.UpdateManager
import ai.arce.core.chat.ChatController
import ai.arce.core.chat.ConversationSnapshot
import ai.arce.core.chat.ConversationStore
import ai.arce.core.chat.Role
import ai.arce.core.net.UrlConnectionHttp
import ai.arce.core.tools.DefaultToolRuntime
import ai.arce.core.tools.DuckDuckGoInstantProvider
import ai.arce.core.tools.OpenMeteoWeather
import ai.arce.core.tools.SearXngProvider
import ai.arce.core.tools.SearchService
import ai.arce.core.tools.ToolRuntime
import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

class ArceApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        container = AppContainer(this)
    }
}

/** A generation that was still running when the app last stopped (spec §25.1). */
data class InterruptedConversation(val id: Long, val title: String)

/**
 * Application-wide objects. The chat and the loaded model live here rather than in an
 * Activity, so a generation survives rotation and backgrounding.
 */
class AppContainer(val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    val settingsRepository = SettingsRepository(app)
    val settings: StateFlow<AppSettings> = settingsRepository.settings.stateIn(scope, SharingStarted.Eagerly, AppSettings())

    val db = ArceDatabase.create(app)
    val secrets = SecretStore(app)
    val device = DeviceInfo(app)
    val consent = ConsentManager(db.consents())
    val updates = UpdateManager(app)
    val engine = LlamaCppEngine()
    val models = ModelController(app, engine, device, settings, scope)

    private val http = UrlConnectionHttp()

    // One writer at a time, in order: the first save of a new chat must get its id before the next.
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val dbWriter = Dispatchers.IO.limitedParallelism(1)

    /** Built per call so a changed SearXNG address or search switch applies immediately. */
    private val toolRuntime = ToolRuntime { call ->
        val s = settings.value
        val providers = buildList {
            if (s.searxngUrl.isNotBlank()) add(SearXngProvider(s.searxngUrl, http))
            add(DuckDuckGoInstantProvider(http))
        }
        DefaultToolRuntime(
            search = if (s.searchEnabled) SearchService(providers, retriesPerProvider = s.retryLimit.coerceIn(0, 3)) else null,
            weather = OpenMeteoWeather(http),
        ).run(call)
    }

    private val _conversationId = MutableStateFlow<Long?>(null)
    val conversationId: StateFlow<Long?> = _conversationId.asStateFlow()

    private val _interrupted = MutableStateFlow<InterruptedConversation?>(null)
    val interrupted: StateFlow<InterruptedConversation?> = _interrupted.asStateFlow()

    val chat = ChatController(
        engine = engine,
        scope = scope,
        toolRuntime = toolRuntime,
        settings = { settings.value.toGeneration(models.state.value.loadedParamsB) },
        store = ConversationStore { snapshot, generating -> persist(snapshot, generating) },
    )

    val conversations = db.conversations().observeAll()

    init {
        models.onRemember { path -> settingsRepository.update { it.copy(lastModelPath = path) } }
        scope.launch {
            settings.first().let { chat.setThinking(it.thinking) }
            db.conversations().interrupted()?.let { _interrupted.value = InterruptedConversation(it.id, it.title) }
            models.restoreLastModel()
        }
        scope.launch {
            // Keep the process in the foreground while generating (spec §35).
            chat.state.distinctUntilChangedBy { it.isGenerating }.collect { state ->
                if (state.isGenerating && settings.value.backgroundGeneration) GenerationService.start(app)
            }
        }
        scope.launch {
            settings.distinctUntilChangedBy { it.updateIntervalHours to it.updateWifiOnly }.collect {
                UpdateManager.schedule(app, it.updateIntervalHours, it.updateWifiOnly)
            }
        }
    }

    fun newConversation() {
        if (chat.state.value.isGenerating) return
        _conversationId.value = null
        chat.clear()
    }

    fun openConversation(id: Long) {
        if (chat.state.value.isGenerating) return
        scope.launch {
            val entity = db.conversations().get(id) ?: return@launch
            chat.restore(json.decodeFromString(ConversationSnapshot.serializer(), entity.snapshotJson))
            _conversationId.value = id
        }
    }

    fun deleteConversation(id: Long) = scope.launch {
        db.conversations().delete(id)
        if (_conversationId.value == id) newConversation()
    }

    /** The user's choice for an interrupted generation: resume it, regenerate, or discard it. */
    fun resolveInterrupted(action: String) {
        val item = _interrupted.value ?: return
        _interrupted.value = null
        scope.launch {
            db.conversations().clearGenerating(item.id)
            if (action == "discard") return@launch
            val entity = db.conversations().get(item.id) ?: return@launch
            chat.restore(json.decodeFromString(ConversationSnapshot.serializer(), entity.snapshotJson))
            _conversationId.value = item.id
            when (action) {
                "resume" -> if (chat.state.value.canContinue) chat.continueReply() else chat.regenerate()
                "regenerate" -> chat.regenerate()
            }
        }
    }

    fun exportConversation(): String? {
        val snapshot = chat.snapshot()
        if (snapshot.messages.isEmpty()) return null
        return snapshot.messages.joinToString("\n\n") { m ->
            (if (m.role == Role.USER) "## User\n" else "## ARCE.AI\n") + m.text
        }
    }

    private fun persist(snapshot: ConversationSnapshot, generating: Boolean) {
        if (snapshot.messages.isEmpty()) return
        val title = snapshot.messages.firstOrNull { it.role == Role.USER }?.text?.take(40)?.ifBlank { null } ?: "新しい会話"
        val payload = json.encodeToString(ConversationSnapshot.serializer(), snapshot)
        val environment = models.environmentJson(settings.value)
        scope.launch(dbWriter) {
            val id = _conversationId.value
            val newId = db.conversations().upsert(
                ConversationEntity(
                    id = id ?: 0, title = title, updatedAt = System.currentTimeMillis(),
                    snapshotJson = payload, generating = generating, environmentJson = environment,
                ),
            )
            if (id == null && newId > 0) _conversationId.value = newId
        }
    }
}
