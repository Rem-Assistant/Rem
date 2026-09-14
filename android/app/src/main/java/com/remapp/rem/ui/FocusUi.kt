package com.remapp.rem.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier as ComposeModifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

enum class FocusPhase {
    Off,
    Setup,
    Warming,
    Running,
    Paused,
    Complete,
}

data class FocusState(
    val phase: FocusPhase = FocusPhase.Off,
    val taskId: String? = null,
    val taskTitle: String = "",
    val durationMinutes: Int = 25,
    val remainingSec: Int = 0,
    val totalSec: Int = 25 * 60,
    val warmUpEnabled: Boolean = false,
    val minimized: Boolean = false,
) {
    val progress: Float
        get() = if (totalSec <= 0) 0f else ((totalSec - remainingSec).toFloat() / totalSec).coerceIn(0f, 1f)

    val isActive: Boolean
        get() = phase == FocusPhase.Warming ||
            phase == FocusPhase.Running ||
            phase == FocusPhase.Paused ||
            phase == FocusPhase.Complete

    val clockLabel: String
        get() = formatFocusClock(remainingSec)

    val modeLabel: String
        get() = when (phase) {
            FocusPhase.Warming -> "WARMING UP"
            FocusPhase.Paused -> "PAUSED"
            FocusPhase.Complete -> "DONE"
            else -> "FOCUSING"
        }
}

data class FocusCallbacks(
    val onOpenSetup: () -> Unit,
    val onCloseSetup: () -> Unit,
    val onPickDuration: (Int) -> Unit,
    val onToggleWarmUp: () -> Unit,
    val onStart: () -> Unit,
    val onMinimize: () -> Unit,
    val onExpand: () -> Unit,
    val onPause: () -> Unit,
    val onResume: () -> Unit,
    val onStop: () -> Unit,
    val onSkipWarmUp: () -> Unit,
    val onExtend: (Int) -> Unit,
    val onMarkComplete: () -> Unit,
    val onDismissComplete: () -> Unit,
)

val FocusGreen = Color(0xFF34C759)
val FocusOrange = Color(0xFFFF9F0A)

internal fun formatFocusClock(totalSeconds: Int): String {
    val clamped = totalSeconds.coerceAtLeast(0)
    val hours = clamped / 3600
    val minutes = (clamped % 3600) / 60
    val seconds = clamped % 60
    return if (hours > 0) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%d:%02d".format(minutes, seconds)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FocusSetupSheet(
    state: FocusState,
    onPickDuration: (Int) -> Unit,
    onToggleWarmUp: () -> Unit,
    onStart: () -> Unit,
    onClose: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onClose,
        sheetState = sheetState,
        containerColor = Color(0xFF171512),
        contentColor = RemCream,
    ) {
        Column(
            modifier = ComposeModifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
        ) {
            Text("Focus session", color = RemCream, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text("Task to focus on", color = RemMuted, fontSize = 13.sp)
            Spacer(modifier = ComposeModifier.height(6.dp))
            Text(state.taskTitle, color = RemCream, fontSize = 18.sp, fontWeight = FontWeight.Medium)
            Spacer(modifier = ComposeModifier.height(20.dp))
            Text("Duration", color = RemMuted, fontSize = 13.sp)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(15, 25, 45, 60).forEach { minutes ->
                    val selected = state.durationMinutes == minutes
                    val label = if (minutes == 60) "1h" else "${minutes}m"
                    Button(
                        onClick = { onPickDuration(minutes) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (selected) RemBlue else Color(0xFF242018),
                            contentColor = if (selected) Color.White else RemCream,
                        ),
                    ) { Text(label) }
                }
            }
            Spacer(modifier = ComposeModifier.height(20.dp))
            Row(
                modifier = ComposeModifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = ComposeModifier.weight(1f)) {
                    Text("Warm up", color = RemCream, fontSize = 16.sp)
                    Text("One extra minute before the timer starts.", color = RemMuted, fontSize = 12.sp)
                }
                Switch(
                    checked = state.warmUpEnabled,
                    onCheckedChange = { onToggleWarmUp() },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = RemBlue,
                    ),
                )
            }
            Spacer(modifier = ComposeModifier.height(24.dp))
            Button(
                onClick = onStart,
                modifier = ComposeModifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = FocusGreen, contentColor = Color.Black),
            ) { Text("Start focus") }
            Spacer(modifier = ComposeModifier.height(28.dp))
        }
    }
}

