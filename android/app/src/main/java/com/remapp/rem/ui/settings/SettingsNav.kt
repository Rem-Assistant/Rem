package com.remapp.rem.ui.settings

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier as ComposeModifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.remapp.rem.BuildConfig
import com.remapp.rem.R
import com.remapp.rem.data.AppEnvironment
import com.remapp.rem.data.ComposioToolkit
import com.remapp.rem.data.ModelChoice
import com.remapp.rem.data.PendingDevice
import com.remapp.rem.data.RemChannel
import com.remapp.rem.data.SkillEntry
import com.remapp.rem.data.UserMemory
import com.remapp.rem.ui.RemBlue
import com.remapp.rem.ui.RemCream
import com.remapp.rem.ui.RemMuted
import com.remapp.rem.ui.RemUiState
import com.remapp.rem.ui.SettingsScreen

@Composable
fun SettingsNav(
    state: RemUiState,
    onNavigate: (SettingsScreen) -> Unit,
    onSignOut: () -> Unit,
    onDeleteAccount: () -> Unit,
    onSwitchEnv: (AppEnvironment) -> Unit,
    onReconnect: () -> Unit,
    onApproveDevice: () -> Unit,
    onRefreshSection: () -> Unit,
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
    onShareRem: () -> Unit,
    onSendFeedback: () -> Unit,
    onReportBug: () -> Unit,
    onOpenLegalUrl: (String) -> Unit,
) {
    when (state.settingsScreen) {
        SettingsScreen.Home -> SettingsHome(
            state = state,
            onNavigate = onNavigate,
            onSignOut = onSignOut,
            onDeleteAccount = onDeleteAccount,
            onSwitchEnv = onSwitchEnv,
            onReconnect = onReconnect,
            onShareRem = onShareRem,
            onSendFeedback = onSendFeedback,
            onReportBug = onReportBug,
        )
        SettingsScreen.Agent -> AgentPane(onNavigate = onNavigate)
        SettingsScreen.Connectors -> ConnectorsPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Home) },
            onRefresh = onRefreshSection,
            onConnect = onConnectToolkit,
            onDisconnect = onDisconnectToolkit,
            onToggle = onToggleToolkit,
        )
        SettingsScreen.Channels -> ChannelsPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Agent) },
            onRefresh = onRefreshSection,
            onTokenChange = onDiscordTokenChange,
            onConnect = onConnectChannel,
            onDisconnect = onDisconnectChannel,
        )
        SettingsScreen.Memory -> MemoryPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Agent) },
            onDraftChange = onMemoryDraftChange,
            onAdd = onAddMemory,
            onDelete = onDeleteMemory,
        )
        SettingsScreen.Models -> ModelsPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Agent) },
            onRefresh = onRefreshSection,
            onToggle = onToggleModel,
        )
        SettingsScreen.Capabilities -> CapabilitiesPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Home) },
            onRefresh = onRefreshSection,
            onToggle = onToggleSkill,
        )
        SettingsScreen.Connections -> ConnectionsPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Agent) },
            onRefresh = onRefreshSection,
            onReconnect = onReconnect,
            onApproveDevice = onApproveDevice,
            onApprovePending = onApprovePending,
            onRejectPending = onRejectPending,
        )
        SettingsScreen.Billing -> BillingPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Home) },
            onRefresh = onRefreshSection,
        )
        SettingsScreen.Permissions -> DevicePermissionsPane(
            state = state,
            onBack = { onNavigate(SettingsScreen.Home) },
        )
        SettingsScreen.About -> AboutPane(
            onBack = { onNavigate(SettingsScreen.Home) },
            onOpenLegalUrl = onOpenLegalUrl,
        )
    }
}

