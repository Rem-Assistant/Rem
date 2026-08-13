import Foundation
import Testing
@testable import RemClaw

/// Tests for `IncrementalSpeechBuffer` — the pure segment/flush logic that decides which
/// text the voice pipeline speaks aloud. Guards the fix for #1092 (spoken ElevenLabs reply
/// truncated mid-reply while the on-screen text was complete).
///
/// Three failure modes are covered:
///  1. A final flush must speak EVERY remaining sentence, not just up to the last boundary.
///  2. Reconciling against the authoritative complete text must recover a tail that the
///     streaming subscription missed — without re-speaking already-voiced text.
///  3. When the authoritative text DIVERGES from the streamed text inside the already-spoken
///     region (whitespace / markdown / normalization) — including LENGTH-changing reformats that
///     a raw character offset cannot survive — the buffer re-anchors on CONTENT and must never
///     replay already-voiced audio, and must not truncate the genuinely-new final sentence
///     (the #1112 double-speech regression + its symmetric truncation).
struct IncrementalSpeechBufferTests {

    // MARK: - Fix 1: final flush must not drop text after an interior boundary

    /// A final ingest of multi-sentence text must return the WHOLE remainder. The previous
    /// implementation returned only up to the last sentence boundary and dropped the trailing
    /// fragment ("Second" here), which truncated the spoken reply.
    @Test func finalIngestSpeaksEverythingAfterInteriorBoundary() {
        var buffer = IncrementalSpeechBuffer()
        let segments = buffer.ingest(text: "First. Second", isFinal: true)
        #expect(segments == ["First. Second"])
    }

    /// A final ingest whose last sentence has an interior "." (e.g. a version string) must not
    /// stop at that interior period. This is the literal shape from the bug report
    /// ("…isn't permitted on 26.2").
    @Test func finalIngestKeepsTailAfterVersionLikePeriod() {
        var buffer = IncrementalSpeechBuffer()
        let segments = buffer.ingest(text: "That isn't permitted on 26.2 for this account", isFinal: true)
        #expect(segments == ["That isn't permitted on 26.2 for this account"])
    }

    // MARK: - Fix 2: reconcile recovers a raced-away tail without double-speaking

