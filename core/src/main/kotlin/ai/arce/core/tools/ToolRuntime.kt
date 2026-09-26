package ai.arce.core.tools

import ai.arce.core.protocol.ToolCall
import java.time.Clock
import java.time.DateTimeException
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlinx.serialization.Serializable

@Serializable
data class Link(val title: String, val url: String)

/** What the chat shows about a tool run (e.g. the collapsible Search list). */
@Serializable
data class ToolActivity(
    val tool: String,
    val summary: String,
    val links: List<Link> = emptyList(),
    val failed: Boolean = false,
)

/** [response] goes back to the model inside <tool_response>; [activity] goes to the UI. */
data class ToolOutcome(val response: String, val activity: ToolActivity)

/** Runs every tool except ask_user, which needs the user and is handled by the chat itself. */
fun interface ToolRuntime {
    suspend fun run(call: ToolCall): ToolOutcome

    companion object {
        val None = ToolRuntime { call ->
            ToolOutcome("This tool is not available.", ToolActivity(call.javaClass.simpleName, "利用できません", failed = true))
        }
    }
}

class DefaultToolRuntime(
    private val search: SearchService?,
    private val weather: OpenMeteoWeather?,
    private val clock: Clock = Clock.systemDefaultZone(),
) : ToolRuntime {

    override suspend fun run(call: ToolCall): ToolOutcome = when (call) {
        is ToolCall.WebSearch -> search(call.query)
        is ToolCall.GetWeather -> weather(call.location)
        is ToolCall.GetTime -> time(call.timezone)
        is ToolCall.AskUser -> error("ask_user is answered by the user, not run as a tool")
    }

    private suspend fun search(query: String): ToolOutcome {
        val service = search
            ?: return ToolOutcome(
                "Web search is turned off. Answer from your own knowledge and say so.",
                ToolActivity("Search", "検索はOFFです", failed = true),
            )
        return when (val outcome = service.search(query)) {
            is SearchOutcome.Found -> ToolOutcome(
                response = buildString {
                    append("Results for \"").append(query).append("\" from ").append(outcome.provider).append(":\n")
                    outcome.hits.forEachIndexed { i, hit ->
                        append(i + 1).append(". ").append(hit.title).append('\n')
                        append("   ").append(hit.url).append('\n')
                        if (hit.snippet.isNotBlank()) append("   ").append(hit.snippet.take(300)).append('\n')
                    }
                    append("Cite the URLs you use.")
                },
                activity = ToolActivity("Search", "「$query」 ${outcome.hits.size}件（${outcome.provider}）", outcome.hits.map { Link(it.title, it.url) }),
            )
            // spec §10.1: every provider failed -> continue with the local model only
            is SearchOutcome.Failed -> ToolOutcome(
                "Web search failed. Answer from your own knowledge and tell the user the answer was not checked online.",
                ToolActivity("Search", "検索に失敗（ローカルAIのみで回答）: ${outcome.errors.lastOrNull().orEmpty()}", failed = true),
            )
        }
    }

    private suspend fun weather(location: String): ToolOutcome {
        val service = weather ?: return ToolOutcome("Weather is unavailable.", ToolActivity("Weather", "天気は利用できません", failed = true))
        return try {
            val r = service.report(location)
            val text = listOfNotNull(
                "${r.place}: ${r.description} ${r.temperatureC}°C",
                r.todayMaxC?.let { "max $it°C" },
                r.todayMinC?.let { "min $it°C" },
                r.windKmh?.let { "wind $it km/h" },
            ).joinToString(", ")
            ToolOutcome("Current weather: $text (Open-Meteo)", ToolActivity("Weather", text, listOf(Link("Open-Meteo", "https://open-meteo.com/"))))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            ToolOutcome("Weather lookup failed: ${e.message}", ToolActivity("Weather", "天気の取得に失敗: ${e.message}", failed = true))
        }
    }

    private fun time(timezone: String?): ToolOutcome {
        val zone = try {
            timezone?.let { ZoneId.of(it) } ?: clock.zone
        } catch (e: DateTimeException) {
            clock.zone
        }
        val now = ZonedDateTime.now(clock.withZone(zone))
        val text = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd (E) HH:mm:ss")) + " " + zone.id
        return ToolOutcome("Current time: $text", ToolActivity("Time", text))
    }
}
