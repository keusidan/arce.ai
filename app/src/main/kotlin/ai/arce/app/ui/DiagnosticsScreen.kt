package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.BuildConfig
import ai.arce.app.Screen
import ai.arce.app.model.ModelController
import ai.arce.app.system.Benchmark
import ai.arce.app.system.BenchmarkResult
import ai.arce.app.system.DeviceInfo
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.content.ClipData
import kotlinx.coroutines.launch

/** Device diagnostics and an on-demand benchmark (spec §29). */
@Composable
fun ColumnScope.DiagnosticsScreen(container: AppContainer, go: (Screen) -> Unit) {
    val device = container.device
    val models by container.models.state.collectAsStateWithLifecycle()
    val settings by container.settings.collectAsStateWithLifecycle()
    val chat by container.chat.state.collectAsStateWithLifecycle()
    val thermal by remember { device.thermalStatusFlow() }.collectAsStateWithLifecycle(device.thermalStatus())
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current
    var running by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<BenchmarkResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableStateOf(0) }

    val report = remember(refresh, models, settings, thermal, result) {
        val memory = device.memory()
        buildString {
            appendLine("ARCE.AI ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            appendLine("Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT}) / ABI ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
            appendLine("端末: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
            appendLine("SoC: ${device.soc()}")
            appendLine("CPUコア: ${device.cores}（使用スレッド ${settings.effectiveThreads(device.cores)}）")
            appendLine("RAM: ${ModelController.gb(memory.totalBytes)}（空き ${ModelController.gb(memory.availableBytes)}${if (memory.lowMemory) "・低メモリ" else ""}）")
            appendLine("ストレージ空き: ${ModelController.gb(device.freeStorageBytes(container.models.store.directory))}")
            appendLine("Vulkan: ${device.vulkanVersion() ?: "なし"}")
            appendLine("OpenCL: ${device.openClLibrary() ?: "なし"}")
            appendLine("GPUデバイス（llama.cpp）: ${models.gpuDevices.ifEmpty { listOf("なし") }.joinToString()}")
            appendLine("温度状態: ${DeviceInfo.thermalLabel(thermal)}（headroom ${"%.2f".format(device.thermalHeadroom())}）")
            appendLine("モデル: ${models.loadedName ?: "未読み込み"}（${models.backend ?: "-"}）")
            appendLine("Context ${settings.contextLength} / Batch ${settings.batchSize} / KV ${settings.kvCache} / GPU ${settings.gpuOffload} / HyperLoad ${settings.hyperLoad}")
            result?.let {
                appendLine("Benchmark: pp ${"%.1f".format(it.promptTokensPerSecond)} t/s（${it.promptTokens} tok）/ tg ${"%.1f".format(it.generateTokensPerSecond)} t/s（${it.generatedPieces} tok）")
            }
        }.trimEnd()
    }

    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
        Text(report, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { refresh++ }) { Text("再取得") }
        TextButton(onClick = { scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("ARCE.AI diagnostics", report))) } }) {
            Text("診断結果をコピー")
        }

        SectionTitle("直近の異常終了")
        val crash = remember(refresh) { runCatching { (container.app as ai.arce.app.ArceApp).crashes.latest() }.getOrNull() }
        Text(crash ?: "記録はありません", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        if (crash != null) TextButton(onClick = { scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("ARCE.AI crash", crash))) } }) {
            Text("異常終了の記録をコピー")
        }

        SectionTitle("ベンチマーク")
        Text("プロンプト処理（pp）と生成（tg）の速度を llama-bench と同じ考え方で別々に測ります。", style = MaterialTheme.typography.bodySmall)
        if (running) LinearProgressIndicator(Modifier.fillMaxWidth())
        error?.let { Text(it, color = ErrorRed) }
        TextButton(
            onClick = {
                running = true
                error = null
                scope.launch {
                    runCatching { Benchmark(container.engine).run() }
                        .onSuccess { result = it }
                        .onFailure { error = it.message }
                    running = false
                }
            },
            enabled = !running && models.loadedName != null && !chat.isGenerating,
        ) { Text(if (models.loadedName == null) "モデルを読み込むと実行できます" else "ベンチマークを実行") }
        if (models.loadedName == null) TextButton(onClick = { go(Screen.MODELS) }) { Text("モデル管理へ →") }
    }
}
