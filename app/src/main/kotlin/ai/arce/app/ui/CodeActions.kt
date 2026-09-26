package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.toolchain.Installer
import ai.arce.app.sandbox.RunResult
import ai.arce.app.system.ConsentManager
import ai.arce.core.toolchain.JavaSource
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal fun isPython(language: String) = language.lowercase() in setOf("python", "py", "python3")
internal fun isJava(language: String) = language.lowercase() == "java"

/**
 * Run / build buttons for Python and Java code blocks (spec §14, 決定事項2). Everything that
 * executes generated code or produces an installable app goes through the consent window.
 */
@Composable
internal fun CodeActions(container: AppContainer, code: String, language: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember(code) { mutableStateOf<String?>(null) }
    var result by remember(code) { mutableStateOf<RunResult?>(null) }
    var built by remember(code) { mutableStateOf<File?>(null) }
    val java = remember(code) { if (isJava(language)) runCatching { JavaSource.parse(code) }.getOrNull() else null }

    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val file = built ?: return@rememberLauncherForActivityResult
        if (uri != null) scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                }
            }.onSuccess { status = "${file.name} を保存しました" }.onFailure { status = "保存に失敗: ${it.message}" }
        }
    }

    fun task(label: String, block: suspend CoroutineScope.() -> Unit) {
        scope.launch {
            status = label
            result = null
            try {
                block()
                if (status == label) status = null
            } catch (e: Exception) {
                result = RunResult(false, e.message ?: e.toString())
                status = null
            }
        }
    }

    Row(Modifier.horizontalScroll(rememberScrollState())) {
        if (isPython(language)) TextButton(onClick = {
            task("Pythonを実行中…（初回は準備に数十秒かかります）") {
                val ok = container.consent.request(
                    ConsentManager.SCOPE_RUN_PYTHON, "生成されたPythonを実行", code.take(2000),
                    listOf("別プロセスでの実行（20秒で強制終了）", "ネットワークアクセス", "ARCE.AIのアプリ内ファイルへのアクセスが可能（Pythonは隔離プロセスで動かせないため）"),
                )
                if (ok) result = container.sandbox.runPython(code)
            }
        }) { Text("実行") }

        if (java?.mainClass != null) TextButton(onClick = {
            task("コンパイルして実行中…") {
                val ok = container.consent.request(
                    ConsentManager.SCOPE_RUN_JAVA, "生成されたJavaを実行", code.take(2000),
                    listOf("隔離プロセスでの実行（権限・ネットワーク・アプリ内ファイルなし、20秒で強制終了）"),
                )
                if (!ok) return@task
                val compiled = container.toolchain.compile(java)
                status = "dexに変換中…"
                val dex = container.toolchain.dex(compiled)
                status = "実行中…"
                result = container.sandbox.runDex(dex, java.mainClass!!)
            }
        }) { Text("実行") }

        if (java?.mainClass != null) TextButton(onClick = {
            task("JARをビルド中…") {
                built = container.toolchain.jar(container.toolchain.compile(java))
                result = RunResult(true, "${built!!.name} を作成しました（PCで java -jar ${built!!.name} で実行できます）")
            }
        }) { Text("JAR") }

        if (java?.activityClass != null) TextButton(onClick = {
            task("APKをビルド中…") {
                val ok = container.consent.request(
                    ConsentManager.SCOPE_BUILD_APP, "生成されたコードからAPKを作成", code.take(2000),
                    listOf("コンパイルとAPKの作成", "ARCE.AI専用の署名鍵（Android Keystore内）で署名", "インストール時はAndroidの確認画面が出ます"),
                )
                if (!ok) return@task
                built = container.toolchain.apk(java)
                result = RunResult(true, "${built!!.name} を作成しました")
            }
        }) { Text("APK") }
    }

    status?.let {
        Text(it, style = MaterialTheme.typography.bodySmall)
        LinearProgressIndicator(Modifier.heightIn(max = 4.dp))
    }
    result?.let { r ->
        Text(if (r.ok) "出力" else if (r.timedOut) "時間切れ" else "エラー", style = MaterialTheme.typography.labelSmall, color = if (r.ok) MaterialTheme.colorScheme.primary else ErrorRed)
        Column(Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
            Text(r.output.ifEmpty { "（出力なし）" }, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        }
    }
    built?.let { file ->
        Row {
            TextButton(onClick = { saver.launch(file.name) }) { Text("保存") }
            if (file.extension == "apk") TextButton(onClick = {
                if (!context.packageManager.canRequestPackageInstalls()) {
                    context.startActivity(container.updates.installPermissionIntent())
                } else {
                    runCatching { Installer.install(context, file) }.onFailure { status = "インストールに失敗: ${it.message}" }
                }
            }) { Text("インストール") }
        }
    }
}
