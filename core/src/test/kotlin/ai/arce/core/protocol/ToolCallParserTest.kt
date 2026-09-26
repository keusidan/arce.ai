package ai.arce.core.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class ToolCallParserTest {
    private val tools = listOf(Protocol.askUser)

    @Test
    fun `parses a question tile`() {
        val result = ToolCallParser.parse(
            """{"name":"ask_user","arguments":{"title":"言語は？","options":["Kotlin","Java"],"multi_select":true}}""",
            tools,
        )
        val call = assertInstanceOf(ParseResult.Ok::class.java, result).call as ToolCall.AskUser
        assertEquals(QuestionTile("言語は？", listOf("Kotlin", "Java"), allowFreeInput = false, multiSelect = true), call.tile)
    }

    @Test
    fun `rejects tools the agent may not use`() {
        val result = ToolCallParser.parse("""{"name":"delete_files","arguments":{}}""", tools)
        assertInstanceOf(ParseResult.Invalid::class.java, result)
    }

    @Test
    fun `rejects content the grammar cannot rule out`() {
        listOf(
            """{"name":"ask_user","arguments":{"title":" ","options":["a"]}}""",
            """{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}""",
            """{"name":"ask_user","arguments":{"title":"q","options":["a",""]}}""",
            """{"name":"ask_user","arguments":{"title":"q","options":"a"}}""",
            """{"name":"ask_user","arguments":{"title":{"x":1},"options":["a"]}}""",
            """not json""",
        ).forEach { body ->
            assertInstanceOf(ParseResult.Invalid::class.java, ToolCallParser.parse(body, tools), body)
        }
    }

    @Test
    fun `tool call schema restricts name and arguments per tool`() {
        val schema = Protocol.toolCallSchema(tools)
        val variant = schema["oneOf"]!!.jsonArray.single().jsonObject
        val props = variant["properties"]!!.jsonObject
        assertEquals("ask_user", props["name"]!!.jsonObject["const"]!!.jsonPrimitive.content)
        assertEquals(Protocol.askUser.parameters, props["arguments"] as JsonObject)
    }

    @Test
    fun `an agent without tools has no tool call schema`() {
        assertThrows<IllegalArgumentException> { Protocol.toolCallSchema(emptyList()) }
    }
}
