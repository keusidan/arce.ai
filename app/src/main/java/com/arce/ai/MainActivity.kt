package com.arce.ai

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.arce.ai.ui.ArceTheme
import com.arce.ai.ui.BuildScreen
import com.arce.ai.ui.ChatScreen
import com.arce.ai.ui.HistoryScreen
import com.arce.ai.ui.ModelDownloadScreen
import com.arce.ai.ui.SettingsScreen

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ArceApp.instance?.heatMonitor?.startIfForced()
        setContent {
            ArceTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ArceNav()
                }
            }
        }
        // Capability probe (once at startup, then cached 助言書準拠)
        probeCapabilities()
    }

    private fun probeCapabilities() {
        kotlin.concurrent.thread {
            try {
                val list = ArceLlama.backends()
                (ArceApp.instance?.settings)?.storeBackends(list)
                ArceApp.instance?.engine?.notifyChange()
            } catch (_: Throwable) {
            }
        }
    }
}

@Composable
fun ArceNav() {
    val app = ArceApp.instance ?: return
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val route = backStack?.destination?.route

    NavHost(navController = nav, startDestination = "chat") {
        composable("chat") {
            ChatScreen(
                app = app,
                onOpenModels = { nav.navigate("models") },
                onOpenSettings = { nav.navigate("settings") },
                onOpenHistory = { nav.navigate("history") },
                onOpenBuild = { nav.navigate("build") }
            )
        }
        composable("models") { ModelDownloadScreen(app = app, onBack = { nav.popBackStack() }) }
        composable("settings") { SettingsScreen(app = app, onBack = { nav.popBackStack() }) }
        composable("history") { HistoryScreen(app = app, onBack = { nav.popBackStack() }) }
        composable("build") { BuildScreen(app = app, onBack = { nav.popBackStack() }) }
    }
}
