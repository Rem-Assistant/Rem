package com.remapp.rem.data

import android.content.Context
import com.remapp.rem.gateway.GatewaySocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

class RemRepository(
    val store: SessionStore,
    val api: RemApiClient = RemApiClient(store),
) {
    val gateway = GatewaySocket()

    fun currentUser(): RemUser? {
        val id = store.userId ?: return null
        return RemUser(id = id, email = store.userEmail, fullName = store.userName)
    }

    fun currentEnvironment(): AppEnvironment = store.environment

    suspend fun switchEnvironment(env: AppEnvironment) = withContext(Dispatchers.IO) {
        gateway.disconnect()
        store.environment = env
        store.clearSession()
    }

    suspend fun signInWithGoogle(idToken: String, email: String?, name: String?): AuthResult =
        withContext(Dispatchers.IO) {
            val result = api.loginWithGoogle(idToken, email, name)
            store.saveAuth(result)
            result
        }

    suspend fun signInWithDevice(context: Context): AuthResult = withContext(Dispatchers.IO) {
        val result = api.loginWithDevice(store.deviceId(context))
        store.saveAuth(result)
        result
    }

    fun signOut() {
        gateway.disconnect()
        store.clearSession()
    }

    suspend fun deleteAccount() = withContext(Dispatchers.IO) {
        api.deleteAccount()
        gateway.disconnect()
        store.clearSession()
    }

    suspend fun ensureGatewayReady(): GatewayCredentials = withContext(Dispatchers.IO) {
        var creds = api.getCredentials()
        if (creds == null) {
            val deploy = api.startDeploy()
            creds = waitForDeploy(deploy.id)
            // Refresh so we also pick up ElevenLabs + other credential fields.
            creds = api.getCredentials() ?: creds
        }
        store.saveGateway(creds)
        runCatching { api.wakeGateway() }
        creds
    }

    suspend fun connectGateway(): Unit = withContext(Dispatchers.IO) {
        val creds = ensureGatewayReady()
        try {
            gateway.connect(creds.gatewayUrl, creds.gatewayToken)
        } catch (_: Exception) {
            runCatching { api.approveDevice() }
            delay(800)
            gateway.connect(creds.gatewayUrl, creds.gatewayToken)
        }
    }

    /**
     * Gates on usage, then sends chat. Returns updated usage summary when consume succeeds.
     * Throws [QuotaExceededException] when the backend returns 429.
     */
    suspend fun sendMessage(
        sessionKey: String,
        text: String,
        thinking: String = "off",
        previousUsage: UsageSummary? = null,
    ): UsageSummary? =
        withContext(Dispatchers.IO) {
            val consumed = api.consumeUsage()
            if (!gateway.isConnected) connectGateway()
            gateway.sendChat(sessionKey, text, thinking = thinking)
            previousUsage?.mergeConsume(consumed) ?: consumed
        }

    fun elevenLabsApiKey(): String? = store.elevenLabsApiKey

    suspend fun abortChat(sessionKey: String) = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) return@withContext
        gateway.abortChat(sessionKey)
    }

    suspend fun loadHistory(sessionKey: String) = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.loadHistory(sessionKey)
    }

    suspend fun listSessions(): List<ChatSession> = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        runCatching {
            gateway.listSessions().map { row ->
                ChatSession(
                    key = row.key,
                    label = row.label,
                    preview = row.preview,
                    updatedAt = row.updatedAt,
                )
            }
        }.getOrDefault(emptyList())
    }

    suspend fun fetchTasks(): List<RemTask> = withContext(Dispatchers.IO) {
        api.fetchTasks()
    }

    suspend fun createTask(title: String): RemTask = withContext(Dispatchers.IO) {
        api.createTask(title)
    }

    suspend fun completeTask(id: String): RemTask = withContext(Dispatchers.IO) {
        api.updateTask(id, status = "completed")
    }

    suspend fun updateTask(
        id: String,
        title: String? = null,
        status: String? = null,
        priority: String? = null,
        startDate: String? = null,
    ): RemTask = withContext(Dispatchers.IO) {
        api.updateTask(id, title, status, priority, startDate)
    }

    suspend fun deleteTask(id: String) = withContext(Dispatchers.IO) {
        api.deleteTask(id)
    }

    suspend fun getTask(id: String): RemTask = withContext(Dispatchers.IO) {
        api.getTask(id)
    }

    suspend fun fetchUsage(): UsageSummary? = withContext(Dispatchers.IO) {
        runCatching { api.fetchUsageSummary() }.getOrNull()
    }

    suspend fun fetchBrief(): DailyBrief? = withContext(Dispatchers.IO) {
        api.fetchBrief()
    }

    suspend fun fetchSuggestions(): List<TaskSuggestion> = withContext(Dispatchers.IO) {
        api.fetchSuggestions()
    }

    suspend fun dismissSuggestion(key: String) = withContext(Dispatchers.IO) {
        api.dismissSuggestion(key)
    }

    suspend fun acceptSuggestion(suggestion: TaskSuggestion): RemTask? = withContext(Dispatchers.IO) {
        when (suggestion.actionKind) {
            "createTask" -> {
                val title = suggestion.actionTaskTitle ?: suggestion.title
                var created = api.createTask(title)
                if (!suggestion.actionStartDate.isNullOrBlank()) {
                    created = api.updateTask(created.id, startDate = suggestion.actionStartDate)
                }
                runCatching { api.dismissSuggestion(suggestion.key) }
                created
            }
            "rescheduleTask" -> {
                val target = suggestion.actionTargetTaskId ?: return@withContext null
                val updated = api.updateTask(
                    target,
                    startDate = suggestion.actionStartDate,
                )
                runCatching { api.dismissSuggestion(suggestion.key) }
                updated
            }
            else -> {
                runCatching { api.dismissSuggestion(suggestion.key) }
                null
            }
        }
    }

    fun loadCalendarEvents(context: Context, dayStartMillis: Long): List<DeviceCalendarEvent> =
        com.remapp.rem.device.DeviceCalendarReader.loadEventsForDay(context, dayStartMillis)

    fun loadTodayCalendarEvents(context: Context): List<DeviceCalendarEvent> =
        loadCalendarEvents(context, com.remapp.rem.device.DeviceCalendarReader.startOfDayMillis())

    fun hasCalendarPermission(context: Context): Boolean =
        com.remapp.rem.device.DeviceCalendarReader.hasPermission(context)

    suspend fun fetchComposioToolkits(): Pair<Boolean, List<ComposioToolkit>> =
        withContext(Dispatchers.IO) { api.fetchComposioToolkits() }

    suspend fun connectComposio(toolkit: String): ComposioConnectSession =
        withContext(Dispatchers.IO) { api.connectComposio(toolkit) }

    suspend fun composioStatus(connectionId: String, toolkit: String): ComposioConnectionState =
        withContext(Dispatchers.IO) { api.composioStatus(connectionId, toolkit) }

    suspend fun disconnectComposio(toolkit: String) = withContext(Dispatchers.IO) {
        api.disconnectComposio(toolkit)
    }

    suspend fun setComposioEnabled(toolkit: String, enabled: Boolean) = withContext(Dispatchers.IO) {
        api.setComposioEnabled(toolkit, enabled)
    }

    suspend fun fetchChannels(): List<RemChannel> = withContext(Dispatchers.IO) {
        api.fetchChannels()
    }

    suspend fun connectChannel(provider: String, token: String = ""): RemChannel =
        withContext(Dispatchers.IO) { api.connectChannel(provider, token) }

    suspend fun disconnectChannel(provider: String): RemChannel =
        withContext(Dispatchers.IO) { api.disconnectChannel(provider) }

    suspend fun fetchMemories(): List<UserMemory> = withContext(Dispatchers.IO) {
        api.fetchMemories()
    }

    suspend fun addMemory(fact: String, source: String? = null): UserMemory =
        withContext(Dispatchers.IO) {
            api.addMemory(fact, source)
        }

    suspend fun deleteMemory(id: String) = withContext(Dispatchers.IO) {
        api.deleteMemory(id)
    }

    suspend fun listSkills(): List<SkillEntry> = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.listSkills().map {
            SkillEntry(
                skillKey = it.skillKey,
                name = it.name,
                description = it.description,
                disabled = it.disabled,
                eligible = it.eligible,
            )
        }
    }

    suspend fun updateSkill(skillKey: String, enabled: Boolean) = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.updateSkill(skillKey, enabled)
    }

    suspend fun listModels(): List<ModelChoice> = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.listModels().map {
            ModelChoice(id = it.id, name = it.name, provider = it.provider)
        }
    }

    suspend fun listPendingDevices(): List<PendingDevice> = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.listPendingDevices().map {
            PendingDevice(
                requestId = it.requestId,
                displayName = it.displayName,
                platform = it.platform,
            )
        }
    }

    suspend fun approvePendingDevice(requestId: String) = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.approvePendingDevice(requestId)
    }

    suspend fun rejectPendingDevice(requestId: String) = withContext(Dispatchers.IO) {
        if (!gateway.isConnected) connectGateway()
        gateway.rejectPendingDevice(requestId)
    }

    suspend fun approveDeviceBackend() = withContext(Dispatchers.IO) {
        api.approveDevice()
    }

    private suspend fun waitForDeploy(deployId: String): GatewayCredentials {
        repeat(90) {
            val status = api.getDeployStatus(deployId)
            if (status.phase == "complete" &&
                !status.gatewayUrl.isNullOrBlank() &&
                !status.gatewayToken.isNullOrBlank()
            ) {
                return GatewayCredentials(
                    gatewayUrl = status.gatewayUrl,
                    gatewayToken = status.gatewayToken,
                    hostingProvider = "fly",
                )
            }
            if (status.phase == "failed") {
                throw IllegalStateException(status.message ?: "Gateway deploy failed")
            }
            delay(2_000)
        }
        throw IllegalStateException("Timed out waiting for gateway deploy")
    }
}
