import Speech
import Testing
@testable import Rem

struct VoiceRecognitionRequestConfigurationTests {
    @Test func configuresDictationWithAutomaticPunctuation() {
        let request = SFSpeechAudioBufferRecognitionRequest()

        VoiceRecognitionRequestConfiguration.apply(to: request)

        #expect(request.shouldReportPartialResults)
        #expect(request.requiresOnDeviceRecognition == false)
        #expect(request.taskHint == .dictation)
        #expect(request.addsPunctuation)
    }
}
