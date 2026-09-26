package ai.arce.core.render

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class MarkdownLiteTest {
    @Test
    fun `bold spans`() {
        assertEquals(
            listOf(Span("これは", false), Span("重要", true), Span("です", false)),
            MarkdownLite.spans("これは**重要**です"),
        )
    }

    @Test
    fun `an unmatched marker stays literal while streaming`() {
        assertEquals(listOf(Span("a **b", false)), MarkdownLite.spans("a **b"))
    }

    @Test
    fun `text and a closed code block`() {
        assertEquals(
            listOf(
                Block.Paragraph(listOf(Span("例:", false))),
                Block.Code("html", "<p>hi</p>", closed = true),
                Block.Paragraph(listOf(Span("以上", false))),
            ),
            MarkdownLite.parse("例:\n```html\n<p>hi</p>\n```\n以上"),
        )
    }

    @Test
    fun `a code block still being streamed is open`() {
        assertEquals(
            listOf(Block.Code("kotlin", "fun main() {", closed = false)),
            MarkdownLite.parse("```kotlin\nfun main() {"),
        )
        assertEquals(listOf(Block.Code("py", "", closed = false)), MarkdownLite.parse("```py"))
    }
}
