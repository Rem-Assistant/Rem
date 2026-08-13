import Foundation

/// Resolves the latest delivered Daily Brief from the gateway transcript.
///
/// The backend's `/brief` response supplies the exact authored artifact while the
/// `rem-orchestrator` Today conversation supplies durable delivery. Ordinary assistant
/// replies share that transcript, so the backend-authored markdown is the identity contract:
/// the client only accepts the exact cleaned artifact that `/brief` says was delivered. It never
/// infers a brief from message position, provider, model, or headings. Failure intentionally leaves
/// the cached brief untouched.
enum DailyBriefTranscriptReconciler {
    static let durableSessionKey = "rem-orchestrator"

    private struct History: Decodable {
        let messages: [Message]?
    }

    private struct Message: Decodable {
        let role: String
        let content: [Content]?
        let timestamp: Double?
    }

    private struct Content: Decodable {
        let type: String?
        let text: String?
    }

    static func requestParameters(sessionKey: String) -> String? {
        struct Parameters: Encodable { let sessionKey: String }
        guard let data = try? JSONEncoder().encode(Parameters(sessionKey: sessionKey)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Summary, navigation, and playback all resolve through the durable Today conversation.
    /// The backend field is intentionally ignored for transcript lookup: an absent or legacy
    /// route must not make Agenda summarize a different conversation from the one its tap opens.
    static func historySessionKeys(advertisedSessionKey: String?) -> [String] {
        _ = advertisedSessionKey
        return [durableSessionKey]
    }

    /// `/brief` always carries deterministic Agenda prose, even when no AI-authored artifact has
    /// been delivered. The backend advertises the durable session key only after the exact current
    /// gateway artifact revision is proven visible there, so that key is the provenance boundary
    /// for explicit narration. Markdown equality by itself cannot grant authority: an older
    /// fallback or ordinary reply may contain the same text in the durable transcript.
    static func backendAuthorizedCanonicalMarkdown(from brief: DailyBrief) -> String? {
        guard brief.briefSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) == durableSessionKey
        else { return nil }
        return brief.briefMarkdown
    }

    struct Artifact: Equatable {
        let markdown: String
        /// Stable content identity used by summary, narration, receipt, and scroll anchoring.
        let fingerprint: String
    }

    /// `chat.history` currently projects away the gateway transcript envelope ID. Exact markdown
    /// matching remains the compatibility identity for older gateways and delivery retries.
    static func latestExactArtifact(
        from historyData: Data,
        matching expectedMarkdown: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        requiresCurrentDay: Bool = true
    ) -> Artifact? {
        let expected = cleaned(expectedMarkdown)
        guard !expected.isEmpty else { return nil }
        guard let history = try? JSONDecoder().decode(History.self, from: historyData)
        else { return nil }

        for message in (history.messages ?? []).reversed()
        where isAssistantRole(message.role)
            && timestampIsEligible(
                message.timestamp,
                requiresCurrentDay: requiresCurrentDay,
                now: now,
                calendar: calendar
            ) {
            let raw = (message.content ?? [])
                .filter { ($0.type ?? "text").lowercased() == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            let candidate = cleaned(raw)
            if candidate == expected {
                return Artifact(
                    markdown: candidate,
                    fingerprint: DailyBriefPlaybackReceipt.stableFingerprint(candidate)
                )
            }
        }
        return nil
    }

    /// Resolve the latest Daily Brief that is visibly present in Today.
    ///
    /// Delivery already persists one canonical artifact and `/brief` returns that exact prose only
    /// after it is proven in this transcript. Matching that prose is therefore both simpler and
    /// safer than trying to infer which assistant turn was proactive. The latter confuses ordinary
    /// tool-assisted replies (`user -> assistant -> toolResult -> assistant`) with briefs.
    static func latestDeliveredArtifact(
        from historyData: Data,
        matching expectedMarkdown: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Artifact? {
        latestExactArtifact(
            from: historyData,
            matching: expectedMarkdown,
            now: now,
            calendar: calendar
        )
    }

    /// Resolve an artifact whose current delivery was already established by `/brief`.
    ///
    /// The backend owns the account timezone and only exposes the current authored prose after
    /// delivery into this durable transcript. Requiring the projected chat message to also carry
    /// a client-local, parseable timestamp can therefore create a false negative for an artifact
    /// that is visibly present. Exact assistant prose remains the identity check.
    static func currentCanonicalArtifact(
        from historyData: Data,
        matching expectedMarkdown: String
    ) -> Artifact? {
        latestExactArtifact(
            from: historyData,
            matching: expectedMarkdown,
            requiresCurrentDay: false
        )
    }

    /// Resolve exact history only after `/brief` has authorized this transcript and prose as the
    /// current delivered gateway artifact. Keeping the two checks together prevents a future caller
    /// from accidentally promoting deterministic fallback prose through an old equality match.
    static func currentBackendAuthorizedArtifact(
        from historyData: Data,
        for brief: DailyBrief
    ) -> Artifact? {
        guard let markdown = backendAuthorizedCanonicalMarkdown(from: brief) else { return nil }
        return currentCanonicalArtifact(from: historyData, matching: markdown)
    }

    private static func cleaned(_ text: String) -> String {
        MessageCleaner.cleanAssistantMessageText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAssistantRole(_ role: String) -> Bool {
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "assistant" || normalized == "model"
    }

    private static func isSameDay(
        _ timestamp: Double?,
        as date: Date,
        calendar: Calendar
    ) -> Bool {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return false }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return calendar.isDate(Date(timeIntervalSince1970: seconds), inSameDayAs: date)
    }

    /// The canonical delivery response may omit its projected transcript timestamp. Explicit Read
    /// can accept that absence because `/brief` already proved the current revision was delivered,
    /// but a present timestamp remains meaningful and must still resolve to the client's Today.
    private static func timestampIsEligible(
        _ timestamp: Double?,
        requiresCurrentDay: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        // Once `/brief` has authorized this exact canonical prose and durable session, the
        // backend's account-local day is authoritative. A late tap can legitimately occur on the
        // next device-calendar day (or while travelling); projected message time must not veto the
        // exact delivered artifact. Unauthorised discovery paths keep the current-day requirement.
        guard requiresCurrentDay else { return true }
        guard timestamp != nil else { return false }
        return isSameDay(timestamp, as: now, calendar: calendar)
    }

    /// Revalidate the authored artifact after any history/network suspension. Transcript prose
    /// may only be layered onto the same authored markdown that initiated reconciliation; a
    /// same-slot backend replacement must win instead of being overwritten by an older result.
    static func isCurrentAuthoredArtifact(
        expectedMarkdown: String,
        currentBrief: DailyBrief?
    ) -> Bool {
        guard let currentMarkdown = currentBrief?.briefMarkdown else { return false }
        let expected = cleaned(expectedMarkdown)
        return !expected.isEmpty && cleaned(currentMarkdown) == expected
    }

    static func reconcile(_ brief: DailyBrief, with historyData: Data) -> DailyBrief {
        guard let authoredMarkdown = brief.briefMarkdown else { return brief }
        guard let artifact = latestDeliveredArtifact(
            from: historyData,
            matching: authoredMarkdown
        ) else { return brief }
        return brief.replacingTranscriptProse(
            markdown: artifact.markdown,
            summary: summaryExcerpt(from: artifact.markdown)
        )
    }

    /// The Agenda remains a compact doorway while the complete delivered reply
    /// is retained as `markdown` for playback and hidden first-turn context.
    static func summaryExcerpt(from text: String, maximumLength: Int = 320) -> String {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let first = paragraphs.first(where: { paragraph in
            paragraph.range(of: #"^#{1,6}\s+"#, options: .regularExpression) == nil
        }) ?? paragraphs.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = first
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)

        guard plain.count > maximumLength else { return plain }
        let end = plain.index(plain.startIndex, offsetBy: maximumLength)
        let prefix = String(plain[..<end])
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd])
        }
        if let wordEnd = prefix.lastIndex(of: " ") {
            return String(prefix[..<wordEnd]) + "…"
        }
        return prefix + "…"
    }
}