@Composable
private fun SettingsHome(
    state: RemUiState,
    onNavigate: (SettingsScreen) -> Unit,
    onSignOut: () -> Unit,
    onDeleteAccount: () -> Unit,
    onSwitchEnv: (AppEnvironment) -> Unit,
    onReconnect: () -> Unit,
    onShareRem: () -> Unit,
    onSendFeedback: () -> Unit,
    onReportBug: () -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
    ) {
        item {
            Text("Settings", color = RemCream, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text(state.userLabel.ifBlank { "Signed in" }, color = RemMuted, fontSize = 14.sp)
            Spacer(modifier = ComposeModifier.height(20.dp))

            NavRow("Agent settings", "Connections, channels, memory, models") {
                onNavigate(SettingsScreen.Agent)
            }
            NavRow("Connectors", "Gmail, Calendar, Slack, and more") {
                onNavigate(SettingsScreen.Connectors)
            }
            NavRow("Capabilities", "Enable or disable skills") {
                onNavigate(SettingsScreen.Capabilities)
            }
            NavRow("Device permissions", "Calendar, mic, notifications") {
                onNavigate(SettingsScreen.Permissions)
            }

            Spacer(modifier = ComposeModifier.height(20.dp))
            Text("Backend", color = RemCream, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(AppEnvironment.Staging, AppEnvironment.Production).forEach { env ->
                    val selected = state.environment == env
                    OutlinedButton(
                        onClick = { onSwitchEnv(env) },
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = if (selected) Color.White else RemCream,
                            containerColor = if (selected) RemBlue else Color.Transparent,
                        ),
                    ) { Text(env.label) }
                }
            }
            Text(
                "Switching environments signs you out so tokens never cross.",
                color = RemMuted,
                fontSize = 12.sp,
                modifier = ComposeModifier.padding(top = 8.dp),
            )

            Spacer(modifier = ComposeModifier.height(20.dp))
            Text("Gateway", color = RemCream, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text(
                if (state.gatewayReady) "Connected" else "Not connected",
                color = RemMuted,
                fontSize = 14.sp,
            )
            TextButton(onClick = onReconnect) { Text("Reconnect gateway", color = RemBlue) }

            Spacer(modifier = ComposeModifier.height(12.dp))
            val usageTeaser = state.usage
            val billingSubtitle = when {
                usageTeaser == null -> "Plan, limits, remaining"
                usageTeaser.isPro -> "Pro · ${usageTeaser.remainingDay ?: "—"} left today"
                else -> "${usageTeaser.planLabel} · ${usageTeaser.remainingDay ?: "—"} left today"
            }
            NavRow("Billing & usage", billingSubtitle) {
                onNavigate(SettingsScreen.Billing)
            }
            NavRow("About", "Version, terms, privacy") {
                onNavigate(SettingsScreen.About)
            }

            Spacer(modifier = ComposeModifier.height(20.dp))
            Text("Feedback", color = RemCream, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = ComposeModifier.height(8.dp))
            NavRow("Share Rem", "Send a friend the Rem link") {
                onShareRem()
            }
            NavRow("Send Feedback", "Email the Rem team") {
                onSendFeedback()
            }
            NavRow("Report a Bug", "Include device details automatically") {
                onReportBug()
            }

            Spacer(modifier = ComposeModifier.height(24.dp))
            OutlinedButton(onClick = onSignOut, modifier = ComposeModifier.fillMaxWidth()) {
                Text("Sign out", color = RemCream)
            }
            Spacer(modifier = ComposeModifier.height(8.dp))
            TextButton(onClick = onDeleteAccount, modifier = ComposeModifier.fillMaxWidth()) {
                Text("Delete account", color = Color(0xFFFF8A80))
            }
            Spacer(modifier = ComposeModifier.height(16.dp))
            Text(
                "Rem Android ${state.environment.label} · ${BuildConfig.VERSION_NAME}",
                color = RemMuted,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun AgentPane(onNavigate: (SettingsScreen) -> Unit) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
    ) {
        item {
            BackHeader("Agent settings") { onNavigate(SettingsScreen.Home) }
            Spacer(modifier = ComposeModifier.height(12.dp))
            Text("Connectivity", color = RemMuted, fontSize = 13.sp)
            Spacer(modifier = ComposeModifier.height(6.dp))
            NavRow("Connections", "Approve devices & pairing") {
                onNavigate(SettingsScreen.Connections)
            }
            NavRow("Channels", "Discord, WhatsApp") {
                onNavigate(SettingsScreen.Channels)
            }
            Spacer(modifier = ComposeModifier.height(16.dp))
            Text("Memory & keys", color = RemMuted, fontSize = 13.sp)
            Spacer(modifier = ComposeModifier.height(6.dp))
            NavRow("Memory", "Facts Rem remembers about you") {
                onNavigate(SettingsScreen.Memory)
            }
            NavRow("Models", "Which models Rem can use") {
                onNavigate(SettingsScreen.Models)
            }
        }
    }
}

@Composable
private fun ConnectorsPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onConnect: (String) -> Unit,
    onDisconnect: (String) -> Unit,
    onToggle: (String, Boolean) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Connectors") { onBack() }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (state.composioConfigured) "Connect accounts Rem can act in."
                    else "Connectors aren’t configured on this backend yet.",
                    color = RemMuted,
                    fontSize = 13.sp,
                    modifier = ComposeModifier.weight(1f),
                )
                TextButton(onClick = onRefresh) { Text("Refresh", color = RemBlue) }
            }
            if (state.settingsBusy) {
                CircularProgressIndicator(
                    modifier = ComposeModifier.size(22.dp),
                    color = RemBlue,
                    strokeWidth = 2.dp,
                )
            }
        }
        items(state.toolkits, key = { it.slug }) { toolkit ->
            ToolkitRow(toolkit, onConnect, onDisconnect, onToggle)
        }
    }
}

