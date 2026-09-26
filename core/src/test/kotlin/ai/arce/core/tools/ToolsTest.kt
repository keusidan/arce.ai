package ai.arce.core.tools

import ai.arce.core.net.HttpException
import ai.arce.core.net.HttpGet
import ai.arce.core.protocol.ToolCall
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ToolsTest {
    private fun http(vararg routes: Pair<String, String>) = HttpGet { url, _ ->
        routes.firstOrNull { url.contains(it.first) }?.second ?: throw HttpException(404, "no route for $url")
    }

    private val searxJson = """{"results":[
        {"url":"https://example.com/a","title":"A","content":"alpha"},
        {"url":"https://www.example.com/a/","title":"A dup","content":"dup"},
        {"url":"https://example.org/b","title":"B","content":"beta"}]}"""

    @Test
    fun `searxng results are parsed and duplicates removed`() = runTest {
        val service = SearchService(listOf(SearXngProvider("http://pi:8080/", http("pi:8080/search" to searxJson))))
        val found = assertInstanceOf(SearchOutcome.Found::class.java, service.search("q"))
        assertEquals(listOf("https://example.com/a", "https://example.org/b"), found.hits.map { it.url })
    }

    @Test
    fun `falls back to the next provider and finally reports failure`() = runTest {
        val ddg = """{"Heading":"Kotlin","AbstractURL":"https://kotlinlang.org","AbstractText":"A language","RelatedTopics":[]}"""
        val service = SearchService(
            listOf(SearXngProvider("http://pi", http()), DuckDuckGoInstantProvider(http("duckduckgo" to ddg))),
            retriesPerProvider = 1,
        )
        val found = assertInstanceOf(SearchOutcome.Found::class.java, service.search("kotlin"))
        assertEquals("DuckDuckGo Instant Answer", found.provider)

        val none = SearchService(listOf(SearXngProvider("http://pi", http())), retriesPerProvider = 1)
        val failed = assertInstanceOf(SearchOutcome.Failed::class.java, none.search("x"))
        assertEquals(2, failed.errors.size, "one try plus one retry")
    }

    @Test
    fun `weather combines geocoding and forecast`() = runTest {
        val weather = OpenMeteoWeather(
            http(
                "geocoding-api" to """{"results":[{"name":"東京","admin1":"東京都","country":"日本","latitude":35.68,"longitude":139.69}]}""",
                "api.open-meteo.com" to """{"current":{"temperature_2m":21.5,"weather_code":3,"wind_speed_10m":7.2},
                    "daily":{"temperature_2m_max":[24.0],"temperature_2m_min":[18.1]}}""",
            ),
        )
        val report = weather.report("東京")
        assertEquals("東京, 東京都, 日本", report.place)
        assertEquals("曇り", report.description)
        assertEquals(24.0, report.todayMaxC)
    }

    @Test
    fun `runtime answers time in the requested zone and reports search failure softly`() = runTest {
        val clock = Clock.fixed(Instant.parse("2026-09-26T12:00:00Z"), ZoneId.of("UTC"))
        val runtime = DefaultToolRuntime(SearchService(listOf(SearXngProvider("http://pi", http()))), null, clock)

        val time = runtime.run(ToolCall.GetTime("Asia/Tokyo"))
        assertTrue(time.response.contains("2026-09-26") && time.response.contains("21:00:00"), time.response)

        val search = runtime.run(ToolCall.WebSearch("x"))
        assertTrue(search.activity.failed)
        assertTrue(search.response.contains("own knowledge"))

        val offline = DefaultToolRuntime(null, null, clock).run(ToolCall.WebSearch("x"))
        assertTrue(offline.activity.failed)
        assertFalse(offline.response.isBlank())
    }
}
