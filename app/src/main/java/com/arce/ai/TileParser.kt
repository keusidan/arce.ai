package com.arce.ai

import org.json.JSONObject
import java.util.regex.Pattern

object TileParser {

    /**
     * Extract a tile spec from model output. Accepts:
     *   ```tile {"title": "...", "options": [...], ...} ```
     *   {"tile": {"title": ..., "options": [...]}}
     *   raw {"title": ..., "options": [...]}
     */
    fun extractTiles(text: String): TileSpec? {
        val m = Pattern.compile("```tile\\s*([\\s\\S]*?)```").matcher(text)
        if (m.find()) {
            parse(m.group(1)?.trim())?.let { return it }
        }
        val i = text.indexOf("\"options\"")
        if (i >= 0) {
            // walk back to the enclosing '{'
            var start = i
            while (start > 0 && text[start] != '{') start--
            if (start > 0) {
                balancedRange(text.substring(start))?.let { (s, e) ->
                    parse(text.substring(start + s, start + e + 1))?.let { return it }
                }
            }
        }
        return null
    }

    private fun parse(s: String?): TileSpec? {
        if (s.isNullOrBlank()) return null
        val t = s.trim()
        val j = try { JSONObject(t) } catch (_: Exception) { null } ?: return null
        val o = if (j.has("tile") && !j.isNull("tile")) j.optJSONObject("tile") ?: j else j
        if (!o.has("options")) return null
        return try {
            TileSpec.fromJson(o)
        } catch (_: Exception) {
            null
        }
    }

    /** Range [start, end] of the balanced object starting at the first '{'. */
    private fun balancedRange(text: String): Pair<Int, Int>? {
        val start = text.indexOf('{')
        if (start < 0) return null
        var depth = 0
        var inStr = false
        var esc = false
        for (i in start until text.length) {
            val c = text[i]
            if (inStr) {
                if (esc) esc = false
                else if (c == '\\') esc = true
                else if (c == '"') inStr = false
                continue
            }
            when (c) {
                '"' -> inStr = true
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return Pair(start, i)
                }
            }
        }
        return null
    }

    /**
     * Extract fenced code blocks. A block whose closing fence is missing is
     * reported as closed=false (partial-preview guard 助言書準拠).
     */
    fun extractCodeBlocks(text: String): List<CodeBlock> {
        val blocks = mutableListOf<CodeBlock>()
        var i = 0
        while (true) {
            val start = text.indexOf("```", i)
            if (start < 0) break
            val lineEnd = text.indexOf('\n', start)
            if (lineEnd < 0) {
                blocks.add(CodeBlock("", text.substring(start + 3).trim(), false))
                break
            }
            val lang = text.substring(start + 3, lineEnd).trim().lowercase()
            val close = text.indexOf("```", lineEnd + 1)
            if (close < 0) {
                blocks.add(CodeBlock(lang, text.substring(lineEnd + 1).trimEnd('\n'), false))
                break
            }
            blocks.add(CodeBlock(lang, text.substring(lineEnd + 1, close).trimEnd('\n'), true))
            i = close + 3
        }
        return blocks
    }
}
