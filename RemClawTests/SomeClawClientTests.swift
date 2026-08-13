import Foundation
import Testing
@testable import RemClaw

struct SomeClawEventDecoderTests {

    // MARK: - Status

    @Test func decodesStatusEvent() {
        let json = #"{"type":"status","session_id":"sid","state":"thinking"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .status(sessionId: "sid", state: "thinking"))
    }

    // MARK: - Chunks

    @Test func decodesChunkInProgress() {
        let json = #"{"type":"chunk","session_id":"sid","text":"Hel","done":false}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .chunk(sessionId: "sid", text: "Hel", done: false))
    }

    @Test func decodesChunkFinal() {
        let json = #"{"type":"chunk","session_id":"sid","text":"!","done":true}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .chunk(sessionId: "sid", text: "!", done: true))
    }

    // MARK: - Response

    @Test func decodesFinalResponse() {
        let json = #"{"type":"response","session_id":"sid","text":"Hi!","done":true}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .response(sessionId: "sid", text: "Hi!", done: true))
    }

    // MARK: - Errors (relay sometimes uses `error` key, sometimes `text`)

    @Test func decodesErrorWithTextField() {
        let json = #"{"type":"error","session_id":"sid","text":"boom"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .errorEvent(sessionId: "sid", text: "boom"))
    }

    @Test func decodesErrorWithErrorField() {
        let json = #"{"type":"error","error":"upstream failure"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .errorEvent(sessionId: nil, text: "upstream failure"))
    }

    @Test func decodesErrorMissingBodyFallsBackToUnknown() {
        let json = #"{"type":"error"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .errorEvent(sessionId: nil, text: "Unknown error"))
    }

    // MARK: - Sessions

    @Test func decodesSessionsAsStringArray() {
        let json = #"{"type":"sessions","sessions":["a","b","c"]}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .sessions(ids: ["a", "b", "c"]))
    }

    @Test func decodesSessionsAsObjectArray() {
        let json = #"{"type":"sessions","sessions":[{"id":"a"},{"id":"b"}]}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .sessions(ids: ["a", "b"]))
    }

    // MARK: - Unknown / malformed

    @Test func decodesUnknownTypeAsUnknown() {
        let json = #"{"type":"thinking"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == .unknown(type: "thinking"))
    }

    @Test func returnsNilForMissingType() {
        let json = #"{"session_id":"sid"}"#.data(using: .utf8) ?? Data()
        let event = SomeClawEventDecoder.decode(json)
        #expect(event == nil)
    }

    @Test func returnsNilForGarbage() {
        let event = SomeClawEventDecoder.decode(Data("not json".utf8))
        #expect(event == nil)
    }
}

@MainActor
struct SomeClawChatViewModelTests {

    // MARK: - Helpers

    private func makeViewModel() -> SomeClawChatViewModel {
        let url = URL(string: "wss://example.test/ws") ?? URL(fileURLWithPath: "/")
        let client = SomeClawClient(endpoint: url)
        return SomeClawChatViewModel(client: client, sessionId: "test-session")
    }

    // MARK: - Streaming behavior

    @Test func streamingChunksAccumulateIntoSingleBubble() {
        let vm = makeViewModel()

        vm.apply(.status(sessionId: "test-session", state: "thinking"))
        #expect(vm.isThinking == true)

        vm.apply(.chunk(sessionId: "test-session", text: "Hello", done: false))
        vm.apply(.chunk(sessionId: "test-session", text: ", ", done: false))
        vm.apply(.chunk(sessionId: "test-session", text: "world", done: true))

        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.text == "Hello, world")
        #expect(vm.messages.first?.role == .assistant)
        #expect(vm.messages.first?.isStreaming == false)
        #expect(vm.isThinking == false)
    }

    @Test func responseAfterChunksKeepsStreamedText() {
        let vm = makeViewModel()
        vm.apply(.chunk(sessionId: "test-session", text: "partial", done: false))
        vm.apply(.response(sessionId: "test-session", text: "different final", done: true))

        // Final response should not overwrite streamed text — the user has
        // already been reading the streamed buffer.
        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.text == "partial")
        #expect(vm.messages.first?.isStreaming == false)
        #expect(vm.isThinking == false)
    }

    @Test func responseWithoutPriorStreamCreatesBubble() {
        let vm = makeViewModel()
        vm.apply(.response(sessionId: "test-session", text: "ok", done: true))

        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.text == "ok")
        #expect(vm.messages.first?.role == .assistant)
        #expect(vm.isThinking == false)
    }

    // MARK: - Error handling

    @Test func errorAppendsErrorBubbleAndStopsThinking() {
        let vm = makeViewModel()
        vm.apply(.status(sessionId: "test-session", state: "thinking"))

        vm.apply(.errorEvent(sessionId: "test-session", text: "boom"))

        #expect(vm.lastErrorMessage == "boom")
        #expect(vm.isThinking == false)
        #expect(vm.messages.last?.role == .errorEvent)
        #expect(vm.messages.last?.text == "boom")
    }

    @Test func serverLevelErrorWithoutSessionIdIsRouted() {
        let vm = makeViewModel()
        vm.apply(.errorEvent(sessionId: nil, text: "upstream failure"))

        #expect(vm.lastErrorMessage == "upstream failure")
        #expect(vm.messages.last?.role == .errorEvent)
    }

    // MARK: - Cross-session isolation (#94 review)

    @Test func eventsForOtherSessionAreIgnored() {
        let vm = makeViewModel()
        vm.apply(.status(sessionId: "test-session", state: "thinking"))
        #expect(vm.isThinking == true)

        // Streamed bytes from a *different* session should not leak into the
        // active chat — the relay multiplexes sessions on one socket.
        vm.apply(.status(sessionId: "other-session", state: "thinking"))
        vm.apply(.chunk(sessionId: "other-session", text: "leak", done: false))
        vm.apply(.response(sessionId: "other-session", text: "also leak", done: true))
        vm.apply(.errorEvent(sessionId: "other-session", text: "their error"))

        #expect(vm.messages.isEmpty)
        #expect(vm.lastErrorMessage == nil)
        // The active session's `thinking` flag should not be cleared by
        // another session's terminal events.
        #expect(vm.isThinking == true)
    }

    // MARK: - Local clear

    @Test func clearLocallyResetsState() {
        let vm = makeViewModel()
        vm.apply(.chunk(sessionId: "test-session", text: "hi", done: true))
        #expect(vm.messages.count == 1)

        vm.clearLocally()
        #expect(vm.messages.isEmpty)
        #expect(vm.isThinking == false)
        #expect(vm.lastErrorMessage == nil)
    }
}
