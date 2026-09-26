package ai.arce.core.agent

import ai.arce.core.chat.Attachment
import ai.arce.core.chat.AttachmentPolicy
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class AgentsTest {
    @Test
    fun `keywords pick the most specific agent`() {
        assertEquals(Agents.artifact, AgentSelector.select("HTMLでゲームを作って", false, null))
        assertEquals(Agents.coding, AgentSelector.select("Pythonで関数を実装して", false, null))
        assertEquals(Agents.research, AgentSelector.select("最新のニュースを調べて", false, null))
        assertEquals(Agents.general, AgentSelector.select("こんにちは", false, null))
    }

    @Test
    fun `attachments and manual override`() {
        assertEquals(Agents.fileAnalysis, AgentSelector.select("これは何？", true, null))
        assertEquals(Agents.coding, AgentSelector.select("こんにちは", false, "coding"))
    }

    @Test
    fun `attachments are capped per file and in total`() {
        val big = Attachment("a.txt", "x".repeat(20_000))
        val composed = AttachmentPolicy.compose("要約して", listOf(big, big, big))
        assertTrue(composed.contains("<file name=\"a.txt\">"))
        assertTrue(composed.contains("characters omitted"))
        assertTrue(composed.length < AttachmentPolicy.MAX_TOTAL_CHARS + 1_000)
        assertTrue(composed.endsWith("要約して"))
    }
}
