package com.remapp.rem.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val RemBlue = Color(0xFF0C50FF)
val RemCream = Color(0xFFF4F1EA)
val RemMuted = Color(0xFFB8B0A2)
val RemInk = Color(0xFF0F0F0F)

private val RemDarkColors = darkColorScheme(
    primary = RemBlue,
    onPrimary = Color.White,
    background = RemInk,
    onBackground = RemCream,
    surface = Color(0xFF171512),
    onSurface = RemCream,
    secondary = RemMuted,
    onSecondary = RemInk,
)

@Composable
fun RemTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = RemDarkColors, content = content)
}
