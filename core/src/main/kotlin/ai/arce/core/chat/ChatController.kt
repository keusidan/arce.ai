package ai.arce.core.chat

import ai.arce.core.agent.AgentDefinition
import ai.arce.core.agent.AgentRouter
import ai.arce.core.engine.EngineException
import ai.arce.core.engine.GenerateRequest
import ai.arce.core.engine.GenerationEvent
import ai.arce.core.engine.InferenceEngine
import ai.arce.core.engine.SamplingParams
import ai.arce.core.generation.FinishReason
import ai.arce.core.generation.GenerationTask
import ai.arce.core.generation.NextStep
import ai.arce.core.generation.RetryPolicy
import ai.arce.core.generation.TaskState
import ai.arce.core.prompt.ChatMessage
import ai.arce.core.prompt.ChatMlPromptBuilder
import ai.arce.core.protocol.ParseResult
import ai.arce.core.protocol.Protocol
import ai.arce.core.protocol.QuestionTile
import ai.arce.core.protocol.ToolCall
import ai.arce.core.protocol.ToolCallParser
import ai.arce.core.stream.StreamEvent
import ai.arce.core.stream.StreamSegmenter
import ai.arce.core.tools.ToolActivity
import ai.arce.core.tools.ToolRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable

@Serializable
enum class Role { USER, ASSISTANT }

@Serializable
data class UiMessage(
    val id: Long,
    val role: Role,
    val text: String,
    val thinking: String = "",
    val question: QuestionTile? = null,
    val finish: FinishReason? = null,
    val activities: List<ToolActivity> = emptyList(),
    val agent: String? = null,
    val attachments: List<String> = emptyList(),
)

data class ChatState(
    val messages: List<UiMessage> = emptyList(),
    val task: TaskState = TaskState.WAITING,
    val thinkingEnabled: Boolean = true,
    val error: String? = null,
    /** e.g. the selected agent expects a larger model than the one loaded (spec §17.2). */
    val notice: String? = null,
) {
    val isGenerating: Boolean
        get() = task == TaskState.THINKING || task == TaskState.GENERATION || task == TaskState.SEARCH
    val pendingQuestion: QuestionTile? get() = if (task == TaskState.USER_WAIT) messages.lastOrNull()?.question else null

    /** The last reply stopped before it was finished and can be continued (spec: 続行). */
    val canContinue: Boolean
        get() = !isGenerating && messages.lastOrNull()?.let {
            it.role == Role.ASSISTANT && it.question == null &&
                (it.finish == FinishReason.LENGTH || it.finish == FinishReason.CANCELLED)
        } == true
}

/** Everything needed to restore a conversation, persisted by the app (spec §33/§34). */
@Serializable
data class ConversationSnapshot(
    val messages: List<UiMessage>,
    val history: List<ChatMessage>,
    val nextId: Long,
)

/** Called at the points where a crash would lose work; [generating] marks an unfinished task. */
fun interface ConversationStore {
    fun save(snapshot: ConversationSnapshot, generating: Boolean)
}

/**
 * Runs one conversation: picks an agent, builds prompts, streams output through
 * [StreamSegmenter], runs tool calls through [ToolRuntime] until the model answers, turns
 * ask_user into a question tile, and regenerates cut-off calls per [RetryPolicy].
 */
