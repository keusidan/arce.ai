package ai.arce.core.render

data class Span(val text: String, val bold: Boolean)

sealed interface Block {
    data class Paragraph(val spans: List<Span>) : Block
    /** [closed] is false while the fence is still being streamed; an Artifact can wait for it. */
    data class Code(val language: String, val code: String, val closed: Boolean) : Block
}

/**
 * The two notations the system prompt asks for: `**bold**` and fenced code blocks.
 * Tolerates half-streamed input: an unclosed fence becomes an open code block and an
 * unmatched `**` is shown as-is.
 */
object MarkdownLite {
    private const val FENCE = "```"

    fun parse(text: String): List<Block> {
        val blocks = mutableListOf<Block>()
        var rest = text
        while (rest.isNotEmpty()) {
            val open = rest.indexOf(FENCE)
            if (open < 0) {
                addParagraph(rest, blocks)
                break
            }
            addParagraph(rest.substring(0, open), blocks)
            val afterFence = rest.substring(open + FENCE.length)
            val headerEnd = afterFence.indexOf('\n')
            if (headerEnd < 0) {
                // only "```lang" so far
                blocks += Block.Code(afterFence.trim(), "", closed = false)
                break
            }
            val language = afterFence.substring(0, headerEnd).trim()
            val body = afterFence.substring(headerEnd + 1)
            val close = body.indexOf(FENCE)
            if (close < 0) {
                blocks += Block.Code(language, body, closed = false)
                break
            }
            blocks += Block.Code(language, body.substring(0, close).removeSuffix("\n"), closed = true)
            rest = body.substring(close + FENCE.length).removePrefix("\n")
        }
        return blocks
    }

    fun spans(text: String): List<Span> {
        val spans = mutableListOf<Span>()
        var i = 0
        var bold = false
        val current = StringBuilder()
        while (i < text.length) {
            if (text.startsWith("**", i) && (bold || text.indexOf("**", i + 2) >= 0)) {
                if (current.isNotEmpty()) spans += Span(current.toString(), bold)
                current.clear()
                bold = !bold
                i += 2
            } else {
                current.append(text[i])
                i++
            }
        }
        if (current.isNotEmpty()) spans += Span(current.toString(), bold)
        return spans
    }

    private fun addParagraph(text: String, blocks: MutableList<Block>) {
        val trimmed = text.trim('\n')
        if (trimmed.isNotEmpty()) blocks += Block.Paragraph(spans(trimmed))
    }
}