@Composable
private fun ToolkitRow(
    toolkit: ComposioToolkit,
    onConnect: (String) -> Unit,
    onDisconnect: (String) -> Unit,
    onToggle: (String, Boolean) -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Text(toolkit.slug.replaceFirstChar { it.uppercase() }, color = RemCream, fontWeight = FontWeight.Medium)
        Text(toolkit.status.replace('_', ' '), color = RemMuted, fontSize = 12.sp)
        Spacer(modifier = ComposeModifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (toolkit.isConnected) {
                Switch(
                    checked = toolkit.enabled,
                    onCheckedChange = { onToggle(toolkit.slug, it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = RemBlue),
                )
                Text("Available", color = RemMuted, fontSize = 12.sp, modifier = ComposeModifier.padding(start = 8.dp))
                Spacer(modifier = ComposeModifier.weight(1f))
                TextButton(onClick = { onDisconnect(toolkit.slug) }) {
                    Text("Disconnect", color = Color(0xFFFF8A80))
                }
            } else {
                TextButton(onClick = { onConnect(toolkit.slug) }) {
                    Text("Connect", color = RemBlue)
                }
            }
        }
    }
}

@Composable
private fun ChannelsPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onTokenChange: (String) -> Unit,
    onConnect: (String) -> Unit,
    onDisconnect: (String) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Channels") { onBack() }
            Row {
                Text(
                    "Reach Rem from Discord or WhatsApp.",
                    color = RemMuted,
                    fontSize = 13.sp,
                    modifier = ComposeModifier.weight(1f),
                )
                TextButton(onClick = onRefresh) { Text("Refresh", color = RemBlue) }
            }
        }
        items(state.channels, key = { it.provider }) { channel ->
            ChannelRow(channel, state.discordTokenDraft, onTokenChange, onConnect, onDisconnect)
        }
    }
}

@Composable
private fun ChannelRow(
    channel: RemChannel,
    discordToken: String,
    onTokenChange: (String) -> Unit,
    onConnect: (String) -> Unit,
    onDisconnect: (String) -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Text(channel.name, color = RemCream, fontWeight = FontWeight.Medium)
        Text(
            when {
                !channel.wired -> "Coming soon"
                channel.isConnected -> "Connected"
                channel.isConnecting -> "Connecting…"
                else -> channel.hint.ifBlank { channel.status }
            },
            color = RemMuted,
            fontSize = 12.sp,
        )
        if (channel.wired) {
            Spacer(modifier = ComposeModifier.height(8.dp))
            if (channel.isConnected || channel.isConnecting) {
                TextButton(onClick = { onDisconnect(channel.provider) }) {
                    Text("Disconnect", color = Color(0xFFFF8A80))
                }
            } else if (channel.connect == "bot_token") {
                OutlinedTextField(
                    value = discordToken,
                    onValueChange = onTokenChange,
                    modifier = ComposeModifier.fillMaxWidth(),
                    placeholder = { Text("Bot token", color = RemMuted) },
                    singleLine = true,
                    colors = fieldColors(),
                )
                TextButton(onClick = { onConnect(channel.provider) }) {
                    Text("Connect", color = RemBlue)
                }
            } else {
                Text(
                    "Tap Connect, then finish pairing in chat if Rem asks for a QR scan.",
                    color = RemMuted,
                    fontSize = 12.sp,
                )
                TextButton(onClick = { onConnect(channel.provider) }) {
                    Text("Connect", color = RemBlue)
                }
            }
        }
    }
}

