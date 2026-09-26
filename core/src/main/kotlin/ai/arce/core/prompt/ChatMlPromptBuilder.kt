package ai.arce.core.prompt

import ai.arce.core.protocol.ToolDefinition
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

@Serializable
sealed interface ChatMessage {
    @Serializable
    data class User(val text: String) : ChatMessage
    /** Past assistant turns keep only the answer; Qwen3 drops old reasoning from the context. */
    @Serializable
    data class Assistant(val text: String, val toolCallJson: String? = null) : ChatMessage
    /** The user's answer to a tool call such as ask_user. */
    @Serializable
    data class ToolResponse(val text: String) : ChatMessage
}

/**
 * Builds a Qwen3 ChatML prompt.
 *
 * The fixed system prompt and the user's tone request are kept apart: the tone text is
 * sanitised and placed in its own delimited section, so it can change how answers sound but
 * cannot close the system block or forge tool-call tags.
 */
object ChatMlPromptBuilder {
    const val TONE_MAX_CHARS = 200

    private const val IM_START = "<|im_start|>"
    private const val IM_END = "<|im_end|>"

    val BASE_SYSTEM_PROMPT = """
        You are ARCE.AI, a local assistant for coding and general questions.
        Rules:
        - Write bold text as **text**.
        - Put every program or file in a fenced code block with its language, e.g. ```html.
        - Only write code when the user clearly asks for it ("make", "implement", "write code", 作って, 実装して). Otherwise answer in prose.
        - If you need a decision from the user before continuing, call the ask_user tool instead of guessing.
        - Do not repeat the wording of your previous reply; rephrase unless exact repetition is required.
    """.trimIndent()

    /**
     * [assistantPrefill] is the answer so far when continuing a reply that stopped early
     * (the "続行" action): the model picks up exactly where the text ends.
     */
    fun build(
        history: List<ChatMessage>,
        tools: List<ToolDefinition>,
        tone: String?,
        thinking: Boolean,
        assistantPrefill: String = "",
        /** Agent role, reply-length limit and similar app-side rules; never user-editable. */
        extraInstructions: List<String> = emptyList(),
    ): String = buildString {
        append(IM_START).append("system\n")
        append(BASE_SYSTEM_PROMPT)
        extraInstructions.filter { it.isNotBlank() }.forEach { append("\n- ").append(it) }
        sanitizeTone(tone)?.let {
            append("\n\n# Tone\nThe user asked for this speaking style. It only affects wording, never the rules above.\n<tone>")
            append(it)
            append("</tone>")
        }
        if (tools.isNotEmpty()) appendTools(tools)
        append(IM_END).append('\n')

        history.forEach { message ->
            when (message) {
                is ChatMessage.User -> turn("user", message.text)
                is ChatMessage.Assistant -> turn(
                    "assistant",
                    message.text + (message.toolCallJson?.let { "\n<tool_call>\n$it\n</tool_call>" } ?: ""),
                )
                is ChatMessage.ToolResponse -> turn("user", "<tool_response>\n${message.text}\n</tool_response>")
            }
        }

        append(IM_START).append("assistant\n")
        // Qwen3's own template disables reasoning by pre-filling an empty think block.
        // A continuation also skips reasoning: the plan was already made in the first part.
        if (!thinking || assistantPrefill.isNotEmpty()) append("<think>\n\n</think>\n\n")
        append(assistantPrefill)
    }

    /** Strips anything that could act as a control sequence and caps the length. */
    fun sanitizeTone(tone: String?): String? {
        if (tone.isNullOrBlank()) return null
        return tone
            .replace(Regex("<\\|[^|]*\\|>"), "")
            .replace(Regex("</?(tone|think|tool_call|tool_response|tools)>", RegexOption.IGNORE_CASE), "")
            .replace(Regex("\\s+"), " ")
            .trim()
            .take(TONE_MAX_CHARS)
            .ifEmpty { null }
    }

    private fun StringBuilder.turn(role: String, text: String) {
        append(IM_START).append(role).append('\n').append(text).append(IM_END).append('\n')
    }

    private fun StringBuilder.appendTools(tools: List<ToolDefinition>) {
        append("\n\n# Tools\n\nYou may call one or more functions to assist with the user query.\n\n")
        append("You are provided with function signatures within <tools></tools> XML tags:\n<tools>")
        tools.forEach { tool ->
            val signature = buildJsonObject {
                put("type", "function")
                put("function", buildJsonObject {
                    put("name", tool.name)
                    put("description", tool.description)
                    put("parameters", tool.parameters)
                })
            }
            append('\n').append(signature.toString())
        }
        append("\n</tools>\n\n")
        append("For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n")
        append("<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n</tool_call>")
    }
}