class ChatController(
    private val engine: InferenceEngine,
    private val scope: CoroutineScope,
    private val toolRuntime: ToolRuntime = ToolRuntime.None,
    private val settings: () -> GenerationSettings = { GenerationSettings() },
    private val store: ConversationStore = ConversationStore { _, _ -> },
) {
    private val _state = MutableStateFlow(ChatState())
    val state: StateFlow<ChatState> = _state.asStateFlow()

    private val history = mutableListOf<ChatMessage>()
    private var nextId = 0L
    private var agent: AgentDefinition? = null
    /** The request the agent is chosen for; selection runs lazily at the start of generation. */
    private var agentRequest: Pair<String, Boolean> = "" to false

    private val router = AgentRouter { prompt, schema ->
        withTimeoutOrNull(20_000) {
            buildString {
                engine.generate(
                    GenerateRequest(
                        prompt, toolCallSchema = null, thinking = false, maxTokens = 32,
                        sampling = SamplingParams(temperature = 0.1f, topP = 1f, topK = 1, minP = 0f, dryMultiplier = 0f),
                        strictJsonSchema = schema,
                    ),
                ).collect { if (it is GenerationEvent.Piece) append(it.text) }
            }
        }
    }

    fun setThinking(enabled: Boolean) = _state.update { it.copy(thinkingEnabled = enabled) }

    fun snapshot() = ConversationSnapshot(_state.value.messages, history.toList(), nextId)

    fun restore(snapshot: ConversationSnapshot) {
        history.clear()
        history += snapshot.history
        nextId = snapshot.nextId
        // Choose the agent again for the restored conversation, from its last request.
        agent = null
        agentRequest = (snapshot.messages.lastOrNull { it.role == Role.USER }?.text ?: "") to false
        val waiting = snapshot.messages.lastOrNull()?.question != null
        _state.update { ChatState(snapshot.messages, if (waiting) TaskState.USER_WAIT else TaskState.WAITING, it.thinkingEnabled) }
    }

    fun clear() = restore(ConversationSnapshot(emptyList(), emptyList(), 0))

    fun send(text: String, attachments: List<Attachment> = emptyList()) {
        if ((text.isBlank() && attachments.isEmpty()) || _state.value.isGenerating) return
        history += ChatMessage.User(AttachmentPolicy.compose(text, attachments))
        append(UiMessage(nextId++, Role.USER, text, attachments = attachments.map { it.name }))
        agent = null
        agentRequest = text to attachments.isNotEmpty()
        start(prefill = "")
    }

    /** Answers the pending question tile and resumes generation. */
    fun answer(selected: List<String>, freeText: String?) {
        if (_state.value.pendingQuestion == null) return
        val answer = (selected + listOfNotNull(freeText?.takeIf { it.isNotBlank() })).joinToString(", ")
        history += ChatMessage.ToolResponse(answer)
        append(UiMessage(nextId++, Role.USER, answer))
        start(prefill = "")
    }

    fun stop() = engine.cancel()

    /** Replaces the last reply with a fresh one generated from the same context. */
    fun regenerate() {
        val last = _state.value.messages.lastOrNull()
        if (_state.value.isGenerating || last?.role != Role.ASSISTANT) return
        dropLastReplyFromHistory()
        _state.update { it.copy(messages = it.messages.dropLast(1)) }
        start(prefill = "")
    }

    fun continueReply() {
        if (!_state.value.canContinue) return
        val partial = _state.value.messages.last()
        // The partial reply is regenerated from its own text, so drop it from the context first.
        if (history.lastOrNull() is ChatMessage.Assistant) history.removeAt(history.lastIndex)
        _state.update { it.copy(messages = it.messages.dropLast(1)) }
        start(prefill = partial.text)
    }

    /** Removes the assistant turns (and tool responses) since the last user or answer message. */
    private fun dropLastReplyFromHistory() {
        while (history.isNotEmpty()) {
            val last = history.last()
            val isToolResult = last is ChatMessage.ToolResponse && history.getOrNull(history.lastIndex - 1).let {
                it is ChatMessage.Assistant && it.toolCallJson != null
            }
            if (last is ChatMessage.Assistant || isToolResult) history.removeAt(history.lastIndex) else break
        }
    }

    private fun start(prefill: String) {
        scope.launch { generate(prefill) }
    }

    private class Attempt(
        val reason: FinishReason,
        val thinking: String,
        val answer: String,
        val toolCallJson: String?,
        val cutInsideToolCall: Boolean,
    )

    private suspend fun generate(prefill: String) {
        val config = settings()
        val agent = agent ?: router.select(
            agentRequest.first, agentRequest.second, config.agentOverride,
            useModel = config.aiAgentSelection && engine.isLoaded,
        ).also { agent = it }
        val tools = agent.tools.filter { config.searchEnabled || it != Protocol.webSearch }
        val schema = if (tools.isEmpty()) null else Protocol.toolCallSchema(tools).toString()
        val retry = RetryPolicy(config.retryLimit)
        val instructions = listOf(
            "Current role: ${agent.displayName}. ${agent.instructions}",
            if (config.maxChars > 0) "Keep each reply under ${config.maxChars} characters." else "",
        )
        val sizeNotice = config.modelParamsB?.takeIf { it < agent.minModelParamsB }?.let {
            "「${agent.displayName}」は${agent.minModelParamsB}B以上のモデルを推奨します（現在 ${it}B）。モデルは自動で変更しません。"
        }

        val id = nextId++
        append(UiMessage(id, Role.ASSISTANT, prefill, agent = agent.displayName))
        _state.update { it.copy(error = null, notice = sizeNotice) }
        store.save(snapshot(), generating = true)

        var earlierText = ""
        val activities = mutableListOf<ToolActivity>()
        var rounds = 0
        var roundPrefill = prefill

        while (true) {
            val thinking = config.effectiveThinking(_state.value.thinkingEnabled) && roundPrefill.isEmpty()
            val prompt = ChatMlPromptBuilder.build(
                history, tools, config.tone, thinking, roundPrefill, instructions,
            )
            val request = GenerateRequest(prompt, schema, thinking, config.effectiveMaxTokens(), sampling(thinking))

            var attempts = 0
            var result: Attempt
            while (true) {
                result = try {
                    attempt(id, request, earlierText, roundPrefill)
                } catch (e: EngineException) {
                    fail(id, e.message ?: "inference error")
                    return
                }
                val parsed = result.toolCallJson?.let { ToolCallParser.parse(it, tools) }
                val semanticError = (parsed as? ParseResult.Invalid)?.reason
                when (val step = retry.decide(result.reason, result.cutInsideToolCall, semanticError, attempts)) {
                    is NextStep.Regenerate -> attempts = step.attempt
                    is NextStep.Fail -> {
                        fail(id, step.reason)
                        return
                    }
                    NextStep.Done -> break
                }
            }

            val call = (result.toolCallJson?.let { ToolCallParser.parse(it, tools) } as? ParseResult.Ok)?.call
            history += ChatMessage.Assistant(result.answer, result.toolCallJson.takeIf { call != null })
            val shown = join(earlierText, result.answer)

            when (call) {
                null -> {
                    replace(id) { it.copy(text = shown, finish = result.reason, activities = activities.toList()) }
                    finishWith(if (result.reason == FinishReason.CANCELLED) TaskState.CANCELLED else TaskState.COMPLETED)
                    return
                }
                is ToolCall.AskUser -> {
                    replace(id) { it.copy(text = shown, question = call.tile, finish = result.reason, activities = activities.toList()) }
                    finishWith(TaskState.USER_WAIT)
                    return
                }
                else -> {
                    rounds++
                    if (rounds > config.maxToolRounds) {
                        fail(id, "tool calls exceeded ${config.maxToolRounds} rounds")
                        return
                    }
                    _state.update { it.copy(task = if (call is ToolCall.WebSearch) TaskState.SEARCH else TaskState.GENERATION) }
                    val outcome = toolRuntime.run(call)
                    activities += outcome.activity
                    history += ChatMessage.ToolResponse(outcome.response)
                    earlierText = shown
                    roundPrefill = ""
                    replace(id) { it.copy(text = earlierText, activities = activities.toList()) }
                }
            }
        }
    }

    /** One pass through the engine; streams text and thinking into message [id]. */
    private suspend fun attempt(id: Long, request: GenerateRequest, earlierText: String, prefill: String): Attempt {
        val task = GenerationTask()
        val segmenter = StreamSegmenter()
        var reason = FinishReason.ERROR
        var thinkingText = ""
        var answer = prefill
        var toolCallJson: String? = null

        fun consume(events: List<StreamEvent>) {
            for (event in events) when (event) {
                is StreamEvent.Thinking -> { thinkingText += event.text; task.moveTo(TaskState.THINKING) }
                is StreamEvent.Text -> { answer += event.text; task.moveTo(TaskState.GENERATION) }
                is StreamEvent.ToolCallEnd -> toolCallJson = event.json
                StreamEvent.ToolCallStart, is StreamEvent.ToolCallDelta -> task.moveTo(TaskState.GENERATION)
            }
            replace(id) { it.copy(text = join(earlierText, answer), thinking = thinkingText) }
            _state.update { it.copy(task = task.state) }
        }

        _state.update { it.copy(task = if (request.thinking) TaskState.THINKING else TaskState.GENERATION) }
        engine.generate(request).collect { event ->
            when (event) {
                is GenerationEvent.Piece -> consume(segmenter.feed(event.text))
                is GenerationEvent.Finished -> reason = event.reason
            }
        }
        consume(segmenter.finish())
        return Attempt(reason, thinkingText, answer, toolCallJson, segmenter.isInsideToolCall)
    }

    private fun join(earlier: String, current: String) =
        if (earlier.isBlank()) current else if (current.isBlank()) earlier else "$earlier\n\n$current"

    private fun finishWith(state: TaskState) {
        _state.update { it.copy(task = state) }
        store.save(snapshot(), generating = false)
    }

    private fun sampling(thinking: Boolean) =
        if (thinking) SamplingParams.qwen3Thinking else SamplingParams.qwen3NonThinking

    private fun fail(id: Long, reason: String) {
        replace(id) { it.copy(finish = FinishReason.ERROR) }
        _state.update { it.copy(task = TaskState.ERROR, error = reason) }
        store.save(snapshot(), generating = false)
    }

    private fun append(message: UiMessage) = _state.update { it.copy(messages = it.messages + message) }

    private fun replace(id: Long, change: (UiMessage) -> UiMessage) = _state.update { state ->
        state.copy(messages = state.messages.map { if (it.id == id) change(it) else it })
    }
}
