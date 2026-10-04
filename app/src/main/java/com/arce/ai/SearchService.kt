package com.arce.ai

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import java.net.HttpURLConnection
import java.net.URL

object SearchService {

    suspend fun search(query: String, max: Int = 5): Result<String> = withContext(Dispatchers.IO) {
        try {
            val url = "https://html.duckduckgo.com/html/?q=" + Uri.encode(query)
            val conn = URL(url).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15000
                conn.readTimeout = 20000
                conn.requestMethod = "GET"
                conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14)")
                if (conn.responseCode != 200) {
                    return@withContext Result.failure(Exception("HTTP ${conn.responseCode}"))
                }
                val html = conn.inputStream.bufferedReader().use { it.readText() }
                val doc = Jsoup.parse(html)
                val sb = StringBuilder()
                var n = 0
                for (res in doc.select("div.result")) {
                    val a = res.selectFirst("a.result__a") ?: continue
                    val title = a.text().trim()
                    if (title.isEmpty()) continue
                    val href = a.attr("href")
                    val snippet = res.selectFirst(".result__snippet")?.text()?.trim() ?: ""
                    n++
                    sb.append(n).append(". ").append(title).append("\n")
                    if (snippet.isNotEmpty()) sb.append("   ").append(snippet).append("\n")
                    if (href.isNotEmpty()) sb.append("   ").append(href).append("\n")
                    if (n >= max) break
                }
                if (n == 0) Result.failure(Exception("検索結果が見つかりませんでした"))
                else Result.success(sb.toString())
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
