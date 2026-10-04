package com.arce.ai.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.arce.ai.ArceApp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(app: ArceApp, onBack: () -> Unit) {
    var hyperLoad by remember { mutableStateOf(app.settings.hyperLoad) }
    var threads by remember { mutableIntStateOf(app.settings.nThreads) }
    var tempThreshold by remember { mutableIntStateOf(app.settings.tempThreshold) }
    var forceTemp by remember { mutableStateOf(app.settings.forceTempMonitor) }
    val tick by app.engine.tick.collectAsState()
    val tempNow = remember(tick) { app.heatMonitor.tempC }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("設定") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                }
            )
        }
    ) { pad ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(pad)
                .verticalScroll(rememberScrollState())
                .padding(12.dp)
        ) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text("モデル設定", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("HyperLoad", style = MaterialTheme.typography.bodyLarge)
                            Text(
                                "文脈8192 / 最大2044トークン（メモリ増・高速化）",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF9CA3AF)
                            )
                        }
                        Switch(checked = hyperLoad, onValueChange = {
                            hyperLoad = it
                            app.settings.hyperLoad = it
                        })
                    }
                    Text("CPUスレッド: $threads", style = MaterialTheme.typography.bodyMedium)
                    Slider(
                        value = threads.toFloat(),
                        onValueChange = {
                            threads = it.toInt().coerceIn(1, 8)
                            app.settings.nThreads = threads
                        },
                        valueRange = 1f..8f,
                        steps = 6
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text(
                        "温度監視 (現在: ${if (tempNow > 0) "$tempNow°C" else "取得中/無効"})",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Spacer(Modifier.height(8.dp))
                    Text("警告しきい値: ${tempThreshold}°C", style = MaterialTheme.typography.bodyMedium)
                    Slider(
                        value = tempThreshold.toFloat(),
                        onValueChange = {
                            tempThreshold = it.toInt().coerceIn(40, 55)
                            app.settings.tempThreshold = tempThreshold
                        },
                        valueRange = 40f..55f,
                        steps = 14
                    )
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("常時監視（強制モード）", style = MaterialTheme.typography.bodyLarge)
                            Text(
                                "オフ時は推論実行中のみの監視（助言書準拠）",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF9CA3AF)
                            )
                        }
                        Switch(checked = forceTemp, onValueChange = {
                            forceTemp = it
                            app.settings.forceTempMonitor = it
                            if (it) app.heatMonitor.start() else app.heatMonitor.stop()
                        })
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text("バックエンド（起動時検査・キャッシュ）", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(6.dp))
                    val bs = app.settings.backends()
                    if (bs.isEmpty()) {
                        Text("検査結果なし（初回起動後に更新されます）", color = Color(0xFF9CA3AF),
                            style = MaterialTheme.typography.bodySmall)
                    } else {
                        bs.forEach {
                            Text(
                                if (it.type == "gpu") "🟢 ${it.name}" else "⚪ ${it.name}",
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Text("データ", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "保存場所: ${app.dataDirLabel()}",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF9CA3AF)
                    )
                    Text(
                        "モデルファイルと履歴は端末に保存されます。アプリをアンインストールすると消去されます。",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF9CA3AF)
                    )
                }
            }
        }
    }
}
