package com.remapp.rem.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Today
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier as ComposeModifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.remapp.rem.R
import com.remapp.rem.data.AppEnvironment
import com.remapp.rem.data.ChatMessage
import com.remapp.rem.data.ChatSession
import com.remapp.rem.data.RemTask
import com.remapp.rem.data.TaskSuggestion
import com.remapp.rem.ui.settings.SettingsNav
import com.remapp.rem.ui.onboarding.MemoryCaptureScreen
import com.remapp.rem.ui.onboarding.PermissionsOnboardingScreen
import com.remapp.rem.voice.TalkPhase

@Composable
fun RemAppRoot(
    state: RemUiState,
    onGoogle: () -> Unit,
    onDevice: () -> Unit,
    onSignOut: () -> Unit,
    onDeleteAccount: () -> Unit,
    onTab: (MainTab) -> Unit,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendPrompt: (String) -> Unit,
    onNewTaskTitle: (String) -> Unit,
    onCreateTask: () -> Unit,
    onCompleteTask: (RemTask) -> Unit,
    onOpenTask: (RemTask) -> Unit,
    onOpenBriefItem: (String) -> Unit,
    onCloseTaskDetail: () -> Unit,
    onDetailTitle: (String) -> Unit,
    onDetailPriority: (String) -> Unit,
    onDetailStatus: (String) -> Unit,
    onSaveTaskDetail: () -> Unit,
    onDeleteTask: () -> Unit,
    onAcceptSuggestion: (com.remapp.rem.data.TaskSuggestion) -> Unit,
    onDismissSuggestion: (com.remapp.rem.data.TaskSuggestion) -> Unit,
    onRequestCalendarPermission: () -> Unit,
    onShiftAgendaDay: (Int) -> Unit,
    onJumpAgendaToday: () -> Unit,
    onOpenSession: (String) -> Unit,
    onNewChat: () -> Unit,
    onAbortChat: () -> Unit,
    onStartTalk: () -> Unit,
    onStopTalk: () -> Unit,
    onToggleTalkMute: () -> Unit,
    onNavigateSettings: (SettingsScreen) -> Unit,
    onRefreshSettingsSection: () -> Unit,
    onApproveDevice: () -> Unit,
    onConnectToolkit: (String) -> Unit,
    onDisconnectToolkit: (String) -> Unit,
    onToggleToolkit: (String, Boolean) -> Unit,
    onDiscordTokenChange: (String) -> Unit,
    onConnectChannel: (String) -> Unit,
    onDisconnectChannel: (String) -> Unit,
    onMemoryDraftChange: (String) -> Unit,
    onAddMemory: () -> Unit,
    onDeleteMemory: (String) -> Unit,
    onToggleSkill: (String, Boolean) -> Unit,
    onToggleModel: (String, Boolean) -> Unit,
    onApprovePending: (String) -> Unit,
    onRejectPending: (String) -> Unit,
    onOpenBilling: () -> Unit,
    onShareRem: () -> Unit,
    onSendFeedback: () -> Unit,
    onReportBug: () -> Unit,
    onOpenLegalUrl: (String) -> Unit,
    onRequestMicPermission: () -> Unit,
    onRequestNotificationsPermission: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onCompletePermissionsOnboarding: () -> Unit,
    onOnboardingNameChange: (String) -> Unit,
    onOnboardingPriorityChange: (String) -> Unit,
    onSaveMemoryCapture: () -> Unit,
    onSkipMemoryCapture: () -> Unit,
    onSwitchEnv: (AppEnvironment) -> Unit,
    onReconnect: () -> Unit,
    onClearError: () -> Unit,
    focus: FocusCallbacks,
) {
    RemTheme {
        Box(
            modifier = ComposeModifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        listOf(Color(0xFF171512), RemInk, Color(0xFF12161F)),
                    ),
                )
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding(),
        ) {
            if (!state.signedIn) {
                SignInScreen(
                    state = state,
                    onGoogle = onGoogle,
                    onDevice = onDevice,
                    onSwitchEnv = onSwitchEnv,
                    onClearError = onClearError,
                )
            } else when (state.onboardingStep) {
                OnboardingStep.Permissions -> PermissionsOnboardingScreen(
                    state = state,
                    onRequestCalendar = onRequestCalendarPermission,
                    onRequestMic = onRequestMicPermission,
                    onRequestNotifications = onRequestNotificationsPermission,
                    onOpenNotificationSettings = onOpenNotificationSettings,
                    onContinue = onCompletePermissionsOnboarding,
                )
                OnboardingStep.MemoryCapture -> MemoryCaptureScreen(
                    state = state,
                    onNameChange = onOnboardingNameChange,
                    onPriorityChange = onOnboardingPriorityChange,
                    onSave = onSaveMemoryCapture,
                    onSkip = onSkipMemoryCapture,
                )
                OnboardingStep.None -> MainShell(
                    state = state,
                    focus = focus,
                    onTab = onTab,
                    onDraftChange = onDraftChange,
                    onSend = onSend,
                    onSendPrompt = onSendPrompt,
                    onNewTaskTitle = onNewTaskTitle,
                    onCreateTask = onCreateTask,
                    onCompleteTask = onCompleteTask,
                    onOpenTask = onOpenTask,
                    onOpenBriefItem = onOpenBriefItem,
                    onCloseTaskDetail = onCloseTaskDetail,
                    onDetailTitle = onDetailTitle,
                    onDetailPriority = onDetailPriority,
                    onDetailStatus = onDetailStatus,
                    onSaveTaskDetail = onSaveTaskDetail,
                    onDeleteTask = onDeleteTask,
                    onAcceptSuggestion = onAcceptSuggestion,
                    onDismissSuggestion = onDismissSuggestion,
                    onRequestCalendarPermission = onRequestCalendarPermission,
                    onShiftAgendaDay = onShiftAgendaDay,
                    onJumpAgendaToday = onJumpAgendaToday,
                    onOpenSession = onOpenSession,
                    onNewChat = onNewChat,
                    onAbortChat = onAbortChat,
                    onStartTalk = onStartTalk,
                    onStopTalk = onStopTalk,
                    onToggleTalkMute = onToggleTalkMute,
                    onNavigateSettings = onNavigateSettings,
                    onRefreshSettingsSection = onRefreshSettingsSection,
                    onApproveDevice = onApproveDevice,
                    onConnectToolkit = onConnectToolkit,
                    onDisconnectToolkit = onDisconnectToolkit,
                    onToggleToolkit = onToggleToolkit,
                    onDiscordTokenChange = onDiscordTokenChange,
                    onConnectChannel = onConnectChannel,
                    onDisconnectChannel = onDisconnectChannel,
                    onMemoryDraftChange = onMemoryDraftChange,
                    onAddMemory = onAddMemory,
                    onDeleteMemory = onDeleteMemory,
                    onToggleSkill = onToggleSkill,
                    onToggleModel = onToggleModel,
                    onApprovePending = onApprovePending,
                    onRejectPending = onRejectPending,
                    onOpenBilling = onOpenBilling,
                    onSignOut = onSignOut,
                    onDeleteAccount = onDeleteAccount,
                    onSwitchEnv = onSwitchEnv,
                    onReconnect = onReconnect,
                    onClearError = onClearError,
                    onShareRem = onShareRem,
                    onSendFeedback = onSendFeedback,
                    onReportBug = onReportBug,
                    onOpenLegalUrl = onOpenLegalUrl,
                )
            }
        }
    }
}

