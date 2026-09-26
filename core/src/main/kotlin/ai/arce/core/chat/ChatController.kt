package ai.arce.core.chat

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
import ai.arce.core.protocol.ToolDefinition
import ai.arce.core.stream.StreamEvent
import ai.arce.core.stream.StreamSegmenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class Role { USER, ASSISTANT }

data class UiMessage(
    val id: Long,
    val role: Role,
    val text: String,
    val thinking: String = "",
    val question: QuestionTile? = null,
    val finish: FinishReason? = null,
)

data class ChatState(
    val messages: List<UiMessage> = emptyList(),
    val task: TaskState = TaskState.WAITING,
    val thinkingEnabled: Boolean = true,
    val error: String? = null,
) {
    val isGenerating: Boolean get() = task == TaskState.THINKING || task == TaskState.GENERATION
    val pendingQuestion: QuestionTile? get() = if (task == TaskState.USER_WAIT) messages.lastOrNull()?.question else null

    /** The last reply stopped before it was finished and can be continued (spec: 続行). */
    val canContinue: Boolean
        get() = !isGenerating && messages.lastOrNull()?.let {
            it.role == Role.ASSISTANT && it.question == null &&
                (it.finish == FinishReason.LENGTH || it.finish == FinishReason.CANCELLED)
        } == true
}

/**
 * Runs one conversation: builds prompts, streams output through [StreamSegmenter],
 * turns tool calls into question tiles, and applies [RetryPolicy] to cut-off calls.
 */
class ChatController(
    private val engine: InferenceEngine,
    private val scope: CoroutineScope,
    private val tools: List<ToolDefinition> = listOf(Protocol.askUser),
    private val retryPolicy: RetryPolicy = RetryPolicy(maxAttempts = 2),
    private val maxTokens: Int = 2048,
    var tone: String? = null,
) {
    private val _state = MutableStateFlow(ChatState())
    val state: StateFlow<ChatState> = _state.asStateFlow()

    private val history = mutableListOf<ChatMessage>()
    private val toolCallSchema = if (tools.isEmpty()) null else Protocol.toolCallSchema(tools).toString()
    private var nextId = 0L

    fun setThinking(enabled: Boolean) = _state.update { it.copy(thinkingEnabled = enabled) }

    fun send(text: String) {
        if (text.isBlank() || _state.value.isGenerating) return
        history += ChatMessage.User(text)
        append(UiMessage(nextId++, Role.USER, text))
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

    fun stop() {
        engine.cancel()
    }

    /** Replaces the last reply with a fresh one generated from the same context. */
    fun regenerate() {
        val last = _state.value.messages.lastOrNull()
        if (_state.value.isGenerating || last?.role != Role.ASSISTANT) return
        if (history.lastOrNull() is ChatMessage.Assistant) history.removeAt(history.lastIndex)
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

    private fun start(prefill: String) {
        scope.launch { generate(prefill) }
    }

    private suspend fun generate(prefill: String) {
        val id = nextId++
        append(UiMessage(id, Role.ASSISTANT, prefill))
        _state.update { it.copy(error = null) }

        val thinking = _state.value.thinkingEnabled && prefill.isEmpty()
        val prompt = ChatMlPromptBuilder.build(history, tools, tone, _state.value.thinkingEnabled, prefill)
        var attempts = 0

        while (true) {
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
                replace(id) { it.copy(text = answer, thinking = thinkingText) }
                _state.update { it.copy(task = task.state) }
            }

            _state.update { it.copy(task = if (thinking) TaskState.THINKING else TaskState.GENERATION) }
            try {
                engine.generate(GenerateRequest(prompt, toolCallSchema, thinking, maxTokens, sampling(thinking)))
                    .collect { event ->
                        when (event) {
                            is GenerationEvent.Piece -> consume(segmenter.feed(event.text))
                            is GenerationEvent.Finished -> reason = event.reason
                        }
                    }
            } catch (e: EngineException) {
                fail(id, e.message ?: "inference error")
                return
            }
            consume(segmenter.finish())

            val callJson = toolCallJson
            val parsed = callJson?.let { ToolCallParser.parse(it, tools) }
            val question = ((parsed as? ParseResult.Ok)?.call as? ToolCall.AskUser)?.tile
            val semanticError = (parsed as? ParseResult.Invalid)?.reason

            when (val step = retryPolicy.decide(reason, segmenter.isInsideToolCall, semanticError, attempts)) {
                is NextStep.Regenerate -> {
                    attempts = step.attempt
                    replace(id) { it.copy(text = prefill, thinking = "") }
                    continue
                }
                is NextStep.Fail -> {
                    fail(id, step.reason)
                    return
                }
                NextStep.Done -> {
                    history += ChatMessage.Assistant(answer, callJson.takeIf { question != null })
                    replace(id) { it.copy(question = question, finish = reason) }
                    _state.update {
                        it.copy(
                            task = when {
                                question != null -> TaskState.USER_WAIT
                                reason == FinishReason.CANCELLED -> TaskState.CANCELLED
                                else -> TaskState.COMPLETED
                            },
                        )
                    }
                    return
                }
            }
        }
    }

    private fun sampling(thinking: Boolean) =
        if (thinking) SamplingParams.qwen3Thinking else SamplingParams.qwen3NonThinking

    private fun fail(id: Long, reason: String) {
        replace(id) { it.copy(finish = FinishReason.ERROR) }
        _state.update { it.copy(task = TaskState.ERROR, error = reason) }
    }

    private fun append(message: UiMessage) = _state.update { it.copy(messages = it.messages + message) }

    private fun replace(id: Long, change: (UiMessage) -> UiMessage) = _state.update { state ->
        state.copy(messages = state.messages.map { if (it.id == id) change(it) else it })
    }
}
