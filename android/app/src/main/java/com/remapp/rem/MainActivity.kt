package com.remapp.rem

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.remapp.rem.ui.FocusCallbacks
import com.remapp.rem.ui.RemAppRoot
import com.remapp.rem.ui.RemAppViewModel

class MainActivity : ComponentActivity() {
    private val viewModel: RemAppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            val calendarPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                viewModel.onCalendarPermissionResult(granted)
            }
            val micPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                viewModel.onMicPermissionResult(granted)
            }
            val speakMicLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                viewModel.onMicPermissionResult(granted)
                if (granted) viewModel.startTalkMode()
                else viewModel.clearError()
            }
            val notificationsLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                viewModel.onNotificationsPermissionResult(granted)
            }

            LaunchedEffect(state.signedIn) {
                if (state.signedIn) {
                    syncPermissions()
                    viewModel.refreshCalendar()
                }
            }

            RemAppRoot(
                state = state,
                onGoogle = { viewModel.signInWithGoogle(this) },
                onDevice = { viewModel.signInWithDevice() },
                onSignOut = { viewModel.signOut() },
                onDeleteAccount = { viewModel.deleteAccount() },
                onTab = viewModel::selectTab,
                onDraftChange = viewModel::updateDraft,
                onSend = { viewModel.send() },
                onSendPrompt = viewModel::sendPrompt,
                onNewTaskTitle = viewModel::updateNewTaskTitle,
                onCreateTask = { viewModel.createTask() },
                onCompleteTask = viewModel::completeTask,
                onOpenTask = viewModel::openTask,
                onOpenBriefItem = viewModel::openBriefItem,
                onCloseTaskDetail = { viewModel.closeTaskDetail() },
                onDetailTitle = viewModel::updateDetailTitle,
                onDetailPriority = viewModel::updateDetailPriority,
                onDetailStatus = viewModel::updateDetailStatus,
                onSaveTaskDetail = { viewModel.saveTaskDetail() },
                onDeleteTask = { viewModel.deleteSelectedTask() },
                onAcceptSuggestion = viewModel::acceptSuggestion,
                onDismissSuggestion = viewModel::dismissSuggestion,
                onRequestCalendarPermission = {
                    calendarPermissionLauncher.launch(Manifest.permission.READ_CALENDAR)
                },
                onShiftAgendaDay = viewModel::shiftAgendaDay,
                onJumpAgendaToday = viewModel::jumpAgendaToday,
                onOpenSession = viewModel::openSession,
                onNewChat = { viewModel.startNewChat() },
                onAbortChat = { viewModel.abortChat() },
                onStartTalk = {
                    if (hasPermission(Manifest.permission.RECORD_AUDIO)) {
                        viewModel.startTalkMode()
                    } else {
                        speakMicLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }
                },
                onStopTalk = { viewModel.stopTalkMode() },
                onToggleTalkMute = { viewModel.toggleTalkMute() },
                onNavigateSettings = viewModel::navigateSettings,
                onRefreshSettingsSection = { viewModel.refreshCurrentSettingsSection() },
                onApproveDevice = { viewModel.approveThisDevice() },
                onConnectToolkit = { slug ->
                    viewModel.connectToolkit(slug) { url ->
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    }
                },
                onDisconnectToolkit = viewModel::disconnectToolkit,
                onToggleToolkit = viewModel::toggleToolkit,
                onDiscordTokenChange = viewModel::updateDiscordTokenDraft,
                onConnectChannel = viewModel::connectChannel,
                onDisconnectChannel = viewModel::disconnectChannel,
                onMemoryDraftChange = viewModel::updateMemoryDraft,
                onAddMemory = { viewModel.addMemory() },
                onDeleteMemory = viewModel::deleteMemory,
                onToggleSkill = viewModel::toggleSkill,
                onToggleModel = viewModel::toggleModel,
                onApprovePending = viewModel::approvePendingDevice,
                onRejectPending = viewModel::rejectPendingDevice,
                onOpenBilling = { viewModel.openBilling() },
                onRequestMicPermission = {
                    micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                },
                onRequestNotificationsPermission = {
                    if (Build.VERSION.SDK_INT >= 33) {
                        notificationsLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        viewModel.onNotificationsPermissionResult(true)
                    }
                },
                onOpenNotificationSettings = { openAppNotificationSettings() },
                onCompletePermissionsOnboarding = {
                    syncPermissions()
                    viewModel.completePermissionsOnboarding()
                },
                onOnboardingNameChange = viewModel::updateOnboardingName,
                onOnboardingPriorityChange = viewModel::updateOnboardingPriority,
                onSaveMemoryCapture = { viewModel.saveMemoryCapture() },
                onSkipMemoryCapture = { viewModel.skipMemoryCapture() },
                onSwitchEnv = viewModel::switchEnvironment,
                onReconnect = { viewModel.reconnectGateway() },
                onClearError = { viewModel.clearError() },
                onShareRem = { shareRem() },
                onSendFeedback = { sendRemEmail(feedback = true) },
                onReportBug = { sendRemEmail(feedback = false) },
                onOpenLegalUrl = { url -> openWebUrl(url) },
                focus = FocusCallbacks(
                    onOpenSetup = viewModel::openFocusSetup,
                    onCloseSetup = viewModel::closeFocusSetup,
                    onPickDuration = viewModel::pickFocusDuration,
                    onToggleWarmUp = viewModel::toggleFocusWarmUp,
                    onStart = viewModel::startFocusSession,
                    onMinimize = viewModel::minimizeFocus,
                    onExpand = viewModel::expandFocus,
                    onPause = viewModel::pauseFocus,
                    onResume = viewModel::resumeFocus,
                    onStop = { viewModel.stopFocus() },
                    onSkipWarmUp = viewModel::skipWarmUp,
                    onExtend = viewModel::extendFocus,
                    onMarkComplete = viewModel::completeFocusTask,
                    onDismissComplete = viewModel::dismissFocusComplete,
                ),
            )
        }
    }

    private fun syncPermissions() {
        val calendar = hasPermission(Manifest.permission.READ_CALENDAR)
        val mic = hasPermission(Manifest.permission.RECORD_AUDIO)
        val notifications = if (Build.VERSION.SDK_INT >= 33) {
            hasPermission(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            true
        }
        viewModel.syncPermissionFlags(calendar, mic, notifications)
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun openAppNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }
        runCatching { startActivity(intent) }.onFailure {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                },
            )
        }
    }

    private fun shareRem() {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "Try Rem")
            putExtra(
                Intent.EXTRA_TEXT,
                "Check out Rem on the App Store.\nhttps://apps.apple.com/us/app/rem-ai-personal-assistant/id6759550315",
            )
        }
        startActivity(Intent.createChooser(send, "Share Rem"))
    }

    private fun sendRemEmail(feedback: Boolean) {
        val version = BuildConfig.VERSION_NAME
        val build = BuildConfig.VERSION_CODE.toString()
        val state = viewModel.state.value
        val subject = if (feedback) {
            "Rem Feedback v$version ($build)"
        } else {
            "Rem Bug Report v$version ($build)"
        }
        val body = if (feedback) {
            "Hi Rem team,\n\nI'd like to share feedback:\n"
        } else {
            """
            Hi Rem team,

            I'm reporting a bug.

            What happened:


            Steps to reproduce:


            Expected result:


            Actual result:

            App: Rem Android $version ($build)
            Backend: ${state.environment.label}
            Device: ${Build.MODEL} Android ${Build.VERSION.RELEASE}
            Gateway: ${if (state.gatewayReady) "connected" else "not connected"}
            """.trimIndent()
        }
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:")
            putExtra(Intent.EXTRA_EMAIL, arrayOf("admin@userem.site"))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
        }
        runCatching {
            startActivity(Intent.createChooser(intent, if (feedback) "Send Feedback" else "Report a Bug"))
        }
    }

    private fun openWebUrl(url: String) {
        runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        }
    }
}
