package com.arce.ai.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddTask
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.arce.ai.ArceApp
import com.arce.ai.ChatEngine
import com.arce.ai.ChatMessage
import com.arce.ai.TileSpec

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    app: ArceApp,
    onOpenModels: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenHistory: () -> Unit,
    onOpenBuild: () -> Unit
) {
    val engine: ChatEngine = app.engine
    val tick by engine.tick.collectAsState()
    val conv = remember(tick) { app.history.current() }
    var input by remember { mutableStateOf("") }
    var tileToShow by remember { mutableStateOf<TileSpec?>(null) }

    val backends = remember(tick) { app.settings.backends() }
    val gpuOk = backends.any { it.type == "gpu" }

    Scaffold(
        topBar = {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onOpenHistory) {
                    Icon(Icons.Default.History, contentDescription = "履歴")
                }
                Text(
                    "ARCE.AI",
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = if (gpuOk) "GPU" else "CPU",
                    color = if (gpuOk) Color(0xFF4ADE80) else Color(0xFF9CA3AF),
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(end = 4.dp)
                )
                IconButton(onClick = onOpenModels) {
                    Icon(Icons.Default.AddTask, contentDescription = "モデル")
                }
                IconButton(onClick = onOpenBuild) {
                    Icon(Icons.Default.Build, contentDescription = "ビルド")
                }
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Default.Close, contentDescription = "設定")
                }
            }
        }
    ) { pad ->
        Column(modifier = Modifier.fillMaxSize().padding(pad)) {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(conv.messages, key = { it.id }) { msg ->
                    MessageBubble(msg = msg, onTileClick = { tileToShow = it })
                }
                if (engine.busy && conv.messages.lastOrNull()?.streaming == true) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(
                                modifier = Modifier.height(16.dp).width(16.dp),
                                strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "生成中…",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.Gray
                            )
                        }
                    }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("指示を入力 (例: HTMLで ToDo リストを作れ)") },
                    maxLines = 4
                )
                Spacer(Modifier.width(8.dp))
                if (engine.busy) {
                    OutlinedButton(onClick = { engine.stop() }) { Text("停止") }
                } else {
                    Button(onClick = {
                        engine.send(input)
                        input = ""
                    }) { Text("送信") }
                }
            }
        }
    }

    tileToShow?.let { tile ->
        TileChoiceDialog(
            tile = tile,
            onDismiss = { tileToShow = null },
            onPick = { picked ->
                engine.send(picked)
                tileToShow = null
            }
        )
    }
}

@Composable
fun MessageBubble(msg: ChatMessage, onTileClick: (TileSpec) -> Unit) {
    val isUser = msg.role == "user"
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth(if (isUser) 0.85f else 0.92f)
                .clip(RoundedCornerShape(14.dp))
                .background(if (isUser) Color(0xFF1D4ED8) else Color(0xFF1F2937))
                .padding(10.dp),
            horizontalAlignment = if (isUser) Alignment.End else Alignment.Start
        ) {
            if (msg.tool != null) {
                Text("🔧 ${msg.tool}", style = MaterialTheme.typography.labelSmall, color = Color(0xFF93C5FD))
            }
            if (msg.streaming && !msg.thinking.isNullOrBlank()) {
                Text(msg.thinking!!, style = MaterialTheme.typography.bodySmall, color = Color(0xFF9CA3AF))
            }
            if (msg.text.isNotEmpty()) {
                Text(msg.text, color = Color.White, style = MaterialTheme.typography.bodyMedium)
            }
            if (msg.tile != null) {
                OutlinedButton(
                    onClick = { onTileClick(msg.tile!!) },
                    modifier = Modifier.padding(top = 6.dp)
                ) { Text("▼ 選択: ${msg.tile!!.title}") }
            }
            if (msg.artifact != null) {
                ArtifactCard(msg.artifact!!, msg.text)
            }
            if (msg.error != null) {
                Text(
                    "⚠ ${msg.error}",
                    color = Color(0xFFFCA5A5),
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
            if (!msg.streaming && msg.error != null) {
                OutlinedButton(
                    onClick = { ArceApp.instance?.engine?.continueLast() },
                    modifier = Modifier.padding(top = 4.dp)
                ) { Text("続行") }
            }
        }
    }
}

@Composable
fun TileChoiceDialog(tile: TileSpec, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    var picked by remember(tile) { mutableStateOf(mutableSetOf<String>()) }
    var free by remember { mutableStateOf("") }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(onClick = { onPick(if (picked.isEmpty()) "未選択" else picked.joinToString(", ")) }) {
                Text("決定")
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) { Text("キャンセル") }
        },
        title = { Text(tile.title) },
        text = {
            Column {
                tile.options.forEach { opt ->
                    Row(
                        modifier = Modifier
                            .clickable {
                                if (tile.multiSelect) {
                                    if (picked.contains(opt)) picked -= opt else picked += opt
                                } else {
                                    onPick(opt)
                                }
                            }
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(if (tile.multiSelect && picked.contains(opt)) "☑ " else "☐ ")
                        Spacer(Modifier.width(6.dp))
                        Text(opt)
                    }
                }
                if (tile.allowFreeInput) {
                    OutlinedTextField(
                        value = free,
                        onValueChange = { free = it },
                        placeholder = { Text("自由入力") },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        singleLine = true
                    )
                    OutlinedButton(
                        onClick = { if (free.isNotBlank()) onPick(free) },
                        modifier = Modifier.padding(top = 6.dp)
                    ) { Text("自由入力で決定") }
                }
            }
        }
    )
}
