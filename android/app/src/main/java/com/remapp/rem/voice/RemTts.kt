package com.remapp.rem.voice

import android.content.Context
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Speaks Rem’s reply aloud.
 * Prefers ElevenLabs HTTP TTS; falls back to Android system TTS.
 */
class RemTts(private val context: Context) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    @Volatile
    var apiKey: String? = null

    @Volatile
    var voiceId: String = DEFAULT_VOICE_ID

    @Volatile
    var modelId: String = DEFAULT_MODEL_ID

    private var mediaPlayer: MediaPlayer? = null
    private var systemTts: TextToSpeech? = null
    private var systemReady = false

    suspend fun speak(text: String) {
        val cleaned = text.trim()
        if (cleaned.isEmpty()) return
        stop()
        val key = apiKey
        if (!key.isNullOrBlank()) {
            try {
                speakElevenLabs(cleaned, key)
                return
            } catch (_: Exception) {
                // Fall through to system TTS.
            }
        }
        speakSystem(cleaned)
    }

    fun stop() {
        runCatching {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        }
        mediaPlayer = null
        systemTts?.stop()
    }

    fun release() {
        stop()
        systemTts?.shutdown()
        systemTts = null
        systemReady = false
    }

    private suspend fun speakElevenLabs(text: String, key: String) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("text", text)
            .put("model_id", modelId)
            .toString()
            .toRequestBody("application/json".toMediaType())
        val url =
            "https://api.elevenlabs.io/v1/text-to-speech/$voiceId?output_format=mp3_44100_128"
        val req = Request.Builder()
            .url(url)
            .addHeader("xi-api-key", key)
            .addHeader("Accept", "audio/mpeg")
            .post(body)
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                throw IllegalStateException("ElevenLabs ${resp.code}: ${resp.message}")
            }
            val bytes = resp.body?.bytes() ?: throw IllegalStateException("Empty TTS body")
            val file = File.createTempFile("rem-tts-", ".mp3", context.cacheDir)
            file.writeBytes(bytes)
            try {
                playFile(file)
            } finally {
                file.delete()
            }
        }
    }

    private suspend fun playFile(file: File) = suspendCancellableCoroutine { cont ->
        val player = MediaPlayer()
        mediaPlayer = player
        cont.invokeOnCancellation {
            runCatching {
                player.stop()
                player.release()
            }
            if (mediaPlayer === player) mediaPlayer = null
        }
        try {
            player.setDataSource(file.absolutePath)
            player.setOnCompletionListener {
                runCatching { player.release() }
                if (mediaPlayer === player) mediaPlayer = null
                if (cont.isActive) cont.resume(Unit)
            }
            player.setOnErrorListener { _, _, _ ->
                runCatching { player.release() }
                if (mediaPlayer === player) mediaPlayer = null
                if (cont.isActive) cont.resumeWithException(IllegalStateException("MediaPlayer error"))
                true
            }
            player.prepare()
            player.start()
        } catch (e: Exception) {
            runCatching { player.release() }
            if (mediaPlayer === player) mediaPlayer = null
            if (cont.isActive) cont.resumeWithException(e)
        }
    }

    private suspend fun speakSystem(text: String) {
        ensureSystemTts()
        val engine = systemTts ?: return
        suspendCancellableCoroutine { cont ->
            val id = "rem-${System.currentTimeMillis()}"
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) {
                    if (utteranceId == id && cont.isActive) cont.resume(Unit)
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    if (utteranceId == id && cont.isActive) {
                        cont.resumeWithException(IllegalStateException("System TTS error"))
                    }
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    if (utteranceId == id && cont.isActive) {
                        cont.resumeWithException(IllegalStateException("System TTS error $errorCode"))
                    }
                }
            })
            cont.invokeOnCancellation { engine.stop() }
            val ok = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
            if (ok == TextToSpeech.ERROR && cont.isActive) {
                cont.resumeWithException(IllegalStateException("System TTS failed to start"))
            }
        }
    }

    private suspend fun ensureSystemTts() = suspendCancellableCoroutine { cont ->
        if (systemReady && systemTts != null) {
            cont.resume(Unit)
            return@suspendCancellableCoroutine
        }
        var settled = false
        systemTts = TextToSpeech(context) { status ->
            if (settled) return@TextToSpeech
            settled = true
            if (status == TextToSpeech.SUCCESS) {
                systemTts?.language = Locale.getDefault()
                systemReady = true
                if (cont.isActive) cont.resume(Unit)
            } else if (cont.isActive) {
                cont.resumeWithException(IllegalStateException("System TTS unavailable"))
            }
        }
    }

    companion object {
        const val DEFAULT_VOICE_ID = "k7KSpqhTjZbrCkUR76Ip"
        const val DEFAULT_MODEL_ID = "eleven_multilingual_v2"
    }
}
