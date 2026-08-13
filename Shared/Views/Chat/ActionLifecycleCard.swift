import Foundation
import Observation
import SwiftUI

struct ActionLifecycleDisplay {
    enum Phase {
        case live
        case historical
    }

    enum Presentation {
        case card
        case editingInstruction
    }

    var sfSymbol: String
    var liveText: String
    var historicalText: String
    var phase: Phase
    var tint: Color
    var presentation: Presentation
    var occurrenceCount: Int
    var detailText: String?

    var text: String {
        phase == .live ? liveText : historicalText
    }

    var isThinking: Bool {
        sfSymbol == "lightbulb" || liveText == "Thinking" || historicalText == "Thought"
    }

    init(
        sfSymbol: String,
        text: String,
        historicalText: String? = nil,
        phase: Phase = .live,
        tint: Color = DesignTokens.Color.systemOrange,
        presentation: Presentation = .card,
        occurrenceCount: Int = 1,
        detailText: String? = nil
    ) {
        self.sfSymbol = sfSymbol
        let sanitizedText = Self.sanitizeLabel(text)
        self.liveText = sanitizedText
        self.historicalText = historicalText.map(Self.sanitizeLabel) ?? Self.historicalLabel(from: sanitizedText)
        self.phase = phase
        self.tint = tint
        self.presentation = presentation
        self.occurrenceCount = max(occurrenceCount, 1)
        self.detailText = detailText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func withPhase(_ phase: Phase) -> ActionLifecycleDisplay {
        var copy = self
        copy.phase = phase
        return copy
    }

    func withOccurrenceCount(_ count: Int) -> ActionLifecycleDisplay {
        var copy = self
        copy.occurrenceCount = max(count, 1)
        return copy
    }

    static func historicalLabel(from liveLabel: String) -> String {
        let replacements: [(String, String)] = [
            ("Thinking", "Thought"),
            ("Checking", "Checked"),
            ("Getting", "Got"),
            ("Notifying", "Notified"),
            ("Sending", "Sent"),
            ("Approving", "Approved"),
            ("Taking", "Took"),
            ("Listing", "Listed"),
            ("Recording", "Recorded"),
            ("Creating", "Created"),
            ("Updating", "Updated"),
            ("Deleting", "Deleted"),
            ("Searching", "Searched"),
            ("Running", "Ran"),
        ]

        for (live, historical) in replacements {
            if liveLabel == live {
                return historical
            }
            if liveLabel.hasPrefix("\(live) ") {
                return historical + liveLabel.dropFirst(live.count)
            }
        }

        return liveLabel
    }

    nonisolated static func sanitizeLabel(_ label: String) -> String {
        let parts = label.components(separatedBy: " · ")
        return parts
            .map(sanitizeLabelPart)
            .joined(separator: " · ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func sanitizeLabelPart(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if looksLikeJSONBlob(trimmed) || containsNodeIDKey(trimmed) {
            return "details hidden"
        }

        var output = trimmed
        output = replaceMatches(
            in: output,
            pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#
        )
        output = replaceMatches(in: output, pattern: #"\b[0-9A-Fa-f]{24,}\b"#)
        output = replaceMatches(in: output, pattern: #"\bnode[-_:][A-Za-z0-9._-]{8,}\b"#)
        return output
    }

    nonisolated private static func looksLikeJSONBlob(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if (first == "{" || first == "[") && text.contains(":") {
            return true
        }
        return text.contains(#""nodeId""#) || text.contains(#""identifier""#)
    }

    nonisolated private static func containsNodeIDKey(_ text: String) -> Bool {
        text.range(of: #"(?i)\bnode_?id\b\s*[:=]"#, options: .regularExpression) != nil
    }

    nonisolated private static func replaceMatches(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "[redacted]")
    }
}

/// Exact transport evidence for one gateway execution. The transport emits this
/// before OpenClawChatUI rewrites an agent event's execution run ID to its
/// persisted history session ID.
struct RunLifecycleEpoch: Hashable, Sendable {
    static let legacy = Self(
        sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        generation: 0
    )

    let sourceID: UUID
    let generation: UInt64
}

struct RunLifecycleTransportLease: Sendable {
    let transportID: UUID
    let epoch: RunLifecycleEpoch
}

final class RunLifecycleEpochSource: @unchecked Sendable {
    let sourceID: UUID
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var currentTransportID: UUID?

    init(sourceID: UUID = UUID()) {
        self.sourceID = sourceID
    }

    func beginTransport() -> RunLifecycleTransportLease {
        lock.withLock {
            let transportID = UUID()
            currentTransportID = transportID
            generation &+= 1
            return RunLifecycleTransportLease(
                transportID: transportID,
                epoch: RunLifecycleEpoch(sourceID: sourceID, generation: generation)
            )
        }
    }

    func issueSubscription(for transportID: UUID) -> RunLifecycleEpoch? {
        lock.withLock {
            guard currentTransportID == transportID else { return nil }
            generation &+= 1
            return RunLifecycleEpoch(sourceID: sourceID, generation: generation)
        }
    }
}

/// Main-actor commit gate for asynchronously constructed chat transports.
/// A factory may finish after a newer binding request or after teardown; only
/// the latest still-ready ticket may synchronously create and install a model.
@MainActor
final class ChatTransportSetupGate {
    struct Ticket: Equatable {
        fileprivate let generation: UInt64
        let bindingKey: String
    }

    private var generation: UInt64 = 0
    private var desiredBindingKey: String?

    struct Request {
        let ticket: Ticket
        let lifecycleLease: RunLifecycleTransportLease
    }

    func begin(bindingKey: String) -> Ticket {
        generation &+= 1
        desiredBindingKey = bindingKey
        return Ticket(generation: generation, bindingKey: bindingKey)
    }

    /// Captures setup authority and lifecycle authority in the same synchronous
    /// main-actor turn, before any unstructured Task can start or be delayed.
    func begin(
        bindingKey: String,
        lifecycleStore: RunLifecycleEvidenceStore
    ) -> Request {
        Request(
            ticket: begin(bindingKey: bindingKey),
            lifecycleLease: lifecycleStore.beginTransportEpoch()
        )
    }

    func invalidate() {
        generation &+= 1
        desiredBindingKey = nil
    }

    @discardableResult
    func commit(
        _ ticket: Ticket,
        currentBindingKey: String,
        isReady: Bool,
        install: () -> Void
    ) -> Bool {
        guard isReady,
              ticket.generation == generation,
              desiredBindingKey == ticket.bindingKey,
              currentBindingKey == ticket.bindingKey
        else { return false }
        install()
        desiredBindingKey = nil
        return true
    }
}

enum ChatTransportSetupReadiness {
    static func isReady(
        operatorReady: Bool,
        sessionHealth: GatewaySessionHealthSnapshot
    ) -> Bool {
        operatorReady && sessionHealth.operatorUsable
    }
}

struct RunLifecycleEvidence: Equatable, Sendable {
    static let defaultEpoch = RunLifecycleEpoch.legacy

    enum TerminalOutcome: Equatable, Sendable {
        case final
        case aborted
        case error
    }

    enum Phase: Equatable, Sendable {
        case localRegistered
        case active
        case terminal(TerminalOutcome)
    }

    struct Run: Hashable, Sendable {
        let sessionKey: String
        let runID: String
    }

    let run: Run
    let phase: Phase
    let connectionEpoch: RunLifecycleEpoch

    init(
        run: Run,
        phase: Phase,
        connectionEpoch: RunLifecycleEpoch = Self.defaultEpoch
    ) {
        self.run = run
        self.phase = phase
        self.connectionEpoch = connectionEpoch
    }
}

/// A narrow transport-to-view bridge. It deliberately stores only exact live
/// execution identities. A terminal event without a matching `(session, run)`
/// cannot close anything; missing identity therefore fails closed until the
/// conversation changes.
@MainActor
@Observable
final class RunLifecycleEvidenceStore {
    private struct TerminalNode {
        var recordedAt: TimeInterval
        var previous: RunLifecycleEvidence.Run?
        var next: RunLifecycleEvidence.Run?
    }

    private(set) var revision = 0
    let epochSource: RunLifecycleEpochSource
    private var connectionEpoch: RunLifecycleEpoch
    private var activeRuns: Set<RunLifecycleEvidence.Run> = []
    private var localRuns: Set<RunLifecycleEvidence.Run> = []
    private var terminalRuns: [RunLifecycleEvidence.Run: TerminalNode] = [:]
    private var terminalHead: RunLifecycleEvidence.Run?
    private var terminalTail: RunLifecycleEvidence.Run?
    private var terminalOverflowUntil: TimeInterval?
    private let terminalCapacity: Int
    private let terminalTTL: TimeInterval
    private let now: () -> TimeInterval

    init(
        terminalCapacity: Int = 512,
        terminalTTL: TimeInterval = 120,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        epochSource: RunLifecycleEpochSource? = nil
    ) {
        self.terminalCapacity = max(1, terminalCapacity)
        self.terminalTTL = max(0, terminalTTL)
        self.now = now
        self.epochSource = epochSource ?? RunLifecycleEpochSource()
        self.connectionEpoch = .legacy
    }

    @discardableResult
    func beginConnectionEpoch() -> RunLifecycleEpoch {
        beginTransportEpoch().epoch
    }

    func beginTransportEpoch() -> RunLifecycleTransportLease {
        let lease = epochSource.beginTransport()
        setCurrentConnectionEpoch(lease.epoch)
        return lease
    }

    func setCurrentConnectionEpoch(_ epoch: RunLifecycleEpoch) {
        guard epoch.sourceID == epochSource.sourceID,
              epoch.generation > connectionEpoch.generation
        else { return }
        connectionEpoch = epoch
        activeRuns.removeAll(keepingCapacity: true)
        localRuns.removeAll(keepingCapacity: true)
        terminalRuns.removeAll(keepingCapacity: true)
        terminalHead = nil
        terminalTail = nil
        terminalOverflowUntil = nil
        revision &+= 1
    }

    func record(_ evidence: RunLifecycleEvidence) {
        let recordedAt = now()
        guard evidence.connectionEpoch == connectionEpoch else { return }
        pruneTerminalRuns(at: recordedAt)

        switch evidence.phase {
        case .localRegistered:
            guard terminalOverflowUntil == nil, terminalRuns[evidence.run] == nil else { return }
            localRuns.insert(evidence.run)
        case .active:
            guard terminalOverflowUntil == nil, terminalRuns[evidence.run] == nil else { return }
            activeRuns.insert(evidence.run)
        case .terminal:
            activeRuns.remove(evidence.run)
            localRuns.remove(evidence.run)
            if terminalOverflowUntil != nil {
                // Quarantine has one fixed deadline. Later terminal traffic
                // must not slide it forward and wedge activity indefinitely.
            } else if terminalRuns[evidence.run] == nil && terminalRuns.count >= terminalCapacity {
                terminalOverflowUntil = recordedAt + terminalTTL
            } else {
                insertOrRefreshTerminal(evidence.run, at: recordedAt)
            }
            pruneTerminalRuns(at: recordedAt)
        }
        revision &+= 1
    }

    private func pruneTerminalRuns(at time: TimeInterval) {
        if let terminalOverflowUntil, time >= terminalOverflowUntil {
            self.terminalOverflowUntil = nil
            activeRuns.removeAll(keepingCapacity: true)
            localRuns.removeAll(keepingCapacity: true)
            terminalRuns.removeAll(keepingCapacity: true)
            terminalHead = nil
            terminalTail = nil
        }
        while let head = terminalHead,
              let node = terminalRuns[head],
              time - node.recordedAt >= terminalTTL {
            removeTerminal(head)
        }
    }

    private func insertOrRefreshTerminal(
        _ run: RunLifecycleEvidence.Run,
        at recordedAt: TimeInterval
    ) {
        if terminalRuns[run] != nil { removeTerminal(run) }
        let previous = terminalTail
        terminalRuns[run] = TerminalNode(
            recordedAt: recordedAt,
            previous: previous,
            next: nil
        )
        if let previous {
            terminalRuns[previous]?.next = run
        } else {
            terminalHead = run
        }
        terminalTail = run
    }

    private func removeTerminal(_ run: RunLifecycleEvidence.Run) {
        guard let node = terminalRuns.removeValue(forKey: run) else { return }
        if let previous = node.previous {
            terminalRuns[previous]?.next = node.next
        } else {
            terminalHead = node.next
        }
        if let next = node.next {
            terminalRuns[next]?.previous = node.previous
        } else {
            terminalTail = node.previous
        }
    }

    func activeRunIDs(for sessionKey: String) -> Set<String> {
        Set(activeRuns.lazy.filter { $0.sessionKey == sessionKey }.map(\.runID))
    }

    func localRunIDs(for sessionKey: String) -> Set<String> {
        Set(localRuns.lazy.filter { $0.sessionKey == sessionKey }.map(\.runID))
    }

    var terminalTombstoneCount: Int { terminalRuns.count }

    /// Session changes are the bounded cleanup for identity-less/missing
    /// terminal events. We never guess completion inside one conversation.
    /// Terminal tombstones remain globally bounded and must survive switching
    /// away: a delayed activity event from the completed run can arrive while
    /// another conversation is visible.
    func retainOnly(sessionKey: String) {
        let retained = activeRuns.filter { $0.sessionKey == sessionKey }
        let retainedLocal = localRuns.filter { $0.sessionKey == sessionKey }
        guard retained.count != activeRuns.count || retainedLocal.count != localRuns.count else {
            return
        }
        activeRuns = Set(retained)
        localRuns = Set(retainedLocal)
        revision &+= 1
    }
}

/// Keeps structured live tool lifecycle stable from first exact transport
/// activity evidence through that execution's exact terminal event.
struct RunActivityAccumulator {

    struct Input {
        let runCount: Int
        let sessionKey: String
        let observations: [Observation]
        var suppressedObservationIDs: Set<String> = []
        var activeTransportRunIDs: Set<String> = []
        var localRegisteredRunIDs: Set<String> = []
        var historyOwnedObservationIDs: Set<String> = []
        var historyOwnershipCounts: [String: Int] = [:]

        var hasAmbiguousMixedOwnership: Bool {
            guard runCount > 0, !activeTransportRunIDs.isEmpty else { return false }
            let activeLocalIDs = activeTransportRunIDs.intersection(localRegisteredRunIDs)
            let activeExternalIDs = activeTransportRunIDs.subtracting(localRegisteredRunIDs)
            return !activeExternalIDs.isEmpty || activeLocalIDs.count > runCount
        }

        /// `max` is valid only after every active transport ID is correlated to
        /// a registered local run. Any unmatched mixed ownership is represented
        /// as overlap so the reducer suppresses rather than merges timelines.
        var effectiveRunCount: Int {
            if hasAmbiguousMixedOwnership {
                return max(2, runCount + activeTransportRunIDs.count)
            }
            return max(runCount, activeTransportRunIDs.count)
        }
    }

    struct Observation {
        let id: String
        let display: ActionLifecycleDisplay
    }

    private struct Entry {
        let id: String
        var display: ActionLifecycleDisplay
    }

    private var entries: [Entry] = []
    private(set) var sessionKey: String?
    private(set) var isActive = false
    private(set) var isAwaitingAuthoritativeHistory = false
    private(set) var isSuppressedForOverlap = false
    private(set) var activeTransportRunIDs: Set<String> = []
    private var lastHistoryOwnershipCounts: [String: Int] = [:]
    private var terminalHistoryBaseline: [String: Int] = [:]

    var displays: [ActionLifecycleDisplay] { entries.map(\.display) }

    mutating func begin(sessionKey: String) {
        entries = []
        self.sessionKey = sessionKey
        isActive = true
        isAwaitingAuthoritativeHistory = false
        isSuppressedForOverlap = false
        activeTransportRunIDs = []
    }

    /// `OpenClawChatViewModel` currently exposes only a count of pending runs,
    /// while pending tool calls are session-wide and carry no public run ID. If
    /// runs overlap, attributing those calls to either run would merge unrelated
    /// timelines. Fail closed for the entire overlap window, then start clean on
    /// the next unambiguous 0 -> 1 run.
    mutating func observeRunCount(_ count: Int, sessionKey: String) {
        if count <= 0 {
            if isSuppressedForOverlap {
                reset()
            } else {
                finish()
            }
            return
        }

        if self.sessionKey != sessionKey || !isActive {
            begin(sessionKey: sessionKey)
        }
        if count > 1 {
            entries = []
            isActive = true
            isAwaitingAuthoritativeHistory = false
            isSuppressedForOverlap = true
        }
    }

    mutating func observePending(_ observations: [Observation]) {
        guard isActive, !isSuppressedForOverlap else { return }
        let pendingIDs = Set(observations.map(\.id))

        for index in entries.indices where !pendingIDs.contains(entries[index].id) {
            entries[index].display = entries[index].display.withPhase(.historical)
        }

        for observation in observations {
            if let index = entries.firstIndex(where: { $0.id == observation.id }) {
                entries[index].display = observation.display.withPhase(.live)
            } else {
                entries.append(Entry(id: observation.id, display: observation.display.withPhase(.live)))
            }
        }
    }

    /// Reconciles the complete user-visible activity projection for one render
    /// pass. Suppressed IDs are removed from retained state before pending
    /// observations are applied, which lets a browser-card `.none -> .live`
    /// transition evict a browser step that was already accumulated.
    mutating func reconcile(_ input: Input) {
        if sessionKey != nil, sessionKey != input.sessionKey {
            reset()
        }
        if input.effectiveRunCount <= 0, isActive {
            terminalHistoryBaseline = lastHistoryOwnershipCounts
        }
        defer { lastHistoryOwnershipCounts = input.historyOwnershipCounts }
        observeRunCount(input.effectiveRunCount, sessionKey: input.sessionKey)
        activeTransportRunIDs = input.activeTransportRunIDs

        if isAwaitingAuthoritativeHistory,
           historyOwnsRetainedEntries(
               observationIDs: input.historyOwnedObservationIDs,
               ownershipCounts: input.historyOwnershipCounts
           )
        {
            authoritativeHistoryArrived()
            return
        }

        guard isActive else { return }
        evict(ids: input.suppressedObservationIDs)
        observePending(input.observations.filter {
            !input.suppressedObservationIDs.contains($0.id)
        })
    }

    mutating func evict(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func finish() {
        guard isActive else { return }
        for index in entries.indices {
            entries[index].display = entries[index].display.withPhase(.historical)
        }
        isActive = false
        isAwaitingAuthoritativeHistory = !entries.isEmpty
    }

    private func historyOwnsRetainedEntries(
        observationIDs: Set<String>,
        ownershipCounts: [String: Int]
    ) -> Bool {
        guard !entries.isEmpty else { return true }
        let unmatchedEntries = entries.filter { !observationIDs.contains($0.id) }
        let requiredCounts = unmatchedEntries.reduce(into: [String: Int]()) { counts, entry in
            counts[Self.ownershipKey(for: entry.display), default: 0] += entry.display.occurrenceCount
        }
        return requiredCounts.allSatisfy { key, requiredCount in
            ownershipCounts[key, default: 0]
                >= terminalHistoryBaseline[key, default: 0] + requiredCount
        }
    }

    static func ownershipKey(for display: ActionLifecycleDisplay) -> String {
        "\(display.sfSymbol)|\(display.historicalText)"
    }

    mutating func authoritativeHistoryArrived() {
        reset()
    }

    mutating func reset() {
        entries = []
        sessionKey = nil
        isActive = false
        isAwaitingAuthoritativeHistory = false
        isSuppressedForOverlap = false
        activeTransportRunIDs = []
        lastHistoryOwnershipCounts = [:]
        terminalHistoryBaseline = [:]
    }
}

struct ActionLifecycleCard: View {
    let display: ActionLifecycleDisplay
    var showsProgress = true
    var accessibilityIdentifier = "ActionLifecycleCard"

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(display.tint)
            }

            ActionLifecycleIcon(symbol: display.sfSymbol, tint: display.tint)

            Text(display.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .conditionalShimmer(active: showsProgress)

            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                .fill(DesignTokens.Color.fillTertiary)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ActionLifecycleDisclosure: View {
    enum Kind: Equatable {
        case agentInstructions
        case toolActivity
        case runActivity
    }

    let displays: [ActionLifecycleDisplay]
    let isExpanded: Bool
    var kind: Kind = .agentInstructions
    var elapsedSeconds: Int? = nil
    var isRunActive = false
    var accessibilityIdentifier = "ActionLifecycleDisclosure"
    var onToggle: () -> Void
    @State private var expandedDetailIndexes: Set<Int> = []

    /// Activity is supporting context, not the primary transcript. A long run remains inspectable
    /// without allowing its expanded timeline to displace the assistant response and composer.
    static let expandedTimelineMaxHeight: CGFloat = 240

    static func title(
        for displays: [ActionLifecycleDisplay],
        kind: Kind = .agentInstructions,
        elapsedSeconds: Int? = nil
    ) -> String {
        switch kind {
        case .agentInstructions:
            return displays.contains { $0.phase == .live }
                ? "Updating agent instructions"
                : "Updated agent instructions"
        case .toolActivity:
            return "Working"
        case .runActivity:
            let thinkingOnly = !displays.isEmpty && displays.allSatisfy(\.isThinking)
            if thinkingOnly {
                guard let elapsedSeconds else { return "Thought" }
                return "Thought for \(elapsedDurationLabel(elapsedSeconds))"
            }
            guard let elapsedSeconds else { return "Activity" }
            return "Worked for \(elapsedDurationLabel(elapsedSeconds))"
        }
    }

    /// Compact, user-facing elapsed time. Historical timestamps can legitimately span minutes or
    /// hours; exposing the backing integer (`37507s`) makes a delayed turn look like a broken timer.
    static func elapsedDurationLabel(_ elapsedSeconds: Int) -> String {
        let seconds = max(elapsedSeconds, 1)
        if seconds < 60 { return "\(seconds)s" }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0
                ? "\(minutes)m"
                : "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours)h"
            : "\(hours)h \(remainingMinutes)m"
    }

    static func resolvedElapsedSeconds(
        from startMilliseconds: Double?,
        through endMilliseconds: Double?
    ) -> Int? {
        guard let startMilliseconds,
              let endMilliseconds,
              startMilliseconds.isFinite,
              endMilliseconds.isFinite
        else { return nil }
        let start = normalizedMilliseconds(startMilliseconds)
        let end = normalizedMilliseconds(endMilliseconds)
        guard end >= start else { return nil }
        return max(Int(((end - start) / 1_000).rounded()), 1)
    }

    /// Gateway history is millisecond-based, but legacy and fixture rows can use Unix seconds.
    /// Normalize realistic epoch-second values before comparing two rows so a mixed persisted turn
    /// cannot inflate a few seconds into millions.
    private static func normalizedMilliseconds(_ timestamp: Double) -> Double {
        // Older bridges have emitted epoch nanoseconds or microseconds. Normalize those alongside
        // the gateway's canonical milliseconds and legacy seconds before comparing two rows.
        if timestamp >= 100_000_000_000_000_000 { return timestamp / 1_000_000 }
        if timestamp >= 100_000_000_000_000 { return timestamp / 1_000 }
        let isRealisticUnixSeconds = timestamp >= 1_000_000_000 && timestamp < 10_000_000_000
        return isRealisticUnixSeconds ? timestamp * 1_000 : timestamp
    }

    /// Expansion is user-owned, for every kind and every phase. Run state must never open a
    /// disclosure on its own.
    ///
    /// #1278: the in-progress "Working" disclosure used to auto-expand while a turn streamed
    /// (`isRunActive && (kind == .toolActivity || kind == .runActivity)`), so a running turn showed
    /// an open section the user never opened, and each new step it accumulated shoved the reply the
    /// user was reading further down the transcript. Collapsed-by-default now matches the completed
    /// Activity disclosure, which was always keyed purely off the user's own toggle.
    ///
    /// Upstream holds the same contract: the OpenClaw TUI starts live tool activity collapsed
    /// (`openclaw/src/tui/tui.ts` — `let toolsExpanded = false`) and only an explicit user toggle
    /// opens it.
    ///
    /// `kind` and `isRunActive` stay in the signature deliberately. They are not consulted, but
    /// keeping them makes "an active run does not expand anything" directly assertable at this seam
    /// rather than something a caller has to re-derive.
    static func resolvesExpanded(
        userExpanded: Bool,
        kind: Kind,
        isRunActive: Bool
    ) -> Bool {
        userExpanded
    }

    static func showsLeadingHeaderIcon(for kind: Kind) -> Bool {
        kind == .agentInstructions
    }

    static func accessibilityStateLabel(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }

    static func occurrenceLabel(for count: Int) -> String? {
        count > 1 ? "×\(count)" : nil
    }

    private var displayTitle: String {
        if isRunActive, kind == .runActivity {
            return "Working"
        }
        return Self.title(for: displays, kind: kind, elapsedSeconds: elapsedSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 4) {
                    if Self.showsLeadingHeaderIcon(for: kind) {
                        Image(systemName: "square.and.pencil")
                            .font(DesignTokens.Typography.chatMeta)
                    }
                    Text(displayTitle)
                        .font(DesignTokens.Typography.chatMeta.weight(.medium))
                    if kind == .agentInstructions, displays.count > 1 {
                        Text("\(displays.count)")
                            .font(DesignTokens.Typography.chatMeta)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DesignTokens.Typography.chatMeta.weight(.semibold))
                }
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Self.accessibilityStateLabel(isExpanded: isExpanded))
            .accessibilityHint(isExpanded ? "Collapses activity steps" : "Expands activity steps")

            if isExpanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(spacing: 0) {
                                    ActionLifecycleIcon(symbol: display.sfSymbol, tint: display.tint, size: 16)
                                    if index < displays.count - 1 {
                                        Rectangle()
                                            .fill(DesignTokens.Color.separator)
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 16)

                                activityStepContent(display, index: index)
                            }
                            .frame(minHeight: index < displays.count - 1 ? 30 : 20, alignment: .top)
                        }
                    }
                    .padding(.leading, 4)
                }
                .frame(maxHeight: Self.expandedTimelineMaxHeight)
                .clipped()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func activityStepContent(_ display: ActionLifecycleDisplay, index: Int) -> some View {
        if let detailText = display.detailText, !detailText.isEmpty {
            let isDetailExpanded = expandedDetailIndexes.contains(index)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if isDetailExpanded {
                        expandedDetailIndexes.remove(index)
                    } else {
                        expandedDetailIndexes.insert(index)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(display.text)
                            .font(DesignTokens.Typography.chatMessage)
                        if let occurrenceLabel = Self.occurrenceLabel(for: display.occurrenceCount) {
                            Text(occurrenceLabel)
                                .font(DesignTokens.Typography.chatMeta)
                                .foregroundStyle(DesignTokens.Color.labelTertiary)
                        }
                        Image(systemName: isDetailExpanded ? "chevron.up" : "chevron.down")
                            .font(DesignTokens.Typography.chatMeta.weight(.semibold))
                    }
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Self.accessibilityStateLabel(isExpanded: isDetailExpanded))
                .accessibilityHint(isDetailExpanded ? "Collapses tool result" : "Expands tool result")

                if isDetailExpanded {
                    ScrollView(.vertical) {
                        Text(detailText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                Text(display.text)
                    .font(DesignTokens.Typography.chatMessage)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let occurrenceLabel = Self.occurrenceLabel(for: display.occurrenceCount) {
                    Text(occurrenceLabel)
                        .font(DesignTokens.Typography.chatMeta)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
            }
        }
    }
}

private struct ActionLifecycleIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 18

    var body: some View {
        if symbol == "asset.apple-reminders-logo" {
            Image("AppleRemindersLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size - 2, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}

private extension View {
    @ViewBuilder
    func conditionalShimmer(active: Bool) -> some View {
        if active {
            shimmering()
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Reminders Search") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "asset.apple-reminders-logo", text: "Searching through reminders")
    )
    .padding()
}

#Preview("Reminder Update") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "asset.apple-reminders-logo", text: "Updating reminder")
    )
    .padding()
}

#Preview("Historical Reminder Update") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "asset.apple-reminders-logo", text: "Updating reminder", phase: .historical),
        showsProgress: false
    )
    .padding()
}

#Preview("Calendar Create") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "calendar.badge.plus", text: "Creating event")
    )
    .padding()
}

#Preview("Pending Devices") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "person.badge.clock", text: "Checking pending devices")
    )
    .padding()
}

#Preview("Updated Agent Instructions") {
    ActionLifecycleCard(
        display: .init(
            sfSymbol: "square.and.pencil",
            text: "write · /data/workspace/USER.md",
            phase: .historical,
            presentation: .editingInstruction
        ),
        showsProgress: false
    )
    .padding()
}