@Composable
private fun MemoryPane(
    state: RemUiState,
    onBack: () -> Unit,
    onDraftChange: (String) -> Unit,
    onAdd: () -> Unit,
    onDelete: (String) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Memory") { onBack() }
            Text("Facts Rem remembers about you.", color = RemMuted, fontSize = 13.sp)
            Spacer(modifier = ComposeModifier.height(8.dp))
            OutlinedTextField(
                value = state.memoryDraft,
                onValueChange = onDraftChange,
                modifier = ComposeModifier.fillMaxWidth(),
                placeholder = { Text("Add a fact…", color = RemMuted) },
                colors = fieldColors(),
            )
            TextButton(onClick = onAdd, enabled = state.memoryDraft.isNotBlank()) {
                Text("Add", color = RemBlue)
            }
        }
        items(state.memories, key = { it.id }) { memory ->
            MemoryRow(memory, onDelete)
        }
    }
}

@Composable
private fun MemoryRow(memory: UserMemory, onDelete: (String) -> Unit) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            memory.fact,
            color = RemCream,
            fontSize = 14.sp,
            modifier = ComposeModifier.weight(1f),
        )
        TextButton(onClick = { onDelete(memory.id) }) {
            Text("Delete", color = Color(0xFFFF8A80))
        }
    }
}

@Composable
private fun ModelsPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onToggle: (String, Boolean) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Models") { onBack() }
            Row {
                Text(
                    "Turn models on or off for this phone. Saved locally.",
                    color = RemMuted,
                    fontSize = 13.sp,
                    modifier = ComposeModifier.weight(1f),
                )
                TextButton(onClick = onRefresh) { Text("Refresh", color = RemBlue) }
            }
        }
        items(state.models, key = { it.id }) { model ->
            ModelRow(model, enabled = model.id !in state.disabledModelIds, onToggle = onToggle)
        }
    }
}

@Composable
private fun ModelRow(model: ModelChoice, enabled: Boolean, onToggle: (String, Boolean) -> Unit) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = ComposeModifier.weight(1f)) {
            Text(model.name, color = RemCream, fontWeight = FontWeight.Medium)
            Text(model.provider, color = RemMuted, fontSize = 12.sp)
        }
        Switch(
            checked = enabled,
            onCheckedChange = { onToggle(model.id, it) },
            colors = SwitchDefaults.colors(checkedTrackColor = RemBlue),
        )
    }
}

@Composable
private fun CapabilitiesPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onToggle: (String, Boolean) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Capabilities") { onBack() }
            Row {
                Text(
                    "Skills installed on your gateway.",
                    color = RemMuted,
                    fontSize = 13.sp,
                    modifier = ComposeModifier.weight(1f),
                )
                TextButton(onClick = onRefresh) { Text("Refresh", color = RemBlue) }
            }
            if (!state.gatewayReady) {
                Text("Connect the gateway to manage skills.", color = Color(0xFFFF8A80), fontSize = 13.sp)
            }
        }
        items(state.skills, key = { it.skillKey }) { skill ->
            SkillRow(skill, onToggle)
        }
    }
}

@Composable
private fun SkillRow(skill: SkillEntry, onToggle: (String, Boolean) -> Unit) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = ComposeModifier.weight(1f)) {
            Text(skill.label, color = RemCream, fontWeight = FontWeight.Medium)
            if (!skill.description.isNullOrBlank()) {
                Text(skill.description, color = RemMuted, fontSize = 12.sp, maxLines = 2)
            }
        }
        Switch(
            checked = skill.isEnabled,
            onCheckedChange = { onToggle(skill.skillKey, it) },
            enabled = skill.eligible,
            colors = SwitchDefaults.colors(checkedTrackColor = RemBlue),
        )
    }
}

