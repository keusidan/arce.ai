package ai.arce.core.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * A tool the model may call. [parameters] is a JSON Schema object; the same schema is shown
 * to the model in the system prompt and compiled to GBNF on the native side, so the two
 * cannot drift apart.
 */
data class ToolDefinition(
    val name: String,
    val description: String,
    val parameters: JsonObject,
)

object Protocol {
    /**
     * Bumped whenever a tool schema changes. Stored with each generation so a regeneration
     * can tell whether it runs under the same protocol as the original.
     */
    const val SCHEMA_VERSION = 2

    val askUser = ToolDefinition(
        name = "ask_user",
        description = "Ask the user a question and wait for the answer before continuing.",
        parameters = objectSchema(required = listOf("title", "options")) {
            putJsonObject("title") { put("type", "string") }
            putJsonObject("options") {
                put("type", "array")
                putJsonObject("items") { put("type", "string") }
                put("minItems", 1)
                put("maxItems", QuestionTile.MAX_OPTIONS)
            }
            putJsonObject("allow_free_input") { put("type", "boolean") }
            putJsonObject("multi_select") { put("type", "boolean") }
        },
    )

    val webSearch = ToolDefinition(
        name = "web_search",
        description = "Search the web. Use only when the answer needs current or external information.",
        parameters = objectSchema(required = listOf("query")) {
            putJsonObject("query") { put("type", "string") }
        },
    )

    val getWeather = ToolDefinition(
        name = "get_weather",
        description = "Get the current weather for a city or place name.",
        parameters = objectSchema(required = listOf("location")) {
            putJsonObject("location") { put("type", "string") }
        },
    )

    val getTime = ToolDefinition(
        name = "get_time",
        description = "Get the current date and time. timezone is an IANA name such as Asia/Tokyo; omit it for the device time zone.",
        parameters = objectSchema(required = emptyList()) {
            putJsonObject("timezone") { put("type", "string") }
        },
    )

    /**
     * JSON Schema for the body of one `<tool_call>` block restricted to [tools]:
     * `{"name": <one of the tools>, "arguments": <that tool's parameters>}`.
     * Each agent passes only the tools it may use, so the grammar cannot express any other call.
     */
    fun toolCallSchema(tools: List<ToolDefinition>): JsonObject {
        require(tools.isNotEmpty()) { "an agent without tools needs no tool-call grammar" }
        return buildJsonObject {
            put("oneOf", buildJsonArray {
                tools.forEach { tool ->
                    add(buildJsonObject {
                        put("type", "object")
                        putJsonObject("properties") {
                            putJsonObject("name") { put("const", tool.name) }
                            put("arguments", tool.parameters)
                        }
                        put("required", strings(listOf("name", "arguments")))
                        put("additionalProperties", false)
                    })
                }
            })
        }
    }

    private fun objectSchema(
        required: List<String>,
        properties: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ): JsonObject = buildJsonObject {
        put("type", "object")
        putJsonObject("properties", properties)
        put("required", strings(required))
        put("additionalProperties", false)
    }

    private fun strings(values: List<String>) = JsonArray(values.map { JsonPrimitive(it) })
}
