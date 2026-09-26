package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.Screen
import ai.arce.app.model.ModelState
import ai.arce.app.system.ConsentManager
import ai.arce.app.system.DeviceInfo
import ai.arce.core.agent.Agents
import ai.arce.core.chat.Attachment
import ai.arce.core.chat.ChatState
import ai.arce.core.chat.Role
import ai.arce.core.chat.UiMessage
import ai.arce.core.generation.FinishReason
import ai.arce.core.generation.TaskState
import ai.arce.core.protocol.QuestionTile
import ai.arce.core.render.Block
import ai.arce.core.render.MarkdownLite
import ai.arce.core.tools.ToolActivity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColor
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

@Composable
fun ColumnScope.ChatScreen(container: AppContainer, go: (Screen) -> Unit) {
    val chat by container.chat.state.collectAsStateWithLifecycle()
    val model by container.models.state.collectAsStateWithLifecycle()
    val settings by container.settings.collectAsStateWithLifecycle()
    val thermal by remember { container.device.thermalStatusFlow() }.collectAsStateWithLifecycle(PowerManager.THERMAL_STATUS_NONE)

    // spec §32 status line
    Text(
        "Model: ${model.loadedName ?: "未選択"} / Backend: ${if (model.gpuDevices.isEmpty()) "CPU" else "GPU"} / " +
            "Thinking: ${if (chat.thinkingEnabled) "ON" else "OFF"} / HyperLoad: ${if (settings.hyperLoad) "ON" else "OFF"} / " +
            "Agent: ${Agents.byId(settings.agentOverride)?.displayName ?: "自動"}",
        style = MaterialTheme.typography.labelSmall,
        modifier = Modifier.padding(horizontal = 12.dp),
    )
    model.busy?.let { Text(it, modifier = Modifier.padding(horizontal = 12.dp)) }
    model.error?.let { Text("モデル: $it", color = ErrorRed, modifier = Modifier.padding(horizontal = 12.dp)) }
    // spec §28: warn, never change settings on our own
    if (settings.hyperLoad && thermal >= PowerManager.THERMAL_STATUS_MODERATE) {
        Text("端末温度: ${DeviceInfo.thermalLabel(thermal)}。HyperLoadを続けるか判断してください。", color = ErrorRed, modifier = Modifier.padding(horizontal = 12.dp))
    }
    chat.notice?.let { Text(it, color = Indigo, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp)) }

    Messages(container, chat, Modifier.weight(1f))
    chat.error?.let { Text("エラー: $it", color = ErrorRed, modifier = Modifier.padding(horizontal = 12.dp)) }
    InputBar(container, chat, model, go)
}

/** Sending history out of the app goes through the consent window. */
internal suspend fun shareConversation(context: Context, container: AppContainer) {
    val text = container.exportConversation() ?: return
    val ok = container.consent.request(
        ConsentManager.SCOPE_EXPORT_HISTORY, "会話を他のアプリに共有",
        text.take(500) + if (text.length > 500) "\n…" else "", listOf("会話履歴の読み取り", "他のアプリへの送信"),
    )
    if (!ok) return
    context.startActivity(
        Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "会話を共有")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}

@Composable
private fun Messages(container: AppContainer, chat: ChatState, modifier: Modifier) {
    val listState = rememberLazyListState()
    LaunchedEffect(chat.messages.size, chat.messages.lastOrNull()?.text?.length) {
        if (chat.messages.isNotEmpty()) listState.animateScrollToItem(chat.messages.lastIndex)
    }
    LazyColumn(modifier.fillMaxWidth(), state = listState, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(chat.messages, key = { it.id }) { message ->
            val isCurrent = message.id == chat.messages.last().id
            when (message.role) {
                Role.USER -> UserBubble(message)
                Role.ASSISTANT -> AssistantMessage(
                    container = container,
                    message = message,
                    task = if (isCurrent) chat.task else TaskState.COMPLETED,
                    onAnswer = container.chat::answer,
                    onRegenerate = container.chat::regenerate.takeIf { isCurrent && !chat.isGenerating },
                )
            }
        }
    }
}

