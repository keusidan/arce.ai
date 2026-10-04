package com.arce.ai

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ChatEngine(private val app: ArceApp) {

    private val tickState = mutableStateOf(0)
    val tick: State<Int> = tickState

    @Volatile
    var busy: Boolean = false
        private set

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var genJob: Job? = null

    fun notifyChange() { tickState.value++ }

    val selectedModel: ModelInfo?
        get() = ModelInfo.byId(app.settings.selectedModelId)

    // ------------------------------------------------------------------
    // Entry points
    // ------------------------------------------------------------------

    fun send(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || busy) return
        val conv = app.history.current()
        val userMsg = ChatMessage(role = "user", text = trimmed)
        app.history.append(conv, userMsg)
        app.history.saveNow(conv)
        notifyChange()

        val intent = parseIntent(trimmed)
        when (intent.first) {
            "time" -> handleSyncTool(conv, "時刻") { timeTool() }
            "weather" -> handleAsyncTool(conv, "天気", intent.second) { arg ->
                suspend { WeatherService.fetch(arg) }
            }
            "search" -> handleAsyncTool(conv, "検索", intent.second) { arg ->
                suspend { SearchService.search(arg) }
            }
            else -> runLlm(conv)
        }
    }

    fun stop() {
        ArceLlama.stop()
    }

    fun continueLast() {
        if (busy) return
        val conv = app.history.current()
        runLlm(conv)
    }

    // ------------------------------------------------------------------
    // Tools
    // ------------------------------------------------------------------

    private fun parseIntent(text: String): Pair<String, String> {
        if (text.contains("今何時") || text.contains("現在時刻") || text.contains("今日の日付") || text.contains("今は何時")) {
            return Pair("time", "")
        }
        if (text.contains("天気") || text.contains("お天気")) {
            val city = text
                .replace(Regex("の天気(は|が|がどう|はどう|予報|を教えて|を調べ)?[はです]*[?？!！。]*"), "")
                .replace(Regex("^(教えて|教えてね|教えてくれ|調べ|調べて|調べると|天気は)"), "")
                .trim()
            return Pair("weather", if (city.isEmpty()) "新潟" else city)
        }
        if (text.contains("検索して") || text.contains("調べて") || text.contains("調べてくれ") || text.contains("調べてみて")) {
            val q = text
                .replace(Regex("^(検索して|調べて|調べてくれ|調べてみて)"), "")
                .replace(Regex("[?？!！。]*$"), "")
                .trim()
            return Pair("search", if (q.isEmpty()) text else q)
        }
        return Pair("llm", "")
    }

    private fun timeTool(): String {
        val f = SimpleDateFormat("yyyy年M月d日 (EEE) HH:mm:ss", Locale.JAPAN)
        return "現在時刻: " + f.format(Date())
    }

    private fun handleSyncTool(conv: Conversation, tool: String, block: () -> String) {
        val aiMsg = ChatMessage(role = "ai", tool = tool, streaming = true)
        app.history.append(conv, aiMsg)
        notifyChange()
        scope.launch {
            try {
                aiMsg.text = block()
            } catch (e: Exception) {
                aiMsg.error = e.message
            }
            aiMsg.streaming = false
            app.history.saveNow(conv)
            notifyChange()
        }
    }

    private fun handleAsyncTool(
        conv: Conversation,
        tool: String,
        arg: String,
        block: (String) -> suspend () -> Result<String>
    ) {
        val aiMsg = ChatMessage(role = "ai", tool = tool, streaming = true)
        app.history.append(conv, aiMsg)
        notifyChange()
        scope.launch {
            try {
                aiMsg.thinking = "取得中: $arg"
                notifyChange()
                val r = block(arg)()
                if (r.isSuccess) aiMsg.text = r.getOrThrow()
                else aiMsg.error = r.exceptionOrNull()?.message ?: "失敗しました"
            } catch (e: Exception) {
                aiMsg.error = e.message
            }
            aiMsg.streaming = false
            app.history.saveNow(conv)
            notifyChange()
        }
    }

    // ------------------------------------------------------------------
    // LLM
    // ------------------------------------------------------------------

    private fun nCtx(): Int = if (app.settings.hyperLoad) 8192 else 2048
    private fun maxTokens(): Int = if (app.settings.hyperLoad) 2048 else 1024

    private fun runLlm(conv: Conversation) {
        busy = true
        genJob?.cancel()
        val aiMsg = ChatMessage(role = "ai", streaming = true, thinking = "指示を解析中...")
        app.history.append(conv, aiMsg)
        app.history.saveNow(conv)
        notifyChange()
        app.heatMonitor.start()

        genJob = scope.launch {
            try {
                val m = selectedModel
                if (m == null) {
                    finalizeAi(conv, aiMsg, error = "モデルが選択されていません。上部のモデルメニューから選択してください。")
                    return@launch
                }
                val file = app.modelFile(m.id)
                if (!file.exists()) {
                    finalizeAi(conv, aiMsg, error = "モデルがまだダウンロードされていません。上部のモデルメニューから「+ モデルを追加」でダウンロードしてください。")
                    return@launch
                }
                if (!ArceLlama.isModelLoaded) {
                    app.history.updateInPlace(conv, aiMsg.id) {
                        it.thinking = "モデル読込中… (${file.length() / 1024 / 1024}MB)"
                    }
                    notifyChange()
                    val ok = withContext(Dispatchers.IO) {
                        ArceLlama.initModel(file.absolutePath, app.settings.nGpuLayers, nCtx(), app.settings.nThreads)
                    }
                    if (!ok) {
                        finalizeAi(conv, aiMsg, error = "モデルの読込に失敗しました。${ArceLlama.loadError ?: ""}")
                        return@launch
                    }
                }

                val prompt = buildPrompt(conv, m.template)
                val sb = StringBuilder()
                var fullText = ""
                var errText: String? = null
                app.history.updateInPlace(conv, aiMsg.id) { it.thinking = "生成を開始します" }
                notifyChange()

                withContext(Dispatchers.IO) {
                    ArceLlama.generate(prompt, maxTokens(), 0.7f, 1.1f, object : ArceLlama.TokenCallback {
                        override fun onToken(piece: String) {
                            sb.append(piece)
                            app.history.updateInPlace(conv, aiMsg.id) { it.text = sb.toString() }
                            if (sb.length % 48 < piece.length + 1) notifyChange()
                        }

                        override fun onDone(full: String, errorMsg: String?) {
                            fullText = full
                            errText = errorMsg
                        }
                    })
                }

                if (errText != null) {
                    finalizeAi(conv, aiMsg, error = errText, partial = fullText)
                } else {
                    postProcess(conv, aiMsg, fullText)
                }
            } catch (e: Exception) {
                finalizeAi(conv, aiMsg, error = "例外: ${e.message}")
            } finally {
                busy = false
                genJob = null
                if (!app.settings.forceTempMonitor) app.heatMonitor.stop()
                notifyChange()
            }
        }
    }

    private fun postProcess(conv: Conversation, aiMsg: ChatMessage, text: String) {
        aiMsg.text = text
        aiMsg.streaming = false
        aiMsg.thinking = null
        aiMsg.tile = TileParser.extractTiles(text)

        val blocks = TileParser.extractCodeBlocks(text)
        val allClosed = blocks.isEmpty() || blocks.all { it.closed }
        if (allClosed) {
            val html = blocks.firstOrNull {
                it.closed && (it.lang == "html" || it.lang == "htm" ||
                    it.content.trimStart().startsWith("<!DOCTYPE") ||
                    (it.content.contains("<html", ignoreCase = true) && it.lang.isEmpty()))
            }
            val js = blocks.firstOrNull { it.closed && (it.lang == "js" || it.lang == "javascript") }
            val css = blocks.firstOrNull { it.closed && it.lang == "css" }
            val art = html?.let {
                Artifact(kind = "html", title = "HTMLプレビュー", content = it.content,
                    fileName = "art_${aiMsg.id}.html")
            } ?: js?.let {
                Artifact(kind = "js", title = "JavaScript", content = it.content,
                    fileName = "art_${aiMsg.id}.js")
            } ?: css?.let {
                Artifact(kind = "css", title = "CSS", content = it.content,
                    fileName = "art_${aiMsg.id}.css")
            }
            if (art != null) {
                aiMsg.artifact = art
                app.previewServer.saveArtifact(art.fileName, art.content)
            }
        }
        app.history.saveNow(conv)
        notifyChange()
    }

    private fun finalizeAi(conv: Conversation, aiMsg: ChatMessage, error: String, partial: String = "") {
        if (partial.isNotEmpty() && aiMsg.text.isEmpty()) aiMsg.text = partial
        aiMsg.error = error
        aiMsg.streaming = false
        app.history.saveNow(conv)
        notifyChange()
    }

    // ------------------------------------------------------------------
    // Prompt templates (built by concatenation only)
    // ------------------------------------------------------------------

    private fun buildPrompt(conv: Conversation, template: String): String {
        val sys = "あなたはARCE.AIです。日本語で簡潔に答えてください。" +
            "コードを生成する場合は ```html / ```js / ```css のフェンスを使い、" +
            "動作する完成コードをフェンス内に含めてください。" +
            "質問の選択肢を提示する場合は ```tile {\"title\":\"...\",\"options\":[\"...\",...]} の形式でJSONを1つ含めてください。"
        val sb = StringBuilder()
        if (template == "qwen") {
            val sysTag = "<|im_start|>system\n"
            val endTag = "<|im_end|>\n"
            val userTag = "<|im_start|>user\n"
            val asstTag = "<|im_start|>assistant\n"
            sb.append(sysTag).append(sys).append(endTag)
            for (m in conv.messages) {
                if (m.role == "user") {
                    sb.append(userTag).append(m.text).append(endTag)
                } else if (m.text.isNotEmpty()) {
                    sb.append(asstTag).append(m.text).append(endTag)
                }
            }
            sb.append(asstTag)
        } else {
            val startTag = "<start_of_turn>"
            val endTag = "<end_of_turn>\n"
            sb.append(startTag).append("user\n").append(sys).append(endTag)
            for (m in conv.messages) {
                if (m.role == "user") {
                    sb.append(startTag).append("user\n").append(m.text).append(endTag)
                } else if (m.text.isNotEmpty()) {
                    sb.append(startTag).append("model\n").append(m.text).append(endTag)
                }
            }
            sb.append(startTag).append("model\n")
        }
        return sb.toString()
    }

    fun shutdown() {
        scope.cancel()
    }
}
