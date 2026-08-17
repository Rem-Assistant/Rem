package com.remapp.rem.ui.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier as ComposeModifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.remapp.rem.ui.RemBlue
import com.remapp.rem.ui.RemCream
import com.remapp.rem.ui.RemMuted
import com.remapp.rem.ui.RemUiState

@Composable
fun PermissionsOnboardingScreen(
    state: RemUiState,
    onRequestCalendar: () -> Unit,
    onRequestMic: () -> Unit,
    onRequestNotifications: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onContinue: () -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxSize()
            .padding(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Allow Rem a few things", color = RemCream, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "You can change these later in Settings. Deny anything you don’t need.",
            color = RemMuted,
            fontSize = 14.sp,
        )
        Spacer(modifier = ComposeModifier.height(8.dp))

        PermissionCard(
            title = "Calendar",
            body = "So Rem can show today’s events on Agenda.",
            actionLabel = if (state.calendarPermissionGranted) "Allowed" else "Allow calendar",
            enabled = !state.calendarPermissionGranted,
            onAction = onRequestCalendar,
        )
        PermissionCard(
            title = "Microphone",
            body = "So you can talk to Rem in Speak mode.",
            actionLabel = if (state.micPermissionGranted) "Allowed" else "Allow microphone",
            enabled = !state.micPermissionGranted,
            onAction = onRequestMic,
        )
        PermissionCard(
            title = "Notifications",
            body = "So Rem can nudge you about tasks. On some phones, also turn Rem on in system notification settings.",
            actionLabel = if (state.notificationsPermissionGranted) "Allowed" else "Allow notifications",
            enabled = !state.notificationsPermissionGranted,
            onAction = onRequestNotifications,
        )
        if (!state.notificationsPermissionGranted) {
            TextButton(onClick = onOpenNotificationSettings) {
                Text("Open notification settings", color = RemBlue)
            }
        }

        Spacer(modifier = ComposeModifier.weight(1f))
        Button(
            onClick = onContinue,
            modifier = ComposeModifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = RemBlue, contentColor = Color.White),
        ) {
            Text("Continue")
        }
        TextButton(onClick = onContinue, modifier = ComposeModifier.fillMaxWidth()) {
            Text("Skip for now", color = RemMuted)
        }
    }
}

@Composable
fun MemoryCaptureScreen(
    state: RemUiState,
    onNameChange: (String) -> Unit,
    onPriorityChange: (String) -> Unit,
    onSave: () -> Unit,
    onSkip: () -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxSize()
            .padding(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Quick intro", color = RemCream, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "Optional. Rem can remember a couple of facts so chat feels personal.",
            color = RemMuted,
            fontSize = 14.sp,
        )
        Spacer(modifier = ComposeModifier.height(8.dp))
        OutlinedTextField(
            value = state.onboardingName,
            onValueChange = onNameChange,
            modifier = ComposeModifier.fillMaxWidth(),
            placeholder = { Text("What should Rem call you?", color = RemMuted) },
            singleLine = true,
            colors = fieldColors(),
        )
        OutlinedTextField(
            value = state.onboardingPriority,
            onValueChange = onPriorityChange,
            modifier = ComposeModifier.fillMaxWidth(),
            placeholder = { Text("What’s your top priority right now?", color = RemMuted) },
            colors = fieldColors(),
        )
        Spacer(modifier = ComposeModifier.weight(1f))
        Button(
            onClick = onSave,
            modifier = ComposeModifier.fillMaxWidth(),
            enabled = state.onboardingName.isNotBlank() || state.onboardingPriority.isNotBlank(),
            colors = ButtonDefaults.buttonColors(containerColor = RemBlue, contentColor = Color.White),
        ) {
            Text("Save & continue")
        }
        TextButton(onClick = onSkip, modifier = ComposeModifier.fillMaxWidth()) {
            Text("Skip", color = RemMuted)
        }
    }
}

@Composable
private fun PermissionCard(
    title: String,
    body: String,
    actionLabel: String,
    enabled: Boolean,
    onAction: () -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Text(title, color = RemCream, fontWeight = FontWeight.SemiBold)
        Text(body, color = RemMuted, fontSize = 13.sp, modifier = ComposeModifier.padding(top = 4.dp, bottom = 10.dp))
        OutlinedButton(onClick = onAction, enabled = enabled) {
            Text(actionLabel, color = if (enabled) RemBlue else RemMuted)
        }
    }
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = RemBlue,
    unfocusedBorderColor = RemMuted.copy(alpha = 0.35f),
    focusedTextColor = RemCream,
    unfocusedTextColor = RemCream,
    cursorColor = RemBlue,
)