@Composable
private fun SignInScreen(
    state: RemUiState,
    onGoogle: () -> Unit,
    onDevice: () -> Unit,
    onSwitchEnv: (AppEnvironment) -> Unit,
    onClearError: () -> Unit,
) {
    Column(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 36.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            painter = painterResource(R.drawable.rem_logo),
            contentDescription = "Rem",
            modifier = ComposeModifier.size(96.dp).clip(RoundedCornerShape(22.dp)),
        )
        Spacer(modifier = ComposeModifier.height(24.dp))
        Text("Rem", color = RemCream, fontSize = 48.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-1).sp)
        Spacer(modifier = ComposeModifier.height(10.dp))
        Text(
            "Your AI assistant on Android.\nSign in to use Agenda, chat, and your gateway.",
            color = RemMuted,
            fontSize = 15.sp,
            textAlign = TextAlign.Center,
            lineHeight = 22.sp,
        )
        Spacer(modifier = ComposeModifier.height(28.dp))
        EnvPicker(state.environment, onSwitchEnv)
        Spacer(modifier = ComposeModifier.height(20.dp))
        Button(
            onClick = onGoogle,
            enabled = !state.busy,
            modifier = ComposeModifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = RemBlue, contentColor = Color.White),
            shape = RoundedCornerShape(14.dp),
        ) { Text("Continue with Google", modifier = ComposeModifier.padding(vertical = 6.dp)) }
        Spacer(modifier = ComposeModifier.height(12.dp))
        OutlinedButton(
            onClick = onDevice,
            enabled = !state.busy,
            modifier = ComposeModifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = RemCream),
        ) { Text("Continue with this device", modifier = ComposeModifier.padding(vertical = 6.dp)) }
        Spacer(modifier = ComposeModifier.height(20.dp))
        if (state.busy) {
            CircularProgressIndicator(color = RemBlue, modifier = ComposeModifier.size(28.dp))
            Spacer(modifier = ComposeModifier.height(10.dp))
        }
        if (state.status.isNotBlank()) {
            Text(state.status, color = RemMuted, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
        if (!state.error.isNullOrBlank()) {
            Spacer(modifier = ComposeModifier.height(10.dp))
            Text(state.error, color = Color(0xFFFF8A80), fontSize = 13.sp, textAlign = TextAlign.Center)
            TextButton(onClick = onClearError) { Text("Dismiss", color = RemMuted) }
        }
    }
}