/// Prevents an asynchronous brief-history response from starting playback after its original
/// Today destination has been replaced, covered by a deeper route, or superseded by another tap.
enum LatestBriefPlaybackGate {
    static func shouldStart(
        requestID: UUID,
        activeRequestID: UUID?,
        destinationDepth: Int,
        currentDepth: Int,
        expectedSessionKey: String,
        currentSessionKey: String?,
        expectedAccountID: String,
        currentAccountID: String?
    ) -> Bool {
        requestID == activeRequestID
            && currentDepth == destinationDepth
            && currentSessionKey == expectedSessionKey
            && currentAccountID == expectedAccountID
    }
}

/// Account- and artifact-qualified receipt for the explicit Daily Brief listening action.
/// Starting or interrupting playback must never record one.
struct DailyBriefPlaybackIdentity: Codable, Equatable, Hashable {
    let accountID: String
    let localDayKey: String
    let briefKey: String
}

/// Keeps a Daily Brief narration bound to the authenticated account that initiated it.
enum DailyBriefPlaybackAccountBoundary {
    static func shouldCancelActivePlayback(
        previousAccountID: String?,
        currentAccountID: String?,
        isBriefVoiceSession: Bool,
        isTalkModeEnabled: Bool
    ) -> Bool {
        isBriefVoiceSession && isTalkModeEnabled && previousAccountID != currentAccountID
    }

