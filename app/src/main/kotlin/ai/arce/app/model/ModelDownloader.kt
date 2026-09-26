package ai.arce.app.model

import ai.arce.core.model.ModelSpec
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

data class RemoteFile(val sizeBytes: Long, val sha256: String?)

sealed interface DownloadState {
    data object Idle : DownloadState
    data class Running(val done: Long, val total: Long) : DownloadState
    /** Stopped by the user or a network error; the partial file is kept for Resume (spec §19). */
    data class Paused(val done: Long, val total: Long, val reason: String?) : DownloadState
    data object Verifying : DownloadState
    data object Installed : DownloadState
    data class Failed(val reason: String) : DownloadState
}

/**
 * Downloads a GGUF from Hugging Face into the model directory.
 * - resumes a `.part` file with an HTTP Range request, but only when the user presses Resume
 * - verifies the SHA-256 that Hugging Face publishes for LFS files before installing
 * - never downloads a model that is already installed and intact
 */
class ModelDownloader(private val directory: File) {

    fun target(spec: ModelSpec) = File(directory, spec.fileName)
    fun partial(spec: ModelSpec) = File(directory, spec.fileName + ".part")

    /** Size and checksum from the Hugging Face tree API. */
    suspend fun remote(spec: ModelSpec): RemoteFile = withContext(Dispatchers.IO) {
        val body = open("https://huggingface.co/api/models/${spec.hfRepo}/tree/main", null).useBody()
        val entry = Json.parseToJsonElement(body).jsonArray
            .map { it.jsonObject }
            .firstOrNull { it["path"]?.jsonPrimitive?.contentOrNull == spec.fileName }
            ?: error("${spec.fileName} not found in ${spec.hfRepo}")
        val lfs = entry["lfs"] as? JsonObject
        RemoteFile(
            sizeBytes = (lfs?.get("size") ?: entry["size"])?.jsonPrimitive?.longOrNull ?: spec.fileBytes,
            sha256 = lfs?.get("oid")?.jsonPrimitive?.contentOrNull,
        )
    }

    /**
     * Downloads (or continues) [spec]. [onProgress] runs on the IO thread. Throws on network
     * errors; the `.part` file stays so the user can resume.
     */
    suspend fun download(spec: ModelSpec, remote: RemoteFile, onProgress: (Long, Long) -> Unit): File =
        withContext(Dispatchers.IO) {
            directory.mkdirs()
            val part = partial(spec)
            val start = if (part.exists()) part.length() else 0L
            val url = "https://huggingface.co/${spec.hfRepo}/resolve/main/${spec.fileName}"
            val connection = open(url, start.takeIf { it > 0 })
            val resumed = connection.responseCode == HttpURLConnection.HTTP_PARTIAL
            var done = if (resumed) start else 0L
            RandomAccessFile(part, "rw").use { out ->
                if (!resumed) out.setLength(0)
                out.seek(done)
                connection.inputStream.use { input ->
                    val buffer = ByteArray(1 shl 20)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        done += n
                        onProgress(done, remote.sizeBytes)
                    }
                }
            }
            connection.disconnect()
            part
        }

    /** Checks the SHA-256 and moves the file into place; deletes it when corrupt. */
    suspend fun install(spec: ModelSpec, remote: RemoteFile, part: File): File = withContext(Dispatchers.IO) {
        remote.sha256?.let { expected ->
            val actual = sha256(part)
            if (!actual.equals(expected, ignoreCase = true)) {
                part.delete()
                error("SHA-256 mismatch (file corrupted); downloaded file removed")
            }
        }
        val target = target(spec)
        check(part.renameTo(target)) { "could not move the model into place" }
        target
    }

    /** Integrity check of an installed model (spec §19 整合性確認). */
    suspend fun verify(spec: ModelSpec, remote: RemoteFile): Boolean = withContext(Dispatchers.IO) {
        val file = target(spec)
        file.exists() && file.length() == remote.sizeBytes &&
            (remote.sha256 == null || sha256(file).equals(remote.sha256, ignoreCase = true))
    }

    private fun open(url: String, rangeStart: Long?): HttpURLConnection {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("User-Agent", "ARCE.AI")
        rangeStart?.let { connection.setRequestProperty("Range", "bytes=$it-") }
        val code = connection.responseCode
        if (code !in 200..299) {
            connection.disconnect()
            error("HTTP $code for $url")
        }
        return connection
    }

    private fun HttpURLConnection.useBody(): String = try {
        inputStream.bufferedReader().use { it.readText() }
    } finally {
        disconnect()
    }

    companion object {
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