@Composable
private fun EnvPicker(current: AppEnvironment, onSwitchEnv: (AppEnvironment) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AppEnvironment.entries.forEach { env ->
            val selected = env == current
            Button(
                onClick = { onSwitchEnv(env) },
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (selected) RemBlue else Color(0xFF242018),
                    contentColor = if (selected) Color.White else RemCream,
                ),
                shape = RoundedCornerShape(20.dp),
            ) { Text(env.label, fontSize = 13.sp) }
        }
    }
}

@Composable
private fun MainShell(
    state: RemUiState,
    focus: FocusCallbacks,
    onTab: (MainTab) -> Unit,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendPrompt: (String) -> Unit,
    onNewTaskTitle: (String) -> Unit,
    onCreateTask: () -> Unit,
    onCompleteTask: (RemTask) -> Unit,
    onOpenTask: (RemTask) -> Unit,
    onOpenBriefItem: (String) -> Unit,
    onCloseTaskDetail: () -> Unit,
    onDetailTitle: (String) -> Unit,
    onDetailPriority: (String) -> Unit,
    onDetailStatus: (String) -> Unit,
    onSaveTaskDetail: () -> Unit,
    onDeleteTask: () -> Unit,
    onAcceptSuggestion: (com.remapp.rem.data.TaskSuggestion) -> Unit,
    onDismissSuggestion: (com.remapp.rem.data.TaskSuggestion) -> Unit,
    onRequestCalendarPermission: () -> Unit,
    onShiftAgendaDay: (Int) -> Unit,
    onJumpAgendaToday: () -> Unit,
    onOpenSession: (String) -> Unit,
    onNewChat: () -> Unit,
    onAbortChat: () -> Unit,
    onStartTalk: () -> Unit,
    onStopTalk: () -> Unit,
    onToggleTalkMute: () -> Unit,
    onNavigateSettings: (SettingsScreen) -> Unit,
    onRefreshSettingsSection: () -> Unit,
    onApproveDevice: () -> Unit,
    onConnectToolkit: (String) -> Unit,
    onDisconnectToolkit: (String) -> Unit,
    onToggleToolkit: (String, Boolean) -> Unit,
    onDiscordTokenChange: (String) -> Unit,
    onConnectChannel: (String) -> Unit,
    onDisconnectChannel: (String) -> Unit,
    onMemoryDraftChange: (String) -> Unit,
    onAddMemory: () -> Unit,
    onDeleteMemory: (String) -> Unit,
    onToggleSkill: (String, Boolean) -> Unit,
    onToggleModel: (String, Boolean) -> Unit,
    onApprovePending: (String) -> Unit,
    onRejectPending: (String) -> Unit,
    onOpenBilling: () -> Unit,
    onSignOut: () -> Unit,
    onDeleteAccount: () -> Unit,
    onSwitchEnv: (AppEnvironment) -> Unit,
    onReconnect: () -> Unit,
    onClearError: () -> Unit,
    onShareRem: () -> Unit,
    onSendFeedback: () -> Unit,
    onReportBug: () -> Unit,
    onOpenLegalUrl: (String) -> Unit,
) {
    Box(modifier = ComposeModifier.fillMaxSize()) {
    Column(modifier = ComposeModifier.fillMaxSize()) {
        Row(
            modifier = ComposeModifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Image(
                painter = painterResource(R.drawable.rem_logo),
                contentDescription = null,
                modifier = ComposeModifier.size(34.dp).clip(RoundedCornerShape(9.dp)),
            )
            Column(modifier = ComposeModifier.padding(start = 12.dp).weight(1f)) {
                Text("Rem", color = RemCream, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(
                    text = state.status.ifBlank {
                        if (state.gatewayReady) "Connected · ${state.environment.label}"
                        else state.environment.label
                    },
                    color = RemMuted,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (!state.error.isNullOrBlank()) {
            Text(
                state.error!!,
                color = Color(0xFFFF8A80),
                fontSize = 13.sp,
                modifier = ComposeModifier.padding(horizontal = 16.dp),
            )
            TextButton(onClick = onClearError, modifier = ComposeModifier.padding(horizontal = 8.dp)) {
                Text("Dismiss", color = RemMuted)
            }
        }
        Box(modifier = ComposeModifier.weight(1f).fillMaxWidth()) {
            when (state.tab) {
                MainTab.Agenda -> AgendaPane(
                    state = state,
                    onNewTaskTitle = onNewTaskTitle,
                    onCreateTask = onCreateTask,
                    onCompleteTask = onCompleteTask,
                    onOpenTask = onOpenTask,
                    onOpenBriefItem = onOpenBriefItem,
                    onAcceptSuggestion = onAcceptSuggestion,
                    onDismissSuggestion = onDismissSuggestion,
                    onRequestCalendarPermission = onRequestCalendarPermission,
                    onShiftAgendaDay = onShiftAgendaDay,
                    onJumpAgendaToday = onJumpAgendaToday,
                )
                MainTab.Inbox -> InboxPane(
                    state = state,
                    onNewTaskTitle = onNewTaskTitle,
                    onCreateTask = onCreateTask,
                    onCompleteTask = onCompleteTask,
                    onOpenTask = onOpenTask,
                )
                MainTab.Chats -> ChatPane(
                    state = state,
                    onDraftChange = onDraftChange,
                    onSend = onSend,
                    onSendPrompt = onSendPrompt,
                    onOpenSession = onOpenSession,
                    onNewChat = onNewChat,
                    onAbortChat = onAbortChat,
                    onStartTalk = onStartTalk,
                    onStopTalk = onStopTalk,
                    onToggleTalkMute = onToggleTalkMute,
                    onOpenBilling = onOpenBilling,
                )
                MainTab.Settings -> SettingsNav(
                    state = state,
                    onNavigate = onNavigateSettings,
                    onSignOut = onSignOut,
                    onDeleteAccount = onDeleteAccount,
                    onSwitchEnv = onSwitchEnv,
                    onReconnect = onReconnect,
                    onApproveDevice = onApproveDevice,
                    onRefreshSection = onRefreshSettingsSection,
                    onConnectToolkit = onConnectToolkit,
                    onDisconnectToolkit = onDisconnectToolkit,
                    onToggleToolkit = onToggleToolkit,
                    onDiscordTokenChange = onDiscordTokenChange,
                    onConnectChannel = onConnectChannel,
                    onDisconnectChannel = onDisconnectChannel,
                    onMemoryDraftChange = onMemoryDraftChange,
                    onAddMemory = onAddMemory,
                    onDeleteMemory = onDeleteMemory,
                    onToggleSkill = onToggleSkill,
                    onToggleModel = onToggleModel,
                    onApprovePending = onApprovePending,
                    onRejectPending = onRejectPending,
                    onShareRem = onShareRem,
                    onSendFeedback = onSendFeedback,
                    onReportBug = onReportBug,
                    onOpenLegalUrl = onOpenLegalUrl,
                )
            }
        }
        if (state.selectedTask != null) {
            TaskDetailSheet(
                state = state,
                onTitle = onDetailTitle,
                onPriority = onDetailPriority,
                onStatus = onDetailStatus,
                onSave = onSaveTaskDetail,
                onDelete = onDeleteTask,
                onClose = onCloseTaskDetail,
                onStartFocus = focus.onOpenSetup,
            )
        }
        if (state.focus.phase == FocusPhase.Setup) {
            FocusSetupSheet(
                state = state.focus,
                onPickDuration = focus.onPickDuration,
                onToggleWarmUp = focus.onToggleWarmUp,
                onStart = focus.onStart,
                onClose = focus.onCloseSetup,
            )
        }
        if (state.focus.isActive && state.focus.minimized) {
            FocusMiniBar(
                state = state.focus,
                onExpand = focus.onExpand,
                onPause = focus.onPause,
                onResume = focus.onResume,
                onStop = focus.onStop,
            )
        }
        NavigationBar(containerColor = Color(0xFF141210)) {
            NavigationBarItem(
                selected = state.tab == MainTab.Agenda,
                onClick = { onTab(MainTab.Agenda) },
                icon = { Icon(Icons.Default.Today, contentDescription = "Agenda") },
                label = { Text("Agenda") },
            )
            NavigationBarItem(
                selected = state.tab == MainTab.Inbox,
                onClick = { onTab(MainTab.Inbox) },
                icon = { Icon(Icons.Default.Inbox, contentDescription = "Inbox") },
                label = { Text("Inbox") },
            )
            NavigationBarItem(
                selected = state.tab == MainTab.Chats,
                onClick = { onTab(MainTab.Chats) },
                icon = { Icon(Icons.Default.Chat, contentDescription = "Chats") },
                label = { Text("Chats") },
            )
            NavigationBarItem(
                selected = state.tab == MainTab.Settings,
                onClick = { onTab(MainTab.Settings) },
                icon = { Icon(Icons.Default.Settings, contentDescription = "Settings") },
                label = { Text("Settings") },
            )
        }
    }
        if (state.focus.isActive && !state.focus.minimized) {
            FocusTimerScreen(
                state = state.focus,
                onMinimize = focus.onMinimize,
                onPause = focus.onPause,
                onResume = focus.onResume,
                onStop = focus.onStop,
                onSkipWarmUp = focus.onSkipWarmUp,
                onExtend = focus.onExtend,
                onMarkComplete = focus.onMarkComplete,
                onDismissComplete = focus.onDismissComplete,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatPane(
    state: RemUiState,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendPrompt: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    onNewChat: () -> Unit,
    onAbortChat: () -> Unit,
    onStartTalk: () -> Unit,
    onStopTalk: () -> Unit,
    onToggleTalkMute: () -> Unit,
    onOpenBilling: () -> Unit,
) {
    val listState = rememberLazyListState()
    var showSessions by remember { mutableStateOf(false) }
    LaunchedEffect(state.messages.size, state.messages.lastOrNull()?.text) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.lastIndex)
    }
    val currentTitle = state.sessions.firstOrNull { it.key == state.activeSessionKey }?.label
        ?.ifBlank { null }
        ?: "Chat"
    val starters = chatStarters(state.suggestions)
    Column(modifier = ComposeModifier.fillMaxSize()) {
        Row(
            modifier = ComposeModifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = ComposeModifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { showSessions = true }
                    .padding(horizontal = 4.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    currentTitle,
                    color = RemCream,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 18.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = ComposeModifier.weight(1f, fill = false),
                )
                Icon(
                    Icons.Default.KeyboardArrowDown,
                    contentDescription = "Past chats",
                    tint = RemMuted,
                )
            }
            TextButton(onClick = onNewChat) { Text("New", color = RemBlue) }
            if (state.streaming) {
                TextButton(onClick = onAbortChat) { Text("Stop", color = Color(0xFFFF8A80)) }
            }
        }
        if (state.talkEnabled) {
            TalkMiniBar(
                state = state,
                onToggleMute = onToggleTalkMute,
                onHangUp = onStopTalk,
            )
        }
        if (state.quotaBlocked) {
            TextButton(
                onClick = onOpenBilling,
                modifier = ComposeModifier.padding(horizontal = 8.dp),
            ) {
                Text(
                    "Usage limit reached. Open Billing.",
                    color = Color(0xFFFF8A80),
                    fontSize = 13.sp,
                )
            }
        } else {
            state.usage?.remainingDay?.let { day ->
                Text(
                    "$day left today",
                    color = RemMuted,
                    fontSize = 11.sp,
                    modifier = ComposeModifier.padding(horizontal = 16.dp, vertical = 2.dp),
                )
            }
        }
        LazyColumn(
            state = listState,
            modifier = ComposeModifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (state.messages.isEmpty()) {
                item {
                    Column(modifier = ComposeModifier.padding(top = 28.dp)) {
                        Text(
                            if (state.gatewayReady) "What can Rem help with?"
                            else "Getting your gateway ready…",
                            color = RemCream,
                            fontSize = 22.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(modifier = ComposeModifier.height(8.dp))
                        Text(
                            if (state.gatewayReady) "Ask anything, or tap a starter."
                            else "Chat will unlock once Rem is connected.",
                            color = RemMuted,
                            fontSize = 15.sp,
                        )
                        if (state.gatewayReady) {
                            Spacer(modifier = ComposeModifier.height(16.dp))
                            starters.forEach { starter ->
                                Column(
                                    modifier = ComposeModifier
                                        .fillMaxWidth()
                                        .padding(bottom = 8.dp)
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(Color(0xFF1B2744))
                                        .clickable(enabled = !state.busy && !state.quotaBlocked) {
                                            onSendPrompt(starter.text)
                                        }
                                        .padding(horizontal = 14.dp, vertical = 12.dp),
                                ) {
                                    Text(starter.text, color = RemCream, fontSize = 15.sp)
                                    starter.subtitle?.let {
                                        Spacer(modifier = ComposeModifier.height(4.dp))
                                        Text(it, color = RemMuted, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            items(state.messages, key = { it.id }) { MessageBubble(it) }
        }
        Row(
            modifier = ComposeModifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = state.draft,
                onValueChange = onDraftChange,
                modifier = ComposeModifier.weight(1f),
                minLines = 1,
                maxLines = 5,
                placeholder = {
                    Text(
                        when {
                            state.quotaBlocked -> "Quota exceeded"
                            state.talkEnabled && state.talkPartial.isNotBlank() -> state.talkPartial
                            state.talkEnabled -> "Listening…"
                            else -> "Ask anything"
                        },
                        color = RemMuted,
                    )
                },
                enabled = state.gatewayReady && !state.busy && !state.quotaBlocked && state.talkPhase != TalkPhase.Thinking,
                shape = RoundedCornerShape(22.dp),
                colors = fieldColors(),
            )
            IconButton(
                onClick = {
                    if (state.talkEnabled) onStopTalk() else onStartTalk()
                },
                enabled = state.gatewayReady,
            ) {
                Icon(
                    imageVector = if (state.talkEnabled) Icons.Default.CallEnd else Icons.Default.Mic,
                    contentDescription = if (state.talkEnabled) "End speak" else "Speak",
                    tint = if (state.talkEnabled) Color(0xFFFF8A80) else RemBlue,
                )
            }
            IconButton(
                onClick = onSend,
                enabled = state.gatewayReady && !state.busy && !state.quotaBlocked && state.draft.isNotBlank(),
            ) {
                if (state.busy || state.streaming) {
                    CircularProgressIndicator(modifier = ComposeModifier.size(22.dp), color = RemBlue, strokeWidth = 2.dp)
                } else {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", tint = RemBlue)
                }
            }
        }
    }
    if (showSessions) {
        ModalBottomSheet(
            onDismissRequest = { showSessions = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = Color(0xFF171512),
            contentColor = RemCream,
        ) {
            Column(modifier = ComposeModifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                Text("Chats", color = RemCream, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
                Spacer(modifier = ComposeModifier.height(12.dp))
                if (state.sessions.isEmpty()) {
                    Text("No past chats yet.", color = RemMuted, modifier = ComposeModifier.padding(bottom = 28.dp))
                } else {
                    state.sessions.take(30).forEach { session ->
                        SessionPickRow(
                            session = session,
                            selected = session.key == state.activeSessionKey,
                            onClick = {
                                onOpenSession(session.key)
                                showSessions = false
                            },
                        )
                    }
                    Spacer(modifier = ComposeModifier.height(28.dp))
                }
            }
        }
    }
}

private data class ChatStarter(val text: String, val subtitle: String? = null)

private fun chatStarters(suggestions: List<TaskSuggestion>): List<ChatStarter> {
    val fromSuggestions = suggestions
        .filter { it.actionKind.equals("createTask", ignoreCase = true) }
        .take(3)
        .map { ChatStarter(it.title, it.subtitle.ifBlank { null }) }
    if (fromSuggestions.isNotEmpty()) return fromSuggestions
    return listOf(
        ChatStarter("Help me plan the rest of my day."),
        ChatStarter("Turn this into tasks: follow up with Alex, schedule my dentist appointment, and prep for Friday."),
        ChatStarter("Remind me to send the investor update tomorrow morning."),
    )
}

@Composable
private fun SessionPickRow(
    session: ChatSession,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Color(0xFF1B2744) else Color(0xFF242018))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(
            session.label.ifBlank { "Chat" },
            color = if (selected) RemBlue else RemCream,
            fontSize = 15.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (!session.preview.isNullOrBlank()) {
            Text(
                session.preview,
                color = RemMuted,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun TalkMiniBar(
    state: RemUiState,
    onToggleMute: () -> Unit,
    onHangUp: () -> Unit,
) {
    val label = when (state.talkPhase) {
        TalkPhase.Listening -> if (state.talkMuted) "Muted" else "Listening"
        TalkPhase.Thinking -> "Thinking…"
        TalkPhase.Speaking -> "Speaking…"
        TalkPhase.Off -> "Speak"
    }
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color = RemCream,
            fontWeight = FontWeight.Medium,
            fontSize = 14.sp,
            modifier = ComposeModifier.weight(1f),
        )
        if (state.talkPartial.isNotBlank() && state.talkPhase == TalkPhase.Listening) {
            Text(
                state.talkPartial,
                color = RemMuted,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = ComposeModifier.weight(1.4f).padding(end = 8.dp),
            )
        }
        IconButton(onClick = onToggleMute) {
            Icon(
                imageVector = if (state.talkMuted) Icons.Default.MicOff else Icons.Default.Mic,
                contentDescription = if (state.talkMuted) "Unmute" else "Mute",
                tint = RemCream,
            )
        }
        IconButton(onClick = onHangUp) {
            Icon(Icons.Default.CallEnd, contentDescription = "End speak", tint = Color(0xFFFF8A80))
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    val mine = message.role == ChatMessage.Role.User
    Row(
        modifier = ComposeModifier.fillMaxWidth(),
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
    ) {
        Box(
            modifier = ComposeModifier
                .widthIn(max = 340.dp)
                .clip(
                    RoundedCornerShape(
                        topStart = 18.dp,
                        topEnd = 18.dp,
                        bottomStart = if (mine) 18.dp else 4.dp,
                        bottomEnd = if (mine) 4.dp else 18.dp,
                    ),
                )
                .background(if (mine) RemBlue else Color(0xFF242018))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Text(
                text = message.text + if (message.isStreaming) " …" else "",
                color = if (mine) Color.White else RemCream,
                style = MaterialTheme.typography.bodyMedium,
            )
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