@Composable
private fun ConnectionsPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
    onApproveDevice: () -> Unit,
    onApprovePending: (String) -> Unit,
    onRejectPending: (String) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Connections") { onBack() }
            Text(
                if (state.gatewayReady) "Gateway connected."
                else "Gateway not connected.",
                color = RemMuted,
                fontSize = 13.sp,
            )
            TextButton(onClick = onReconnect) { Text("Reconnect", color = RemBlue) }
            TextButton(onClick = onApproveDevice) {
                Text("Approve this device", color = RemBlue)
            }
            TextButton(onClick = onRefresh) { Text("Refresh pending", color = RemBlue) }
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text("Pending devices", color = RemCream, fontWeight = FontWeight.SemiBold)
            if (state.pendingDevices.isEmpty()) {
                Text("No devices waiting.", color = RemMuted, fontSize = 13.sp)
            }
        }
        items(state.pendingDevices, key = { it.requestId }) { device ->
            PendingRow(device, onApprovePending, onRejectPending)
        }
    }
}

@Composable
private fun PendingRow(
    device: PendingDevice,
    onApprove: (String) -> Unit,
    onReject: (String) -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Text(device.displayName, color = RemCream, fontWeight = FontWeight.Medium)
        if (!device.platform.isNullOrBlank()) {
            Text(device.platform, color = RemMuted, fontSize = 12.sp)
        }
        Row {
            TextButton(onClick = { onApprove(device.requestId) }) {
                Text("Approve", color = RemBlue)
            }
            TextButton(onClick = { onReject(device.requestId) }) {
                Text("Decline", color = Color(0xFFFF8A80))
            }
        }
    }
}


@Composable
private fun BillingPane(
    state: RemUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
) {
    val usage = state.usage
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            BackHeader("Billing & usage") { onBack() }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Your Rem account plan and request limits.",
                    color = RemMuted,
                    fontSize = 13.sp,
                    modifier = ComposeModifier.weight(1f),
                )
                TextButton(onClick = onRefresh) { Text("Refresh", color = RemBlue) }
            }
        }
        item {
            if (usage == null) {
                Text("Usage unavailable on this account yet.", color = RemMuted, fontSize = 14.sp)
            } else {
                PlanCard(usage)
                Spacer(modifier = ComposeModifier.height(4.dp))
                UsageBarCard(
                    title = "Today",
                    used = usage.usedDay,
                    limit = usage.requestsPerDay,
                    remaining = usage.remainingDay,
                    warn = (usage.remainingDay ?: 99) < 10,
                )
                UsageBarCard(
                    title = "This month",
                    used = usage.usedMonth,
                    limit = usage.requestsPerMonth,
                    remaining = usage.remainingMonth,
                    warn = (usage.remainingMonth ?: 999) < 50,
                )
                if (!usage.allowed) {
                    Text(
                        when (usage.reason) {
                            "daily_limit" -> "Daily request limit reached."
                            "monthly_limit" -> "Monthly request limit reached."
                            else -> "You’re out of Rem requests for now."
                        },
                        color = Color(0xFFFF8A80),
                        fontSize = 14.sp,
                        modifier = ComposeModifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(Color(0xFF3A1F1F))
                            .padding(14.dp),
                    )
                }
                if (!usage.modelTier.isNullOrBlank()) {
                    Text(
                        "Model tier: ${usage.modelTier}",
                        color = RemMuted,
                        fontSize = 12.sp,
                    )
                }
                if (!usage.quotaCycleStartedAt.isNullOrBlank()) {
                    Text(
                        "Quota cycle started ${usage.quotaCycleStartedAt.take(10)}",
                        color = RemMuted,
                        fontSize = 12.sp,
                    )
                }
            }
        }
        item {
            Text(
                "Purchases aren’t available on Android yet. Pro comes from your Rem account (for example, if you upgraded on iPhone).",
                color = RemMuted,
                fontSize = 12.sp,
                modifier = ComposeModifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun PlanCard(usage: com.remapp.rem.data.UsageSummary) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Current plan", color = RemMuted, fontSize = 12.sp, modifier = ComposeModifier.weight(1f))
            if (usage.isPro) {
                Text(
                    "Pro",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = ComposeModifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(RemBlue)
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }
        Text(
            usage.planLabel,
            color = if (usage.isPro) RemBlue else RemCream,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
        )
        val status = usage.status?.ifBlank { null }
        if (status != null && !status.equals("active", ignoreCase = true)) {
            Text(
                "Status: $status",
                color = Color(0xFFFFB74D),
                fontSize = 13.sp,
                modifier = ComposeModifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun UsageBarCard(
    title: String,
    used: Int?,
    limit: Int?,
    remaining: Int?,
    warn: Boolean,
) {
    val usedSafe = used ?: 0
    val limitSafe = (limit ?: 0).coerceAtLeast(0)
    val progress = if (limitSafe > 0) (usedSafe.toFloat() / limitSafe.toFloat()).coerceIn(0f, 1f) else 0f
    val accent = if (warn) Color(0xFFFFB74D) else RemBlue
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(14.dp),
    ) {
        Text(title, color = RemCream, fontWeight = FontWeight.Medium)
        Text(
            if (limitSafe > 0) "$usedSafe / $limitSafe used · ${remaining ?: "—"} left"
            else "${remaining ?: "—"} left",
            color = RemMuted,
            fontSize = 12.sp,
            modifier = ComposeModifier.padding(top = 2.dp, bottom = 8.dp),
        )
        if (limitSafe > 0) {
            LinearProgressIndicator(
                progress = { progress },
                modifier = ComposeModifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
                color = accent,
                trackColor = RemMuted.copy(alpha = 0.25f),
            )
        }
    }
}

@Composable
private fun DevicePermissionsPane(
    state: RemUiState,
    onBack: () -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            BackHeader("Device permissions") { onBack() }
            Text(
                "Rem asks for these on this phone. If Speak or Agenda feels broken on Redmi/MIUI, also check Apps → Rem → Notifications and Battery → No restrictions.",
                color = RemMuted,
                fontSize = 13.sp,
            )
            Spacer(modifier = ComposeModifier.height(8.dp))
        }
        item {
            StatusRow("Calendar", if (state.calendarPermissionGranted) "Allowed" else "Not allowed")
            StatusRow("Microphone", if (state.micPermissionGranted) "Allowed" else "Not allowed")
            StatusRow(
                "Notifications",
                if (state.notificationsPermissionGranted) "Allowed" else "Not allowed",
            )
        }
    }
}

@Composable
private fun StatusRow(title: String, status: String) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = RemCream, modifier = ComposeModifier.weight(1f))
        Text(status, color = RemMuted, fontSize = 13.sp)
    }
}

