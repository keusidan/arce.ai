package ai.arce.core.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Semantic version "1.2.3" with an optional "-suffix"; a suffix sorts before the plain release. */
data class Version(val major: Int, val minor: Int, val patch: Int, val suffix: String = "") : Comparable<Version> {
    override fun compareTo(other: Version): Int = compareValuesBy(
        this, other, { it.major }, { it.minor }, { it.patch }, { if (it.suffix.isEmpty()) "￿" else it.suffix },
    )

    override fun toString() = "$major.$minor.$patch" + if (suffix.isEmpty()) "" else "-$suffix"

    companion object {
        private val pattern = Regex("^v?(\\d+)\\.(\\d+)\\.(\\d+)(?:[-.](.+))?$")

        fun parse(text: String): Version? = pattern.matchEntire(text.trim())?.destructured?.let { (a, b, c, s) ->
            Version(a.toInt(), b.toInt(), c.toInt(), s)
        }
    }
}

data class ReleaseAsset(val id: Long, val name: String, val sizeBytes: Long)

data class Release(val tag: String, val version: Version, val notes: String, val assets: List<ReleaseAsset>) {
    val apk: ReleaseAsset? get() = assets.firstOrNull { it.name.endsWith(".apk") }
    val checksum: ReleaseAsset? get() = assets.firstOrNull { it.name.endsWith(".apk.sha256") }
}

object ReleaseParser {
    /** Parses GitHub's "get the latest release" response. */
    fun parse(json: String): Release? {
        val o = Json.parseToJsonElement(json).jsonObject
        val tag = o["tag_name"]?.jsonPrimitive?.contentOrNull ?: return null
        val version = Version.parse(tag) ?: return null
        val assets = o["assets"]?.jsonArray.orEmpty().mapNotNull { a ->
            val asset = a as? JsonObject ?: return@mapNotNull null
            ReleaseAsset(
                id = asset["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null,
                name = asset["name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null,
                sizeBytes = asset["size"]?.jsonPrimitive?.longOrNull ?: 0,
            )
        }
        return Release(tag, version, o["body"]?.jsonPrimitive?.contentOrNull.orEmpty(), assets)
    }

    /** "<hex>  file.apk" as written by sha256sum. */
    fun parseChecksum(text: String): String? = text.trim().split(Regex("\\s+")).firstOrNull()
        ?.takeIf { it.matches(Regex("[0-9a-fA-F]{64}")) }
}
