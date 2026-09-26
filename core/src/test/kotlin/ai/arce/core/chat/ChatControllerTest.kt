package ai.arce.core.chat

import ai.arce.core.engine.EngineException
import ai.arce.core.engine.GenerateRequest
import ai.arce.core.engine.GenerationEvent
import ai.arce.core.engine.InferenceEngine
import ai.arce.core.engine.LoadParams
import ai.arce.core.generation.FinishReason
import ai.arce.core.generation.TaskState
import ai.arce.core.protocol.QuestionTile
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** Replays one scripted reply per generate() call, split into small pieces like real tokens. */
private class ScriptedEngine(vararg replies: Pair<String, FinishReason>) : InferenceEngine {
    private val queue = ArrayDeque(replies.toList())
    val requests = mutableListOf<GenerateRequest>()
    var failWith: String? = null

    override val isLoaded = true
    override suspend fun load(params: LoadParams) = Unit
    override fun cancel() = Unit
    override suspend fun unload() = Unit

    override fun generate(request: GenerateRequest): Flow<GenerationEvent> = flow {
        requests += request
        failWith?.let { throw EngineException(it) }
        val (text, reason) = queue.removeFirst()
        text.chunked(3).forEach { emit(GenerationEvent.Piece(it)) }
        emit(GenerationEvent.Finished(reason))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChatControllerTest {
    private fun TestScope.controller(engine: InferenceEngine) =
        ChatController(engine, TestScope(UnconfinedTestDispatcher(testScheduler)))

    private val askJson =
        """{"name":"ask_user","arguments":{"title":"どの言語？","options":["Kotlin","Java"],"allow_free_input":true}}"""

    @Test
    fun `separates thinking from the answer`() = runTest {
        val chat = controller(ScriptedEngine("<think>考え中</think>こんにちは" to FinishReason.EOG))
        chat.send("hi")
        val reply = chat.state.value.messages.last()
        assertEquals("考え中", reply.thinking)
        assertEquals("こんにちは", reply.text)
        assertEquals(TaskState.COMPLETED, chat.state.value.task)
    }

    @Test
    fun `a tool call becomes a question tile and the answer resumes generation`() = runTest {
        val engine = ScriptedEngine(
            "<think>聞く</think>確認します。<tool_call>\n$askJson\n</tool_call>" to FinishReason.EOG,
            "<think></think>Kotlinで作ります。" to FinishReason.EOG,
        )
        val chat = controller(engine)
        chat.send("アプリを作って")

        assertEquals(TaskState.USER_WAIT, chat.state.value.task)
        assertEquals(QuestionTile("どの言語？", listOf("Kotlin", "Java"), allowFreeInput = true, multiSelect = false), chat.state.value.pendingQuestion)
        assertNotNull(engine.requests.single().toolCallSchema)

        chat.answer(listOf("Kotlin"), freeText = null)
        assertNull(chat.state.value.pendingQuestion)
        assertEquals("Kotlinで作ります。", chat.state.value.messages.last().text)
        assertTrue(engine.requests.last().prompt.contains("<tool_response>\nKotlin\n</tool_response>"))
        assertTrue(engine.requests.last().prompt.contains("<tool_call>\n$askJson\n</tool_call>"))
    }

    @Test
    fun `a tool call cut off by the token limit is regenerated`() = runTest {
        val engine = ScriptedEngine(
            "<tool_call>\n{\"name\":\"ask_" to FinishReason.LENGTH,
            "<tool_call>\n$askJson\n</tool_call>" to FinishReason.EOG,
        )
        val chat = controller(engine)
        chat.send("質問して")
        assertEquals(2, engine.requests.size)
        assertEquals(TaskState.USER_WAIT, chat.state.value.task)
    }

    @Test
    fun `a stopped reply can be continued from where it ended`() = runTest {
        val engine = ScriptedEngine(
            "<think>x</think>前半" to FinishReason.CANCELLED,
            "と後半" to FinishReason.EOG,
        )
        val chat = controller(engine)
        chat.send("長い説明をして")
        assertTrue(chat.state.value.canContinue)

        chat.continueReply()
        assertEquals("前半と後半", chat.state.value.messages.last().text)
        assertFalse(chat.state.value.canContinue)
        assertFalse(engine.requests.last().thinking, "a continuation does not reason again")
        assertTrue(engine.requests.last().prompt.endsWith("前半"))
    }

    @Test
    fun `regenerate replaces the last reply using the same prompt`() = runTest {
        val engine = ScriptedEngine("一回目" to FinishReason.EOG, "二回目" to FinishReason.EOG)
        val chat = controller(engine)
        chat.send("hi")
        chat.regenerate()
        assertEquals(listOf("hi", "二回目"), chat.state.value.messages.map { it.text })
        assertEquals(engine.requests[0].prompt, engine.requests[1].prompt)
    }

    @Test
    fun `an invalid question is reported, not shown`() = runTest {
        val bad = """{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}"""
        val chat = controller(ScriptedEngine("<tool_call>\n$bad\n</tool_call>" to FinishReason.EOG))
        chat.send("質問して")
        assertEquals(TaskState.ERROR, chat.state.value.task)
        assertEquals("options are not distinct", chat.state.value.error)
        assertNull(chat.state.value.pendingQuestion)
    }

    @Test
    fun `engine errors surface in the state`() = runTest {
        val engine = ScriptedEngine().apply { failWith = "model load failed" }
        val chat = controller(engine)
        chat.send("hi")
        assertEquals(TaskState.ERROR, chat.state.value.task)
        assertEquals("model load failed", chat.state.value.error)
    }
}