    static func canRecordCompletion(
        expectedAccountID: String,
        currentAccountID: String?
    ) -> Bool {
        currentAccountID == expectedAccountID
    }
}

/// Owns the unstructured work that bridges an Agenda tap into durable history and Talk Mode.
/// Cancellation alone is not enough: some dependencies do not cooperatively throw, so callers
/// must also revalidate the request after every suspension before enabling audio.
@MainActor
final class LatestBriefPlaybackController {
    private(set) var activeRequestID: UUID?
    private(set) var briefVoiceSessionRequestID: UUID?
    private var task: Task<Void, Never>?

    var hasPendingRequest: Bool { activeRequestID != nil }
    var isBriefVoiceSession: Bool { briefVoiceSessionRequestID != nil }

    func beginRequest(
        supersedingActiveRequest: Bool = false,
        onSupersedeActivePlayback: () -> Void = {}
    ) -> UUID? {
        if activeRequestID != nil {
            guard supersedingActiveRequest else { return nil }
            // Notification taps resolve forward to the newest brief. A newer tap owns the read:
            // synchronously stop any already-audible prose before cancelling the retained async
            // bridge. Task cancellation alone does not stop continuation-backed audio players.
            onSupersedeActivePlayback()
            cancelPendingRequest()
            briefVoiceSessionRequestID = nil
        }
        let requestID = UUID()
        activeRequestID = requestID
        return requestID
    }

    func retain(_ task: Task<Void, Never>, for requestID: UUID) {
        guard activeRequestID == requestID else {
            task.cancel()
            return
        }
        self.task = task
    }

    func canContinue(_ requestID: UUID) -> Bool {
        activeRequestID == requestID && !Task.isCancelled
    }

    func markBriefVoiceSessionStarted(for requestID: UUID) -> Bool {
        guard canContinue(requestID) else { return false }
        briefVoiceSessionRequestID = requestID
        return true
    }

    func finishRequest(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        task = nil
    }

    func cancelPendingRequest() {
        task?.cancel()
        task = nil
        activeRequestID = nil
    }

