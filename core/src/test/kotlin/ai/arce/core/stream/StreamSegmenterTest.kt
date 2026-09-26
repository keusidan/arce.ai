package ai.arce.core.stream

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class StreamSegmenterTest {
    private fun run(vararg pieces: String): List<StreamEvent> {
        val s = StreamSegmenter()
        return pieces.flatMap { s.feed(it) } + s.finish()
    }

    /** Joins adjacent deltas of the same kind so assertions don't depend on chunking. */
    private fun merged(events: List<StreamEvent>): List<StreamEvent> = events.fold(mutableListOf()) { acc, e ->
        val last = acc.lastOrNull()
        when {
            last is StreamEvent.Text && e is StreamEvent.Text -> acc[acc.lastIndex] = StreamEvent.Text(last.text + e.text)
            last is StreamEvent.Thinking && e is StreamEvent.Thinking -> acc[acc.lastIndex] = StreamEvent.Thinking(last.text + e.text)
            last is StreamEvent.ToolCallDelta && e is StreamEvent.ToolCallDelta -> acc[acc.lastIndex] = StreamEvent.ToolCallDelta(last.text + e.text)
            else -> acc += e
        }
        acc
    }

    @Test
    fun `splits thinking from the answer`() {
        assertEquals(
            listOf(StreamEvent.Thinking("plan"), StreamEvent.Text("answer")),
            merged(run("<think>plan</think>answer")),
        )
    }

    @Test
    fun `handles tags split across pieces`() {
        assertEquals(
            listOf(StreamEvent.Thinking("plan"), StreamEvent.Text("answer")),
            merged(run("<th", "ink>pl", "an</thi", "nk>ans", "wer")),
        )
    }

    @Test
    fun `holds back a possible tag until it is decided`() {
        val s = StreamSegmenter()
        assertEquals(listOf(StreamEvent.Text("a ")), s.feed("a <thi"))
        // "<thi" turned out not to be a tag: it must come back as text, not be lost
        assertEquals(listOf(StreamEvent.Text("<thin b")), merged(s.feed("n b") + s.finish()))
    }

    @Test
    fun `emits a complete tool call`() {
        val events = merged(run("Let me ask.<tool_call>\n{\"name\":", "\"ask_user\"}\n</tool_", "call>"))
        assertEquals(StreamEvent.Text("Let me ask."), events[0])
        assertEquals(StreamEvent.ToolCallStart, events[1])
        assertEquals(StreamEvent.ToolCallEnd("{\"name\":\"ask_user\"}"), events.last())
    }

    @Test
    fun `reports a tool call cut off by the token limit`() {
        val s = StreamSegmenter()
        s.feed("<tool_call>{\"name\":\"ask")
        s.finish()
        assertTrue(s.isInsideToolCall)
    }

    @Test
    fun `passes multibyte text through untouched`() {
        assertEquals(listOf(StreamEvent.Text("こんにちは🙂<")), merged(run("こんにちは", "🙂", "<")))
    }
}
