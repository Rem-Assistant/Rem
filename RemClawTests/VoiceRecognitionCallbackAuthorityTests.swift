import Testing
@testable import RemClaw

struct VoiceRecognitionCallbackAuthorityTests {
    @Test func currentRecognizerCallbackMayMutateVoiceState() {
        #expect(VoiceRecognitionCallbackAuthority.canHandle(
            capturedGeneration: 9,
            currentGeneration: 9
        ))
    }

    @Test func callbackFromRecognizerRetiredByTTSCompletionFailsClosed() {
        #expect(!VoiceRecognitionCallbackAuthority.canHandle(
            capturedGeneration: 9,
            currentGeneration: 10
        ))
    }

    @Test func callbackFromRecognizerReplacedForNextListeningTurnFailsClosed() {
        #expect(!VoiceRecognitionCallbackAuthority.canHandle(
            capturedGeneration: 10,
            currentGeneration: 11
        ))
    }

    @Test @MainActor
    func deferredMutationRechecksAuthorityAfterInvalidation() async {
        let capturedGeneration: UInt64 = 41
        var currentGeneration = capturedGeneration

        #expect(VoiceRecognitionCallbackAuthority.canHandle(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration
        ))

        // Model stopRecognition retiring the recognizer while its callback waits for MainActor.
        currentGeneration &+= 1
        await Task.yield()

        #expect(!VoiceRecognitionCallbackAuthority.canHandle(
            capturedGeneration: capturedGeneration,
            currentGeneration: currentGeneration
        ))
    }
}
