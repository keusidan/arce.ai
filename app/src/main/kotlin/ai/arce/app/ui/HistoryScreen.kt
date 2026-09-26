package ai.arce.app.ui

import ai.arce.app.AppContainer
import ai.arce.app.Screen
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.text.DateFormat
import java.util.Date

/** Saved conversations (spec §25): search, open, delete. */
@Composable
fun ColumnScope.HistoryScreen(container: AppContainer, go: (Screen) -> Unit) {
    val all by container.conversations.collectAsStateWithLifecycle(emptyList())
    val current by container.conversationId.collectAsStateWithLifecycle()
    val chat by container.chat.state.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    var confirmDelete by remember { mutableStateOf<Long?>(null) }
    val format = remember { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT) }

    val shown = if (query.isBlank()) all else all.filter {
        it.title.contains(query, ignoreCase = true) || it.snapshotJson.contains(query, ignoreCase = true)
    }

    Column(Modifier.padding(horizontal = 12.dp).weight(1f)) {
        OutlinedTextField(query, { query = it }, label = { Text("履歴を検索") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        TextButton(onClick = { container.newConversation(); go(Screen.CHAT) }, enabled = !chat.isGenerating) { Text("＋ 新しい会話") }
        if (chat.isGenerating) Text("生成中は会話を切り替えられません", style = MaterialTheme.typography.bodySmall)
        if (shown.isEmpty()) Text(if (all.isEmpty()) "まだ会話がありません" else "一致する会話がありません", modifier = Modifier.padding(8.dp))
        LazyColumn(Modifier.weight(1f)) {
            items(shown, key = { it.id }) { c ->
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = !chat.isGenerating) {
                        container.openConversation(c.id)
                        go(Screen.CHAT)
                    }.padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text((if (c.id == current) "● " else "") + c.title, maxLines = 1)
                        Text(
                            format.format(Date(c.updatedAt)) + if (c.generating) "  ・途中終了" else "",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    TextButton(onClick = { confirmDelete = c.id }) { Text("削除", color = ErrorRed) }
                }
                HorizontalDivider()
            }
        }
    }

    confirmDelete?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("会話を削除しますか？") },
            text = { Text("削除した会話は元に戻せません。") },
            confirmButton = { TextButton(onClick = { container.deleteConversation(id); confirmDelete = null }) { Text("削除", color = ErrorRed) } },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("キャンセル") } },
        )
    }
}
