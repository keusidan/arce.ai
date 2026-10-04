package com.arce.ai

import org.nanohttpd.nanohttpd.IHTTPSession
import org.nanohttpd.nanohttpd.NanoHTTPD
import org.nanohttpd.nanohttpd.Response
import java.io.File
import java.io.StringReader

/**
 * Local HTTP server for artifact previews (助言書: WebView is same-origin only,
 * JS errors are captured via a wrapper iframe that POSTs to /__error).
 * NanoHTTPD 2.3.1 API: listeningPort / newFixedLengthResponse / newChunkedResponse.
 */
class LocalPreviewServer(private val root: File) : NanoHTTPD(0) {

    init { root.mkdirs() }

    private val errorQueue = ArrayDeque<String>()

    fun port(): Int = try { listeningPort } catch (_: Exception) { 0 }

    fun previewUrl(fileName: String): String = "http://127.0.0.1:${port()}/wrap/$fileName"

    fun rawUrl(fileName: String): String = "http://127.0.0.1:${port()}/a/$fileName"

    fun takeError(): String? = synchronized(this) { errorQueue.removeFirstOrNull() }

    fun saveArtifact(fileName: String, content: String) {
        val f = File(root, fileName)
        f.parentFile?.mkdirs()
        f.writeText(content)
    }

    override fun serve(session: IHTTPSession): Response {
        val uri = session.uri ?: "/"
        return try {
            when {
                uri == "/" -> listPage()

                uri == "/__error" -> {
                    val msg = session.parameters["msg"]?.firstOrNull() ?: ""
                    if (msg.isNotBlank()) synchronized(this) { errorQueue.addLast(msg) }
                    newFixedLengthResponse(IStatus.OK, "text/plain; charset=utf-8", "ok")
                }

                uri.startsWith("/a/") -> {
                    val name = File(uri.removePrefix("/a/")).name
                    val f = File(root, name)
                    if (!f.exists() || !f.canRead()) {
                        newFixedLengthResponse(IStatus.NOT_FOUND, "text/plain", "not found")
                    } else {
                        newFixedLengthResponse(guessMime(name) + "; charset=utf-8", f.readText())
                    }
                }

                uri.startsWith("/wrap/") -> {
                    val name = File(uri.removePrefix("/wrap/")).name
                    val f = File(root, name)
                    if (!f.exists()) {
                        newFixedLengthResponse(IStatus.NOT_FOUND, "text/plain", "not found")
                    } else {
                        newFixedLengthResponse("text/html; charset=utf-8", wrapperPage(name))
                    }
                }

                else -> newFixedLengthResponse(IStatus.NOT_FOUND, "text/plain", "not found")
            }
        } catch (e: Exception) {
            newFixedLengthResponse(IStatus.INTERNAL_SERVER_ERROR, "text/plain", e.message ?: "error")
        }
    }

    private fun listPage(): Response {
        val sb = StringBuilder("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>ARCE.AI preview</title></head><body style=\"font-family:sans-serif\">")
        sb.append("<h2>ARCE.AI ローカルプレビュー</h2><ul>")
        root.listFiles()?.forEach {
            sb.append("<li><a href=\"/a/").append(it.name).append("\">").append(it.name).append("</a>")
                .append(" (").append(it.length()).append("B)</li>")
        }
        sb.append("</ul></body></html>")
        return newFixedLengthResponse("text/html; charset=utf-8", sb.toString())
    }

    private fun wrapperPage(name: String): String = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0">
        <script>
        function sendErr(m){ try{ fetch('/__error?msg='+encodeURIComponent(m),{method:'POST'}); }catch(e){} }
        window.addEventListener('error', function(e){ sendErr('wrap: '+(e.message||'error')); });
        </script>
        <iframe id="pv" src="/a/${name}" style="width:100%;height:100vh;border:0"></iframe>
        <script>
        var f = document.getElementById('pv');
        f.addEventListener('load', function(){
          try {
            var w = f.contentWindow;
            if (w) {
              w.addEventListener('error', function(e){
                sendErr('page: '+(e.message||'js error')+' @line '+(e.lineno||'?'));
              });
            }
          } catch(e) { sendErr('wrap-catch: '+e.message); }
        });
        </script>
        </body></html>
    """.trimIndent()

    private fun guessMime(name: String): String = when {
        name.endsWith(".html") || name.endsWith(".htm") -> "text/html"
        name.endsWith(".js") -> "application/javascript"
        name.endsWith(".css") -> "text/css"
        name.endsWith(".json") -> "application/json"
        name.endsWith(".png") -> "image/png"
        name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
        name.endsWith(".svg") -> "image/svg+xml"
        else -> "text/plain"
    }
}
