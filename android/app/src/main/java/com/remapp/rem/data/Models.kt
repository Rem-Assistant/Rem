package com.remapp.rem.data

data class RemUser(
    val id: String,
    val email: String?,
    val fullName: String?,
)

data class AuthResult(
    val accessToken: String,
    val user: RemUser,
    val isNewUser: Boolean,
)

data class GatewayCredentials(
    val gatewayUrl: String,
    val gatewayToken: String,
    val hostingProvider: String?,
    val elevenLabsApiKey: String? = null,
)

data class DeployStatus(
    val id: String,
    val phase: String,
    val message: String?,
    val gatewayUrl: String?,
    val gatewayToken: String?,
)

data class RemTask(
    val id: String,
    val title: String,
    val status: String?,
    val priority: String?,
    val startDate: String?,
    val endDate: String?,
    val type: String?,
    val listId: String?,
    val runStatus: String?,
) {
    val isDone: Boolean
        get() = status.equals("completed", ignoreCase = true) ||
            status.equals("done", ignoreCase = true)

    val isScheduled: Boolean
        get() = !startDate.isNullOrBlank()
}

data class BriefCounts(
    val blocked: Int,
    val overdue: Int,
    val scheduledToday: Int,
    val completedToday: Int,
    val total: Int,
    val done: Int,
) {
    val progress: Float
        get() = if (total <= 0) 0f else (done.toFloat() / total).coerceIn(0f, 1f)
}

data class BriefItem(
    val id: String,
    val title: String,
    val status: String?,
    val priority: String?,
    val runStatus: String?,
    val startDate: String?,
    val type: String,
    val bucket: String,
    val latestActivitySummary: String?,
)

data class DailyBrief(
    val generatedAt: String?,
    val counts: BriefCounts,
    val blocked: List<BriefItem>,
    val overdue: List<BriefItem>,
    val scheduledToday: List<BriefItem>,
    val completedToday: List<BriefItem>,
    val summary: String?,
    val markdown: String?,
    val briefSessionKey: String?,
)

data class TaskSuggestion(
    val key: String,
    val source: String,
    val title: String,
    val subtitle: String,
    val actionKind: String,
    val actionTaskTitle: String?,
    val actionTargetTaskId: String?,
    val actionStartDate: String?,
)

data class DeviceCalendarEvent(
    val id: Long,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val allDay: Boolean,
    val calendarName: String?,
)

data class UsageSummary(
    val plan: String? = null,
    val status: String? = null,
    val requestsPerDay: Int? = null,
    val requestsPerMonth: Int? = null,
    val modelTier: String? = null,
    val usedDay: Int? = null,
    val usedMonth: Int? = null,
    val remainingDay: Int? = null,
    val remainingMonth: Int? = null,
    val allowed: Boolean = true,
    val reason: String? = null,
    val quotaCycleStartedAt: String? = null,
) {
    val isPro: Boolean get() = plan.equals("pro", ignoreCase = true)
    val planLabel: String
        get() = plan?.replaceFirstChar { it.uppercase() } ?: "—"

    fun mergeConsume(partial: UsageSummary): UsageSummary = copy(
        usedDay = partial.usedDay ?: usedDay,
        usedMonth = partial.usedMonth ?: usedMonth,
        remainingDay = partial.remainingDay ?: remainingDay,
        remainingMonth = partial.remainingMonth ?: remainingMonth,
        allowed = partial.allowed,
        reason = partial.reason ?: reason,
        plan = plan ?: partial.plan,
        status = status ?: partial.status,
        requestsPerDay = requestsPerDay ?: partial.requestsPerDay,
        requestsPerMonth = requestsPerMonth ?: partial.requestsPerMonth,
        modelTier = modelTier ?: partial.modelTier,
    )
}

data class ChatMessage(
    val id: String,
    val role: Role,
    val text: String,
    val isStreaming: Boolean = false,
) {
    enum class Role { User, Assistant, System }
}

data class ChatSession(
    val key: String,
    val label: String,
    val preview: String? = null,
    val updatedAt: Long? = null,
)

class QuotaExceededException(
    message: String,
    val remainingDay: Int? = null,
    val remainingMonth: Int? = null,
) : Exception(message)

data class ComposioToolkit(
    val slug: String,
    val logoUrl: String? = null,
    val status: String,
    val enabled: Boolean = true,
) {
    val isConnected: Boolean get() = status == "connected"
}

data class ComposioConnectSession(
    val redirectUrl: String,
    val connectionId: String,
    val toolkit: String,
)

data class ComposioConnectionState(
    val toolkit: String?,
    val status: String,
    val connectedAccountId: String? = null,
    val enabled: Boolean = true,
)

data class RemChannel(
    val provider: String,
    val name: String,
    val icon: String? = null,
    val wired: Boolean = false,
    val connect: String = "none",
    val hint: String = "",
    val status: String = "available",
    val hasCredential: Boolean = false,
    val updatedAt: String? = null,
) {
    val isConnected: Boolean get() = status == "connected"
    val isConnecting: Boolean get() = status == "connecting"
}

data class UserMemory(
    val id: String,
    val fact: String,
    val source: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

data class SkillEntry(
    val skillKey: String,
    val name: String?,
    val description: String? = null,
    val disabled: Boolean = false,
    val eligible: Boolean = true,
) {
    val isEnabled: Boolean get() = eligible && !disabled
    val label: String get() = name?.ifBlank { null } ?: skillKey
}

data class ModelChoice(
    val id: String,
    val name: String,
    val provider: String,
)

data class PendingDevice(
    val requestId: String,
    val displayName: String,
    val platform: String? = null,
)
