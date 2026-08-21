package com.remapp.rem.voice

/** Matches iOS TalkPromptBuilder’s spoken-tone wrap for gateway chat.send. */
object TalkPrompt {
    fun wrap(transcript: String): String =
        """
        |Talk Mode active. Reply in a concise, spoken tone.
        |You may optionally prefix the response with JSON voice directives, e.g. {"voice":"<id>","once":true}.
        |
        |${transcript.trim()}
        """.trimMargin()

    fun stripForDisplay(text: String): String {
        val marker = "\"once\":true}."
        val idx = text.indexOf(marker)
        if (idx >= 0) {
            return text.substring(idx + marker.length).trim()
        }
        if (text.startsWith("Talk Mode active.")) {
            return text.lineSequence().lastOrNull { it.isNotBlank() }?.trim() ?: text
        }
        return text
    }
}
