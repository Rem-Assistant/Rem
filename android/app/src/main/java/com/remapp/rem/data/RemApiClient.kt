package com.remapp.rem.data

import com.remapp.rem.BuildConfig
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class RemApiClient(
    private val store: SessionStore,
    private val clientVersion: String = BuildConfig.CLIENT_VERSION,
) {
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private val http = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(90, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    private val baseUrl: String
        get() = store.environment.baseUrl

    fun loginWithGoogle(idToken: String, email: String?, name: String?): AuthResult {
        val body = JSONObject()
            .put("provider", "google")
            .put("id_token", idToken)
            .put(
                "profile",
                JSONObject()
                    .put("email", email)
                    .put("name", name)
                    .put("full_name", name),
            )
        return parseAuth(post("/api/v1/auth/login", body, auth = false))
    }

    fun loginWithDevice(deviceId: String): AuthResult {
        val body = JSONObject().put("device_id", deviceId)
        return parseAuth(post("/api/v1/auth/device", body, auth = false))
    }

    fun refresh(token: String): String {
        val json = post("/api/v1/auth/refresh", JSONObject(), bearerOverride = token, auth = false)
        return json.getString("access_token")
    }

    fun deleteAccount() {
        delete("/api/v1/auth/me")
    }

    fun getCredentials(): GatewayCredentials? {
        return try {
            val json = get("/api/v1/me/credentials")
            GatewayCredentials(
                gatewayUrl = json.getString("gatewayUrl"),
                gatewayToken = json.getString("gatewayToken"),
                hostingProvider = json.optString("hostingProvider").ifBlank { null },
                elevenLabsApiKey = json.optString("elevenLabsApiKey").ifBlank { null },
            )
        } catch (e: ApiException) {
            if (e.statusCode == 404) null else throw e
        }
    }

    fun wakeGateway(): JSONObject = post("/api/v1/gateway/wake", JSONObject())

    fun approveDevice(): JSONObject = post("/api/v1/approve-device", JSONObject())

    fun fetchComposioToolkits(): Pair<Boolean, List<ComposioToolkit>> {
        val json = get("/api/v1/composio/toolkits")
        val configured = json.optBoolean("configured", true)
        val arr = json.optJSONArray("toolkits") ?: JSONArray()
        val list = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            ComposioToolkit(
                slug = o.optString("slug"),
                logoUrl = o.optString("logoUrl").ifBlank { null },
                status = o.optString("status").ifBlank { "not_connected" },
                enabled = if (o.has("enabled")) o.optBoolean("enabled", true) else true,
            ).takeIf { it.slug.isNotBlank() }
        }
        return configured to list
    }

    fun connectComposio(toolkit: String, callbackUrl: String? = null): ComposioConnectSession {
        val body = JSONObject().put("toolkit", toolkit)
        if (!callbackUrl.isNullOrBlank()) body.put("callbackUrl", callbackUrl)
        val json = post("/api/v1/composio/connect", body)
        return ComposioConnectSession(
            redirectUrl = json.getString("redirectUrl"),
            connectionId = json.getString("connectionId"),
            toolkit = json.optString("toolkit").ifBlank { toolkit },
        )
    }

    fun composioStatus(connectionId: String, toolkit: String): ComposioConnectionState {
        val id = java.net.URLEncoder.encode(connectionId, Charsets.UTF_8.name())
        val tk = java.net.URLEncoder.encode(toolkit, Charsets.UTF_8.name())
        val json = get("/api/v1/composio/status/$id?toolkit=$tk")
        return ComposioConnectionState(
            toolkit = json.optString("toolkit").ifBlank { null },
            status = json.optString("status").ifBlank { "unknown" },
            connectedAccountId = json.optString("connectedAccountId").ifBlank { null },
            enabled = if (json.has("enabled")) json.optBoolean("enabled", true) else true,
        )
    }

    fun disconnectComposio(toolkit: String) {
        val slug = java.net.URLEncoder.encode(toolkit, Charsets.UTF_8.name())
        delete("/api/v1/composio/toolkit/$slug/connections")
    }

    fun setComposioEnabled(toolkit: String, enabled: Boolean) {
        val slug = java.net.URLEncoder.encode(toolkit, Charsets.UTF_8.name())
        post("/api/v1/composio/toolkit/$slug/enabled", JSONObject().put("enabled", enabled))
    }

    fun fetchChannels(): List<RemChannel> {
        val json = get("/api/v1/channels")
        val arr = json.optJSONArray("channels") ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            RemChannel(
                provider = o.optString("provider"),
                name = o.optString("name").ifBlank { o.optString("provider") },
                icon = o.optString("icon").ifBlank { null },
                wired = o.optBoolean("wired", false),
                connect = o.optString("connect").ifBlank { "none" },
                hint = o.optString("hint"),
                status = o.optString("status").ifBlank { "available" },
                hasCredential = o.optBoolean("hasCredential", false),
                updatedAt = o.optString("updated_at").ifBlank {
                    o.optString("updatedAt").ifBlank { null }
                },
            ).takeIf { it.provider.isNotBlank() }
        }
    }

    fun connectChannel(provider: String, token: String = ""): RemChannel {
        val body = if (token.isBlank()) JSONObject() else JSONObject().put("token", token)
        return post("/api/v1/channels/$provider/connect", body).toChannel()
    }

    fun disconnectChannel(provider: String): RemChannel =
        post("/api/v1/channels/$provider/disconnect", JSONObject()).toChannel()

    fun fetchMemories(): List<UserMemory> {
        val json = get("/api/v1/memory")
        val arr = json.optJSONArray("memories") ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            arr.optJSONObject(i)?.toUserMemory()
        }
    }

    fun addMemory(fact: String, source: String? = null): UserMemory {
        val body = JSONObject().put("fact", fact)
        if (!source.isNullOrBlank()) body.put("source", source)
        return post("/api/v1/memory", body).toUserMemory()
    }

    fun updateMemory(id: String, fact: String): UserMemory =
        patch("/api/v1/memory/$id", JSONObject().put("fact", fact)).toUserMemory()

    fun deleteMemory(id: String) {
        delete("/api/v1/memory/$id")
    }

    fun startDeploy(): DeployStatus {
        val json = post("/api/v1/deploy", JSONObject())
        val status = json.optJSONObject("status") ?: json
        return parseDeploy(status, json.optString("deployId"))
    }

    fun getDeployStatus(deployId: String): DeployStatus {
        val json = get("/api/v1/deploy/status?id=$deployId")
        return parseDeploy(json, deployId)
    }

    fun fetchTasks(limit: Int = 200, offset: Int = 0): List<RemTask> {
        val json = get("/api/v1/tasks?limit=$limit&offset=$offset")
        val arr = json.optJSONArray("tasks") ?: JSONArray()
        return (0 until arr.length()).mapNotNull { i ->
            arr.optJSONObject(i)?.toRemTask()
        }
    }

    fun createTask(title: String, status: String = "pending", priority: String = "medium"): RemTask {
        val body = JSONObject()
            .put("title", title)
            .put("status", status)
            .put("priority", priority)
        return post("/api/v1/tasks", body).toRemTask()
    }

    fun getTask(id: String): RemTask = get("/api/v1/tasks/$id").toRemTask()

    fun updateTask(
        id: String,
        title: String? = null,
        status: String? = null,
        priority: String? = null,
        startDate: String? = null,
    ): RemTask {
        val body = JSONObject()
        if (title != null) body.put("title", title)
        if (status != null) body.put("status", status)
        if (priority != null) body.put("priority", priority)
        if (startDate != null) body.put("start_date", startDate)
        return patch("/api/v1/tasks/$id", body).toRemTask()
    }

    fun deleteTask(id: String) {
        delete("/api/v1/tasks/$id")
    }

    fun fetchBrief(): DailyBrief? {
        return try {
            get("/api/v1/brief").toDailyBrief()
        } catch (e: ApiException) {
            if (e.statusCode == 404) null else throw e
        }
    }

    fun fetchSuggestions(): List<TaskSuggestion> {
        return try {
            val json = get("/api/v1/suggestions")
            val arr = json.optJSONArray("suggestions") ?: JSONArray()
            (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.toTaskSuggestion()
            }
        } catch (e: ApiException) {
            if (e.statusCode == 404) emptyList() else throw e
        }
    }

    fun dismissSuggestion(key: String) {
        val encoded = java.net.URLEncoder.encode(key, Charsets.UTF_8.name())
            .replace("+", "%20")
        post("/api/v1/suggestions/$encoded/dismiss", JSONObject())
    }

    fun fetchUsageSummary(): UsageSummary = get("/api/v1/usage/summary").toUsageSummary()

    /** Consumes one request slot. Throws [QuotaExceededException] on HTTP 429. */
    fun consumeUsage(): UsageSummary {
        return try {
            post("/api/v1/usage/consume", JSONObject()).toUsageSummary(fromConsume = true)
        } catch (e: ApiException) {
            if (e.statusCode == 429) {
                val remaining = e.details?.optJSONObject("remaining")
                throw QuotaExceededException(
                    message = e.message ?: "Daily or monthly quota exceeded",
                    remainingDay = remaining?.optInt("day"),
                    remainingMonth = remaining?.optInt("month"),
                )
            }
            throw e
        }
    }

    private fun parseDeploy(json: JSONObject, fallbackId: String): DeployStatus =
        DeployStatus(
            id = json.optString("id").ifBlank { fallbackId },
            phase = json.optString("phase"),
            message = json.optString("message").ifBlank { null },
            gatewayUrl = json.optString("gatewayUrl").ifBlank { null },
            gatewayToken = json.optString("gatewayToken").ifBlank { null },
        )

    private fun parseAuth(json: JSONObject): AuthResult {
        val user = json.getJSONObject("user")
        return AuthResult(
            accessToken = json.getString("access_token"),
            user = RemUser(
                id = user.getString("id"),
                email = user.optString("email").ifBlank { null },
                fullName = user.optString("full_name").ifBlank {
                    user.optString("name").ifBlank { null }
                },
            ),
            isNewUser = json.optBoolean("is_new_user"),
        )
    }

    private fun JSONObject.toRemTask(): RemTask =
        RemTask(
            id = getString("id"),
            title = optString("title"),
            status = optString("status").ifBlank { null },
            priority = optString("priority").ifBlank { null },
            startDate = optString("start_date").ifBlank { null },
            endDate = optString("end_date").ifBlank { null },
            type = optString("type").ifBlank { null },
            listId = optString("list_id").ifBlank { null },
            runStatus = optString("run_status").ifBlank { null },
        )

    private fun JSONObject.toDailyBrief(): DailyBrief {
        val countsObj = optJSONObject("counts") ?: JSONObject()
        fun items(key: String): List<BriefItem> {
            val arr = optJSONArray(key) ?: JSONArray()
            return (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.toBriefItem()
            }
        }
        return DailyBrief(
            generatedAt = optString("generated_at").ifBlank { null },
            counts = BriefCounts(
                blocked = countsObj.optInt("blocked"),
                overdue = countsObj.optInt("overdue"),
                scheduledToday = countsObj.optInt("scheduled_today"),
                completedToday = countsObj.optInt("completed_today"),
                total = countsObj.optInt("total"),
                done = countsObj.optInt("done"),
            ),
            blocked = items("blocked"),
            overdue = items("overdue"),
            scheduledToday = items("scheduled_today"),
            completedToday = items("completed_today"),
            summary = optString("summary").ifBlank { null },
            markdown = optString("markdown").ifBlank { null },
            briefSessionKey = optString("brief_session_key").ifBlank { null },
        )
    }

    private fun JSONObject.toBriefItem(): BriefItem {
        val activity = optJSONObject("latest_activity")
        return BriefItem(
            id = getString("id"),
            title = optString("title"),
            status = optString("status").ifBlank { null },
            priority = optString("priority").ifBlank { null },
            runStatus = optString("run_status").ifBlank { null },
            startDate = optString("start_date").ifBlank { null },
            type = optString("type").ifBlank { "task" },
            bucket = optString("bucket").ifBlank { "" },
            latestActivitySummary = activity?.optString("summary")?.ifBlank { null },
        )
    }

    private fun JSONObject.toUsageSummary(fromConsume: Boolean = false): UsageSummary {
        val limits = optJSONObject("limits")
        val usage = optJSONObject("usage")
        val remaining = optJSONObject("remaining")
        return UsageSummary(
            plan = optString("plan").ifBlank { null },
            status = optString("status").ifBlank { null },
            requestsPerDay = limits?.optInt("requestsPerDay"),
            requestsPerMonth = limits?.optInt("requestsPerMonth"),
            modelTier = limits?.optString("modelTier")?.ifBlank { null },
            usedDay = usage?.optInt("day"),
            usedMonth = usage?.optInt("month"),
            remainingDay = remaining?.optInt("day"),
            remainingMonth = remaining?.optInt("month"),
            allowed = if (has("allowed")) optBoolean("allowed", true) else true,
            reason = optString("reason").ifBlank { null },
            quotaCycleStartedAt = optString("quotaCycleStartedAt").ifBlank { null },
        ).let { summary ->
            // Consume responses omit plan/limits; keep remaining/usage only.
            if (fromConsume) summary else summary
        }
    }

    private fun JSONObject.toChannel(): RemChannel =
        RemChannel(
            provider = optString("provider"),
            name = optString("name").ifBlank { optString("provider") },
            icon = optString("icon").ifBlank { null },
            wired = optBoolean("wired", false),
            connect = optString("connect").ifBlank { "none" },
            hint = optString("hint"),
            status = optString("status").ifBlank { "available" },
            hasCredential = optBoolean("hasCredential", false),
            updatedAt = optString("updated_at").ifBlank {
                optString("updatedAt").ifBlank { null }
            },
        )

    private fun JSONObject.toUserMemory(): UserMemory =
        UserMemory(
            id = getString("id"),
            fact = optString("fact"),
            source = optString("source").ifBlank { null },
            createdAt = optString("created_at").ifBlank { null },
            updatedAt = optString("updated_at").ifBlank { null },
        )

    private fun JSONObject.toTaskSuggestion(): TaskSuggestion {
        val action = optJSONObject("action") ?: JSONObject()
        return TaskSuggestion(
            key = getString("key"),
            source = optString("source"),
            title = optString("title"),
            subtitle = optString("subtitle"),
            actionKind = action.optString("kind"),
            actionTaskTitle = action.optString("taskTitle").ifBlank { null },
            actionTargetTaskId = action.optString("targetTaskId").ifBlank { null },
            actionStartDate = action.optString("startDate").ifBlank { null },
        )
    }

    private fun get(path: String): JSONObject =
        executeAuthed(Request.Builder().url(baseUrl + path).get())

    private fun post(
        path: String,
        body: JSONObject,
        auth: Boolean = true,
        bearerOverride: String? = null,
    ): JSONObject {
        val builder = Request.Builder()
            .url(baseUrl + path)
            .post(body.toString().toRequestBody(jsonMedia))
        return if (auth) executeAuthed(builder) else execute(builder.headers(commonHeaders(bearerOverride)).build())
    }

    private fun patch(path: String, body: JSONObject): JSONObject =
        executeAuthed(
            Request.Builder()
                .url(baseUrl + path)
                .patch(body.toString().toRequestBody(jsonMedia)),
        )

    private fun delete(path: String): JSONObject =
        executeAuthed(Request.Builder().url(baseUrl + path).delete())

    private fun executeAuthed(builder: Request.Builder): JSONObject {
        val token = store.accessToken
            ?: throw ApiException(401, "Not signed in")
        return execute(builder.headers(commonHeaders(token)).build())
    }

    private fun execute(request: Request): JSONObject {
        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (response.code == 401 && store.accessToken != null &&
                !request.url.encodedPath.contains("/auth/refresh")
            ) {
                val old = store.accessToken!!
                val fresh = runCatching { refresh(old) }.getOrNull()
                if (!fresh.isNullOrBlank()) {
                    store.accessToken = fresh
                    val retry = request.newBuilder()
                        .header("Authorization", "Bearer $fresh")
                        .build()
                    return execute(retry)
                }
            }
            if (!response.isSuccessful) {
                val body = runCatching { JSONObject(text) }.getOrNull()
                val errorNode = body?.opt("error")
                val message = when (errorNode) {
                    is JSONObject -> errorNode.optString("message").ifBlank {
                        errorNode.optString("type")
                    }
                    is String -> errorNode
                    else -> null
                }?.takeIf { it.isNotBlank() }
                val details = when (errorNode) {
                    is JSONObject -> errorNode
                    else -> body
                }
                throw ApiException(
                    statusCode = response.code,
                    message = message ?: text.ifBlank { response.message },
                    details = details,
                )
            }
            if (text.isBlank()) return JSONObject()
            return JSONObject(text)
        }
    }

    private fun commonHeaders(bearer: String?): okhttp3.Headers {
        val builder = okhttp3.Headers.Builder()
            .add("Content-Type", "application/json")
            .add("X-Client-Version", clientVersion)
            .add("X-Client-Platform", "android")
        if (!bearer.isNullOrBlank()) {
            builder.add("Authorization", "Bearer $bearer")
        }
        return builder.build()
    }
}

class ApiException(
    val statusCode: Int,
    message: String,
    val details: JSONObject? = null,
) : Exception(message)
