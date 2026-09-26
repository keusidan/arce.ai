package ai.arce.core.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class QuestionTile(
    val title: String,
    val options: List<String>,
    val allowFreeInput: Boolean,
    val multiSelect: Boolean,
) {
    companion object {
        const val MAX_OPTIONS = 8
    }
}

sealed interface ToolCall {
    data class AskUser(val tile: QuestionTile) : ToolCall
    data class WebSearch(val query: String) : ToolCall
    data class GetWeather(val location: String) : ToolCall
    data class GetTime(val timezone: String?) : ToolCall
}

sealed interface ParseResult {
    data class Ok(val call: ToolCall) : ParseResult
    /** The grammar guarantees syntax, so this means the content itself is unusable. */
    data class Invalid(val reason: String) : ParseResult
}

/**
 * Turns the body of a `<tool_call>` block into a [ToolCall] and checks what the grammar
 * cannot: meaning. GBNF guarantees the JSON shape, not that option labels are non-blank
 * or distinct.
 */
object ToolCallParser {
    private val json = Json { ignoreUnknownKeys = false }

    fun parse(body: String, allowed: List<ToolDefinition>): ParseResult {
        val root = try {
            json.parseToJsonElement(body).jsonObject
        } catch (e: SerializationException) {
            return ParseResult.Invalid("not JSON: ${e.message}")
        } catch (e: IllegalArgumentException) {
            return ParseResult.Invalid("not a JSON object")
        }

        val name = (root["name"] as? JsonPrimitive)?.contentOrNull
            ?: return ParseResult.Invalid("missing tool name")
        if (allowed.none { it.name == name }) return ParseResult.Invalid("tool '$name' is not allowed here")
        val args = root["arguments"] as? JsonObject ?: return ParseResult.Invalid("missing arguments")

        return try {
            when (name) {
                Protocol.askUser.name -> parseAskUser(args)
                Protocol.webSearch.name -> requiredText(args, "query")?.let { ParseResult.Ok(ToolCall.WebSearch(it)) }
                    ?: ParseResult.Invalid("search query is blank")
                Protocol.getWeather.name -> requiredText(args, "location")?.let { ParseResult.Ok(ToolCall.GetWeather(it)) }
                    ?: ParseResult.Invalid("weather location is blank")
                Protocol.getTime.name -> ParseResult.Ok(ToolCall.GetTime(requiredText(args, "timezone")))
                else -> ParseResult.Invalid("tool '$name' has no handler")
            }
        } catch (e: IllegalArgumentException) {
            // jsonPrimitive / jsonArray throw this when an argument has the wrong JSON type
            ParseResult.Invalid("argument has the wrong type: ${e.message}")
        }
    }

    private fun requiredText(args: JsonObject, key: String): String? =
        args[key]?.jsonPrimitive?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }

    private fun parseAskUser(args: JsonObject): ParseResult {
        val title = requiredText(args, "title") ?: return ParseResult.Invalid("question title is blank")

        val options = args["options"]?.jsonArray
            ?.map { it.jsonPrimitive.contentOrNull?.trim().orEmpty() }
            .orEmpty()
        if (options.isEmpty()) return ParseResult.Invalid("question has no options")
        if (options.size > QuestionTile.MAX_OPTIONS) return ParseResult.Invalid("too many options")
        if (options.any { it.isEmpty() }) return ParseResult.Invalid("an option is blank")
        if (options.toSet().size != options.size) return ParseResult.Invalid("options are not distinct")

        return ParseResult.Ok(
            ToolCall.AskUser(
                QuestionTile(
                    title = title,
                    options = options,
                    allowFreeInput = args["allow_free_input"]?.jsonPrimitive?.booleanOrNull ?: false,
                    multiSelect = args["multi_select"]?.jsonPrimitive?.booleanOrNull ?: false,
                ),
            ),
        )
    }
}
