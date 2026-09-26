package ai.arce.app.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Languages the WebView can preview or run. */
fun isPreviewable(language: String) = language.lowercase() in setOf("html", "htm", "svg")
fun isRunnableJs(language: String) = language.lowercase() in setOf("js", "javascript")

/** Wraps a JavaScript snippet so it runs as a page and its console output is shown. */
fun javascriptPage(code: String) = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <script>
    window.onerror = function(msg, src, line) { console.error(msg + " (line " + line + ")"); };
    </script>
    <script>
    $code
    </script>
    </body></html>
""".trimIndent()

/**
 * Previews an HTML Artifact or runs JavaScript.
 *
 * Isolation: the page runs in WebView's sandboxed renderer process, gets no JavaScript
 * bridge into the app (no addJavascriptInterface), no file or content:// access, and a
 * throw-away origin; links open in the browser instead of inside the app.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun ArtifactWebView(html: String, heightDp: Int = 320) {
    val console = remember(html) { mutableStateListOf<String>() }
    Column {
        // Load once per html. Loading from update{} would reload on every recomposition,
        // and each console line recomposes, so the page would restart in a loop.
        key(html) { AndroidView(
            modifier = Modifier.fillMaxWidth().height(heightDp.dp),
            factory = { context ->
                WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.setGeolocationEnabled(false)
                    settings.mediaPlaybackRequiresUserGesture = true
                    webChromeClient = object : WebChromeClient() {
                        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                            console += "[${message.messageLevel().name.lowercase()}] ${message.message()}"
                            return true
                        }
                    }
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                            view.context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(request.url.toString())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            return true
                        }
                    }
                    loadDataWithBaseURL("https://artifact.arce.invalid/", html, "text/html", "utf-8", null)
                }
            },
        ) }
        if (console.isNotEmpty()) {
            Text("Console", style = MaterialTheme.typography.labelSmall)
            console.takeLast(50).forEach { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
        }
    }
}