@Composable
private fun UserBubble(message: UiMessage) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalAlignment = Alignment.End) {
        message.attachments.forEach { Text("📎 $it", style = MaterialTheme.typography.labelSmall) }
        if (message.text.isNotBlank()) {
            Text(
                message.text,
                color = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(16.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun AssistantMessage(
    container: AppContainer,
    message: UiMessage,
    task: TaskState,
    onAnswer: (List<String>, String?) -> Unit,
    onRegenerate: (() -> Unit)?,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        message.agent?.let { Text("Agent: $it", style = MaterialTheme.typography.labelSmall) }
        if (message.thinking.isNotBlank() || task == TaskState.THINKING) {
            Collapsible("Thinking", active = task == TaskState.THINKING, colors = ThinkingGreen to ThinkingCyan) {
                Text(message.thinking, style = MaterialTheme.typography.bodySmall)
            }
        }
        message.activities.forEach { ToolActivityView(it) }
        if (task == TaskState.SEARCH) Collapsible("Search…", active = true, colors = ThinkingCyan to Indigo) {}

        if (task == TaskState.GENERATION) {
            Collapsible("生成中…", active = true, colors = Color.Black to Color.White) { MarkdownBody(container, message.text, finished = false) }
        } else {
            MarkdownBody(container, message.text, finished = true)
        }

        message.question?.let { tile -> QuestionCard(tile, enabled = task == TaskState.USER_WAIT, onAnswer = onAnswer) }
        if (message.finish != null && task != TaskState.GENERATION) MessageActions(message, onRegenerate)
    }
}

@Composable
private fun ToolActivityView(activity: ToolActivity) {
    val context = LocalContext.current
    Collapsible(
        label = "${activity.tool}: ${activity.summary}",
        active = false,
        colors = Indigo to Indigo,
        failed = activity.failed,
    ) {
        activity.links.forEach { link ->
            Text(
                "${link.title}\n${link.url}",
                color = Indigo,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.clickable {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link.url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.padding(vertical = 2.dp),
            )
        }
    }
}

@Composable
private fun Collapsible(
    label: String,
    active: Boolean,
    colors: Pair<Color, Color>,
    failed: Boolean = false,
    content: @Composable () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val pulse = rememberInfiniteTransition(label = "pulse")
    val animated by pulse.animateColor(colors.first, colors.second, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "labelColor")
    Text(
        text = "$label ${if (open) "▲" else "▼"}",
        color = when {
            failed -> ErrorRed
            active -> animated
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        },
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.clickable { open = !open }.padding(vertical = 4.dp),
    )
    if (open) content()
}

@Composable
private fun MarkdownBody(container: AppContainer, text: String, finished: Boolean) {
    MarkdownLite.parse(text).forEach { block ->
        when (block) {
            is Block.Paragraph -> Text(
                buildAnnotatedString {
                    block.spans.forEach { span ->
                        if (span.bold) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(span.text) } else append(span.text)
                    }
                },
                color = MaterialTheme.colorScheme.onBackground,
            )
            is Block.Code -> CodeBlock(container, block, finished)
        }
    }
}

/** Code, or an Artifact: slide between the source and a live preview / run (spec §13). */
@Composable
private fun CodeBlock(container: AppContainer, block: Block.Code, finished: Boolean) {
    var mode by remember(block.code) { mutableStateOf("code") }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    val previewable = isPreviewable(block.language)
    val runnable = isRunnableJs(block.language)
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Column(Modifier.padding(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(block.language.ifEmpty { "code" } + if (block.closed) "" else " …", style = MaterialTheme.typography.labelSmall)
                Spacer(Modifier.weight(1f))
                if (block.closed && finished && (previewable || runnable)) {
                    TextButton(onClick = { mode = "code" }) { Text("コード") }
                    if (previewable) TextButton(onClick = { mode = "preview" }) { Text("プレビュー") }
                    if (runnable) TextButton(onClick = {
                        scope.launch {
                            // generated code runs only after the consent window
                            val ok = container.consent.request(
                                ConsentManager.SCOPE_RUN_CODE, "生成されたJavaScriptを実行", block.code.take(2000),
                                listOf("サンドボックス（WebViewのレンダラー）内での実行", "ネットワークアクセス", "アプリ内データへのアクセスなし"),
                            )
                            if (ok) mode = "run"
                        }
                    }) { Text("実行") }
                }
                TextButton(onClick = { scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("code", block.code))) } }) { Text("コピー") }
            }
            when (mode) {
                "preview" -> ArtifactWebView(block.code)
                "run" -> ArtifactWebView(javascriptPage(block.code), heightDp = 120)
                else -> Text(
                    block.code,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QuestionCard(tile: QuestionTile, enabled: Boolean, onAnswer: (List<String>, String?) -> Unit) {
    val selected = remember(tile) { mutableStateListOf<String>() }
    var freeText by remember(tile) { mutableStateOf("") }
    Card(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.padding(12.dp)) {
            Text(tile.title, fontWeight = FontWeight.Bold)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                tile.options.forEach { option ->
                    FilterChip(
                        selected = option in selected,
                        enabled = enabled,
                        onClick = {
                            if (tile.multiSelect) {
                                if (!selected.remove(option)) selected.add(option)
                            } else {
                                selected.clear()
                                selected.add(option)
                            }
                        },
                        label = { Text(option) },
                    )
                }
            }
            if (tile.allowFreeInput) {
                OutlinedTextField(freeText, { freeText = it }, enabled = enabled, label = { Text("自由入力") }, modifier = Modifier.fillMaxWidth())
            }
            Button(
                onClick = { onAnswer(selected.toList(), freeText) },
                enabled = enabled && (selected.isNotEmpty() || freeText.isNotBlank()),
                modifier = Modifier.padding(top = 8.dp),
            ) { Text("回答する") }
        }
    }
}

@Composable
private fun MessageActions(message: UiMessage, onRegenerate: (() -> Unit)?) {
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    Row(verticalAlignment = Alignment.CenterVertically) {
        when (message.finish) {
            FinishReason.ERROR -> Text("×", color = ErrorRed)
            FinishReason.CANCELLED, FinishReason.LENGTH -> Text("途中で停止", style = MaterialTheme.typography.labelSmall)
            else -> Text("✓", color = ThinkingGreen)
        }
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = { scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("reply", message.text))) } }) { Text("コピー") }
        if (onRegenerate != null) TextButton(onClick = onRegenerate) { Text("再生成") }
    }
}

