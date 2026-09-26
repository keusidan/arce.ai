package ai.arce.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// White / black / indigo, per the design policy.
val Indigo = Color(0xFF283593)
val IndigoLight = Color(0xFF9FA8DA)
val ThinkingGreen = Color(0xFF2E7D32)
val ThinkingCyan = Color(0xFF00ACC1)

private val Light = lightColorScheme(
    primary = Indigo,
    onPrimary = Color.White,
    background = Color.White,
    onBackground = Color.Black,
    surface = Color.White,
    onSurface = Color.Black,
    surfaceVariant = Color(0xFFE8EAF6),
    onSurfaceVariant = Indigo,
)

private val Dark = darkColorScheme(
    primary = IndigoLight,
    onPrimary = Color.Black,
    background = Color.Black,
    onBackground = Color.White,
    surface = Color.Black,
    onSurface = Color.White,
    surfaceVariant = Color(0xFF1A237E),
    onSurfaceVariant = Color.White,
)

@Composable
fun ArceTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}