#Preview("Updated Agent Instructions Collapsed") {
    ActionLifecycleDisclosure(
        displays: [
            .init(
                sfSymbol: "square.and.pencil",
                text: "write · /data/workspace/USER.md",
                phase: .historical,
                presentation: .editingInstruction
            ),
        ],
        isExpanded: false,
        onToggle: {}
    )
    .padding()
}

#Preview("Updated Agent Instructions Expanded") {
    ActionLifecycleDisclosure(
        displays: [
            .init(
                sfSymbol: "square.and.pencil",
                text: "write · /data/workspace/USER.md",
                phase: .historical,
                presentation: .editingInstruction
            ),
            .init(
                sfSymbol: "square.and.pencil",
                text: "write · /data/workspace/IDENTITY.md",
                phase: .historical,
                presentation: .editingInstruction
            ),
            .init(
                sfSymbol: "terminal",
                text: "exec · rm /data/workspace/BOOTSTRAP.md",
                phase: .historical,
                presentation: .editingInstruction
            ),
        ],
        isExpanded: true,
        onToggle: {}
    )
    .padding()
}

#Preview("Dark") {
    ActionLifecycleCard(
        display: .init(sfSymbol: "checklist", text: "Searching through reminders")
    )
    .padding()
    .preferredColorScheme(.dark)
}
#endif
