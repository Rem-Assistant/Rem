package com.remapp.rem.voice

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

enum class TalkPhase {
    Off,
    Listening,
    Thinking,
    Speaking,
}

/**
 * Continuous listen (not hold-to-talk): SpeechRecognizer → transcript callback →
 * after reply, ElevenLabs/system TTS → listen again.
 */
class TalkModeManager(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val tts: RemTts,
) {
    @Volatile
    var enabled: Boolean = false
        private set

    @Volatile
    var muted: Boolean = false
        private set

    @Volatile
    private var phase: TalkPhase = TalkPhase.Off

    @Volatile
    private var ignoreUntilMs: Long = 0L

    @Volatile
    private var lastSpokenNorm: String = ""

    @Volatile
    private var restartAllowed: Boolean = true

    var onPhase: ((TalkPhase, partial: String) -> Unit)? = null
    var onFinalTranscript: ((String) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var speakJob: Job? = null

    fun start() {
        if (enabled) return
        if (!SpeechRecognizer.isRecognitionAvailable(appContext)) {
            onPhase?.invoke(TalkPhase.Off, "")
            return
        }
        enabled = true
        muted = false
        restartAllowed = true
        main.post {
            ensureRecognizer()
            setPhase(TalkPhase.Listening)
            startListeningInternal()
        }
    }

    fun stop() {
        enabled = false
        restartAllowed = false
        speakJob?.cancel()
        speakJob = null
        tts.stop()
        main.post {
            runCatching { recognizer?.stopListening() }
            runCatching { recognizer?.cancel() }
            runCatching { recognizer?.destroy() }
            recognizer = null
            setPhase(TalkPhase.Off)
        }
    }

    fun setMuted(value: Boolean) {
        muted = value
        if (!enabled) return
        if (value) {
            main.post {
                runCatching { recognizer?.stopListening() }
                runCatching { recognizer?.cancel() }
                if (phase == TalkPhase.Listening) {
                    onPhase?.invoke(TalkPhase.Listening, "(muted)")
                }
            }
        } else if (phase == TalkPhase.Listening || phase == TalkPhase.Off) {
            main.post {
                setPhase(TalkPhase.Listening)
                startListeningInternal()
            }
        }
    }

    /** Pause mic while a turn is in flight. */
    fun notifyThinking() {
        if (!enabled) return
        restartAllowed = false
        main.post {
            runCatching { recognizer?.stopListening() }
            runCatching { recognizer?.cancel() }
            setPhase(TalkPhase.Thinking)
        }
    }

    /** Speak assistant reply, then resume listening (unless stopped/muted). */
    fun speakThenListen(text: String) {
        if (!enabled) return
        val cleaned = text.trim()
        if (cleaned.isEmpty()) {
            resumeListeningAfterGap()
            return
        }
        speakJob?.cancel()
        speakJob = scope.launch {
            setPhase(TalkPhase.Speaking)
            main.post {
                runCatching { recognizer?.stopListening() }
                runCatching { recognizer?.cancel() }
            }
            try {
                tts.speak(cleaned)
            } catch (_: Exception) {
                // Still resume listening.
            }
            lastSpokenNorm = normalize(cleaned)
            ignoreUntilMs = System.currentTimeMillis() + ECHO_GUARD_MS
            if (enabled) resumeListeningAfterGap()
            else setPhase(TalkPhase.Off)
        }
    }

    private fun resumeListeningAfterGap() {
        scope.launch {
            delay(400)
            if (!enabled) return@launch
            restartAllowed = true
            if (muted) {
                setPhase(TalkPhase.Listening)
                onPhase?.invoke(TalkPhase.Listening, "(muted)")
            } else {
                main.post {
                    setPhase(TalkPhase.Listening)
                    startListeningInternal()
                }
            }
        }
    }

    private fun setPhase(next: TalkPhase, partial: String = "") {
        phase = next
        onPhase?.invoke(next, partial)
    }

    private fun ensureRecognizer() {
        if (recognizer != null) return
        val r = SpeechRecognizer.createSpeechRecognizer(appContext)
        r.setRecognitionListener(listener)
        recognizer = r
    }

    private fun startListeningInternal() {
        if (!enabled || muted || !restartAllowed) return
        if (phase == TalkPhase.Speaking || phase == TalkPhase.Thinking) return
        ensureRecognizer()
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, appContext.packageName)
        }
        runCatching {
            recognizer?.startListening(intent)
        }.onFailure {
            scheduleRestart(800)
        }
    }

    private fun scheduleRestart(delayMs: Long) {
        if (!enabled || muted) return
        main.postDelayed({
            if (enabled && !muted && restartAllowed &&
                (phase == TalkPhase.Listening || phase == TalkPhase.Off)
            ) {
                setPhase(TalkPhase.Listening)
                startListeningInternal()
            }
        }, delayMs)
    }

    private fun normalize(s: String): String =
        s.lowercase(Locale.getDefault()).replace(Regex("[^a-z0-9\\s]"), "").trim()

    private fun isEcho(transcript: String): Boolean {
        if (System.currentTimeMillis() < ignoreUntilMs) return true
        val n = normalize(transcript)
        if (n.isBlank()) return true
        if (lastSpokenNorm.isBlank()) return false
        if (n == lastSpokenNorm) return true
        if (lastSpokenNorm.contains(n) && n.length >= 8) return true
        if (n.contains(lastSpokenNorm) && lastSpokenNorm.length >= 8) return true
        return false
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit

        override fun onError(error: Int) {
            if (!enabled) return
            // Common end-of-utterance / no-speech → keep listening.
            when (error) {
                SpeechRecognizer.ERROR_CLIENT,
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                -> scheduleRestart(500)
                else -> scheduleRestart(350)
            }
        }

        override fun onResults(results: Bundle?) {
            if (!enabled || muted || phase == TalkPhase.Thinking || phase == TalkPhase.Speaking) {
                return
            }
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isBlank() || isEcho(text)) {
                scheduleRestart(300)
                return
            }
            restartAllowed = false
            setPhase(TalkPhase.Thinking, text)
            onFinalTranscript?.invoke(text)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (!enabled || muted || phase != TalkPhase.Listening) return
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isNotBlank()) {
                onPhase?.invoke(TalkPhase.Listening, text)
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    companion object {
        private const val ECHO_GUARD_MS = 1_200L
    }
}