/**
 * Input panel from the layout sketch: a dark rounded box with the message on top and, below
 * it, file add (left), the model dropdown (centre), and one send / continue / stop button (right).
 */
@Composable
private fun InputBar(container: AppContainer, chat: ChatState, model: ModelState, go: (Screen) -> Unit) {
    var input by remember { mutableStateOf("") }
    val attachments = remember { mutableStateListOf<Attachment>() }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var modelMenu by remember { mutableStateOf(false) }
    var attachError by remember { mutableStateOf<String?>(null) }
    val modelLoaded = model.loadedName != null

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        uris.forEach { uri -> readTextAttachment(context, uri).fold({ attachments += it }, { attachError = it.message }) }
    }

    // one button, three roles (spec §12)
    val action = when {
        chat.isGenerating -> "■"
        input.isNotBlank() || attachments.isNotEmpty() -> "▶"
        chat.canContinue -> "⏩"
        else -> "▶"
    }
    val enabled = when (action) {
        "■", "⏩" -> true
        else -> modelLoaded && (input.isNotBlank() || attachments.isNotEmpty()) && chat.pendingQuestion == null
    }
    val onPanel = Color.White

    Surface(color = PanelGray, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().padding(8.dp)) {
        Column(Modifier.padding(10.dp)) {
            attachError?.let { Text(it, color = ErrorRed, style = MaterialTheme.typography.labelSmall) }
            if (attachments.isNotEmpty()) {
                Row(Modifier.horizontalScroll(rememberScrollState())) {
                    attachments.forEach { a -> TextButton(onClick = { attachments.remove(a) }) { Text("📎 ${a.name} ✕", color = onPanel) } }
                }
            }
            androidx.compose.foundation.text.BasicTextField(
                value = input,
                onValueChange = { input = it },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = onPanel),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(onPanel),
                maxLines = 6,
                modifier = Modifier.fillMaxWidth().padding(4.dp).heightIn(min = 48.dp),
                decorationBox = { field ->
                    if (input.isEmpty()) {
                        Text(if (modelLoaded) "メッセージを入力" else "先にモデルを選んでください", color = onPanel.copy(alpha = 0.5f))
                    }
                    field()
                },
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { picker.launch(arrayOf("*/*")) }) { Text("□+", color = onPanel, style = MaterialTheme.typography.titleMedium) }
                Box {
                    TextButton(
                        onClick = { container.models.refresh(); modelMenu = true },
                        modifier = Modifier.border(1.dp, onPanel.copy(alpha = 0.4f), RoundedCornerShape(8.dp)),
                    ) { Text("${model.loadedName ?: "モデル未選択"} ﹀", color = onPanel, maxLines = 1) }
                    DropdownMenu(expanded = modelMenu, onDismissRequest = { modelMenu = false }) {
                        model.installed.forEach { file ->
                            DropdownMenuItem(
                                text = { Text(file.nameWithoutExtension + if (file.absolutePath == model.loadedPath) " ✓" else "") },
                                enabled = !chat.isGenerating,
                                onClick = { modelMenu = false; container.models.load(file) },
                            )
                        }
                        DropdownMenuItem(text = { Text("＋モデルを追加") }, onClick = { modelMenu = false; go(Screen.MODELS) })
                    }
                }
                Text("Thinking", color = onPanel, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(start = 8.dp))
                Switch(
                    checked = chat.thinkingEnabled,
                    onCheckedChange = { on ->
                        container.chat.setThinking(on)
                        scope.launch { container.settingsRepository.update { it.copy(thinking = on) } }
                    },
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = {
                        when (action) {
                            "■" -> container.chat.stop()
                            "⏩" -> container.chat.continueReply()
                            else -> {
                                container.chat.send(input, attachments.toList())
                                input = ""
                                attachments.clear()
                                attachError = null
                            }
                        }
                    },
                    enabled = enabled,
                    shape = RoundedCornerShape(4.dp),
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color(0xFF8E8E8E)),
                ) { Text(action, color = Color.White) }
            }
        }
    }
}

/** Reads a picked file as UTF-8 text; binary files and files over 1 MB are refused (spec §18). */
private fun readTextAttachment(context: Context, uri: Uri): Result<Attachment> = runCatching {
    val resolver = context.contentResolver
    val (name, size) = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) to c.getLong(1) else null
    } ?: ("file" to -1L)
    require(size <= 1_000_000) { "$name は1MBを超えるため追加できません" }
    val bytes = resolver.openInputStream(uri)!!.use { it.readBytes() }
    require(bytes.none { it == 0.toByte() }) { "$name はテキストファイルではありません" }
    Attachment(name, String(bytes, Charsets.UTF_8))
}

internal val ErrorRed = Color(0xFFC62828)
private val PanelGray = Color(0xFF505050)
