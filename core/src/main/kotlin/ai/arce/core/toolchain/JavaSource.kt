package ai.arce.core.toolchain

/**
 * What the on-device Java tools need to know about one source file from a code block:
 * its file name, the class with `main`, and the Activity for an APK. Regex-based on purpose:
 * it only has to be right for the single-file programs a chat produces; the compiler reports
 * anything else.
 */
data class JavaSource(
    val code: String,
    val packageName: String?,
    /** Public top-level class, which fixes the file name; else the first class. */
    val primaryClass: String,
    /** Fully qualified class with `public static void main(String[])`, if any. */
    val mainClass: String?,
    /** Fully qualified class extending android.app.Activity (or a known subclass), if any. */
    val activityClass: String?,
) {
    val fileName: String get() = "$primaryClass.java"

    /** The same source with a package added when it had none (an APK's classes need one). */
    fun withPackage(fallback: String): JavaSource =
        if (packageName != null) this else parse("package $fallback;\n$code")

    companion object {
        const val JAVA_LEVEL = "1.8"

        private val comments = Regex("""/\*[\s\S]*?\*/|//[^\n]*""")
        private val strings = Regex(""""(?:\\.|[^"\\\n])*"""")
        private val pkg = Regex("""^\s*package\s+([\w.]+)\s*;""", RegexOption.MULTILINE)
        private val publicClass = Regex("""\bpublic\s+(?:final\s+|abstract\s+)*class\s+(\w+)""")
        private val anyClass = Regex("""\bclass\s+(\w+)""")
        private val mainMethod = Regex("""\bpublic\s+static\s+void\s+main\s*\(\s*(?:final\s+)?String\s*(?:\[\s*]\s*\w+|\.\.\.\s*\w+|\w+\s*\[\s*])\s*\)""")
        private val activity = Regex("""\bclass\s+(\w+)\s+extends\s+(?:android\.app\.)?(?:Activity|ListActivity)\b""")

        fun parse(code: String): JavaSource {
            // Search a copy without comments and string contents so they cannot fake a match.
            val bare = strings.replace(comments.replace(code, " "), "\"\"")
            val packageName = pkg.find(bare)?.groupValues?.get(1)
            val classes = anyClass.findAll(bare).map { it.groupValues[1] to it.range.first }.toList()
            require(classes.isNotEmpty()) { "クラス宣言が見つかりません" }
            val primary = publicClass.find(bare)?.groupValues?.get(1) ?: classes.first().first

            fun qualified(name: String) = if (packageName == null) name else "$packageName.$name"

            // main belongs to the nearest class declared before it
            val main = mainMethod.find(bare)?.let { m -> classes.lastOrNull { it.second < m.range.first }?.first }
            return JavaSource(
                code = code,
                packageName = packageName,
                primaryClass = primary,
                mainClass = main?.let(::qualified),
                activityClass = activity.find(bare)?.groupValues?.get(1)?.let(::qualified),
            )
        }
    }
}
