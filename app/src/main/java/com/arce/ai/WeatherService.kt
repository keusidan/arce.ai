package com.arce.ai

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

object WeatherService {

    suspend fun fetch(city: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val url = "https://wttr.in/${Uri.encode(city)}?format=j1&lang=ja"
            val conn = URL(url).openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15000
                conn.readTimeout = 20000
                conn.requestMethod = "GET"
                conn.setRequestProperty("User-Agent", "curl/8.0")
                if (conn.responseCode != 200) {
                    return@withContext Result.failure(Exception("HTTP ${conn.responseCode}"))
                }
                val json = conn.inputStream.bufferedReader().use { it.readText() }
                Result.success(parse(json, city))
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun parse(json: String, city: String): String {
        val o = JSONObject(json)
        val sb = StringBuilder()
        try {
            val areaArr = o.optJSONArray("weather")?.optJSONObject(0)
                ?.optJSONArray("area")?.optJSONObject(0)
            val areaName = areaArr?.optString("value") ?: city
            val cur = o.optJSONArray("current_condition")?.optJSONObject(0)
            val temp = cur?.optString("temp_C")
            val feels = cur?.optString("FeelsLikeC")
            val humidity = cur?.optString("humidity")
            val windKph = cur?.optString("windspeedKmph")
            val windDir = cur?.optString("winddir16Point")
            val desc = cur?.optJSONObject("lang_ja")?.optJSONArray(0)?.optString("value")
                ?: cur?.optJSONObject("weatherDesc")?.optJSONArray(0)?.optString("value")
            sb.append(areaName).append(" の天気：")
            if (desc != null) sb.append(desc).append("、")
            if (temp != null) sb.append("気温 ").append(temp).append("°C")
            if (feels != null) sb.append("（体感 ").append(feels).append("°C）")
            sb.append("。")
            if (humidity != null) sb.append(" 湿度 ").append(humidity).append("%")
            if (windKph != null) sb.append("、風 ").append(windKph).append("km/h ").append(windDir ?: "")
            sb.append("。")

            // today's summary
            val today = o.optJSONArray("weather")?.optJSONObject(0)
            val maxT = today?.optString("maxtempC")
            val minT = today?.optString("mintempC")
            if (maxT != null && minT != null) {
                sb.append(" 本日の予想: 最高 ").append(maxT).append("°C / 最低 ").append(minT).append("°C。")
            }
        } catch (_: Exception) {
            return "天気を取得しましたが、解析に失敗しました。"
        }
        return sb.toString()
    }
}
