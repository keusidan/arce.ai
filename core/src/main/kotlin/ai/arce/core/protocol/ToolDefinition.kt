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
    const val SCHEMA_VERSION = 1

    val askUser = ToolDefinition(
        name = "ask_user",
        description = "Ask the user a question and wait for the answer before continuing.",
        parameters = buildJsonObject {
            put("type", "object")
            putJsonObject("properties") {
                putJsonObject("title") { put("type", "string") }
                putJsonObject("options") {
                    put("type", "array")
                    putJsonObject("items") { put("type", "string") }
                    put("minItems", 1)
                    put("maxItems", QuestionTile.MAX_OPTIONS)
                }
                putJsonObject("allow_free_input") { put("type", "boolean") }
                putJsonObject("multi_select") { put("type", "boolean") }
            }
            put("required", JsonArray(listOf(JsonPrimitive("title"), JsonPrimitive("options"))))
            put("additionalProperties", false)
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
                        put("required", JsonArray(listOf(JsonPrimitive("name"), JsonPrimitive("arguments"))))
                        put("additionalProperties", false)
                    })
                }
            })
        }
    }
}