    @discardableResult
    func invalidateAll() -> Bool {
        cancelPendingRequest()
        let hadBriefVoiceSession = briefVoiceSessionRequestID != nil
        briefVoiceSessionRequestID = nil
        return hadBriefVoiceSession
    }

    func endVoiceSession() {
        briefVoiceSessionRequestID = nil
    }
}

struct DailyBriefPlaybackTeardownDecision: Equatable {
    let invalidatePendingRequest: Bool
    let stopTalkMode: Bool
}

/// The authenticated root can be removed before an account-ID observer receives the nil value.
/// Disappearance therefore owns a second, idempotent teardown boundary for pending narration.
enum DailyBriefPlaybackLifecycle {
    static func teardownDecision(
        hasPendingRequest: Bool,
        isTalkModeEnabled: Bool
    ) -> DailyBriefPlaybackTeardownDecision {
        DailyBriefPlaybackTeardownDecision(
            invalidatePendingRequest: hasPendingRequest,
            stopTalkMode: isTalkModeEnabled
        )
    }
}

enum DailyBriefPlaybackReceipt {
    private struct Ledger: Codable {
        var latestByAccount: [String: DailyBriefPlaybackIdentity] = [:]
    }

    static func localDayKey(
        for date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [components.era, components.year, components.month, components.day]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }

    static func identity(
        accountID: String?,
        generatedAt _: String?,
        sessionKey: String?,
        briefMarkdown: String?,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyBriefPlaybackIdentity? {
        guard let accountID = trimmed(accountID) else { return nil }

        return identity(
            accountID: accountID,
            localDayKey: localDayKey(for: date, calendar: calendar),
            sessionKey: sessionKey,
            briefMarkdown: briefMarkdown
        )
    }

    /// Rebinds a tapped account/day context to the durable transcript that playback actually
    /// resolved. The pre-history Agenda prose may be stale and must never own the completion key.
    static func identity(
        accountID: String?,
        localDayKey: String,
        sessionKey: String?,
        briefMarkdown: String?
    ) -> DailyBriefPlaybackIdentity? {
        guard let accountID = trimmed(accountID),
              let localDayKey = trimmed(localDayKey)
        else { return nil }

        let briefKey: String
        // GET /brief currently stamps `generated_at` with the request time even when it returns
        // the same durable transcript artifact. It is therefore discovery metadata, not identity.
        // Prefer the authored transcript itself so routine Agenda reloads preserve read state while
        // a genuinely changed brief on the same local day still requires its own completion.
        if let briefMarkdown = trimmed(briefMarkdown) {
            briefKey = "content:\(stableFingerprint(briefMarkdown))"
        } else if let sessionKey = trimmed(sessionKey) {
            briefKey = "session:\(sessionKey)"
        } else {
            briefKey = "day"
        }

        return DailyBriefPlaybackIdentity(
            accountID: accountID,
            localDayKey: localDayKey,
            briefKey: briefKey
        )
    }

    static func contains(
        _ identity: DailyBriefPlaybackIdentity?,
        in encodedLedger: String
    ) -> Bool {
        guard let identity else { return false }
        return decode(encodedLedger).latestByAccount[identity.accountID] == identity
    }

    static func recording(
        _ identity: DailyBriefPlaybackIdentity,
        in encodedLedger: String
    ) -> String {
        var ledger = decode(encodedLedger)
        ledger.latestByAccount[identity.accountID] = identity
        guard let data = try? JSONEncoder().encode(ledger),
              let encoded = String(data: data, encoding: .utf8)
        else { return encodedLedger }
        return encoded
    }

    private static func decode(_ encodedLedger: String) -> Ledger {
        guard let data = encodedLedger.data(using: .utf8),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data)
        else { return Ledger() }
        return ledger
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Deterministic FNV-1a fingerprint for a same-day brief that lacks a generated artifact ID.
    /// Swift's `hashValue` is intentionally randomized between launches and cannot back a receipt.
    fileprivate static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
