package com.remapp.rem.ui

import android.app.Application
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.NoCredentialException
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.remapp.rem.BuildConfig
import com.remapp.rem.RemApplication
import com.remapp.rem.device.DeviceCalendarReader
import com.remapp.rem.data.AppEnvironment
import com.remapp.rem.data.ChatMessage
import com.remapp.rem.data.ChatSession
import com.remapp.rem.data.DailyBrief
import com.remapp.rem.data.DeviceCalendarEvent
import com.remapp.rem.data.QuotaExceededException
import com.remapp.rem.data.RemRepository
import com.remapp.rem.data.RemTask
import com.remapp.rem.data.TaskSuggestion
import com.remapp.rem.data.UsageSummary
import com.remapp.rem.data.ComposioToolkit
import com.remapp.rem.data.ModelChoice
import com.remapp.rem.data.ModelPreferencesStore
import com.remapp.rem.data.PendingDevice
import com.remapp.rem.data.RemChannel
import com.remapp.rem.data.SkillEntry
import com.remapp.rem.data.UserMemory
import com.remapp.rem.voice.RemTts
import com.remapp.rem.voice.TalkModeManager
import com.remapp.rem.voice.TalkPhase
import com.remapp.rem.voice.TalkPrompt
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.UUID

enum class MainTab { Agenda, Inbox, Chats, Settings }

enum class SettingsScreen {
    Home, Agent, Connectors, Channels, Memory, Models, Capabilities, Connections, Billing, Permissions, About
}

enum class OnboardingStep {
    None,
    Permissions,
    MemoryCapture,
}

data class RemUiState(
    val signedIn: Boolean = false,
    val userLabel: String = "",
    val environment: AppEnvironment = AppEnvironment.Staging,
    val tab: MainTab = MainTab.Agenda,
    val status: String = "",
    val busy: Boolean = false,
    val gatewayReady: Boolean = false,
    val tasks: List<RemTask> = emptyList(),
    val brief: DailyBrief? = null,
    val suggestions: List<TaskSuggestion> = emptyList(),
    val calendarEvents: List<DeviceCalendarEvent> = emptyList(),
    val agendaDayStartMillis: Long = 0L,
    val calendarPermissionGranted: Boolean = false,
    val micPermissionGranted: Boolean = false,
    val notificationsPermissionGranted: Boolean = false,
    val onboardingStep: OnboardingStep = OnboardingStep.None,
    val onboardingName: String = "",
    val onboardingPriority: String = "",
    val selectedTask: RemTask? = null,
    val detailTitle: String = "",
    val detailPriority: String = "medium",
    val detailStatus: String = "pending",
    val sessions: List<ChatSession> = emptyList(),
    val activeSessionKey: String = "android-main",
    val messages: List<ChatMessage> = emptyList(),
    val draft: String = "",
    val newTaskTitle: String = "",
    val usage: UsageSummary? = null,
    val quotaBlocked: Boolean = false,
    val streaming: Boolean = false,
    val talkEnabled: Boolean = false,
    val talkMuted: Boolean = false,
    val talkPhase: TalkPhase = TalkPhase.Off,
    val talkPartial: String = "",
    val settingsScreen: SettingsScreen = SettingsScreen.Home,
    val toolkits: List<ComposioToolkit> = emptyList(),
    val composioConfigured: Boolean = true,
    val channels: List<RemChannel> = emptyList(),
    val memories: List<UserMemory> = emptyList(),
    val skills: List<SkillEntry> = emptyList(),
    val models: List<ModelChoice> = emptyList(),
    val disabledModelIds: Set<String> = emptySet(),
    val pendingDevices: List<PendingDevice> = emptyList(),
    val memoryDraft: String = "",
    val discordTokenDraft: String = "",
    val settingsBusy: Boolean = false,
    val error: String? = null,
    val focus: FocusState = FocusState(),
)

class RemAppViewModel(app: Application) : AndroidViewModel(app) {
    private val repo: RemRepository = (app as RemApplication).repository
    private val remTts = RemTts(app.applicationContext)
    private val modelPrefs = ModelPreferencesStore(app.applicationContext)
    private val talk = TalkModeManager(app.applicationContext, viewModelScope, remTts)
    private var focusTicker: Job? = null

    private val _state = MutableStateFlow(
        RemUiState(
            signedIn = repo.store.isSignedIn,
            userLabel = repo.currentUser()?.fullName ?: repo.currentUser()?.email.orEmpty(),
            environment = repo.currentEnvironment(),
            agendaDayStartMillis = DeviceCalendarReader.startOfDayMillis(),
            onboardingStep = if (repo.store.isSignedIn) {
                when {
                    !repo.store.hasSeenPermissionsOnboarding -> OnboardingStep.Permissions
                    !repo.store.hasSeenMemoryCapture -> OnboardingStep.MemoryCapture
                    else -> OnboardingStep.None
                }
            } else {
                OnboardingStep.None
            },
        ),
    )
    val state: StateFlow<RemUiState> = _state.asStateFlow()

