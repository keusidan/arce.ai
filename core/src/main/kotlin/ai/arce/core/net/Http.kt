package ai.arce.core.net

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class HttpException(val status: Int, message: String) : IOException(message)

/** The only network primitive the core needs; tests substitute a fake. */
fun interface HttpGet {
    suspend fun get(url: String, headers: Map<String, String>): String
}

/**
 * HttpURLConnection works unchanged on the JVM and on Android (java.net.http does not exist
 * on Android), so the core stays free of an HTTP library dependency.
 */
class UrlConnectionHttp(
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 20_000,
) : HttpGet {
    override suspend fun get(url: String, headers: Map<String, String>): String = withContext(Dispatchers.IO) {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.setRequestProperty("User-Agent", "ARCE.AI")
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            val status = connection.responseCode
            if (status !in 200..299) throw HttpException(status, "HTTP $status for ${url.substringBefore('?')}")
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }
}

fun String.urlEncode(): String = URLEncoder.encode(this, Charsets.UTF_8)
