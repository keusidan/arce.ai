package ai.arce.app.ui

import ai.arce.app.ChatViewModel
import ai.arce.app.ModelUiState
import ai.arce.core.chat.ChatState
import ai.arce.core.chat.Role
import ai.arce.core.chat.UiMessage
import ai.arce.core.generation.FinishReason
import ai.arce.core.generation.TaskState
import ai.arce.core.protocol.QuestionTile
import ai.arce.core.render.Block
import ai.arce.core.render.MarkdownLite
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColor
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun ChatScreen(viewModel: ChatViewModel) {
    val chat by viewModel.chat.state.collectAsStateWithLifecycle()
    val model by viewModel.model.collectAsStateWithLifecycle()

    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.safeDrawingPadding())  // includes the keyboard (IME) inset {
            StatusBar(model, chat, viewModel)
            Messages(chat, viewModel, Modifier.weight(1f))
            chat.error?.let { Text("エラー: $it", color = Color(0xFFC62828), modifier = Modifier.padding(horizontal = 12.dp)) }
            InputBar(chat, modelLoaded = model.loaded != null, viewModel)
        }
    }
}

@Composable
private fun StatusBar(model: ModelUiState, chat: ChatState, viewModel: ChatViewModel) {
    var menuOpen by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(viewModel::importModel)
    }

    Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            TextButton(onClick = { menuOpen = true }) {
                Text("Model: ${model.loaded ?: "未選択"} ▼")
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                model.available.forEach { file ->
                    DropdownMenuItem(text = { Text(file.name) }, onClick = {
                        menuOpen = false
                        viewModel.loadModel(file)
                    })
                }
                DropdownMenuItem(text = { Text("+ モデルを追加（GGUF）") }, onClick = {
                    menuOpen = false
                    picker.launch(arrayOf("*/*"))
                })
            }
        }
        Spacer(Modifier.weight(1f))
        Text(
            text = model.busy ?: model.error ?: "Thinking: ${if (chat.thinkingEnabled) "ON" else "OFF"}",
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable
private fun Messages(chat: ChatState, viewModel: ChatViewModel, modifier: Modifier) {
    val listState = rememberLazyListState()
    LaunchedEffect(chat.messages.size, chat.messages.lastOrNull()?.text?.length) {
        if (chat.messages.isNotEmpty()) listState.animateScrollToItem(chat.messages.lastIndex)
    }
    LazyColumn(modifier.fillMaxWidth(), state = listState, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(chat.messages, key = { it.id }) { message ->
            val isCurrent = message.id == chat.messages.last().id
            when (message.role) {
                Role.USER -> UserBubble(message.text)
                Role.ASSISTANT -> AssistantMessage(
                    message = message,
                    task = if (isCurrent) chat.task else TaskState.COMPLETED,
                    onAnswer = viewModel.chat::answer,
                    onRegenerate = viewModel.chat::regenerate.takeIf { isCurrent && !chat.isGenerating },
                )
            }
        }
    }
}

@Composable
private fun UserBubble(text: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
        Text(
            text,
            color = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier
                .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(16.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun AssistantMessage(
    message: UiMessage,
    task: TaskState,
    onAnswer: (List<String>, String?) -> Unit,
    onRegenerate: (() -> Unit)?,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        if (message.thinking.isNotBlank() || task == TaskState.THINKING) {
            Collapsible(
                label = "Thinking",
                active = task == TaskState.THINKING,
                colors = ThinkingGreen to ThinkingCyan,
                initiallyOpen = false,
            ) { Text(message.thinking, style = MaterialTheme.typography.bodySmall) }
        }

        if (task == TaskState.GENERATION) {
            // spec: the text being generated is folded behind a "生成中" row until tapped
            Collapsible(label = "生成中…", active = true, colors = Color.Black to Color.White, initiallyOpen = false) {
                MarkdownBody(message.text)
            }
        } else {
            MarkdownBody(message.text)
        }

        message.question?.let { tile ->
            QuestionCard(tile, enabled = task == TaskState.USER_WAIT, onAnswer = onAnswer)
        }

        if (message.finish != null && task != TaskState.GENERATION) {
            MessageActions(message, onRegenerate)
        }
    }
}

@Composable
private fun Collapsible(
    label: String,
    active: Boolean,
    colors: Pair<Color, Color>,
    initiallyOpen: Boolean,
    content: @Composable () -> Unit,
) {
    var open by remember { mutableStateOf(initiallyOpen) }
    val pulse = rememberInfiniteTransition(label = "pulse")
    val animated by pulse.animateColor(
        initialValue = colors.first,
        targetValue = colors.second,
        animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse),
        label = "labelColor",
    )
    Text(
        text = "$label ${if (open) "▲" else "▼"}",
        color = if (active) animated else MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.clickable { open = !open }.padding(vertical = 4.dp),
    )
    if (open) content()
}

@Composable
private fun MarkdownBody(text: String) {
    MarkdownLite.parse(text).forEach { block ->
        when (block) {
            is Block.Paragraph -> Text(
                buildAnnotatedString {
                    block.spans.forEach { span ->
                        if (span.bold) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(span.text) }
                        else append(span.text)
                    }
                },
                color = MaterialTheme.colorScheme.onBackground,
            )
            // Phase 5 turns closed html/js/css blocks into Artifacts; the prototype shows the source.
            is Block.Code -> Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            ) {
                Column(Modifier.padding(8.dp)) {
                    Text(
                        block.language.ifEmpty { "code" } + if (block.closed) "" else " …",
                        style = MaterialTheme.typography.labelSmall,
                    )
                    Text(
                        block.code,
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    )
                }
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
                OutlinedTextField(
                    value = freeText,
                    onValueChange = { freeText = it },
                    enabled = enabled,
                    label = { Text("自由入力") },
                    modifier = Modifier.fillMaxWidth(),
                )
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
    val clipboard = LocalClipboardManager.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        when (message.finish) {
            FinishReason.ERROR -> Text("×", color = Color(0xFFC62828))
            FinishReason.CANCELLED, FinishReason.LENGTH -> Text("途中で停止", style = MaterialTheme.typography.labelSmall)
            else -> Text("✓", color = Color(0xFF2E7D32))
        }
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = { clipboard.setText(AnnotatedString(message.text)) }) { Text("コピー") }
        if (onRegenerate != null) TextButton(onClick = onRegenerate) { Text("再生成") }
    }
}

@Composable
private fun InputBar(chat: ChatState, modelLoaded: Boolean, viewModel: ChatViewModel) {
    var input by remember { mutableStateOf("") }

    // one button, three roles (spec §12)
    val action = when {
        chat.isGenerating -> "停止"
        input.isNotBlank() -> "送信"
        chat.canContinue -> "続行"
        else -> "送信"
    }
    val enabled = when (action) {
        "停止" -> true
        "続行" -> true
        else -> modelLoaded && input.isNotBlank() && chat.pendingQuestion == null
    }

    Column(Modifier.fillMaxWidth().padding(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Thinking", style = MaterialTheme.typography.labelMedium)
            Switch(
                checked = chat.thinkingEnabled,
                onCheckedChange = viewModel.chat::setThinking,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                placeholder = { Text(if (modelLoaded) "メッセージを入力" else "先にモデルを選んでください") },
                modifier = Modifier.weight(1f),
                maxLines = 5,
            )
            Button(
                onClick = {
                    when (action) {
                        "停止" -> viewModel.chat.stop()
                        "続行" -> viewModel.chat.continueReply()
                        else -> {
                            viewModel.chat.send(input)
                            input = ""
                        }
                    }
                },
                enabled = enabled,
                modifier = Modifier.padding(start = 8.dp),
            ) { Text(action) }
        }
    }
}
