package ai.arce.core.agent

import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class AgentRouterTest {
    private val unclearRequest = "週末に家族で楽しめる過ごし方を一緒に考えてほしいです"

    @Test
    fun `clear keyword hits never ask the model`() = runBlocking {
        var asked = false
        val router = AgentRouter { _, _ -> asked = true; """{"agent":"research"}""" }
        assertEquals(Agents.coding, router.select("Pythonでスクリプトを作って", false, null, useModel = true))
        assertFalse(asked)
    }

    @Test
    fun `ambiguous request is settled by the model`() = runBlocking {
        assertTrue(AgentSelector.isAmbiguous(unclearRequest, false))
        val router = AgentRouter { prompt, schema ->
            assertTrue("research" in schema && "file-analysis" in schema)
            assertTrue(prompt.endsWith("</think>\n\n"))
            """{"agent": "research"}"""
        }
        assertEquals(Agents.research, router.select(unclearRequest, false, null, useModel = true))
    }

    @Test
    fun `bad answers, failures and disabled selection fall back to the rules`() = runBlocking {
        assertEquals(Agents.general, AgentRouter { _, _ -> """{"agent":"hacker"}""" }.select(unclearRequest, false, null, true))
        assertEquals(Agents.general, AgentRouter { _, _ -> null }.select(unclearRequest, false, null, true))
        assertEquals(Agents.general, AgentRouter { _, _ -> error("boom") }.select(unclearRequest, false, null, true))
        assertEquals(Agents.general, AgentRouter { _, _ -> """{"agent":"coding"}""" }.select(unclearRequest, false, null, false))
    }

    @Test
    fun `user override wins and greetings are not ambiguous`() = runBlocking {
        assertEquals(Agents.artifact, AgentRouter { _, _ -> """{"agent":"coding"}""" }.select(unclearRequest, false, "artifact", true))
        assertFalse(AgentSelector.isAmbiguous("こんにちは", false))
    }
}
