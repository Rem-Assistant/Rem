package com.remapp.rem.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.UUID

class SessionStore(context: Context) {
    private val prefs: SharedPreferences = openPrefs(context.applicationContext)

    var environment: AppEnvironment
        get() = AppEnvironment.fromStorage(prefs.getString(KEY_ENV, null))
        set(value) = prefs.edit { putString(KEY_ENV, value.storageKey) }

    var accessToken: String?
        get() = prefs.getString(KEY_TOKEN, null)
        set(value) = prefs.edit { putString(KEY_TOKEN, value) }

    var userId: String?
        get() = prefs.getString(KEY_USER_ID, null)
        set(value) = prefs.edit { putString(KEY_USER_ID, value) }

    var userName: String?
        get() = prefs.getString(KEY_USER_NAME, null)
        set(value) = prefs.edit { putString(KEY_USER_NAME, value) }

    var userEmail: String?
        get() = prefs.getString(KEY_USER_EMAIL, null)
        set(value) = prefs.edit { putString(KEY_USER_EMAIL, value) }

    var gatewayUrl: String?
        get() = prefs.getString(KEY_GATEWAY_URL, null)
        set(value) = prefs.edit { putString(KEY_GATEWAY_URL, value) }

    var gatewayToken: String?
        get() = prefs.getString(KEY_GATEWAY_TOKEN, null)
        set(value) = prefs.edit { putString(KEY_GATEWAY_TOKEN, value) }

    var elevenLabsApiKey: String?
        get() = prefs.getString(KEY_ELEVENLABS, null)
        set(value) = prefs.edit { putString(KEY_ELEVENLABS, value) }

    var hasSeenPermissionsOnboarding: Boolean
        get() = prefs.getBoolean(KEY_SEEN_PERMISSIONS, false)
        set(value) = prefs.edit { putBoolean(KEY_SEEN_PERMISSIONS, value) }

    var hasSeenMemoryCapture: Boolean
        get() = prefs.getBoolean(KEY_SEEN_MEMORY_CAPTURE, false)
        set(value) = prefs.edit { putBoolean(KEY_SEEN_MEMORY_CAPTURE, value) }

    fun deviceId(context: Context): String {
        val existing = prefs.getString(KEY_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) return existing
        val androidId = android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        )
        val id = "android-${androidId.orEmpty()}-${UUID.randomUUID()}".take(64)
        prefs.edit { putString(KEY_DEVICE_ID, id) }
        return id
    }

    fun saveAuth(result: AuthResult) {
        accessToken = result.accessToken
        userId = result.user.id
        userName = result.user.fullName
        userEmail = result.user.email
    }

    fun saveGateway(creds: GatewayCredentials) {
        gatewayUrl = creds.gatewayUrl
        gatewayToken = creds.gatewayToken
        if (!creds.elevenLabsApiKey.isNullOrBlank()) {
            elevenLabsApiKey = creds.elevenLabsApiKey
        }
    }

    /** Clears auth + gateway for env switch. Keeps device id, env, and onboarding flags. */
    fun clearSession() {
        val device = prefs.getString(KEY_DEVICE_ID, null)
        val env = environment.storageKey
        val seenPerms = hasSeenPermissionsOnboarding
        val seenMemory = hasSeenMemoryCapture
        prefs.edit { clear() }
        prefs.edit {
            if (device != null) putString(KEY_DEVICE_ID, device)
            putString(KEY_ENV, env)
            putBoolean(KEY_SEEN_PERMISSIONS, seenPerms)
            putBoolean(KEY_SEEN_MEMORY_CAPTURE, seenMemory)
        }
    }

    fun clear() = clearSession()

    val isSignedIn: Boolean
        get() = !accessToken.isNullOrBlank()

    companion object {
        private const val TAG = "SessionStore"
        private const val PREFS_NAME = "rem_secure_session"
        private const val KEY_ENV = "backend.environment"
        private const val KEY_TOKEN = "backend.token"
        private const val KEY_USER_ID = "user.id"
        private const val KEY_USER_NAME = "user.name"
        private const val KEY_USER_EMAIL = "user.email"
        private const val KEY_GATEWAY_URL = "gateway.url"
        private const val KEY_GATEWAY_TOKEN = "gateway.token"
        private const val KEY_ELEVENLABS = "elevenlabs.api_key"
        private const val KEY_DEVICE_ID = "device.id"
        private const val KEY_SEEN_PERMISSIONS = "onboarding.permissions.v1"
        private const val KEY_SEEN_MEMORY_CAPTURE = "onboarding.memory.v1"

        private fun openPrefs(context: Context): SharedPreferences {
            return try {
                createEncrypted(context)
            } catch (first: Exception) {
                Log.w(TAG, "Encrypted session prefs unreadable; wiping and recreating", first)
                wipeEncryptedArtifacts(context)
                try {
                    createEncrypted(context)
                } catch (second: Exception) {
                    Log.e(TAG, "Encrypted prefs still failing; falling back to plain prefs", second)
                    wipeEncryptedArtifacts(context)
                    context.getSharedPreferences("${PREFS_NAME}_fallback", Context.MODE_PRIVATE)
                }
            }
        }

        private fun createEncrypted(context: Context): SharedPreferences {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }

        private fun wipeEncryptedArtifacts(context: Context) {
            runCatching { context.deleteSharedPreferences(PREFS_NAME) }
            // Tink / EncryptedSharedPreferences companion keyset files (name variants).
            runCatching {
                context.deleteSharedPreferences("__androidx_security_crypto_encrypted_prefs_key_keyset__$PREFS_NAME")
            }
            runCatching {
                context.deleteSharedPreferences("__androidx_security_crypto_encrypted_prefs_value_keyset__$PREFS_NAME")
            }
            runCatching {
                val dir = context.filesDir?.parentFile
                dir?.listFiles()?.forEach { file ->
                    if (file.name.contains("rem_secure_session") ||
                        file.name.contains("androidx_security_crypto")
                    ) {
                        file.delete()
                    }
                }
            }
            runCatching {
                val sharedPrefsDir = context.applicationInfo.dataDir + "/shared_prefs"
                java.io.File(sharedPrefsDir).listFiles()?.forEach { file ->
                    if (file.name.contains("rem_secure_session") ||
                        file.name.contains("androidx_security_crypto")
                    ) {
                        file.delete()
                    }
                }
            }
        }
    }
}
