package com.arce.ai

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class Conversation(
    val id: String = UUID.randomUUID().toString(),
    var title: String = "新しい会話",
    val ts: Long = System.currentTimeMillis(),
    val messages: MutableList<ChatMessage> = mutableListOf()
) {
    fun toConvJson(): JSONObject = JSONObject().apply {
        put("id", id); put("title", title); put("ts", ts)
        put("messages", JSONArray().apply { messages.forEach { put(it.toJson()) } })
    }
    companion object {
        fun fromJson(o: JSONObject) = Conversation(
            id = o.getString("id"),
            title = o.optString("title", "新しい会話"),
            ts = o.optLong("ts", System.currentTimeMillis()),
            messages = (0 until o.optJSONArray("messages")?.length() ?: 0).map {
                ChatMessage.fromJson(o.getJSONArray("messages").getJSONObject(it))
            }.toMutableList()
        )
    }
}

class HistoryStore(context: Context) {

    private val file: File =
        File(context.getExternalFilesDir(null), "generated/conversations.json")

    val all = mutableListOf<Conversation>()
    var currentId: String = ""

    init { load() }

    fun current(): Conversation {
        val c = all.firstOrNull { it.id == currentId } ?: newConversation()
        return c
    }

    fun newConversation(title: String = "新しい会話"): Conversation {
        val c = Conversation(title = title)
        all.add(0, c)
        currentId = c.id
        save()
        return c
    }

    fun open(id: String) {
        if (all.any { it.id == id }) { currentId = id }
    }

    fun delete(id: String) {
        all.removeAll { it.id == id }
        if (currentId == id) currentId = all.firstOrNull()?.id ?: ""
        save()
    }

    fun append(conv: Conversation, msg: ChatMessage) {
        conv.messages.add(msg)
        if (conv.title == "新しい会話" && msg.role == "user") {
            conv.title = msg.text.take(30)
        }
        save()
    }

    /** Streaming update: replace message in place (no full save per token). */
    fun updateInPlace(conv: Conversation, msgId: String, transform: (ChatMessage) -> Unit) {
        val m = conv.messages.firstOrNull { it.id == msgId } ?: return
        transform(m)
    }

    fun saveNow(conv: Conversation) {
        // mark dirty -> save
        save()
    }

    private fun load() {
        all.clear()
        if (!file.exists()) return
        try {
            val arr = JSONArray(file.readText())
            repeat(arr.length()) { all.add(Conversation.fromJson(arr.getJSONObject(it))) }
            currentId = all.firstOrNull()?.id ?: ""
        } catch (_: Exception) {
        }
    }

    private fun save() {
        try {
            file.parentFile?.mkdirs()
            val arr = JSONArray()
            all.forEach { arr.put(it.toConvJson()) }
            file.writeText(arr.toString())
        } catch (_: Exception) {
        }
    }
}
