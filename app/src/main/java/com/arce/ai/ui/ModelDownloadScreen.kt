package com.arce.ai.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.arce.ai.ArceApp
import com.arce.ai.ModelInfo
import com.arce.ai.Workers
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelDownloadScreen(app: ArceApp, onBack: () -> Unit) {
    var refresh by remember { mutableLongStateOf(0L) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("モデル管理") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                }
            )
        }
    ) { pad ->
        Column(
            modifier = Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState())
        ) {
            // Backends (capability cache: grey-out 助言書準拠)
            val backends = app.settings.backends()
            Card(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text("バックエンド", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(6.dp))
                    val cpuOk = backends.any { it.type == "cpu" }
                    val gpuOk = backends.any { it.type == "gpu" }
                    Row(Modifier.fillMaxWidth()) {
                        BackendChip("CPU", cpuOk)
                        Spacer(Modifier.width(8.dp))
                        BackendChip("GPU (Vulkan)", gpuOk)
                        Spacer(Modifier.width(8.dp))
                        BackendChip("NPU", false, note = "未対応")
                    }
                    if (backends.isNotEmpty()) {
                        Text(
                            backends.joinToString { it.name },
                            style = MaterialTheme.typography.bodySmall,
                            color = Color(0xFF9CA3AF),
                            modifier = Modifier.padding(top = 6.dp)
                        )
                    }
                }
            }

            Text(
                "ダウンロード済みモデルは端末に保存されます（アンインストールで消えます）。",
                style = MaterialTheme.typography.bodySmall,
                color = Color(0xFF9CA3AF),
                modifier = Modifier.padding(horizontal = 12.dp)
            )

            ModelInfo.CATALOG.forEach { m ->
                ModelRow(app = app, m = m, refresh = refresh)
            }
        }
    }
}

@Composable
private fun BackendChip(label: String, available: Boolean, note: String = "") {
    Card(
        modifier = Modifier.padding(end = 0.dp),
        colors = androidx.compose.material3.CardDefaults.cardColors(
            containerColor = if (available) Color(0xFF14532D) else Color(0xFF374151)
        )
    ) {
        Text(
            "$label${if (note.isNotEmpty()) " ($note)" else ""}",
            color = if (available) Color(0xFF4ADE80) else Color(0xFF6B7280),
            style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
        )
    }
}

@Composable
private fun ModelRow(app: ArceApp, m: ModelInfo, refresh: Long) {
    var state by remember(m.id, refresh) { mutableStateOf("idle") }
    var pct by remember(m.id, refresh) { mutableStateOf(0) }
    var errorMsg by remember(m.id, refresh) { mutableStateOf("") }
    val file = app.modelFile(m.id)
    val installed = remember(m.id, refresh) { file.exists() }
    val selected = app.settings.selectedModelId == m.id

    LaunchedEffect(m.id, refresh) {
        val wm = WorkManager.getInstance(app)
        val unique = "model_${m.id}"
        val existing = wm.getWorkInfosForUniqueWork(unique).getOrNull()
        if (existing != null) {
            val latest = existing.firstOrNull()
            when (latest?.state) {
                androidx.work.WorkInfo.State.RUNNING,
                androidx.work.WorkInfo.State.ENQUEUED -> state = "downloading"
                androidx.work.WorkInfo.State.FAILED -> {
                    state = "failed"
                    errorMsg = "ダウンロード失敗しました"
                }
                androidx.work.WorkInfo.State.SUCCEEDED -> state = "idle"
                else -> state = "idle"
            }
        }
    }

    // poll progress via notifications is not available; poll file size instead
    LaunchedEffect(state) {
        if (state != "downloading") return@LaunchedEffect
        while (true) {
            val tmp = File(file.parentFile, "${m.id}.part")
            if (tmp.exists() && m.sizeMB > 0) {
                pct = (tmp.length() * 100 / (m.sizeMB * 1024 * 1024)).toInt().coerceIn(0, 100)
            }
            if (!tmp.exists() && file.exists()) {
                state = "idle"
                break
            }
            kotlinx.coroutines.delay(2000)
        }
    }

    Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "${m.name}${if (selected) " (使用中)" else ""}",
                        style = MaterialTheme.typography.titleSmall
                    )
                    Text(
                        "約 ${m.sizeMB}MB",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF9CA3AF)
                    )
                }
                when {
                    installed -> OutlinedButton(onClick = {
                        app.settings.selectedModelId = m.id
                    }) {
                        Text(if (selected) "選択済み" else "選択")
                    }
                    state == "downloading" -> CircularProgressIndicator(Modifier.height(20.dp).width(20.dp), strokeWidth = 2.dp)
                    else -> Button(onClick = {
                        state = "downloading"
                        Workers.scheduleDownload(app, m)
                    }) { Text("ダウンロード") }
                }
            }
            if (state == "downloading") {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(
                    progress = { (pct / 100f).coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth()
                )
                Text("${pct}%", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 2.dp))
            }
            if (state == "failed") {
                Text(errorMsg, color = Color(0xFFFCA5A5), style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = { state = "idle"; Workers.scheduleDownload(app, m) },
                    modifier = Modifier.padding(top = 4.dp)) { Text("再試行") }
            }
        }
    }
}
