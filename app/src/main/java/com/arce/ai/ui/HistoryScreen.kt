package com.arce.ai.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.arce.ai.ArceApp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(app: ArceApp, onBack: () -> Unit) {
    var refresh by remember { mutableIntStateOf(0) }
    val list = remember(refresh) { app.history.all.toList() }
    val fmt = SimpleDateFormat("M/d HH:mm", Locale.JAPAN)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("会話履歴") },
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
            if (list.isEmpty()) {
                Text(
                    "履歴はありません",
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color(0xFF9CA3AF),
                    modifier = Modifier.padding(top = 24.dp)
                )
            }
            list.forEach { conv ->
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                        .clickable {
                            app.history.open(conv.id)
                            onBack()
                        }
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(conv.title, style = MaterialTheme.typography.titleSmall)
                            Text(
                                "${fmt.format(Date(conv.ts))} / ${conv.messages.size}メッセージ",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF9CA3AF)
                            )
                        }
                        IconButton(onClick = {
                            app.history.delete(conv.id)
                            refresh++
                        }) {
                            Icon(
                                Icons.Default.Delete,
                                contentDescription = "削除",
                                tint = Color(0xFF9CA3AF)
                            )
                        }
                    }
                }
            }
        }
    }
}