    /// Streaming delivered only the first sentence before being cancelled; reconciling against
    /// the complete text must speak ONLY the missing final sentence — not replay "Hi there."
    @Test func reconcileRecoversMissedTailWithoutReplay() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "Hi there.", isFinal: false)
        #expect(streamed == ["Hi there."])

        // Authoritative complete text (from chat history) — streaming never delivered the tail.
        let reconciled = buffer.ingest(text: "Hi there. It is done.", isFinal: true)
        #expect(reconciled == ["It is done."])
    }

    /// When the streamed text already equals the complete text, reconciling must produce
    /// nothing — no duplicate playback of the final sentence.
    @Test func reconcileWithNoNewTextSpeaksNothing() {
        var buffer = IncrementalSpeechBuffer()
        _ = buffer.ingest(text: "All done.", isFinal: false)
        let reconciled = buffer.ingest(text: "All done.", isFinal: true)
        #expect(reconciled.isEmpty)
    }

    // MARK: - Streaming boundaries still behave (regression guard)

    /// Non-final ingest still emits completed sentences and holds back an unterminated tail.
    @Test func streamingEmitsCompletedSentencesAndHoldsTail() {
        var buffer = IncrementalSpeechBuffer()
        let first = buffer.ingest(text: "One done. Two", isFinal: false)
        #expect(first == ["One done."])
        // The unterminated "Two" is held until a boundary or final flush arrives.
        let second = buffer.ingest(text: "One done. Two more.", isFinal: false)
        #expect(second == ["Two more."])
    }

    // MARK: - Fix 3: history/streaming divergence must never replay already-spoken sentences (#1112)

    /// Regression from #1112's truncation fix: the authoritative (history) text can diverge from
    /// the streamed text WITHIN the already-spoken region (whitespace / markdown / normalization).
    /// Here the first sentence streamed with a double space but history normalized it to one space.
    /// The reconcile must NOT walk `spokenOffset` back to the common prefix and replay the
    /// already-voiced sentence — it speaks only the genuinely-new tail. (Pre-fix, `updateText` reset
    /// the offset to the common prefix at the divergence and re-emitted "there. It is done.")
    @Test func divergenceInSpokenRegionDoesNotReplaySpokenSentence() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "Hi  there.", isFinal: false)
        #expect(streamed == ["Hi  there."])

        let reconciled = buffer.ingest(text: "Hi there. It is done.", isFinal: true)
        #expect(reconciled == ["It is done."])
    }

    /// Divergence spanning MULTIPLE already-spoken sentences: history re-formats both sentences the
    /// buffer already voiced AND appends a new one. Nothing at or before the spoken offset may
    /// replay — only the appended final sentence is spoken.
    @Test func divergenceAcrossMultipleSpokenSentencesOnlySpeaksNewTail() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "One.  Two.", isFinal: false)
        #expect(streamed == ["One.  Two."])

        // History collapses the double space in the already-spoken region and appends a third
        // sentence. Only "Three." is new.
        let reconciled = buffer.ingest(text: "One. Two. Three.", isFinal: true)
        #expect(reconciled == ["Three."])
    }

    /// The truncation fix itself must survive the monotonic-offset guard: when history is a CLEAN
    /// extension of the streamed text (a final sentence the streaming subscription raced past), the
    /// new tail is spoken exactly once and the already-spoken sentences are not repeated (#1092).
    @Test func cleanExtensionSpeaksOnlyTheNewFinalSentence() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "First. Second.", isFinal: false)
        #expect(streamed == ["First. Second."])

        let reconciled = buffer.ingest(text: "First. Second. Third recovered.", isFinal: true)
        #expect(reconciled == ["Third recovered."])
    }

    /// Authoritative text equals the streamed text exactly (multi-sentence) — reconcile speaks
    /// nothing; no duplicate playback of any sentence.
    @Test func identicalMultiSentenceAuthoritativeTextSpeaksNothing() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "Alpha. Beta.", isFinal: false)
        #expect(streamed == ["Alpha. Beta."])
        let reconciled = buffer.ingest(text: "Alpha. Beta.", isFinal: true)
        #expect(reconciled.isEmpty)
    }

    // MARK: - Fix 4: LENGTH-changing divergence — content anchoring, provably no replay (Codex P1)

    /// Codex P1: history INSERTS characters (markdown bold) inside the already-spoken region, so the
    /// spoken region is now LONGER than what streamed. A raw character offset (= 9, the length of
    /// "Hi there.") would land mid-word in the reformatted text and replay "e**. It is done." — the
    /// exact double-speech. Content anchoring locates the already-spoken text past the inserted
    /// markers and speaks ONLY the new tail.
    @Test func markdownInsertionBeforeOffsetDoesNotReplay() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "Hi there.", isFinal: false)
        #expect(streamed == ["Hi there."])

        let reconciled = buffer.ingest(text: "Hi **there**. It is done.", isFinal: true)
        #expect(reconciled == ["It is done."])
    }

    /// Symmetric truncation: history DELETES characters (collapses runs of whitespace) inside the
    /// already-spoken region, shrinking it by MORE than the single-space slack, then appends a new
    /// sentence. A raw offset (= 18) would overshoot into the new sentence and emit "ur here.",
    /// dropping "Fo" — a #1092-class truncation. Content anchoring keeps the new final sentence
    /// intact.
    @Test func whitespaceDeletionBeforeOffsetDoesNotTruncateNewSentence() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "One.  Two.  Three.", isFinal: false)
        #expect(streamed == ["One.  Two.  Three."])

        let reconciled = buffer.ingest(text: "One. Two. Three. Four here.", isFinal: true)
        #expect(reconciled == ["Four here."])
    }

    /// Authoritative text is SHORTER than what already streamed (history dropped a sentence). The
    /// already-spoken content cannot be located as a prefix of the shorter text, so the buffer
    /// under-speaks (emits nothing) rather than crash or replay. Everything the shorter text
    /// contains was already voiced, so nothing new is owed.
    @Test func authoritativeShorterThanStreamedSpeaksNothing() {
        var buffer = IncrementalSpeechBuffer()
        let streamed = buffer.ingest(text: "All done. Extra spoken.", isFinal: false)
        #expect(streamed == ["All done. Extra spoken."])

        let reconciled = buffer.ingest(text: "All done.", isFinal: true)
        #expect(reconciled.isEmpty)
    }
}
