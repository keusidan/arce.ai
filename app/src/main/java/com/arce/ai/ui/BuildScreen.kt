package com.arce.ai.ui

import android.os.Handler
import android.os.Looper
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.arce.ai.ArceApp
import com.arce.ai.BuildPipeline
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BuildScreen(app: ArceApp, onBack: () -> Unit) {
    var target by remember { mutableStateOf("apk") }
    var log by remember { mutableStateOf("APK / EXE / JAR のビルドを試せます。\nEXE は PC ビルドサーバー必須です（企画書準拠）。") }
    var running by remember { mutableStateOf(false) }
    val pipeline = remember { BuildPipeline(app) }
    val scope = rememberCoroutineScope()
    val main = Handler(Looper.getMainLooper())

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("ビルド") },
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
            Row {
                listOf("apk" to "APK", "exe" to "EXE", "jar" to "JAR").forEach { (key, label) ->
                    FilterChip(
                        selected = target == key,
                        onClick = { target = key },
                        label = { Text(label) }
                    )
                    Spacer(Modifier.width(8.dp))
                }
            }
            Spacer(Modifier.height(8.dp))
            if (target == "exe") {
                Text(
                    "EXE（Windows PC）の生成はPCビルドサーバー必須です。" +
                        "この端末からは環境検査と必要な手順の確認のみ行います。",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFFFBBF24)
                )
                Spacer(Modifier.height(8.dp))
            }
            Button(
                enabled = !running,
                onClick = {
                    running = true
                    log = ""
                    scope.launch {
                        val report = pipeline.run(target) { line ->
                            main.post { log += line + "\n" }
                        }
                        main.post {
                            log += if (report.ok) "\n=== 完了 ===\n" else "\n=== 失敗 ===\n"
                            log += "不足: " + (report.missing.joinToString("、").ifEmpty { "なし" }) + "\n"
                            running = false
                        }
                    }
                }
            ) {
                Text(if (running) "実行中…" else "実行")
            }
            Spacer(Modifier.height(10.dp))
            Card(Modifier.fillMaxWidth()) {
                Text(
                    log,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFFD1D5DB),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(480.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(8.dp)
                )
            }
        }
    }
}
