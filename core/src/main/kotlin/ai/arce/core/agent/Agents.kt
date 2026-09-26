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
            "(language, platform, scope) is missing instead of guessing.",
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
        val text = request.lowercase()
        val scored = Agents.all
            .map { agent -> agent to agent.keywords.count { it in text } + if (hasAttachments && agent == Agents.fileAnalysis) 2 else 0 }
            .filter { it.second > 0 }
        // ties keep the order of Agents.all, i.e. the more specific agent listed first wins
        return scored.maxByOrNull { it.second }?.first ?: Agents.general
    }
}
