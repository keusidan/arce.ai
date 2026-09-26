package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.Screen
import ai.arce.app.model.DownloadState
import ai.arce.app.model.ModelController
import ai.arce.core.model.MemoryEstimator
import ai.arce.core.model.ModelSpec
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.File

/** Model manager (spec §19, §24): catalog downloads, local files, import, load. */
@Composable
fun ColumnScope.ModelsScreen(container: AppContainer, go: (Screen) -> Unit) {
    val models = container.models
    val state by models.state.collectAsStateWithLifecycle()
    val settings by container.settings.collectAsStateWithLifecycle()
    val chat by container.chat.state.collectAsStateWithLifecycle()
    var confirmDelete by remember { mutableStateOf<File?>(null) }
    val memory = remember(state.installed, state.loadedPath) { container.device.memory() }

    LaunchedEffect(Unit) { models.refresh() }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(models::import) }

    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
        Text("読み込み中: ${state.loadedName ?: "なし"}")
        Text("端末RAM: ${ModelController.gb(memory.totalBytes)}（空き ${ModelController.gb(memory.availableBytes)}）", style = MaterialTheme.typography.bodySmall)
        Text("Context Length ${settings.contextLength} / KV Cache ${settings.kvCache} で見積もり", style = MaterialTheme.typography.bodySmall)
        state.busy?.let { Text(it); LinearProgressIndicator(Modifier.fillMaxWidth()) }
        state.error?.let { Text(it, color = ErrorRed) }
        if (chat.isGenerating) Text("生成中はモデルを切り替えられません", style = MaterialTheme.typography.bodySmall)

        if (state.installed.none { it.name == models.basic.fileName }) BasicModelCard(container, state)
        if (state.backend != null) Text("実行エンジン: ${state.backend}", style = MaterialTheme.typography.bodySmall)

        SectionTitle("カタログ（Hugging Face）")
        Text("GGUFはllama.cpp、.litertlmはLiteRT-LM（GPU/NPU）で動きます。", style = MaterialTheme.typography.bodySmall)
        models.catalog.forEach { spec ->
            CatalogCard(container, spec, state.downloads[spec.id] ?: models.downloadStateOf(spec), settings.forceExecution, loaded = state.loadedPath == models.fileOf(spec).absolutePath, generating = chat.isGenerating)
        }

        SectionTitle("端末内のモデル")
        if (state.installed.isEmpty()) Text("GGUFファイルがありません", style = MaterialTheme.typography.bodySmall)
        state.installed.forEach { file ->
            val loaded = file.absolutePath == state.loadedPath
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text((if (loaded) "● " else "") + file.name, maxLines = 2)
                    Text("${ModelController.gb(file.length())}・推定 ${ModelController.gb(models.estimateBytes(file))}", style = MaterialTheme.typography.bodySmall)
                }
                TextButton(onClick = { models.load(file) }, enabled = !loaded && !chat.isGenerating && state.busy == null) { Text("読み込む") }
                TextButton(onClick = { confirmDelete = file }, enabled = !loaded) { Text("削除", color = ErrorRed) }
            }
        }
        TextButton(onClick = { importer.launch(arrayOf("application/octet-stream", "*/*")) }, enabled = state.busy == null) {
            Text("＋ GGUF / LiteRT-LMファイルを取り込む")
        }
        if (state.gpuDevices.isNotEmpty()) Text("GPU: " + state.gpuDevices.joinToString(), style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { go(Screen.CHAT) }) { Text("チャットに戻る") }
    }

    confirmDelete?.let { file ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("モデルを削除しますか？") },
            text = { Text("${file.name}（${ModelController.gb(file.length())}）を端末から削除します。") },
            confirmButton = { TextButton(onClick = { models.delete(file); confirmDelete = null }) { Text("削除", color = ErrorRed) } },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("キャンセル") } },
        )
    }
}

@Composable
private fun CatalogCard(container: AppContainer, spec: ModelSpec, download: DownloadState, force: Boolean, loaded: Boolean, generating: Boolean) {
    val models = container.models
    val settings = container.settings.value
    val fits = models.fits(spec)
    // Greyed out when it would not fit in RAM, unless Force Execution is on (spec §24/§60).
    val usable = fits || force
    Card(Modifier.fillMaxWidth().padding(vertical = 4.dp).alpha(if (usable) 1f else 0.45f)) {
        Column(Modifier.padding(12.dp)) {
            Text((if (loaded) "● " else "") + spec.displayName + if (spec.id == models.basic.id) "（基本）" else "", style = MaterialTheme.typography.titleSmall)
            Text(
                "${spec.fileName}・${ModelController.gb(spec.fileBytes)}・推定RAM ${ModelController.gb(MemoryEstimator.totalBytes(spec, settings.contextLength, settings.kvCache))}",
                style = MaterialTheme.typography.bodySmall,
            )
            if (!fits) Text(if (force) "RAM不足の可能性（Force Execution有効）" else "この端末のRAMでは不足します", color = ErrorRed, style = MaterialTheme.typography.bodySmall)
            when (download) {
                is DownloadState.Running -> {
                    LinearProgressIndicator(progress = { fraction(download.done, download.total) }, modifier = Modifier.fillMaxWidth())
                    Text("${ModelController.gb(download.done)} / ${ModelController.gb(download.total)}", style = MaterialTheme.typography.bodySmall)
                }
                is DownloadState.Paused -> {
                    LinearProgressIndicator(progress = { fraction(download.done, download.total) }, modifier = Modifier.fillMaxWidth())
                    Text("一時停止中 ${ModelController.gb(download.done)} / ${ModelController.gb(download.total)}" + (download.reason?.let { "（$it）" } ?: ""), style = MaterialTheme.typography.bodySmall)
                }
                DownloadState.Verifying -> Text("整合性チェック中（SHA-256）…", style = MaterialTheme.typography.bodySmall)
                is DownloadState.Failed -> Text(download.reason, color = ErrorRed, style = MaterialTheme.typography.bodySmall)
                else -> Unit
            }
            Row {
                when (download) {
                    DownloadState.Idle, is DownloadState.Failed ->
                        TextButton(onClick = { models.startDownload(spec, loadWhenDone = true) }, enabled = usable && !generating) { Text("追加して使う") }
                    is DownloadState.Running -> TextButton(onClick = { models.pauseDownload(spec) }) { Text("一時停止") }
                    is DownloadState.Paused -> TextButton(onClick = { models.startDownload(spec) }, enabled = usable) { Text("再開") }
                    DownloadState.Verifying -> Unit
                    DownloadState.Installed -> {
                        TextButton(onClick = { models.load(models.fileOf(spec)) }, enabled = usable && !loaded && !generating) { Text("読み込む") }
                        TextButton(onClick = { models.verify(spec) }) { Text("整合性チェック") }
                    }
                }
            }
        }
    }
}

private fun fraction(done: Long, total: Long) = if (total > 0) (done.toFloat() / total).coerceIn(0f, 1f) else 0f
