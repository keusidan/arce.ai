package com.arce.ai.ui

import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.view.AndroidView
import com.arce.ai.ArceApp
import com.arce.ai.Artifact
import kotlinx.coroutines.delay

@Composable
fun ArtifactCard(artifact: Artifact, sourceText: String) {
    val app = ArceApp.instance
    val server = app?.previewServer
    val url = server?.previewUrl(artifact.fileName) ?: ""
    val canPreview = artifact.kind == "html" || artifact.kind == "js" || artifact.kind == "css"
    var tab by remember(artifact.id) {
        mutableStateOf(if (canPreview) "preview" else "code")
    }
    var jsError by remember(artifact.id) { mutableStateOf("") }

    // JS error capture: wrapper iframe (same origin) POSTs to /__error
    LaunchedEffect(artifact.id) {
        if (!canPreview) return@LaunchedEffect
        while (true) {
            val e = server?.takeError()
            if (e != null) jsError = e
            delay(1500)
        }
    }

    val context = LocalContext.current
    val saveLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri ->
        if (uri != null) {
            try {
                context.contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(artifact.content.toByteArray())
                }
            } catch (_: Exception) {
            }
        }
    }

    Card(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Column(Modifier.padding(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "📄 ${artifact.title} (${artifact.fileName})",
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f)
                )
                OutlinedButton(onClick = { saveLauncher.launch(artifact.fileName) }) {
                    Text("保存")
                }
            }
            Spacer(Modifier.height(6.dp))
            Row {
                if (canPreview) {
                    TabChip("プレビュー", tab == "preview") { tab = "preview" }
                    Spacer(Modifier.width(6.dp))
                }
                TabChip("コード", tab == "code") { tab = "code" }
            }
            Spacer(Modifier.height(6.dp))
            if (tab == "preview" && canPreview) {
                AndroidView(
                    factory = { ctx ->
                        WebView(ctx).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            webViewClient = object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(
                                    view: WebView?,
                                    request: WebResourceRequest?
                                ): Boolean = true
                            }
                            if (url.isNotEmpty()) loadUrl(url)
                        }
                    },
                    modifier = Modifier.height(420.dp).fillMaxWidth()
                )
                if (jsError.isNotEmpty()) {
                    Text(
                        "⚠ JSエラー: $jsError",
                        color = Color(0xFFFCA5A5),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
            } else {
                val vScroll = rememberScrollState()
                val hScroll = rememberScrollState()
                Text(
                    artifact.content,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFFD1D5DB),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(420.dp)
                        .padding(8.dp)
                        .verticalScroll(vScroll)
                        .horizontalScroll(hScroll)
                )
            }
        }
    }
}

@Composable
private fun TabChip(label: String, selected: Boolean, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick) {
        Text(label, color = if (selected) Color(0xFF4ADE80) else Color(0xFF9CA3AF))
    }
}
