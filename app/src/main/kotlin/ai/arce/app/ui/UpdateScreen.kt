package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.BuildConfig
import ai.arce.app.Screen
import ai.arce.app.model.ModelController
import ai.arce.app.update.UpdateManager
import ai.arce.app.update.UpdateState
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

/**
 * Update from the private GitHub Releases (決定事項9): the check can run periodically, but the
 * download starts only when the user presses the button here.
 */
@Composable
fun ColumnScope.UpdateScreen(container: AppContainer, go: (Screen) -> Unit) {
    val updates = container.updates
    val settings by container.settings.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf<UpdateState>(UpdateState.Idle) }
    var hasToken by remember { mutableStateOf(container.secrets.get(UpdateManager.TOKEN_NAME) != null) }
    var tokenInput by remember { mutableStateOf("") }

    fun check() {
        state = UpdateState.Checking
        scope.launch {
            state = runCatching { updates.latest(settings.updateRepo) }
                .fold({ if (updates.isNewer(it)) UpdateState.Available(it) else UpdateState.UpToDate }, { UpdateState.Failed(it.message ?: "error") })
        }
    }

    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
        Text("現在のバージョン: ${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）")
        Text("リポジトリ: ${settings.updateRepo}・${settings.updateIntervalHours}時間ごとに確認", style = MaterialTheme.typography.bodySmall)

        SectionTitle("GitHubトークン")
        Text(
            "非公開リポジトリのため、Fine-grained PAT(Personal Access Token)が必要です。対象リポジトリのみ、権限は Contents: Read-only にしてください。" +
                "トークンはAndroid Keystoreの鍵で暗号化して端末内にだけ保存します。",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(if (hasToken) "保存済み" else "未設定", color = if (hasToken) MaterialTheme.colorScheme.primary else ErrorRed)
        OutlinedTextField(
            value = tokenInput,
            onValueChange = { tokenInput = it.trim() },
            label = { Text("github_pat_…") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        TextButton(onClick = {
            container.secrets.put(UpdateManager.TOKEN_NAME, tokenInput)
            tokenInput = ""
            hasToken = true
        }, enabled = tokenInput.length >= 20) { Text("保存") }
        if (hasToken) TextButton(onClick = { container.secrets.put(UpdateManager.TOKEN_NAME, null); hasToken = false }) { Text("削除", color = ErrorRed) }

        SectionTitle("確認とインストール")
        when (val s = state) {
            UpdateState.Idle -> Unit
            UpdateState.Checking -> { Text("確認中…"); LinearProgressIndicator(Modifier.fillMaxWidth()) }
            UpdateState.UpToDate -> Text("最新版です")
            is UpdateState.Available -> {
                Text("新しいバージョン ${s.release.tag} があります")
                s.release.apk?.let { Text("APK ${ModelController.gb(it.sizeBytes)}", style = MaterialTheme.typography.bodySmall) }
                if (s.release.notes.isNotBlank()) Text(s.release.notes.take(2000), style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = {
                    state = UpdateState.Downloading(s.release, 0, s.release.apk?.sizeBytes ?: 0)
                    scope.launch {
                        state = runCatching {
                            updates.download(settings.updateRepo, s.release) { done, total -> state = UpdateState.Downloading(s.release, done, total) }
                        }.fold({ UpdateState.ReadyToInstall(s.release, it) }, { UpdateState.Failed(it.message ?: "error") })
                    }
                }) { Text("ダウンロードする") }
            }
            is UpdateState.Downloading -> {
                Text("${s.release.tag} をダウンロード中 ${ModelController.gb(s.done)} / ${ModelController.gb(s.total)}")
                LinearProgressIndicator(progress = { if (s.total > 0) s.done.toFloat() / s.total else 0f }, modifier = Modifier.fillMaxWidth())
            }
            is UpdateState.ReadyToInstall -> {
                Text("${s.release.tag} のSHA-256を確認しました")
                if (!updates.canInstall()) {
                    Text("最初の1回だけ「この提供元のアプリを許可」が必要です", style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { context.startActivity(updates.installPermissionIntent()) }) { Text("許可設定を開く") }
                }
                TextButton(onClick = {
                    runCatching { updates.install(s.apk) }.onFailure { state = UpdateState.Failed(it.message ?: "error") }
                }, enabled = updates.canInstall()) { Text("インストール") }
            }
            is UpdateState.Failed -> Text(s.reason, color = ErrorRed)
        }
        TextButton(onClick = ::check, enabled = state !is UpdateState.Checking && state !is UpdateState.Downloading) { Text("今すぐ確認") }
        TextButton(onClick = { go(Screen.SETTINGS) }) { Text("確認間隔などの設定 →") }
    }
}
