package com.remapp.rem.gateway

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class GatewaySocket {
    private val http = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var socket: WebSocket? = null
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JSONObject>>()
    private val connected = AtomicBoolean(false)

    var onChatDelta: ((sessionKey: String, text: String, done: Boolean, runId: String?) -> Unit)? = null
    var onDisconnected: ((reason: String) -> Unit)? = null

    val isConnected: Boolean get() = connected.get()
    @Volatile var lastRunId: String? = null
        private set

    suspend fun connect(gatewayUrl: String, gatewayToken: String) {
        disconnect()
        val wsUrl = toWebSocketUrl(gatewayUrl)
        val deferred = CompletableDeferred<Unit>()
        val request = Request.Builder().url(wsUrl).build()

        val connectSent = AtomicBoolean(false)
        socket = http.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    // Some gateways send connect.challenge first; others expect connect
                    // immediately. Try challenge-first, then fall back.
                    scope.launch {
                        delay(400)
                        if (!connected.get() && connectSent.compareAndSet(false, true)) {
                            sendConnect(webSocket, gatewayToken)
                        }
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleFrame(webSocket, text, gatewayToken, deferred, connectSent)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    connected.set(false)
                    if (!deferred.isCompleted) {
                        deferred.completeExceptionally(t)
                    }
                    failPending(t)
                    onDisconnected?.invoke(t.message ?: "socket failure")
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    connected.set(false)
                    if (!deferred.isCompleted) {
                        deferred.completeExceptionally(IllegalStateException("closed: $reason"))
                    }
                    failPending(IllegalStateException("closed: $reason"))
                    onDisconnected?.invoke(reason.ifBlank { "closed $code" })
                }
            },
        )

        withTimeout(25_000) { deferred.await() }
    }

    fun disconnect() {
        connected.set(false)
        socket?.close(1000, "bye")
        socket = null
        failPending(IllegalStateException("disconnected"))
    }

    fun close() {
        disconnect()
        scope.cancel()
    }

    suspend fun request(method: String, params: JSONObject? = null, timeoutMs: Long = 120_000): JSONObject {
        val ws = socket ?: throw IllegalStateException("Not connected")
        val id = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<JSONObject>()
        pending[id] = deferred
        val frame = JSONObject()
            .put("type", "req")
            .put("id", id)
            .put("method", method)
            .put("params", params ?: JSONObject())
        if (!ws.send(frame.toString())) {
            pending.remove(id)
            throw IllegalStateException("Failed to send $method")
        }
        return withTimeout(timeoutMs) { deferred.await() }
    }

    suspend fun sendChat(
        sessionKey: String,
        message: String,
        thinking: String = "off",
    ): JSONObject {
        lastRunId = null
        val params = JSONObject()
            .put("sessionKey", sessionKey)
            .put("message", message)
            .put("thinking", thinking)
            .put("timeoutMs", 120_000)
            .put("idempotencyKey", UUID.randomUUID().toString())
        val res = request("chat.send", params, timeoutMs = 125_000)
        val payload = res.optJSONObject("payload") ?: res
        lastRunId = payload.optString("runId").ifBlank {
            payload.optString("run_id").ifBlank { null }
        }
        return res
    }

    suspend fun abortChat(sessionKey: String, runId: String? = lastRunId): JSONObject {
        val params = JSONObject().put("sessionKey", sessionKey)
        if (!runId.isNullOrBlank()) params.put("runId", runId)
        return request("chat.abort", params, timeoutMs = 15_000)
    }

    suspend fun listSkills(): List<SkillRow> {
        val res = request("skills.status", timeoutMs = 20_000)
        val payload = res.optJSONObject("payload") ?: res
        val arr = payload.optJSONArray("skills") ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val key = o.optString("skillKey").ifBlank { o.optString("key") }
            if (key.isBlank()) return@mapNotNull null
            SkillRow(
                skillKey = key,
                name = o.optString("name").ifBlank { null },
                description = o.optString("description").ifBlank { null },
                disabled = o.optBoolean("disabled", false),
                eligible = if (o.has("eligible")) o.optBoolean("eligible", true) else true,
            )
        }
    }

    suspend fun updateSkill(skillKey: String, enabled: Boolean): JSONObject =
        request(
            "skills.update",
            JSONObject().put("skillKey", skillKey).put("enabled", enabled),
            timeoutMs = 20_000,
        )

    suspend fun listModels(): List<ModelRow> {
        val res = request("models.list", timeoutMs = 20_000)
        val payload = res.optJSONObject("payload") ?: res
        val arr = payload.optJSONArray("models") ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optString("id").ifBlank { o.optString("modelId") }
            if (id.isBlank()) return@mapNotNull null
            ModelRow(
                id = id,
                name = o.optString("name").ifBlank { id },
                provider = o.optString("provider").ifBlank { "unknown" },
            )
        }
    }

    suspend fun listPendingDevices(): List<PendingDeviceRow> {
        val res = request("device.pair.list", timeoutMs = 15_000)
        val payload = res.optJSONObject("payload") ?: res
        val arr = payload.optJSONArray("pending")
            ?: payload.optJSONArray("requests")
            ?: payload.optJSONArray("devices")
            ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optString("requestId").ifBlank {
                o.optString("id").ifBlank { o.optString("deviceId") }
            }
            if (id.isBlank()) return@mapNotNull null
            PendingDeviceRow(
                requestId = id,
                displayName = o.optString("displayName").ifBlank {
                    o.optString("name").ifBlank {
                        o.optString("deviceName").ifBlank { "Device" }
                    }
                },
                platform = o.optString("platform").ifBlank {
                    o.optString("deviceFamily").ifBlank { null }
                },
            )
        }
    }

    suspend fun approvePendingDevice(requestId: String): JSONObject =
        request("device.pair.approve", JSONObject().put("requestId", requestId), timeoutMs = 15_000)

    suspend fun rejectPendingDevice(requestId: String): JSONObject =
        request("device.pair.reject", JSONObject().put("requestId", requestId), timeoutMs = 15_000)

    data class SkillRow(
        val skillKey: String,
        val name: String?,
        val description: String?,
        val disabled: Boolean,
        val eligible: Boolean,
    )

    data class ModelRow(
        val id: String,
        val name: String,
        val provider: String,
    )

    data class PendingDeviceRow(
        val requestId: String,
        val displayName: String,
        val platform: String?,
    )

    suspend fun listSessions(limit: Int = 40): List<ChatSessionRow> {
        return try {
            parseSessions(
                request(
                    "sessions.list",
                    JSONObject()
                        .put("limit", limit)
                        .put("includeDerivedTitles", true)
                        .put("includeLastMessage", true),
                    timeoutMs = 20_000,
                ),
            )
        } catch (_: Exception) {
            parseSessions(
                request(
                    "sessions.list",
                    JSONObject().put("limit", limit),
                    timeoutMs = 20_000,
                ),
            )
        }
    }

    data class ChatSessionRow(
        val key: String,
        val label: String,
        val preview: String?,
        val updatedAt: Long?,
    )

    private fun parseSessions(res: JSONObject): List<ChatSessionRow> {
        val payload = res.optJSONObject("payload") ?: res
        val arr = payload.optJSONArray("sessions")
            ?: payload.optJSONArray("items")
            ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val key = o.optString("key").ifBlank { o.optString("sessionKey") }
            if (key.isBlank()) return@mapNotNull null
            val label = o.optString("displayName").ifBlank {
                o.optString("derivedTitle").ifBlank {
                    o.optString("label").ifBlank {
                        o.optString("title").ifBlank { key.substringAfterLast(':') }
                    }
                }
            }
            val preview = o.optString("lastMessagePreview").ifBlank {
                o.optString("preview").ifBlank { null }
            }
            val updated = when {
                o.has("updatedAt") && !o.isNull("updatedAt") -> o.optLong("updatedAt")
                o.has("updated_at") -> o.optLong("updated_at")
                else -> null
            }
            ChatSessionRow(key = key, label = label, preview = preview, updatedAt = updated)
        }
    }

    suspend fun loadHistory(sessionKey: String): List<Pair<String, String>> {
        val res = request("chat.history", JSONObject().put("sessionKey", sessionKey), timeoutMs = 30_000)
        val payload = res.optJSONObject("payload") ?: res
        val messages = payload.optJSONArray("messages") ?: payload.optJSONArray("items") ?: JSONArray()
        val out = mutableListOf<Pair<String, String>>()
        for (i in 0 until messages.length()) {
            val m = messages.optJSONObject(i) ?: continue
            val role = m.optString("role").ifBlank { m.optString("sender") }
            val text = extractText(m)
            if (text.isNotBlank() && (role == "user" || role == "assistant")) {
                out += role to text
            }
        }
        return out
    }

    private fun handleFrame(
        webSocket: WebSocket,
        text: String,
        gatewayToken: String,
        connectDeferred: CompletableDeferred<Unit>,
        connectSent: AtomicBoolean,
    ) {
        val frame = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (frame.optString("type")) {
            "event" -> {
                val event = frame.optString("event")
                if (event == "connect.challenge" && !connected.get()) {
                    if (connectSent.compareAndSet(false, true)) {
                        sendConnect(webSocket, gatewayToken)
                    }
                } else if (event == "chat" || event == "agent") {
                    handleChatEvent(frame.optJSONObject("payload") ?: JSONObject())
                }
            }
            "res" -> {
                val id = frame.optString("id")
                if (!connected.get() && !connectDeferred.isCompleted) {
                    if (frame.optBoolean("ok")) {
                        connected.set(true)
                        connectDeferred.complete(Unit)
                    } else {
                        val err = frame.optJSONObject("error")?.optString("message")
                            ?: frame.optString("error")
                        connectDeferred.completeExceptionally(
                            IllegalStateException(err.ifBlank { "connect rejected" }),
                        )
                    }
                    return
                }
                val deferred = pending.remove(id) ?: return
                if (frame.optBoolean("ok")) {
                    deferred.complete(frame)
                } else {
                    val err = frame.optJSONObject("error")?.optString("message")
                        ?: frame.optString("error")
                    deferred.completeExceptionally(IllegalStateException(err.ifBlank { "request failed" }))
                }
            }
        }
    }

    private fun sendConnect(webSocket: WebSocket, gatewayToken: String) {
        val id = "connect-${UUID.randomUUID()}"
        val params = JSONObject()
            .put("minProtocol", 3)
            .put("maxProtocol", 4)
            .put(
                "client",
                JSONObject()
                    .put("id", "gateway-client")
                    .put("version", "0.2.0")
                    .put("platform", "android")
                    .put("mode", "operator"),
            )
            .put("role", "operator")
            .put(
                "scopes",
                JSONArray()
                    .put("operator.read")
                    .put("operator.write")
                    .put("operator.admin"),
            )
            .put("auth", JSONObject().put("token", gatewayToken))
            .put("locale", "en-US")
            .put("userAgent", "rem-android/0.2.0")
        val frame = JSONObject()
            .put("type", "req")
            .put("id", id)
            .put("method", "connect")
            .put("params", params)
        webSocket.send(frame.toString())
    }

    private fun handleChatEvent(payload: JSONObject) {
        val sessionKey = payload.optString("sessionKey")
        val state = payload.optString("state").ifBlank { payload.optString("status") }
        val runId = payload.optString("runId").ifBlank {
            payload.optString("run_id").ifBlank { null }
        }
        if (!runId.isNullOrBlank()) lastRunId = runId
        val message = payload.optJSONObject("message")
        val text = when {
            message != null -> extractText(message)
            else -> payload.optString("text").ifBlank {
                payload.optJSONObject("data")?.optString("text").orEmpty()
            }
        }
        val done = state == "final" || state == "done" || state == "aborted" ||
            payload.optBoolean("done")
        if (text.isBlank() && !done) return
        scope.launch {
            onChatDelta?.invoke(sessionKey, text, done, runId)
        }
    }

    private fun extractText(message: JSONObject): String {
        val content = message.opt("content")
        when (content) {
            is String -> return content
            is JSONArray -> {
                val parts = mutableListOf<String>()
                for (i in 0 until content.length()) {
                    val part = content.optJSONObject(i) ?: continue
                    val t = part.optString("text").ifBlank { part.optString("content") }
                    if (t.isNotBlank()) parts += t
                }
                return parts.joinToString("")
            }
        }
        return message.optString("text").ifBlank { message.optString("message") }
    }

    private fun failPending(error: Throwable) {
        pending.values.forEach { it.completeExceptionally(error) }
        pending.clear()
    }

    companion object {
        fun toWebSocketUrl(gatewayUrl: String): String {
            val trimmed = gatewayUrl.trim().trimEnd('/')
            return when {
                trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://")
                trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://")
                trimmed.startsWith("wss://") || trimmed.startsWith("ws://") -> trimmed
                else -> "wss://$trimmed"
            }
        }
    }
}
