package ai.arce.core.stream

/** A piece of model output, classified by the block it belongs to. */
sealed interface StreamEvent {
    data class Thinking(val text: String) : StreamEvent
    data class Text(val text: String) : StreamEvent
    data object ToolCallStart : StreamEvent
    data class ToolCallDelta(val text: String) : StreamEvent
    /** [json] is the full body between the tags, not yet validated. */
    data class ToolCallEnd(val json: String) : StreamEvent
}

/**
 * Splits streamed model output into Thinking, plain text and tool-call blocks.
 *
 * Qwen3 wraps reasoning in `<think>…</think>` and tool calls in `<tool_call>…</tool_call>`.
 * Tokens arrive in arbitrary pieces, so a tag can be split across two [feed] calls; the tail
 * that could still become a tag is held back until the next piece decides it.
 */
class StreamSegmenter {
    private enum class Block { TEXT, THINKING, TOOL_CALL }

    private var block = Block.TEXT
    private val pending = StringBuilder()
    private val toolCall = StringBuilder()

    fun feed(piece: String): List<StreamEvent> {
        pending.append(piece)
        val events = mutableListOf<StreamEvent>()
        while (true) {
            val closing = when (block) {
                Block.TEXT -> null
                Block.THINKING -> THINK_CLOSE
                Block.TOOL_CALL -> TOOL_CLOSE
            }
            val candidates = if (closing != null) listOf(closing) else listOf(THINK_OPEN, TOOL_OPEN)
            val hit = candidates
                .map { it to pending.indexOf(it) }
                .filter { it.second >= 0 }
                .minByOrNull { it.second }

            if (hit == null) {
                val safe = pending.length - longestTagPrefixSuffix(candidates)
                emit(pending.substring(0, safe), events)
                pending.delete(0, safe)
                return events
            }

            val (tag, at) = hit
            emit(pending.substring(0, at), events)
            pending.delete(0, at + tag.length)
            transition(tag, events)
        }
    }

    /** Flushes whatever is held back once the stream has ended. */
    fun finish(): List<StreamEvent> {
        val events = mutableListOf<StreamEvent>()
        emit(pending.toString(), events)
        pending.clear()
        return events
    }

    /** True when the stream ended inside a tool call, i.e. the call was cut off. */
    val isInsideToolCall: Boolean get() = block == Block.TOOL_CALL

    private fun transition(tag: String, events: MutableList<StreamEvent>) {
        when (tag) {
            THINK_OPEN -> block = Block.THINKING
            THINK_CLOSE -> block = Block.TEXT
            TOOL_OPEN -> {
                block = Block.TOOL_CALL
                toolCall.clear()
                events += StreamEvent.ToolCallStart
            }
            TOOL_CLOSE -> {
                block = Block.TEXT
                events += StreamEvent.ToolCallEnd(toolCall.toString().trim())
            }
        }
    }

    private fun emit(text: String, events: MutableList<StreamEvent>) {
        if (text.isEmpty()) return
        events += when (block) {
            Block.TEXT -> StreamEvent.Text(text)
            Block.THINKING -> StreamEvent.Thinking(text)
            Block.TOOL_CALL -> StreamEvent.ToolCallDelta(text).also { toolCall.append(text) }
        }
    }

    /** Length of the longest suffix of [pending] that is a proper prefix of one of [tags]. */
    private fun longestTagPrefixSuffix(tags: List<String>): Int {
        val max = minOf(pending.length, tags.maxOf { it.length } - 1)
        for (len in max downTo 1) {
            val suffix = pending.substring(pending.length - len)
            if (tags.any { it.startsWith(suffix) }) return len
        }
        return 0
    }

    companion object {
        const val THINK_OPEN = "<think>"
        const val THINK_CLOSE = "</think>"
        const val TOOL_OPEN = "<tool_call>"
        const val TOOL_CLOSE = "</tool_call>"
    }
}
