package ai.arce.core.agent

import ai.arce.core.protocol.Protocol
import ai.arce.core.protocol.ToolDefinition

/**
 * An agent is a role, not a model (spec §17): extra system instructions, the tools it may
 * call, and the smallest model it is expected to work with.
 */
data class AgentDefinition(
    val id: String,
    val displayName: String,
    val instructions: String,
    val tools: List<ToolDefinition>,
    /** Parameters in billions; small models are unreliable at tool use (spec §17.2). */
    val minModelParamsB: Double,
    /** Lower-cased words that suggest this agent in a request. */
    val keywords: List<String>,
)

object Agents {
    val general = AgentDefinition(
        id = "general",
        displayName = "General Chat",
        instructions = "Answer conversationally. Use tools only when they are clearly needed.",
        tools = listOf(Protocol.askUser, Protocol.webSearch, Protocol.getWeather, Protocol.getTime),
        minModelParamsB = 1.7,
        keywords = emptyList(),
    )

    val coding = AgentDefinition(
        id = "coding",
        displayName = "Coding",
        instructions = "You are writing code. Give complete, runnable files, each in its own fenced block " +
            "with the language (```kotlin, ```python, ```html ...). Ask with ask_user when a key choice " +
            "(language, platform, scope) is missing instead of guessing. The app can run Python and Java and " +
            "build JAR/APK files on the phone: Java must be one file in Java 8 syntax (no `var`); an Android " +
            "app extends android.app.Activity and builds its UI in code, because XML layouts and images are not supported.",
        tools = listOf(Protocol.askUser, Protocol.webSearch),
        minModelParamsB = 4.0,
        keywords = listOf("作って", "実装", "コード", "プログラム", "関数", "バグ", "エラー", "code", "implement",
            "function", "bug", "kotlin", "python", "java", "javascript", "rust", "c++", "script", "スクリプト"),
    )

    val research = AgentDefinition(
        id = "research",
        displayName = "Research / Search",
        instructions = "Research the question. Search first, compare sources, and cite the URLs you rely on.",
        tools = listOf(Protocol.webSearch, Protocol.getTime, Protocol.askUser),
        minModelParamsB = 4.0,
        keywords = listOf("調べ", "検索", "最新", "ニュース", "比較", "ソース", "search", "latest", "news", "compare", "source"),
    )

    val artifact = AgentDefinition(
        id = "artifact",
        displayName = "Artifact",
        instructions = "Build a self-contained web page. Put all HTML, CSS and JavaScript in ONE ```html block " +
            "so it can be previewed; do not load external scripts. Add a short usage note after the block.",
        tools = listOf(Protocol.askUser),
        minModelParamsB = 4.0,
        keywords = listOf("html", "css", "webページ", "ウェブページ", "サイト", "ゲーム", "プレビュー", "artifact",
            "アーティファクト", "ui", "page", "game"),
    )

    val fileAnalysis = AgentDefinition(
        id = "file-analysis",
        displayName = "File Analysis",
        instructions = "The user attached files. Base the answer on their contents and quote the relevant parts.",
        tools = listOf(Protocol.askUser),
        minModelParamsB = 4.0,
        keywords = listOf("ファイル", "添付", "要約", "解析", "読んで", "file", "attached", "summarize", "analyze"),
    )

    val all = listOf(general, coding, research, artifact, fileAnalysis)

    fun byId(id: String?): AgentDefinition? = all.firstOrNull { it.id == id }
}

/**
 * Rule-based selection (spec §17.1): keyword hits narrow the candidates; the user can
 * always override. Attachments steer towards file analysis.
 */
object AgentSelector {
    fun select(request: String, hasAttachments: Boolean, override: String?): AgentDefinition {
        Agents.byId(override)?.let { return it }
        // ties keep the order of Agents.all, i.e. the more specific agent listed first wins
        return rank(request, hasAttachments).firstOrNull()?.first ?: Agents.general
    }

    /** Agents with at least one hit, best first (stable for ties). */
    fun rank(request: String, hasAttachments: Boolean): List<Pair<AgentDefinition, Int>> {
        val text = request.lowercase()
        return Agents.all
            .map { agent -> agent to agent.keywords.count { it in text } + if (hasAttachments && agent == Agents.fileAnalysis) 2 else 0 }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
    }

    /**
     * The rules are unsure when nothing matched in a real sentence, or when the best two tie.
     * Short greetings ("こんにちは") are plainly general chat and need no model call.
     */
    fun isAmbiguous(request: String, hasAttachments: Boolean): Boolean {
        val ranked = rank(request, hasAttachments)
        return when {
            ranked.isEmpty() -> request.trim().length >= 20
            ranked.size >= 2 -> ranked[0].second == ranked[1].second
            else -> false
        }
    }
}

/**
 * Final selection by the loaded model (spec §17.1): only when [AgentSelector] is unsure.
 * The model must answer `{"agent": "<id>"}` under a strict JSON grammar, so it cannot invent
 * an agent; any failure or timeout falls back to the rule-based choice.
 */
class AgentRouter(private val classify: suspend (prompt: String, schema: String) -> String?) {
    suspend fun select(request: String, hasAttachments: Boolean, override: String?, useModel: Boolean): AgentDefinition {
        Agents.byId(override)?.let { return it }
        val byRules = AgentSelector.select(request, hasAttachments, null)
        if (!useModel || !AgentSelector.isAmbiguous(request, hasAttachments)) return byRules
        val answer = runCatching { classify(prompt(request, hasAttachments), SCHEMA) }.getOrNull() ?: return byRules
        return parse(answer) ?: byRules
    }

    companion object {
        val SCHEMA: String = buildString {
            append("""{"type":"object","properties":{"agent":{"type":"string","enum":[""")
            append(Agents.all.joinToString(",") { "\"${it.id}\"" })
            append("""]}},"required":["agent"],"additionalProperties":false}""")
        }

        fun prompt(request: String, hasAttachments: Boolean): String = buildString {
            append("<|im_start|>system\n")
            append("Pick the one assistant role that fits the user's request best. Roles:\n")
            Agents.all.forEach { append("- ${it.id}: ${it.displayName}. ${it.instructions}\n") }
            append("Reply only with JSON like {\"agent\": \"general\"}.<|im_end|>\n")
            append("<|im_start|>user\n")
            if (hasAttachments) append("(files attached)\n")
            append(request.take(1000))
            append("<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        }

        fun parse(answer: String): AgentDefinition? =
            Regex("\"agent\"\\s*:\\s*\"([a-z-]+)\"").find(answer)?.groupValues?.get(1)?.let(Agents::byId)
    }
}
