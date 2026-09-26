package ai.arce.core.tools

import ai.arce.core.net.HttpGet
import ai.arce.core.net.urlEncode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

data class SearchHit(val title: String, val url: String, val snippet: String)

interface SearchProvider {
    val name: String
    suspend fun search(query: String, limit: Int): List<SearchHit>
}

/** SearXNG's JSON API (`search.formats` must include `json` in its settings.yml). */
class SearXngProvider(private val baseUrl: String, private val http: HttpGet) : SearchProvider {
    override val name = "SearXNG"

    override suspend fun search(query: String, limit: Int): List<SearchHit> {
        val body = http.get("${baseUrl.trimEnd('/')}/search?q=${query.urlEncode()}&format=json", emptyMap())
        val results = Json.parseToJsonElement(body).jsonObject["results"]?.jsonArray ?: JsonArray(emptyList())
        return results.mapNotNull { element ->
            val o = element as? JsonObject ?: return@mapNotNull null
            val url = o.string("url") ?: return@mapNotNull null
            SearchHit(o.string("title") ?: url, url, o.string("content").orEmpty())
        }.take(limit)
    }
}

/**
 * DuckDuckGo's Instant Answer API: no key, but only abstracts and related topics, not a
 * full result list. Used as a fallback when the SearXNG server cannot be reached.
 */
class DuckDuckGoInstantProvider(private val http: HttpGet) : SearchProvider {
    override val name = "DuckDuckGo Instant Answer"

    override suspend fun search(query: String, limit: Int): List<SearchHit> {
        val body = http.get("https://api.duckduckgo.com/?q=${query.urlEncode()}&format=json&no_html=1&skip_disambig=1", emptyMap())
        val root = Json.parseToJsonElement(body).jsonObject
        val hits = mutableListOf<SearchHit>()
        val abstractUrl = root.string("AbstractURL")
        if (!abstractUrl.isNullOrBlank()) {
            hits += SearchHit(root.string("Heading") ?: abstractUrl, abstractUrl, root.string("AbstractText").orEmpty())
        }
        fun collect(topics: JsonArray?) {
            topics?.forEach { t ->
                val o = t as? JsonObject ?: return@forEach
                o["Topics"]?.let { nested -> collect(nested as? JsonArray); return@forEach }
                val url = o.string("FirstURL") ?: return@forEach
                val text = o.string("Text").orEmpty()
                hits += SearchHit(text.substringBefore(" - ").ifBlank { url }, url, text)
            }
        }
        collect(root["RelatedTopics"] as? JsonArray)
        return hits.take(limit)
    }
}

sealed interface SearchOutcome {
    data class Found(val provider: String, val hits: List<SearchHit>) : SearchOutcome
    data class Failed(val errors: List<String>) : SearchOutcome
}

/**
 * Tries providers in priority order (spec §10.1), retrying each up to [retriesPerProvider]
 * times, and removes duplicate pages. When every provider fails the caller continues with
 * the local model only.
 */
class SearchService(
    private val providers: List<SearchProvider>,
    private val retriesPerProvider: Int = 1,
    private val limit: Int = 5,
) {
    suspend fun search(query: String): SearchOutcome {
        val errors = mutableListOf<String>()
        providers@ for (provider in providers) {
            for (attempt in 0..retriesPerProvider) {
                try {
                    val hits = provider.search(query, limit * 2).distinctBy { normalize(it.url) }.take(limit)
                    if (hits.isNotEmpty()) return SearchOutcome.Found(provider.name, hits)
                    // an empty answer is not an error; retrying the same provider would not help
                    errors += "${provider.name}: no results"
                    continue@providers
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    errors += "${provider.name}: ${e.message}"
                }
            }
        }
        return SearchOutcome.Failed(errors)
    }

    private fun normalize(url: String) = url.lowercase().removeSuffix("/").replace(Regex("^https?://(www\\.)?"), "")
}

internal fun JsonObject.string(key: String): String? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