@Composable
fun FocusTimerScreen(
    state: FocusState,
    onMinimize: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onStop: () -> Unit,
    onSkipWarmUp: () -> Unit,
    onExtend: (Int) -> Unit,
    onMarkComplete: () -> Unit,
    onDismissComplete: () -> Unit,
) {
    val ringColor = when (state.phase) {
        FocusPhase.Warming -> FocusOrange
        FocusPhase.Paused -> FocusOrange
        else -> FocusGreen
    }
    Box(
        modifier = ComposeModifier
            .fillMaxSize()
            .background(RemInk),
    ) {
        Column(
            modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(modifier = ComposeModifier.height(12.dp))
            Row(
                modifier = ComposeModifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onMinimize) {
                    Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Hide", tint = RemCream)
                }
                Text(
                    "Focus Session",
                    color = RemCream,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp,
                    modifier = ComposeModifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                TextButton(onClick = onStop) { Text("End", color = Color(0xFFFF8A80)) }
            }
            Spacer(modifier = ComposeModifier.height(28.dp))
            Text(state.modeLabel, color = RemMuted, fontSize = 16.sp)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text(
                state.taskTitle,
                color = RemCream,
                fontSize = 30.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = ComposeModifier.padding(horizontal = 16.dp),
            )
            Spacer(modifier = ComposeModifier.height(36.dp))
            FocusRing(progress = state.progress, color = ringColor, label = state.clockLabel)
            Spacer(modifier = ComposeModifier.height(36.dp))
            if (state.phase == FocusPhase.Warming) {
                OutlinedButton(onClick = onSkipWarmUp) { Text("Skip warm-up", color = RemCream) }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Button(
                        onClick = { if (state.phase == FocusPhase.Paused) onResume() else onPause() },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = FocusGreen,
                            contentColor = Color.Black,
                        ),
                    ) {
                        Text(if (state.phase == FocusPhase.Paused) "Resume" else "Pause")
                    }
                    OutlinedButton(onClick = { onExtend(5) }) { Text("Add 5 min", color = RemCream) }
                }
            }
        }

        if (state.phase == FocusPhase.Complete) {
            Dialog(
                onDismissRequest = onDismissComplete,
                properties = DialogProperties(dismissOnBackPress = true, dismissOnClickOutside = false),
            ) {
                Column(
                    modifier = ComposeModifier
                        .clip(RoundedCornerShape(18.dp))
                        .background(Color(0xFF171512))
                        .padding(22.dp),
                ) {
                    Text("Session complete", color = RemCream, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(modifier = ComposeModifier.height(8.dp))
                    Text("Great work. What next?", color = RemMuted, fontSize = 14.sp)
                    Spacer(modifier = ComposeModifier.height(18.dp))
                    Button(
                        onClick = onMarkComplete,
                        modifier = ComposeModifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = FocusGreen, contentColor = Color.Black),
                    ) { Text("Mark task complete") }
                    Spacer(modifier = ComposeModifier.height(8.dp))
                    OutlinedButton(onClick = { onExtend(5) }, modifier = ComposeModifier.fillMaxWidth()) {
                        Text("Add 5 minutes", color = RemCream)
                    }
                    TextButton(onClick = onDismissComplete, modifier = ComposeModifier.fillMaxWidth()) {
                        Text("Done", color = RemMuted)
                    }
                }
            }
        }
    }
}

@Composable
fun FocusMiniBar(
    state: FocusState,
    onExpand: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onStop: () -> Unit,
) {
    val ringColor = when (state.phase) {
        FocusPhase.Warming, FocusPhase.Paused -> FocusOrange
        else -> FocusGreen
    }
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(Color(0xFF1A1814))
            .clickable(onClick = onExpand)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MiniFocusRing(progress = state.progress, color = ringColor)
        Spacer(modifier = ComposeModifier.width(12.dp))
        Column(modifier = ComposeModifier.weight(1f)) {
            Text(state.modeLabel, color = RemMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            Text(
                state.taskTitle,
                color = RemCream,
                fontSize = 14.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text("${state.clockLabel} left", color = RemMuted, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
        }
        IconButton(
            onClick = { if (state.phase == FocusPhase.Paused) onResume() else onPause() },
            modifier = ComposeModifier
                .size(40.dp)
                .clip(CircleShape)
                .background(FocusGreen),
        ) {
            Icon(
                if (state.phase == FocusPhase.Paused) Icons.Default.PlayArrow else Icons.Default.Pause,
                contentDescription = if (state.phase == FocusPhase.Paused) "Resume" else "Pause",
                tint = Color.Black,
            )
        }
        Spacer(modifier = ComposeModifier.width(6.dp))
        IconButton(
            onClick = onStop,
            modifier = ComposeModifier
                .size(40.dp)
                .clip(CircleShape)
                .background(Color(0xFF3A1F1F)),
        ) {
            Icon(Icons.Default.Close, contentDescription = "End", tint = Color(0xFFFF8A80))
        }
    }
}

@Composable
private fun FocusRing(progress: Float, color: Color, label: String) {
    Box(contentAlignment = Alignment.Center, modifier = ComposeModifier.size(280.dp)) {
        Canvas(modifier = ComposeModifier.fillMaxSize()) {
            val stroke = 24.dp.toPx()
            val inset = stroke / 2
            drawArc(
                color = Color(0xFF2A2620),
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(size.width - stroke, size.height - stroke),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            drawArc(
                color = color,
                startAngle = -90f,
                sweepAngle = 360f * progress,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(size.width - stroke, size.height - stroke),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Text(
            label,
            color = RemCream,
            fontSize = 48.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun MiniFocusRing(progress: Float, color: Color) {
    Canvas(modifier = ComposeModifier.size(44.dp)) {
        val stroke = 5.dp.toPx()
        val inset = stroke / 2
        drawArc(
            color = Color(0xFF2A2620),
            startAngle = -90f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = Size(size.width - stroke, size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
        drawArc(
            color = color,
            startAngle = -90f,
            sweepAngle = 360f * progress,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = Size(size.width - stroke, size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
    }
}
