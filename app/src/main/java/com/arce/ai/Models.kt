package com.arce.ai

import org.json.JSONObject
import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String, // "user" | "ai"
    var text: String = "",
    var thinking: String? = null,
    var tool: String? = null,
    var artifact: Artifact? = null,
    var tile: TileSpec? = null,
    var error: String? = null,
    var ts: Long = System.currentTimeMillis(),
    var streaming: Boolean = false
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("role", role); put("text", text)
        put("thinking", thinking ?: JSONObject.NULL)
        put("tool", tool ?: JSONObject.NULL)
        put("error", error ?: JSONObject.NULL)
        put("ts", ts)
        if (artifact != null) put("artifact", artifact!!.toJson())
        if (tile != null) put("tile", tile!!.toJson())
    }

    companion object {
        fun fromJson(o: JSONObject): ChatMessage = ChatMessage(
            id = o.optString("id", UUID.randomUUID().toString()),
            role = o.optString("role", "ai"),
            text = o.optString("text"),
            thinking = if (o.isNull("thinking")) null else o.optString("thinking"),
            tool = if (o.isNull("tool")) null else o.optString("tool"),
            error = if (o.isNull("error")) null else o.optString("error"),
            ts = o.optLong("ts", System.currentTimeMillis()),
            artifact = if (o.has("artifact") && !o.isNull("artifact"))
                Artifact.fromJson(o.getJSONObject("artifact")) else null,
            tile = if (o.has("tile") && !o.isNull("tile"))
                TileSpec.fromJson(o.getJSONObject("tile")) else null
        )
    }
}

data class Artifact(
    val id: String = UUID.randomUUID().toString(),
    val kind: String, // html | js | css | image
    val title: String,
    var content: String,
    val fileName: String
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("kind", kind); put("title", title)
        put("content", content); put("fileName", fileName)
    }
    companion object {
        fun fromJson(o: JSONObject) = Artifact(
            id = o.optString("id"), kind = o.optString("kind"),
            title = o.optString("title"), content = o.optString("content"),
            fileName = o.optString("fileName")
        )
    }
}

data class TileSpec(
    val title: String,
    val options: List<String>,
    val allowFreeInput: Boolean = false,
    val multiSelect: Boolean = false
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("title", title)
        put("options", org.json.JSONArray(options))
        put("allow_free_input", allowFreeInput)
        put("multi_select", multiSelect)
    }
    companion object {
        fun fromJson(o: JSONObject): TileSpec = TileSpec(
            title = o.optString("title", "選択してください"),
            options = (0 until o.optJSONArray("options")?.length() ?: 0).map {
                o.getJSONArray("options").optString(it)
            },
            allowFreeInput = o.optBoolean("allow_free_input", false),
            multiSelect = o.optBoolean("multi_select", false)
        )
    }
}

data class CodeBlock(
    val lang: String,
    val content: String,
    val closed: Boolean
)

data class ModelInfo(
    val id: String,
    val name: String,
    val sizeMB: Long,
    val url: String,
    val template: String // qwen | gemma
) {
    companion object {
        val CATALOG = listOf(
            ModelInfo(
                id = "qwen2.5-0.5b-instruct-q4_k_m",
                name = "Qwen2.5 0.5B Instruct (q4_k_m)",
                sizeMB = 469,
                url = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
                template = "qwen"
            ),
            ModelInfo(
                id = "qwen2.5-1.5b-instruct-q4_k_m",
                name = "Qwen2.5 1.5B Instruct (q4_k_m)",
                sizeMB = 1065,
                url = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
                template = "qwen"
            ),
            ModelInfo(
                id = "gemma-2-2b-it-q4_k_m",
                name = "Gemma-2 2B IT (q4_k_m)",
                sizeMB = 1750,
                url = "https://huggingface.co/google/gemma-2-2b-it-GGUF/resolve/main/2b_it_v2.gguf",
                template = "gemma"
            )
        )
        fun byId(id: String) = CATALOG.firstOrNull { it.id == id }
    }
}

data class BackendInfo(
    val name: String,
    val type: String // cpu | gpu
) {
    val available: Boolean get() = type != "missing"
}

data class BuildReport(
    val target: String, // apk | exe | jar
    val ok: Boolean,
    val log: String,
    val missing: List<String>
)
