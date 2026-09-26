package ai.arce.core.chat

/** A file the user added to a message, already decoded to text. */
data class Attachment(val name: String, val text: String)

/**
 * Keeps attachments from swamping the context window (spec §18): caps the number of files
 * and the characters taken from each and in total, and says so when it cuts.
 */
object AttachmentPolicy {
    const val MAX_FILES = 5
    const val MAX_CHARS_PER_FILE = 8_000
    const val MAX_TOTAL_CHARS = 16_000

    fun compose(text: String, attachments: List<Attachment>): String {
        if (attachments.isEmpty()) return text
        var budget = MAX_TOTAL_CHARS
        return buildString {
            attachments.take(MAX_FILES).forEach { file ->
                val limit = minOf(MAX_CHARS_PER_FILE, budget)
                val body = file.text.take(limit)
                budget -= body.length
                append("<file name=\"").append(file.name.replace("\"", "'")).append("\">\n")
                append(body)
                if (body.length < file.text.length) {
                    append("\n[… ${file.text.length - body.length} characters omitted …]")
                }
                append("\n</file>\n")
            }
            if (attachments.size > MAX_FILES) append("[${attachments.size - MAX_FILES} more files not included]\n")
            append(text)
        }
    }
}
