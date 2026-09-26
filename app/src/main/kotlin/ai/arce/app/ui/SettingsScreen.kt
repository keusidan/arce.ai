package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.Screen
import ai.arce.app.settings.AppSettings
import ai.arce.app.settings.GpuOffload
import ai.arce.app.settings.ThemeMode
import ai.arce.app.system.ConsentManager
import ai.arce.core.model.KvCacheType
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

/** Basic and developer settings (spec §8, §26). Every change is saved immediately. */
@Composable
fun ColumnScope.SettingsScreen(container: AppContainer, go: (Screen) -> Unit) {
    val s by container.settings.collectAsStateWithLifecycle()
    val grants by container.consent.granted.collectAsStateWithLifecycle(emptyList())
    val scope = rememberCoroutineScope()
    var developer by remember { mutableStateOf(false) }
    val set: ((AppSettings) -> AppSettings) -> Unit = { change -> scope.launch { container.settingsRepository.update(change) } }

    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
        SectionTitle("基本設定")
        SwitchRow("Thinking", s.thinking, "考える過程を出力してから回答します") { v ->
            set { it.copy(thinking = v) }
            container.chat.setThinking(v)
        }
        SwitchRow("Web検索", s.searchEnabled, "必要なときにAIが検索します") { v -> set { it.copy(searchEnabled = v) } }
        var searx by remember(s.searxngUrl) { mutableStateOf(s.searxngUrl) }
        OutlinedTextField(
            value = searx,
            onValueChange = { searx = it.trim(); set { c -> c.copy(searxngUrl = searx) } },
            label = { Text("SearXNG URL（任意）") },
            supportingText = { Text("例: http://raspberrypi.local:8080 空欄ならDuckDuckGoのみ") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        var tone by remember(s.tone) { mutableStateOf(s.tone) }
        OutlinedTextField(
            value = tone,
            onValueChange = { tone = it.take(200); set { c -> c.copy(tone = tone) } },
            label = { Text("口調（任意・200文字まで）") },
            modifier = Modifier.fillMaxWidth(),
        )
        IntField("最大文字数（0 = 制限なし）", s.maxChars, 0..100_000) { v -> set { it.copy(maxChars = v) } }

        Text("速度 ⇔ 精度: ${"%.2f".format(s.speedAccuracy)}", modifier = Modifier.padding(top = 8.dp))
        Slider(value = s.speedAccuracy, onValueChange = { v -> set { it.copy(speedAccuracy = v) } })
        Text("左ほど速さ優先（短い思考）、右ほど精度優先", style = MaterialTheme.typography.bodySmall)

        SwitchRow("HyperLoad", s.hyperLoad, "全コアとGPUを最大限使います。発熱・電池消費が増えます") { v -> set { it.copy(hyperLoad = v) } }
        SwitchRow("通知", s.notifications) { v -> set { it.copy(notifications = v) } }
        SwitchRow("バックグラウンド生成", s.backgroundGeneration, "アプリを離れても生成を続けます（常駐通知あり）") { v -> set { it.copy(backgroundGeneration = v) } }
        ChoiceRow("テーマ", listOf(ThemeMode.SYSTEM to "端末", ThemeMode.LIGHT to "ライト", ThemeMode.DARK to "ダーク"), s.theme) { v -> set { it.copy(theme = v) } }

        SectionTitle("権限")
        if (grants.none { it.always }) Text("「常に許可」した権限はありません", style = MaterialTheme.typography.bodySmall)
        grants.filter { it.always }.forEach { g ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(scopeLabel(g.scope), Modifier.weight(1f))
                TextButton(onClick = { scope.launch { container.consent.revoke(g.scope) } }) { Text("取り消す") }
            }
        }

        SectionTitle("アップデート")
        var repo by remember(s.updateRepo) { mutableStateOf(s.updateRepo) }
        OutlinedTextField(
            value = repo,
            onValueChange = { repo = it.trim(); if (repo.count { c -> c == '/' } == 1) set { c -> c.copy(updateRepo = repo) } },
            label = { Text("リポジトリ（owner/name）") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        IntField("確認間隔（時間）", s.updateIntervalHours, 1..168) { v -> set { it.copy(updateIntervalHours = v) } }
        SwitchRow("Wi-Fi接続時のみ確認", s.updateWifiOnly) { v -> set { it.copy(updateWifiOnly = v) } }
        TextButton(onClick = { go(Screen.UPDATE) }) { Text("GitHubトークン・手動確認 →") }

        SectionTitle("開発者設定")
        TextButton(onClick = { developer = !developer }) { Text(if (developer) "▲ 閉じる" else "▼ 開く") }
        if (developer) {
            Text("モデルの読み込み設定は次回の読み込みから反映されます", style = MaterialTheme.typography.bodySmall)
            IntField("Context Length", s.contextLength, 512..131_072) { v -> set { it.copy(contextLength = v) } }
            IntField("Threads（0 = 自動）", s.threads, 0..32, "自動: HyperLoad時は全コア、通常は半分") { v -> set { it.copy(threads = v) } }
            IntField("Batch Size（0 = 自動）", s.batchSize, 0..4096) { v -> set { it.copy(batchSize = v) } }
            ChoiceRow(
                "GPU Offload",
                listOf(GpuOffload.AUTO to "自動", GpuOffload.CPU_ONLY to "CPUのみ", GpuOffload.GPU_PRIORITY to "GPU優先", GpuOffload.MAX_GPU to "最大"),
                s.gpuOffload,
            ) { v -> set { it.copy(gpuOffload = v) } }
            ChoiceRow("KV Cache", listOf(KvCacheType.F16 to "F16", KvCacheType.Q8_0 to "Q8_0（省メモリ）"), s.kvCache) { v -> set { it.copy(kvCache = v) } }
            IntField("最大生成トークン", s.maxTokens, 64..32_768) { v -> set { it.copy(maxTokens = v) } }
            IntField("再試行回数", s.retryLimit, 0..5) { v -> set { it.copy(retryLimit = v) } }
            IntField("ツール呼び出しの最大回数", s.maxToolRounds, 1..10) { v -> set { it.copy(maxToolRounds = v) } }
            SwitchRow("Force Execution", s.forceExecution, "RAM不足の警告を無視して読み込めるようにします（強制終了の危険あり）") { v ->
                set { it.copy(forceExecution = v) }
            }
        }
    }
}

private fun scopeLabel(scope: String) = when (scope) {
    ConsentManager.SCOPE_RUN_CODE -> "コードの実行"
    ConsentManager.SCOPE_EXPORT_HISTORY -> "会話の書き出し・共有"
    else -> scope
}
