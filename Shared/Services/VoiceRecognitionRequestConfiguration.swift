import Speech

/// Shared request policy for Rem's iOS and macOS speech-to-text pipelines.
///
/// Keep recognizer behavior here so spoken chat messages have the same transcription semantics
/// on both platforms. Punctuation comes from Apple's recognizer; Rem does not guess or rewrite it.
enum VoiceRecognitionRequestConfiguration {
    static func apply(to request: SFSpeechAudioBufferRecognitionRequest) {
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        request.addsPunctuation = true
    }
}