@Composable
private fun AboutPane(
    onBack: () -> Unit,
    onOpenLegalUrl: (String) -> Unit,
) {
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        item {
            BackHeader("About") { onBack() }
            Spacer(modifier = ComposeModifier.height(20.dp))
            Image(
                painter = painterResource(R.drawable.rem_logo),
                contentDescription = null,
                modifier = ComposeModifier.size(80.dp).clip(RoundedCornerShape(18.dp)),
            )
            Spacer(modifier = ComposeModifier.height(12.dp))
            Text("Rem", color = RemCream, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(
                "Turn your thoughts into actions",
                color = RemMuted,
                fontSize = 16.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = ComposeModifier.height(24.dp))
            NavRow("Terms of Service", "userem.site") {
                onOpenLegalUrl("https://userem.site/terms-of-service")
            }
            NavRow("Privacy Policy", "userem.site") {
                onOpenLegalUrl("https://userem.site/privacy-policy")
            }
            Spacer(modifier = ComposeModifier.height(16.dp))
            Text("Version", color = RemMuted, fontSize = 13.sp)
            Text(BuildConfig.VERSION_NAME, color = RemCream, fontSize = 16.sp)
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text("Build", color = RemMuted, fontSize = 13.sp)
            Text("${BuildConfig.VERSION_CODE}", color = RemCream, fontSize = 16.sp)
        }
    }
}

@Composable
private fun BackHeader(title: String, onBack: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = RemCream)
        }
        Text(title, color = RemCream, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun NavRow(title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1B2744))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = ComposeModifier.weight(1f)) {
            Text(title, color = RemCream, fontWeight = FontWeight.Medium)
            Text(subtitle, color = RemMuted, fontSize = 12.sp)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = RemMuted)
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
