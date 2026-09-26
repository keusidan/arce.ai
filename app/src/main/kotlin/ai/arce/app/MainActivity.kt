package ai.arce.app

import ai.arce.app.model.ModelController
import ai.arce.app.settings.ThemeMode
import ai.arce.app.system.ConsentAnswer
import ai.arce.app.system.Notifications
import ai.arce.app.ui.ArceTheme
import ai.arce.app.ui.ChatScreen
import ai.arce.app.ui.DiagnosticsScreen
import ai.arce.app.ui.HistoryScreen
import ai.arce.app.ui.ModelsScreen
import ai.arce.app.ui.SettingsScreen
import ai.arce.app.ui.UpdateScreen
import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import ai.arce.core.agent.Agents
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

enum class Screen(val title: String) {
    CHAT("ARCE.AI"), HISTORY("履歴"), MODELS("モデル管理"), SETTINGS("設定"), DIAGNOSTICS("診断・ベンチマーク"), UPDATE("アップデート")
}

class MainActivity : ComponentActivity() {
    private var requestedScreen by mutableStateOf<Screen?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleIntent(intent)
        val container = (application as ArceApp).container

        // Progress notifications need the runtime permission on Android 13+.
        if (!Notifications.canPost(this)) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
                .launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        setContent {
            val settings by container.settings.collectAsStateWithLifecycle()
            ArceTheme(dark = when (settings.theme) { ThemeMode.LIGHT -> false; ThemeMode.DARK -> true; ThemeMode.SYSTEM -> null }) {
                var screen by rememberSaveable { mutableStateOf(Screen.CHAT) }
                LaunchedEffect(requestedScreen) { requestedScreen?.let { screen = it; requestedScreen = null } }
                BackHandler(enabled = screen != Screen.CHAT) { screen = Screen.CHAT }

                val drawer = rememberDrawerState(DrawerValue.Closed)
                val scope = rememberCoroutineScope()
                val go: (Screen) -> Unit = { screen = it; scope.launch { drawer.close() } }

                // Hamburger menu at the top (layout sketch): every other screen lives in the drawer.
                ModalNavigationDrawer(
                    drawerState = drawer,
                    drawerContent = { ModalDrawerSheet { DrawerContent(container, screen, go) } },
                ) {
                    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
                        Column(Modifier.safeDrawingPadding()) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                TextButton(onClick = { scope.launch { drawer.open() } }) {
                                    Text("≡", style = MaterialTheme.typography.headlineSmall)
                                }
                                Text(screen.title, style = MaterialTheme.typography.titleMedium)
                            }
                            when (screen) {
                                Screen.CHAT -> ChatScreen(container, go)
                                Screen.HISTORY -> HistoryScreen(container, go)
                                Screen.MODELS -> ModelsScreen(container, go)
                                Screen.SETTINGS -> SettingsScreen(container, go)
                                Screen.DIAGNOSTICS -> DiagnosticsScreen(container, go)
                                Screen.UPDATE -> UpdateScreen(container, go)
                            }
                        }
                        GlobalDialogs(container)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        requestedScreen = when (intent?.getStringExtra(Notifications.EXTRA_SCREEN)) {
            "update" -> Screen.UPDATE
            "models" -> Screen.MODELS
            else -> requestedScreen
        }
    }
}

@Composable
private fun DrawerContent(container: AppContainer, current: Screen, go: (Screen) -> Unit) {
    val conversations by container.conversations.collectAsStateWithLifecycle(emptyList())
    val settings by container.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    Column(Modifier.verticalScroll(rememberScrollState()).padding(8.dp)) {
        Text("ARCE.AI", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(8.dp))
        NavigationDrawerItem(label = { Text("＋ 新しい会話") }, selected = false, onClick = { container.newConversation(); go(Screen.CHAT) })
        NavigationDrawerItem(label = { Text("チャット") }, selected = current == Screen.CHAT, onClick = { go(Screen.CHAT) })
        Screen.entries.filter { it != Screen.CHAT }.forEach { target ->
            NavigationDrawerItem(label = { Text(target.title) }, selected = current == target, onClick = { go(target) })
        }
        NavigationDrawerItem(label = { Text("会話を共有") }, selected = false, onClick = {
            scope.launch { ai.arce.app.ui.shareConversation(context, container) }
        })

        Text("Agent", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = 16.dp, top = 12.dp))
        val choices = listOf("" to "自動") + Agents.all.map { it.id to "${it.displayName}（${it.minModelParamsB}B〜）" }
        choices.forEach { (id, label) ->
            NavigationDrawerItem(
                label = { Text(label) },
                selected = settings.agentOverride == id,
                onClick = { scope.launch { container.settingsRepository.update { it.copy(agentOverride = id) } } },
            )
        }

        Text("最近の会話", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = 16.dp, top = 12.dp))
        conversations.take(20).forEach { c ->
            NavigationDrawerItem(label = { Text(c.title, maxLines = 1) }, selected = false, onClick = {
                container.openConversation(c.id)
                go(Screen.CHAT)
            })
        }
    }
}

@Composable
private fun GlobalDialogs(container: AppContainer) {
    val consent by container.consent.pending.collectAsStateWithLifecycle()
    val models by container.models.state.collectAsStateWithLifecycle()
    val interrupted by container.interrupted.collectAsStateWithLifecycle()
    val settings by container.settings.collectAsStateWithLifecycle()

    consent?.let { request ->
        AlertDialog(
            onDismissRequest = { container.consent.respond(ConsentAnswer.DENY) },
            title = { Text(request.title) },
            text = {
                Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
                    Text("必要な権限: " + request.permissions.joinToString("、"))
                    Text(request.detail, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = {
                Column {
                    TextButton(onClick = { container.consent.respond(ConsentAnswer.ONCE) }) { Text("今回だけ許可") }
                    TextButton(onClick = { container.consent.respond(ConsentAnswer.ALWAYS) }) { Text("常に許可") }
                }
            },
            dismissButton = { TextButton(onClick = { container.consent.respond(ConsentAnswer.DENY) }) { Text("拒否") } },
        )
    }

    models.memoryWarning?.let { w ->
        AlertDialog(
            onDismissRequest = container.models::dismissMemoryWarning,
            title = { Text("RAMが不足する可能性があります") },
            text = {
                Text(
                    "推定使用量: ${ModelController.gb(w.estimatedBytes)}\n空きRAM: ${ModelController.gb(w.availableBytes)}\n\n" +
                        if (settings.forceExecution) "Force Executionが有効です。続行するとアプリが強制終了する可能性があります。"
                        else "Context LengthやKV Cacheを下げるか、開発者設定のForce Executionを有効にしてください。設定は自動では変更しません。",
                )
            },
            confirmButton = {
                if (settings.forceExecution) TextButton(onClick = { container.models.load(w.file, confirmed = true) }) { Text("強制的に読み込む") }
            },
            dismissButton = { TextButton(onClick = container.models::dismissMemoryWarning) { Text("キャンセル") } },
        )
    }

    interrupted?.let { item ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("前回の生成処理が途中終了しました") },
            text = { Text("「${item.title}」の生成中にアプリが終了しました。") },
            confirmButton = {
                Column {
                    TextButton(onClick = { container.resolveInterrupted("resume") }) { Text("再開") }
                    TextButton(onClick = { container.resolveInterrupted("regenerate") }) { Text("再生成") }
                }
            },
            dismissButton = { TextButton(onClick = { container.resolveInterrupted("discard") }) { Text("破棄") } },
        )
    }
}