    init {
        repo.gateway.onChatDelta = handler@{ key, text, done, _runId ->
            val active = _state.value.activeSessionKey
            if (key.isNotBlank() && key != active && !key.contains(active) && !active.contains(key)) {
                return@handler
            }
            _state.update { current ->
                val msgs = current.messages.toMutableList()
                val last = msgs.lastOrNull()
                val merged = when {
                    text.isBlank() -> last?.text.orEmpty()
                    last?.role == ChatMessage.Role.Assistant && last.isStreaming -> {
                        if (text.startsWith(last.text) || last.text.isBlank()) text
                        else if (last.text.startsWith(text)) last.text
                        else last.text + text
                    }
                    else -> text
                }
                if (last?.role == ChatMessage.Role.Assistant && last.isStreaming) {
                    msgs[msgs.lastIndex] = last.copy(text = merged, isStreaming = !done)
                } else if (merged.isNotBlank() || done) {
                    msgs += ChatMessage(
                        id = UUID.randomUUID().toString(),
                        role = ChatMessage.Role.Assistant,
                        text = merged.ifBlank { if (done) "(no reply)" else "…" },
                        isStreaming = !done,
                    )
                }
                val nextStatus = when {
                    !done -> "Rem is thinking…"
                    current.talkEnabled -> "Speaking…"
                    else -> "Connected to Rem"
                }
                current.copy(
                    messages = msgs,
                    streaming = !done,
                    busy = if (done) false else true,
                    status = nextStatus,
                    talkPhase = if (done && current.talkEnabled) TalkPhase.Speaking else current.talkPhase,
                )
            }
            if (done) {
                refreshSessions()
                val reply = _state.value.messages.lastOrNull {
                    it.role == ChatMessage.Role.Assistant && !it.isStreaming
                }?.text.orEmpty()
                if (_state.value.talkEnabled && reply.isNotBlank()) {
                    talk.speakThenListen(reply)
                }
            }
        }
        talk.onPhase = { phase, partial ->
            _state.update {
                if (!it.talkEnabled && phase == TalkPhase.Off) {
                    it.copy(talkPhase = TalkPhase.Off, talkPartial = "")
                } else {
                    it.copy(
                        talkPhase = phase,
                        talkPartial = partial,
                        status = when (phase) {
                            TalkPhase.Listening -> if (it.talkMuted) "Muted" else "Listening…"
                            TalkPhase.Thinking -> "Thinking…"
                            TalkPhase.Speaking -> "Speaking…"
                            TalkPhase.Off -> it.status
                        },
                    )
                }
            }
        }
        talk.onFinalTranscript = { transcript ->
            sendInternal(transcript, fromVoice = true)
        }
        if (repo.store.isSignedIn) {
            bootstrap()
        }
    }

    override fun onCleared() {
        focusTicker?.cancel()
        talk.stop()
        remTts.release()
        super.onCleared()
    }

    fun startTalkMode() {
        if (!_state.value.gatewayReady) {
            _state.update { it.copy(error = "Gateway not ready yet") }
            return
        }
        remTts.apiKey = repo.elevenLabsApiKey()
        talk.start()
        _state.update {
            it.copy(
                talkEnabled = true,
                talkMuted = false,
                talkPhase = TalkPhase.Listening,
                talkPartial = "",
                tab = MainTab.Chats,
                status = "Listening…",
                error = null,
            )
        }
    }

    fun stopTalkMode() {
        talk.stop()
        _state.update {
            it.copy(
                talkEnabled = false,
                talkMuted = false,
                talkPhase = TalkPhase.Off,
                talkPartial = "",
                status = if (it.gatewayReady) "Connected to Rem" else it.status,
            )
        }
    }

    fun toggleTalkMute() {
        if (!_state.value.talkEnabled) return
        val next = !_state.value.talkMuted
        talk.setMuted(next)
        _state.update {
            it.copy(
                talkMuted = next,
                status = if (next) "Muted" else "Listening…",
            )
        }
    }

    fun selectTab(tab: MainTab) {
        _state.update { it.copy(tab = tab) }
        when (tab) {
            MainTab.Agenda -> {
                refreshTasks()
                refreshBriefAndSuggestions()
                refreshCalendar()
            }
            MainTab.Inbox -> refreshTasks()
            MainTab.Chats -> refreshSessions()
            MainTab.Settings -> {
                _state.update { it.copy(settingsScreen = SettingsScreen.Home) }
                refreshUsage()
            }
        }
    }

    fun updateDraft(value: String) = _state.update { it.copy(draft = value) }
    fun updateNewTaskTitle(value: String) = _state.update { it.copy(newTaskTitle = value) }
    fun clearError() = _state.update { it.copy(error = null) }

