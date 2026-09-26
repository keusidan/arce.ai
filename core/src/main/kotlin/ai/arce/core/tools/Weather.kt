package ai.arce.core.tools

import ai.arce.core.net.HttpGet
import ai.arce.core.net.urlEncode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class WeatherReport(
    val place: String,
    val temperatureC: Double,
    val description: String,
    val windKmh: Double?,
    val todayMaxC: Double?,
    val todayMinC: Double?,
)

class WeatherException(message: String) : Exception(message)

/** Open-Meteo: geocoding, then the current conditions. No API key (non-commercial use). */
class OpenMeteoWeather(private val http: HttpGet) {
    suspend fun report(location: String): WeatherReport {
        val geo = Json.parseToJsonElement(
            http.get(
                "https://geocoding-api.open-meteo.com/v1/search?name=${location.urlEncode()}&count=1&language=ja&format=json",
                emptyMap(),
            ),
        ).jsonObject
        val place = (geo["results"]?.jsonArray?.firstOrNull() as? JsonObject)
            ?: throw WeatherException("場所が見つかりません: $location")
        val lat = place["latitude"]!!.jsonPrimitive.doubleOrNull!!
        val lon = place["longitude"]!!.jsonPrimitive.doubleOrNull!!
        val name = listOfNotNull(place.string("name"), place.string("admin1"), place.string("country")).distinct().joinToString(", ")

        val forecast = Json.parseToJsonElement(
            http.get(
                "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
                    "&current=temperature_2m,weather_code,wind_speed_10m" +
                    "&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto",
                emptyMap(),
            ),
        ).jsonObject
        val current = forecast["current"]?.jsonObject ?: throw WeatherException("天気を取得できませんでした")
        val daily = forecast["daily"]?.jsonObject
        return WeatherReport(
            place = name,
            temperatureC = current["temperature_2m"]!!.jsonPrimitive.doubleOrNull!!,
            description = describe(current["weather_code"]?.jsonPrimitive?.intOrNull),
            windKmh = current["wind_speed_10m"]?.jsonPrimitive?.doubleOrNull,
            todayMaxC = daily?.get("temperature_2m_max")?.jsonArray?.firstOrNull()?.jsonPrimitive?.doubleOrNull,
            todayMinC = daily?.get("temperature_2m_min")?.jsonArray?.firstOrNull()?.jsonPrimitive?.doubleOrNull,
        )
    }

    companion object {
        /** WMO weather interpretation codes used by Open-Meteo. */
        fun describe(code: Int?): String = when (code) {
            0 -> "快晴"
            1, 2 -> "晴れ"
            3 -> "曇り"
            45, 48 -> "霧"
            51, 53, 55, 56, 57 -> "霧雨"
            61, 63, 65, 66, 67 -> "雨"
            71, 73, 75, 77 -> "雪"
            80, 81, 82 -> "にわか雨"
            85, 86 -> "にわか雪"
            95, 96, 99 -> "雷雨"
            else -> "不明"
        }
    }
}
