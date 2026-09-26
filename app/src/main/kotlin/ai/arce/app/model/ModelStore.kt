package ai.arce.app.model

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * GGUF files kept in app-specific external storage (no storage permission needed).
 * Files can also be placed there with `adb push`, see the prototype README.
 */
class ModelStore(private val context: Context) {
    val directory: File = File(context.getExternalFilesDir(null), "models").apply { mkdirs() }

    fun list(): List<File> =
        directory.listFiles { file -> file.isFile && file.extension.equals("gguf", ignoreCase = true) }
            ?.sortedBy { it.name }
            .orEmpty()

    /** Copies a file picked with the system file picker. Writes to a temp name first so a failed copy leaves no half file. */
    suspend fun import(uri: Uri, onProgress: (copiedBytes: Long) -> Unit): File = withContext(Dispatchers.IO) {
        val name = displayName(uri) ?: "model-${System.currentTimeMillis()}.gguf"
        require(name.endsWith(".gguf", ignoreCase = true)) { "GGUFファイルを選んでください: $name" }

        val target = File(directory, name)
        val temp = File(directory, "$name.part")
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "ファイルを開けませんでした" }
            temp.outputStream().use { output ->
                val buffer = ByteArray(1 shl 20)
                var copied = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    copied += n
                    onProgress(copied)
                }
            }
        }
        check(temp.renameTo(target)) { "コピーしたファイルを保存できませんでした" }
        target
    }

    private fun displayName(uri: Uri): String? =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
}