    fun signInWithGoogle(activityContext: android.content.Context) {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, status = "Signing in with Google…") }
            try {
                val manager = CredentialManager.create(activityContext)
                // Button flow: Sign in with Google picker (works better with multiple accounts).
                val result = try {
                    manager.getCredential(
                        activityContext,
                        GetCredentialRequest.Builder()
                            .addCredentialOption(
                                GetSignInWithGoogleOption.Builder(BuildConfig.GOOGLE_SERVER_CLIENT_ID)
                                    .build(),
                            )
                            .build(),
                    )
                } catch (_: NoCredentialException) {
                    // Fallback bottomsheet of all device Google accounts.
                    manager.getCredential(
                        activityContext,
                        GetCredentialRequest.Builder()
                            .addCredentialOption(
                                GetGoogleIdOption.Builder()
                                    .setFilterByAuthorizedAccounts(false)
                                    .setServerClientId(BuildConfig.GOOGLE_SERVER_CLIENT_ID)
                                    .setAutoSelectEnabled(false)
                                    .build(),
                            )
                            .build(),
                    )
                }
                val credential = result.credential
                if (credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                    val google = GoogleIdTokenCredential.createFrom(credential.data)
                    val auth = repo.signInWithGoogle(google.idToken, google.id, google.displayName)
                    _state.update {
                        it.copy(
                            signedIn = true,
                            userLabel = auth.user.fullName ?: auth.user.email.orEmpty(),
                            status = "Signed in",
                            onboardingStep = initialOnboardingStep(),
                        )
                    }
                    bootstrap()
                } else {
                    throw IllegalStateException("Unexpected Google credential type")
                }
            } catch (e: NoCredentialException) {
                _state.update {
                    it.copy(
                        busy = false,
                        status = "",
                        error = googleSetupErrorMessage(),
                    )
                }
            } catch (e: Exception) {
                val msg = e.message.orEmpty()
                val friendly = when {
                    msg.contains("reauth failed", ignoreCase = true) ||
                        msg.contains("[16]", ignoreCase = true) ||
                        msg.contains("No credentials", ignoreCase = true) ||
                        msg.contains("DEVELOPER_ERROR", ignoreCase = true) ->
                        googleSetupErrorMessage()
                    else -> msg.ifBlank { "Google sign-in failed" }
                }
                _state.update {
                    it.copy(busy = false, status = "", error = friendly)
                }
            }
        }
    }

    private fun googleSetupErrorMessage(): String =
        "Google blocked this debug build (not your Rem password). " +
            "The Cloud project needs an Android OAuth client for package " +
            "com.remapp.rem.debug and this machine’s debug SHA-1 " +
            "(./gradlew :app:signingReport). Until then, use Continue with this device."

    fun signInWithDevice() {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, status = "Creating device session…") }
            try {
                val auth = repo.signInWithDevice(getApplication())
                _state.update {
                    it.copy(
                        signedIn = true,
                        userLabel = auth.user.fullName ?: "Rem tester",
                        status = "Signed in",
                        onboardingStep = initialOnboardingStep(),
                    )
                }
                bootstrap()
            } catch (e: Exception) {
                _state.update {
                    it.copy(busy = false, status = "", error = e.message ?: "Device sign-in failed")
                }
            }
        }
    }

    fun signOut() {
        stopTalkMode()
        stopFocus(silent = true)
        repo.signOut()
        _state.value = RemUiState(environment = repo.currentEnvironment())
    }

    fun deleteAccount() {
        viewModelScope.launch {
            stopTalkMode()
            stopFocus(silent = true)
            _state.update { it.copy(busy = true, status = "Deleting account…") }
            try {
                repo.deleteAccount()
                _state.value = RemUiState(environment = repo.currentEnvironment())
            } catch (e: Exception) {
                _state.update {
                    it.copy(busy = false, error = e.message ?: "Could not delete account")
                }
            }
        }
    }

    fun switchEnvironment(env: AppEnvironment) {
        if (env == _state.value.environment) return
        stopTalkMode()
        stopFocus(silent = true)
        viewModelScope.launch {
            repo.switchEnvironment(env)
            _state.value = RemUiState(environment = env)
        }
    }

    fun openTask(task: RemTask) {
        _state.update {
            it.copy(
                selectedTask = task,
                detailTitle = task.title,
                detailPriority = task.priority ?: "medium",
                detailStatus = task.status ?: "pending",
            )
        }
    }

    fun openBriefItem(id: String) {
        val task = _state.value.tasks.firstOrNull { it.id == id }
        if (task != null) {
            openTask(task)
            return
        }
        viewModelScope.launch {
            try {
                openTask(repo.getTask(id))
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not open task") }
            }
        }
    }

    fun closeTaskDetail() {
        _state.update { it.copy(selectedTask = null) }
    }

    fun updateDetailTitle(value: String) = _state.update { it.copy(detailTitle = value) }
    fun updateDetailPriority(value: String) = _state.update { it.copy(detailPriority = value) }
    fun updateDetailStatus(value: String) = _state.update { it.copy(detailStatus = value) }

    fun saveTaskDetail() {
        val task = _state.value.selectedTask ?: return
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            try {
                repo.updateTask(
                    id = task.id,
                    title = _state.value.detailTitle.trim().ifBlank { task.title },
                    status = _state.value.detailStatus,
                    priority = _state.value.detailPriority,
                )
                _state.update { it.copy(busy = false, selectedTask = null) }
                refreshTasks()
                refreshBriefAndSuggestions()
            } catch (e: Exception) {
                _state.update { it.copy(busy = false, error = e.message ?: "Could not save task") }
            }
        }
    }

    fun deleteSelectedTask() {
        val task = _state.value.selectedTask ?: return
        viewModelScope.launch {
            try {
                repo.deleteTask(task.id)
                _state.update { it.copy(selectedTask = null) }
                refreshTasks()
                refreshBriefAndSuggestions()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not delete task") }
            }
        }
    }

    fun acceptSuggestion(suggestion: TaskSuggestion) {
        viewModelScope.launch {
            try {
                repo.acceptSuggestion(suggestion)
                refreshTasks()
                refreshBriefAndSuggestions()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not accept suggestion") }
            }
        }
    }

    fun dismissSuggestion(suggestion: TaskSuggestion) {
        viewModelScope.launch {
            try {
                repo.dismissSuggestion(suggestion.key)
                refreshBriefAndSuggestions()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not dismiss suggestion") }
            }
        }
    }

    fun onCalendarPermissionResult(granted: Boolean) {
        _state.update { it.copy(calendarPermissionGranted = granted) }
        if (granted) refreshCalendar()
    }

    fun onMicPermissionResult(granted: Boolean) {
        _state.update { it.copy(micPermissionGranted = granted) }
    }

    fun onNotificationsPermissionResult(granted: Boolean) {
        _state.update { it.copy(notificationsPermissionGranted = granted) }
    }

    fun syncPermissionFlags(
        calendar: Boolean,
        mic: Boolean,
        notifications: Boolean,
    ) {
        _state.update {
            it.copy(
                calendarPermissionGranted = calendar,
                micPermissionGranted = mic,
                notificationsPermissionGranted = notifications,
            )
        }
        if (calendar) refreshCalendar()
    }

    fun completePermissionsOnboarding() {
        repo.store.hasSeenPermissionsOnboarding = true
        advanceOnboardingAfterPermissions()
    }

    fun updateOnboardingName(value: String) = _state.update { it.copy(onboardingName = value) }
    fun updateOnboardingPriority(value: String) = _state.update { it.copy(onboardingPriority = value) }

    fun skipMemoryCapture() {
        repo.store.hasSeenMemoryCapture = true
        _state.update {
            it.copy(
                onboardingStep = OnboardingStep.None,
                onboardingName = "",
                onboardingPriority = "",
            )
        }
    }

    fun saveMemoryCapture() {
        viewModelScope.launch {
            val name = _state.value.onboardingName.trim()
            val priority = _state.value.onboardingPriority.trim()
            try {
                if (name.isNotBlank()) {
                    repo.addMemory("My name is $name", source = "onboarding")
                }
                if (priority.isNotBlank()) {
                    repo.addMemory("My top priority right now is $priority", source = "onboarding")
                }
            } catch (_: Exception) {
                // Still leave onboarding; user can add facts later in Settings.
            }
            repo.store.hasSeenMemoryCapture = true
            _state.update {
                it.copy(
                    onboardingStep = OnboardingStep.None,
                    onboardingName = "",
                    onboardingPriority = "",
                )
            }
        }
    }

    private fun initialOnboardingStep(): OnboardingStep = when {
        !repo.store.hasSeenPermissionsOnboarding -> OnboardingStep.Permissions
        !repo.store.hasSeenMemoryCapture -> OnboardingStep.MemoryCapture
        else -> OnboardingStep.None
    }

    private fun maybeStartOnboarding() {
        _state.update { it.copy(onboardingStep = initialOnboardingStep()) }
    }

    private fun advanceOnboardingAfterPermissions() {
        if (!repo.store.hasSeenMemoryCapture) {
            _state.update { it.copy(onboardingStep = OnboardingStep.MemoryCapture) }
        } else {
            _state.update { it.copy(onboardingStep = OnboardingStep.None) }
        }
    }

    fun refreshCalendar() {
        val app = getApplication<Application>()
        val granted = repo.hasCalendarPermission(app)
        val day = _state.value.agendaDayStartMillis.takeIf { it > 0L }
            ?: DeviceCalendarReader.startOfDayMillis()
        val events = if (granted) repo.loadCalendarEvents(app, day) else emptyList()
        _state.update {
            it.copy(
                calendarPermissionGranted = granted,
                calendarEvents = events,
                agendaDayStartMillis = day,
            )
        }
    }

    fun shiftAgendaDay(days: Int) {
        val current = _state.value.agendaDayStartMillis.takeIf { it > 0L }
            ?: DeviceCalendarReader.startOfDayMillis()
        _state.update {
            it.copy(agendaDayStartMillis = DeviceCalendarReader.shiftDayStartMillis(current, days))
        }
        refreshCalendar()
    }

    fun jumpAgendaToday() {
        _state.update { it.copy(agendaDayStartMillis = DeviceCalendarReader.startOfDayMillis()) }
        refreshCalendar()
    }

    fun createTask() {
        val title = _state.value.newTaskTitle.trim()
        if (title.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null) }
            try {
                repo.createTask(title)
                _state.update { it.copy(newTaskTitle = "", busy = false) }
                refreshTasks()
            } catch (e: Exception) {
                _state.update {
                    it.copy(busy = false, error = e.message ?: "Could not create task")
                }
            }
        }
    }

    fun completeTask(task: RemTask) {
        viewModelScope.launch {
            try {
                repo.completeTask(task.id)
                refreshTasks()
                refreshBriefAndSuggestions()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not update task") }
            }
        }
    }

    fun openSession(key: String) {
        _state.update {
            it.copy(
                activeSessionKey = key,
                messages = emptyList(),
                tab = MainTab.Chats,
                streaming = false,
                error = null,
            )
        }
        viewModelScope.launch {
            loadChatHistory(key)
        }
    }

    fun startNewChat() {
        val key = "android-" + UUID.randomUUID().toString().take(8)
        _state.update {
            it.copy(
                activeSessionKey = key,
                messages = emptyList(),
                draft = "",
                tab = MainTab.Chats,
                streaming = false,
                busy = false,
                status = if (it.gatewayReady) "New chat" else it.status,
                error = null,
            )
        }
    }

    fun abortChat() {
        viewModelScope.launch {
            try {
                repo.abortChat(_state.value.activeSessionKey)
                _state.update { current ->
                    val msgs = current.messages.toMutableList()
                    val last = msgs.lastOrNull()
                    if (last?.role == ChatMessage.Role.Assistant && last.isStreaming) {
                        msgs[msgs.lastIndex] = last.copy(isStreaming = false, text = last.text.ifBlank { "(stopped)" })
                    }
                    current.copy(streaming = false, busy = false, status = "Stopped")
                }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not stop reply") }
            }
        }
    }

    fun send() {
        val text = _state.value.draft.trim()
        if (text.isEmpty()) return
        sendInternal(text, fromVoice = false)
    }

    fun sendPrompt(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        sendInternal(trimmed, fromVoice = false)
    }

    private fun sendInternal(text: String, fromVoice: Boolean) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || _state.value.busy || _state.value.quotaBlocked) {
            if (fromVoice && _state.value.talkEnabled && !_state.value.busy) {
                talk.speakThenListen("")
            }
            return
        }
        val talkOn = _state.value.talkEnabled || fromVoice
        val wire = if (talkOn) TalkPrompt.wrap(trimmed) else trimmed
        val thinking = if (talkOn) "low" else "off"
        if (talkOn) talk.notifyThinking()
        viewModelScope.launch {
            val userMsg = ChatMessage(UUID.randomUUID().toString(), ChatMessage.Role.User, trimmed)
            _state.update {
                it.copy(
                    draft = if (fromVoice) it.draft else "",
                    busy = true,
                    streaming = true,
                    status = if (talkOn) "Thinking…" else "Rem is thinking…",
                    talkPhase = if (talkOn) TalkPhase.Thinking else it.talkPhase,
                    error = null,
                    quotaBlocked = false,
                    messages = it.messages + userMsg + ChatMessage(
                        id = UUID.randomUUID().toString(),
                        role = ChatMessage.Role.Assistant,
                        text = "",
                        isStreaming = true,
                    ),
                )
            }
            try {
                val usage = repo.sendMessage(
                    sessionKey = _state.value.activeSessionKey,
                    text = wire,
                    thinking = thinking,
                    previousUsage = _state.value.usage,
                )
                _state.update {
                    it.copy(
                        usage = usage ?: it.usage,
                        status = if (talkOn) "Thinking…" else "Rem is thinking…",
                    )
                }
                kotlinx.coroutines.delay(1500)
                refreshSessions()
            } catch (e: QuotaExceededException) {
                _state.update { current ->
                    val msgs = current.messages.dropLastWhile {
                        it.role == ChatMessage.Role.Assistant && it.isStreaming && it.text.isBlank()
                    }
                    val usage = current.usage?.copy(
                        remainingDay = e.remainingDay ?: current.usage.remainingDay,
                        remainingMonth = e.remainingMonth ?: current.usage.remainingMonth,
                        allowed = false,
                        reason = e.message,
                    )
                    current.copy(
                        messages = msgs,
                        busy = false,
                        streaming = false,
                        quotaBlocked = true,
                        usage = usage,
                        status = "Quota exceeded",
                        error = e.message ?: "You've hit today's Rem usage limit.",
                    )
                }
                if (talkOn) talk.speakThenListen("You've hit today's Rem usage limit.")
                refreshUsage()
            } catch (e: Exception) {
                _state.update { current ->
                    val msgs = current.messages.toMutableList()
                    val last = msgs.lastOrNull()
                    if (last?.role == ChatMessage.Role.Assistant && last.isStreaming && last.text.isBlank()) {
                        msgs.removeAt(msgs.lastIndex)
                    }
                    current.copy(
                        messages = msgs,
                        busy = false,
                        streaming = false,
                        status = "Send failed",
                        error = e.message ?: "Could not send message",
                    )
                }
                if (_state.value.talkEnabled) {
                    talk.speakThenListen("")
                }
            }
        }
    }

    fun reconnectGateway() {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, status = "Reconnecting…", error = null) }
            try {
                repo.connectGateway()
                _state.update { it.copy(busy = false, gatewayReady = true, status = "Connected to Rem") }
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        busy = false,
                        gatewayReady = false,
                        status = "Gateway not ready",
                        error = e.message,
                    )
                }
            }
        }
    }

    private fun bootstrap() {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, status = "Waking gateway…", error = null) }
            try {
                repo.connectGateway()
                remTts.apiKey = repo.elevenLabsApiKey()
                _state.update { it.copy(gatewayReady = true, status = "Connected to Rem") }
                refreshTasks()
                refreshSessions()
                refreshUsage()
                refreshBriefAndSuggestions()
                refreshCalendar()
                val history = runCatching {
                    repo.loadHistory(_state.value.activeSessionKey)
                }.getOrDefault(emptyList())
                val restored = history.map { (role, text) ->
                    ChatMessage(
                        id = UUID.randomUUID().toString(),
                        role = if (role == "user") ChatMessage.Role.User else ChatMessage.Role.Assistant,
                        text = text,
                    )
                }
                _state.update {
                    it.copy(
                        busy = false,
                        messages = if (restored.isNotEmpty()) restored else it.messages,
                    )
                }
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        busy = false,
                        gatewayReady = false,
                        status = "Gateway not ready",
                        error = e.message ?: "Could not connect gateway",
                    )
                }
                refreshTasks()
            } finally {
                maybeStartOnboarding()
            }
        }
    }

    private fun refreshBriefAndSuggestions() {
        viewModelScope.launch {
            val brief = runCatching { repo.fetchBrief() }.getOrNull()
            val suggestions = runCatching { repo.fetchSuggestions() }.getOrDefault(emptyList())
            _state.update { it.copy(brief = brief, suggestions = suggestions) }
        }
    }

    private fun refreshTasks() {
        viewModelScope.launch {
            try {
                val tasks = repo.fetchTasks()
                _state.update { it.copy(tasks = tasks) }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not load tasks") }
            }
        }
    }

    private fun refreshSessions() {
        viewModelScope.launch {
            try {
                val sessions = repo.listSessions()
                _state.update { it.copy(sessions = sessions) }
            } catch (_: Exception) {
                // Chat still works with android-main session.
            }
        }
    }

    private fun refreshUsage() {
        viewModelScope.launch {
            val usage = repo.fetchUsage()
            _state.update { it.copy(usage = usage) }
        }
    }

    private suspend fun loadChatHistory(sessionKey: String) {
        _state.update { it.copy(busy = true) }
        try {
            val history = repo.loadHistory(sessionKey)
            val restored = history.map { (role, text) ->
                ChatMessage(
                    id = UUID.randomUUID().toString(),
                    role = if (role == "user") ChatMessage.Role.User else ChatMessage.Role.Assistant,
                    text = text,
                )
            }
            _state.update { it.copy(messages = restored, busy = false) }
        } catch (e: Exception) {
            _state.update { it.copy(busy = false, error = e.message) }
        }
    }

    fun navigateSettings(screen: SettingsScreen) {
        _state.update { it.copy(settingsScreen = screen, error = null) }
        when (screen) {
            SettingsScreen.Connectors -> refreshToolkits()
            SettingsScreen.Channels -> refreshChannels()
            SettingsScreen.Memory -> refreshMemories()
            SettingsScreen.Models -> refreshModels()
            SettingsScreen.Capabilities -> refreshSkills()
            SettingsScreen.Connections -> refreshPendingDevices()
            SettingsScreen.Billing -> refreshUsage()
            SettingsScreen.Permissions -> Unit
            else -> Unit
        }
    }

    fun openBilling() {
        _state.update {
            it.copy(
                tab = MainTab.Settings,
                settingsScreen = SettingsScreen.Billing,
                error = null,
            )
        }
        refreshUsage()
    }

    fun refreshCurrentSettingsSection() {
        when (_state.value.settingsScreen) {
            SettingsScreen.Connectors -> refreshToolkits()
            SettingsScreen.Channels -> refreshChannels()
            SettingsScreen.Memory -> refreshMemories()
            SettingsScreen.Models -> refreshModels()
            SettingsScreen.Capabilities -> refreshSkills()
            SettingsScreen.Connections -> refreshPendingDevices()
            SettingsScreen.Billing -> refreshUsage()
            SettingsScreen.Permissions -> Unit
            else -> Unit
        }
    }

    fun updateMemoryDraft(value: String) = _state.update { it.copy(memoryDraft = value) }
    fun updateDiscordTokenDraft(value: String) = _state.update { it.copy(discordTokenDraft = value) }

    fun connectToolkit(slug: String, onOpenUrl: (String) -> Unit) {
        viewModelScope.launch {
            _state.update { it.copy(settingsBusy = true, error = null) }
            try {
                val session = repo.connectComposio(slug)
                onOpenUrl(session.redirectUrl)
                // Poll a few times after the browser flow.
                var done = false
                repeat(8) {
                    if (done) return@repeat
                    kotlinx.coroutines.delay(2_500)
                    val st = repo.composioStatus(session.connectionId, session.toolkit)
                    if (st.status == "connected" || st.status == "failed") done = true
                }
                refreshToolkits()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not connect") }
            } finally {
                _state.update { it.copy(settingsBusy = false) }
            }
        }
    }

    fun disconnectToolkit(slug: String) {
        viewModelScope.launch {
            try {
                repo.disconnectComposio(slug)
                refreshToolkits()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not disconnect") }
            }
        }
    }

    fun toggleToolkit(slug: String, enabled: Boolean) {
        viewModelScope.launch {
            try {
                repo.setComposioEnabled(slug, enabled)
                refreshToolkits()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not update connector") }
            }
        }
    }

    fun connectChannel(provider: String) {
        viewModelScope.launch {
            try {
                val token = if (provider == "discord") _state.value.discordTokenDraft.trim() else ""
                repo.connectChannel(provider, token)
                _state.update { it.copy(discordTokenDraft = "") }
                refreshChannels()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not connect channel") }
            }
        }
    }

    fun disconnectChannel(provider: String) {
        viewModelScope.launch {
            try {
                repo.disconnectChannel(provider)
                refreshChannels()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not disconnect channel") }
            }
        }
    }

    fun addMemory() {
        val fact = _state.value.memoryDraft.trim()
        if (fact.isEmpty()) return
        viewModelScope.launch {
            try {
                repo.addMemory(fact)
                _state.update { it.copy(memoryDraft = "") }
                refreshMemories()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not add memory") }
            }
        }
    }

    fun deleteMemory(id: String) {
        viewModelScope.launch {
            try {
                repo.deleteMemory(id)
                refreshMemories()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not delete memory") }
            }
        }
    }

    fun toggleSkill(skillKey: String, enabled: Boolean) {
        viewModelScope.launch {
            try {
                repo.updateSkill(skillKey, enabled)
                refreshSkills()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not update skill") }
            }
        }
    }

    fun toggleModel(modelId: String, enabled: Boolean) {
        modelPrefs.setEnabled(modelId, enabled)
        _state.update { it.copy(disabledModelIds = modelPrefs.disabledIds()) }
    }

    fun approveThisDevice() {
        viewModelScope.launch {
            try {
                repo.approveDeviceBackend()
                repo.connectGateway()
                _state.update { it.copy(gatewayReady = true, status = "Connected to Rem") }
                refreshPendingDevices()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not approve device") }
            }
        }
    }

    fun approvePendingDevice(requestId: String) {
        viewModelScope.launch {
            try {
                repo.approvePendingDevice(requestId)
                refreshPendingDevices()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not approve") }
            }
        }
    }

    fun rejectPendingDevice(requestId: String) {
        viewModelScope.launch {
            try {
                repo.rejectPendingDevice(requestId)
                refreshPendingDevices()
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not decline") }
            }
        }
    }

    private fun refreshToolkits() {
        viewModelScope.launch {
            _state.update { it.copy(settingsBusy = true) }
            try {
                val (configured, toolkits) = repo.fetchComposioToolkits()
                _state.update {
                    it.copy(composioConfigured = configured, toolkits = toolkits, settingsBusy = false)
                }
            } catch (e: Exception) {
                _state.update {
                    it.copy(settingsBusy = false, error = e.message ?: "Could not load connectors")
                }
            }
        }
    }

    private fun refreshChannels() {
        viewModelScope.launch {
            try {
                val channels = repo.fetchChannels()
                _state.update { it.copy(channels = channels) }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not load channels") }
            }
        }
    }

    private fun refreshMemories() {
        viewModelScope.launch {
            try {
                val memories = repo.fetchMemories()
                _state.update { it.copy(memories = memories) }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not load memory") }
            }
        }
    }

    private fun refreshSkills() {
        viewModelScope.launch {
            try {
                val skills = repo.listSkills()
                _state.update { it.copy(skills = skills) }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not load skills") }
            }
        }
    }

    private fun refreshModels() {
        viewModelScope.launch {
            try {
                val models = repo.listModels()
                _state.update {
                    it.copy(models = models, disabledModelIds = modelPrefs.disabledIds())
                }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Could not load models") }
            }
        }
    }

    private fun refreshPendingDevices() {
        viewModelScope.launch {
            try {
                val pending = repo.listPendingDevices()
                _state.update { it.copy(pendingDevices = pending) }
            } catch (_: Exception) {
                _state.update { it.copy(pendingDevices = emptyList()) }
            }
        }
    }

    fun openFocusSetup() {
        val task = _state.value.selectedTask ?: return
        if (task.isDone) return
        _state.update {
            it.copy(
                selectedTask = null,
                focus = FocusState(
                    phase = FocusPhase.Setup,
                    taskId = task.id,
                    taskTitle = task.title,
                    durationMinutes = 25,
                    remainingSec = 25 * 60,
                    totalSec = 25 * 60,
                ),
            )
        }
    }

    fun closeFocusSetup() {
        if (_state.value.focus.phase == FocusPhase.Setup) {
            _state.update { it.copy(focus = FocusState()) }
        }
    }

    fun pickFocusDuration(minutes: Int) {
        _state.update { current ->
            if (current.focus.phase != FocusPhase.Setup) return@update current
            current.copy(
                focus = current.focus.copy(
                    durationMinutes = minutes,
                    remainingSec = minutes * 60,
                    totalSec = minutes * 60,
                ),
            )
        }
    }

    fun toggleFocusWarmUp() {
        _state.update { current ->
            if (current.focus.phase != FocusPhase.Setup) return@update current
            current.copy(focus = current.focus.copy(warmUpEnabled = !current.focus.warmUpEnabled))
        }
    }

    fun startFocusSession() {
        val focus = _state.value.focus
        val taskId = focus.taskId ?: return
        if (focus.phase != FocusPhase.Setup && focus.phase != FocusPhase.Complete) return
        val durationSec = focus.durationMinutes.coerceAtLeast(1) * 60
        val warming = focus.warmUpEnabled && focus.phase == FocusPhase.Setup
        val phase = if (warming) FocusPhase.Warming else FocusPhase.Running
        val remaining = if (warming) 60 else durationSec
        val total = if (warming) 60 else durationSec
        _state.update {
            it.copy(
                focus = focus.copy(
                    phase = phase,
                    remainingSec = remaining,
                    totalSec = total,
                    minimized = false,
                ),
            )
        }
        startFocusTicker()
        viewModelScope.launch {
            runCatching { repo.updateTask(id = taskId, status = "in_progress") }
            refreshTasks()
            refreshBriefAndSuggestions()
        }
    }

    fun minimizeFocus() {
        _state.update { current ->
            if (!current.focus.isActive) return@update current
            current.copy(focus = current.focus.copy(minimized = true))
        }
    }

    fun expandFocus() {
        _state.update { current ->
            if (!current.focus.isActive) return@update current
            current.copy(focus = current.focus.copy(minimized = false))
        }
    }

    fun pauseFocus() {
        val phase = _state.value.focus.phase
        if (phase != FocusPhase.Running && phase != FocusPhase.Warming) return
        _state.update { it.copy(focus = it.focus.copy(phase = FocusPhase.Paused)) }
    }

    fun resumeFocus() {
        if (_state.value.focus.phase != FocusPhase.Paused) return
        _state.update { it.copy(focus = it.focus.copy(phase = FocusPhase.Running, minimized = false)) }
        startFocusTicker()
    }

    fun skipWarmUp() {
        val focus = _state.value.focus
        if (focus.phase != FocusPhase.Warming) return
        val durationSec = focus.durationMinutes.coerceAtLeast(1) * 60
        _state.update {
            it.copy(
                focus = focus.copy(
                    phase = FocusPhase.Running,
                    remainingSec = durationSec,
                    totalSec = durationSec,
                    minimized = false,
                ),
            )
        }
        startFocusTicker()
    }

    fun extendFocus(minutes: Int) {
        val extra = minutes.coerceAtLeast(1) * 60
        val focus = _state.value.focus
        if (!focus.isActive && focus.phase != FocusPhase.Complete) return
        val nextRemaining = if (focus.phase == FocusPhase.Complete) extra else focus.remainingSec + extra
        val nextTotal = if (focus.phase == FocusPhase.Complete) extra else focus.totalSec + extra
        _state.update {
            it.copy(
                focus = focus.copy(
                    phase = FocusPhase.Running,
                    remainingSec = nextRemaining,
                    totalSec = nextTotal,
                    minimized = focus.minimized && focus.phase != FocusPhase.Complete,
                ),
            )
        }
        startFocusTicker()
    }

    fun stopFocus(silent: Boolean = false) {
        focusTicker?.cancel()
        focusTicker = null
        if (silent) {
            _state.update { it.copy(focus = FocusState()) }
            return
        }
        _state.update { it.copy(focus = FocusState()) }
    }

    fun completeFocusTask() {
        val taskId = _state.value.focus.taskId
        stopFocus()
        if (taskId.isNullOrBlank()) return
        viewModelScope.launch {
            runCatching { repo.completeTask(taskId) }
            refreshTasks()
            refreshBriefAndSuggestions()
        }
    }

    fun dismissFocusComplete() {
        stopFocus()
    }

    private fun startFocusTicker() {
        focusTicker?.cancel()
        focusTicker = viewModelScope.launch {
            while (isActive) {
                delay(1_000)
                val focus = _state.value.focus
                val ticking = focus.phase == FocusPhase.Running || focus.phase == FocusPhase.Warming
                if (!ticking) continue
                val next = focus.remainingSec - 1
                if (next <= 0) {
                    if (focus.phase == FocusPhase.Warming) {
                        val durationSec = focus.durationMinutes.coerceAtLeast(1) * 60
                        _state.update {
                            it.copy(
                                focus = focus.copy(
                                    phase = FocusPhase.Running,
                                    remainingSec = durationSec,
                                    totalSec = durationSec,
                                ),
                            )
                        }
                    } else {
                        _state.update {
                            it.copy(
                                focus = focus.copy(
                                    phase = FocusPhase.Complete,
                                    remainingSec = 0,
                                    minimized = false,
                                ),
                            )
                        }
                    }
                } else {
                    _state.update { it.copy(focus = focus.copy(remainingSec = next)) }
                }
            }
        }
    }

}
