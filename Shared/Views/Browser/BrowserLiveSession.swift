import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Cross-platform image, matching the codebase's existing convention
// (Shared/Views/Chat/AssistantMarkdownRenderer.swift:311-315).
#if canImport(UIKit)
typealias BrowserPlatformImage = UIImage
#elseif canImport(AppKit)
typealias BrowserPlatformImage = NSImage
#endif

// MARK: - Transport

/// A message off the wire: a JPEG frame (binary) or a JSON control message (text). The split is
/// the frame type itself — frames are sent binary so the JPEG is never base64'd and re-parsed at
/// 60fps; url/meta/error ride the text channel.
enum BrowserWireMessage {
    case frame(Data)   // raw JPEG bytes
    case control(Data) // JSON, utf8
}

/// Where frames come from.
///
/// This is a protocol because the source is expected to change per platform: on iOS the browser
/// runs in the cloud (the gateway's Chromium) and frames arrive over a WebSocket. On Mac, once we
/// drive the user's own local browser, frames will come off a local CDP connection instead —
/// there is far less reason to use a cloud browser on a machine that already has a real one. The
/// view, the input mapping, and this session don't care which; only the transport changes.
@MainActor
protocol BrowserFrameTransport: AnyObject {
    /// `onMessage` receives each wire message; `onClose` fires once, terminally.
    func connect(onMessage: @escaping (BrowserWireMessage) -> Void, onClose: @escaping (Error?) -> Void)
    func send(_ data: Data)
    func disconnect()
}

/// Streams from the user's cloud gateway.
///
/// Auth is the gateway token in an `Authorization` header — the same credential the app already
/// uses to drive this gateway, so it grants nothing new, and it never appears in a URL.
@MainActor
final class CloudBrowserTransport: BrowserFrameTransport {
    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var closed = false

    /// - Parameter gatewayURL: e.g. `https://remclaw-abc123.fly.dev`
    init?(gatewayURL: URL, token: String) {
        guard var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/browser/stream"
        components.query = nil
        guard let url = components.url else { return nil }
        self.url = url
        self.token = token
    }

    func connect(onMessage: @escaping (BrowserWireMessage) -> Void, onClose: @escaping (Error?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The gateway may be cold: it holds the socket open while Chromium boots (~128s worst
        // case) rather than failing, so this timeout has to outlast that.
        request.timeoutInterval = 180

        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()

        // A loop rather than callback recursion: `receive` yields exactly one message per call,
        // and awaiting it in a loop keeps the re-arm impossible to forget. URLSession preserves
        // the frame type, so `.data` is a JPEG frame and `.string` is a JSON control message.
        Task { @MainActor [weak self] in
            while true {
                guard let self, !self.closed else { return }
                do {
                    switch try await task.receive() {
                    case .data(let data): onMessage(.frame(data))
                    case .string(let string): onMessage(.control(Data(string.utf8)))
                    @unknown default: break
                    }
                } catch {
                    guard !self.closed else { return } // a local disconnect, not a failure
                    self.closed = true
                    onClose(error)
                    return
                }
            }
        }
    }

    func send(_ data: Data) {
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

// MARK: - Session

/// A live view of a browser: decodes incoming frames and translates touches back into input.
///
/// The browser is not on this device. The user sees a picture of it and drives it remotely, so
/// their login lands in the browser the agent is actually using — a profile that persists — and
/// not in a throwaway session on the phone.
@MainActor
@Observable
final class BrowserLiveSession {

    enum HandBackAuthorization: Equatable {
        case authorized
        case denied(String)
    }

    enum Phase: Equatable {
        case idle
        /// Connected or connecting, but no pixels yet. The gateway may be cold-starting, which
        /// legitimately takes ~2 minutes — the UI must say "waking", not spin silently.
        case waking
        case live
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var frame: BrowserPlatformImage?

    /// Durable, conversation-scoped browser evidence captured at gateway-event time. The revision
    /// is intentionally observable: a start/result pair may leave `pendingToolCalls` empty before
    /// SwiftUI renders, but incrementing this value still invalidates the card decision.
    private static let localPendingRunID = "__local_pending_browser_run__"
    private var browserRunEvidenceByConversation: [String: [String: BrowserRunEvidence]] = [:]
    /// Run ids captured by user End remain suppressed even if a newer run begins before an older
    /// run's delayed tool event arrives. Lifecycle end removes them, keeping the guard bounded.
    private var userEndedRunIDsByConversation: [String: Set<String>] = [:]
    struct BrowserTranscriptAnchorState: Equatable {
        var runID: String
        var structuredToolCallIDs: Set<String>
        var runIsActive: Bool
        var didCaptureBaseline: Bool
        var baselineMessageID: UUID?
        var baselineMessageIndex: Int?
        var baselineMessageSignature: String?
        var resolvedMessageID: UUID?
    }

    /// Run-start transcript boundary plus its resolved card row. This is conversation scoped because
    /// gateway browser events can arrive before the external user/final history rows they belong to.
    private var browserTranscriptAnchorByConversation: [String: BrowserTranscriptAnchorState] = [:]
    private(set) var browserActivityRevision = 0

    /// Invalidates delayed evidence work when the authenticated account/gateway boundary changes.
    private var browserEvidenceGeneration = 0

    /// Persists only the latest ended owner. The platform coordinator scopes the receipt to the
    /// authenticated account + gateway; the session never sees or stores either credential.
    var onEndedOwnershipChanged: ((String?) -> Void)?

    func beginBrowserRun(for sessionKey: String, browserRequested: Bool = false) {
        // This callback is the authoritative NEW-run edge. A user End suppresses every late tool
        // event from the run it aborted; only a subsequently begun run may attempt to reopen.
        clearUserEnded(for: sessionKey)
        var runs = browserRunEvidenceByConversation[sessionKey] ?? [:]
        let conversationWasExplicitlyClosed = !runs.values.contains {
            $0.browserDisposition == .live
        } && runs.values.contains {
            $0.browserDisposition == .explicitlyClosed
        }
        runs = runs.filter { $0.value.runIsActive }
        var evidence = BrowserRunEvidence()
        if browserRequested {
            evidence.markBrowserRequested(
                sessionKey: sessionKey,
                runID: Self.localPendingRunID
            )
        } else {
            evidence.begin(sessionKey: sessionKey)
        }
        if conversationWasExplicitlyClosed && !browserRequested {
            evidence.markBrowserExplicitlyClosed()
        }
        runs[Self.localPendingRunID] = evidence
        browserRunEvidenceByConversation[sessionKey] = runs
        browserActivityRevision += 1
    }

    func recordBrowserToolActivity(_ activity: BrowserToolActivity) {
        var runs = browserRunEvidenceByConversation[activity.sessionKey] ?? [:]
        let isNewStructuredRun = runs[activity.runID] == nil
        let conversationWasExplicitlyClosed = !runs.values.contains {
            $0.browserDisposition == .live
        } && runs.values.contains {
            $0.browserDisposition == .explicitlyClosed
        }
        if isNewStructuredRun {
            // Terminal evidence exists only to bridge the just-finished run into transcript
            // reconciliation. A genuinely new external run owns a new transcript boundary; keeping
            // old terminal tool-call IDs would let its prior browser row impersonate this run.
            runs = runs.filter { $0.value.runIsActive }
        }
        // Local sends begin before the gateway returns its real run id. The first routed tool event
        // replaces that untouched placeholder; independently active voice/cross-device runs remain.
        runs.removeValue(forKey: Self.localPendingRunID)
        var evidence = runs[activity.runID] ?? BrowserRunEvidence()
        evidence.record(activity)
        let belongsToUserEndedRun = userEndedRunIDsByConversation[activity.sessionKey]?
            .contains(activity.runID) == true
        if userEndedConversationKeys.contains(activity.sessionKey) || belongsToUserEndedRun {
            // The user ended this still-running turn. Late navigate/status/canvas events from that
            // run cannot undo End; keep the run closed until `beginBrowserRun` observes fresh intent.
            evidence.markBrowserExplicitlyClosed()
        }
        let action = activity.action?.lowercased()
        let explicitlyReopensBrowser =
            activity.toolName.caseInsensitiveCompare("browser") == .orderedSame
                && (action == "navigate" || action == "open")
            || activity.toolName.caseInsensitiveCompare("canvas") == .orderedSame
                && action == "present"
        if conversationWasExplicitlyClosed && !explicitlyReopensBrowser {
            // `record` begins a fresh run when needed, which resets the run-local disposition.
            // Reapply the conversation-wide close authority so a later read-only status/tabs call
            // cannot resurrect a browser that another run explicitly stopped.
            evidence.markBrowserExplicitlyClosed()
        }
        runs[activity.runID] = evidence

        if evidence.containsBrowserActivity {
            if var anchor = browserTranscriptAnchorByConversation[activity.sessionKey],
               anchor.runID == activity.runID
            {
                anchor.structuredToolCallIDs.insert(activity.toolCallID)
                anchor.runIsActive = true
                browserTranscriptAnchorByConversation[activity.sessionKey] = anchor
            } else {
                // The run that most recently produced structured browser activity owns the next
                // transcript boundary. Overlapping runs retain their lifecycle evidence, but their
                // tool IDs can never contaminate this run-scoped anchor.
                browserTranscriptAnchorByConversation[activity.sessionKey] =
                    BrowserTranscriptAnchorState(
                        runID: activity.runID,
                        structuredToolCallIDs: [activity.toolCallID],
                        runIsActive: true,
                        didCaptureBaseline: false,
                        baselineMessageID: nil,
                        baselineMessageIndex: nil,
                        baselineMessageSignature: nil,
                        resolvedMessageID: nil
                    )
            }
        }

        if activity.toolName.caseInsensitiveCompare("browser") == .orderedSame,
           action == "stop" || action == "close"
        {
            // The gateway exposes one browser per conversation. A teardown from any overlapping
            // run closes that shared browser, so older live evidence in another run cannot keep the
            // card open. A later explicit open/navigate (or canvas present) can revive it.
            for key in runs.keys {
                runs[key]?.markBrowserExplicitlyClosed()
            }
            // Run completion is not browser completion: Chromium remains available after the
            // agent's turn ends. Only this explicit browser teardown (or the user's End action)
            // moves the owner to its frozen review state.
            // The teardown event itself is authoritative ownership evidence, including close-first
            // and cross-conversation cases. Claim its conversation before freezing the card so an
            // unrelated prior owner is never ended in its place.
            noteBrowsingConversation(activity.sessionKey, restartViewerIfNeeded: false)
            markSessionEnded()
        }

        // Claim the one shared browser before publishing the new evidence revision. Switching
        // ownership clears the previous conversation's retained frame/URL synchronously, so the
        // new chat can never render a stale frame during the SwiftUI reconciliation pass.
        if runs.values.contains(where: { $0.supportsLiveCard }) {
            noteBrowsingConversation(activity.sessionKey)
            // A real browser action after an explicit close is fresh open intent. Read-only
            // actions cannot reach this branch while the retained disposition is closed.
            noteAgentBrowsing()
        }
        browserRunEvidenceByConversation[activity.sessionKey] = runs
        browserActivityRevision += 1
    }

    func cancelPendingBrowserRun(for sessionKey: String) {
        guard var runs = browserRunEvidenceByConversation[sessionKey],
              runs.removeValue(forKey: Self.localPendingRunID) != nil else { return }
        browserRunEvidenceByConversation[sessionKey] = runs
        browserActivityRevision += 1
    }

    func endBrowserRun(for sessionKey: String, runID: String?) {
        if let runID {
            userEndedRunIDsByConversation[sessionKey]?.remove(runID)
            if userEndedRunIDsByConversation[sessionKey]?.isEmpty == true {
                userEndedRunIDsByConversation.removeValue(forKey: sessionKey)
            }
        } else {
            userEndedRunIDsByConversation.removeValue(forKey: sessionKey)
        }
        guard var runs = browserRunEvidenceByConversation[sessionKey] else { return }
        if var anchor = browserTranscriptAnchorByConversation[sessionKey],
           runID == nil || anchor.runID == runID
        {
            anchor.runIsActive = false
            browserTranscriptAnchorByConversation[sessionKey] = anchor
        }
        if let runID, var evidence = runs[runID] {
            evidence.end(sessionKey: sessionKey, runID: runID)
            runs[runID] = evidence
        } else if runID != nil {
            // A run that never invoked browser/canvas still terminates the local placeholder.
            // Without this, every ordinary chat send leaves a permanently active sentinel.
            runs.removeValue(forKey: Self.localPendingRunID)
        } else if runID == nil {
            for key in runs.keys {
                runs[key]?.end(sessionKey: sessionKey, runID: nil)
            }
        }
        let activeRuns = runs.filter { $0.value.runIsActive }
        if activeRuns.isEmpty {
            // Retain only the latest terminal authority for the pending-count handoff. Sequential
            // voice/cross-device runs otherwise accumulate forever because they never call the
            // local-send `beginBrowserRun` pruning path.
            if let runID, let terminal = runs[runID] {
                runs = [runID: terminal]
            } else {
                runs.removeAll(keepingCapacity: true)
            }
        } else {
            runs = activeRuns
        }
        browserRunEvidenceByConversation[sessionKey] = runs
        browserActivityRevision += 1
    }

    /// Ends a routed agent run after giving a newly-observed browser start one render window.
    ///
    /// The gateway can emit browser start, result, and lifecycle end back-to-back for a warm
    /// `tabs`/`status` call. Ending synchronously in that case collapses the durable evidence before
    /// SwiftUI gets a frame, so neither the live card nor its eventual review card can claim this
    /// conversation after a cold app launch. Non-browser runs and explicit browser close/stop events
    /// still end immediately.
    func endBrowserRunEnsuringPresentation(
        for sessionKey: String,
        runID: String?,
        minimumVisibilityNanoseconds: UInt64 = 1_000_000_000
    ) {
        let runIDsToEndAfterPresentation: [String] = {
            guard let runs = browserRunEvidenceByConversation[sessionKey] else { return [] }
            if let runID {
                return runs[runID]?.supportsLiveCard == true ? [runID] : []
            }
            guard runs.values.contains(where: \.supportsLiveCard) else { return [] }
            // A nil lifecycle id means "all runs active at this event", not runs that may start
            // during the visibility window. Snapshot the current keys so this delayed cleanup can
            // never terminate a newer overlapping run.
            return Array(runs.keys)
        }()

        guard !runIDsToEndAfterPresentation.isEmpty else {
            endBrowserRun(for: sessionKey, runID: runID)
            return
        }

        let evidenceGeneration = browserEvidenceGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: minimumVisibilityNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.browserEvidenceGeneration == evidenceGeneration
            else { return }
            for capturedRunID in runIDsToEndAfterPresentation {
                self.endBrowserRun(for: sessionKey, runID: capturedRunID)
            }
        }
    }

    func browserRunEvidences(for sessionKey: String) -> [BrowserRunEvidence] {
        guard let runs = browserRunEvidenceByConversation[sessionKey] else { return [] }
        return Array(runs.values)
    }

    func browserTranscriptAnchorState(for sessionKey: String) -> BrowserTranscriptAnchorState? {
        browserTranscriptAnchorByConversation[sessionKey]
    }

    func captureBrowserTranscriptBaselineIfNeeded(
        messageID: UUID?,
        messageIndex: Int?,
        messageSignature: String?,
        for sessionKey: String
    ) {
        guard var state = browserTranscriptAnchorByConversation[sessionKey],
              !state.didCaptureBaseline else { return }
        state.didCaptureBaseline = true
        state.baselineMessageID = messageID
        state.baselineMessageIndex = messageIndex
        state.baselineMessageSignature = messageSignature
        browserTranscriptAnchorByConversation[sessionKey] = state
        browserActivityRevision += 1
    }

    func noteBrowserResolvedAnchor(_ messageID: UUID, for sessionKey: String) {
        guard var state = browserTranscriptAnchorByConversation[sessionKey],
              state.resolvedMessageID != messageID else { return }
        state.resolvedMessageID = messageID
        browserTranscriptAnchorByConversation[sessionKey] = state
        browserActivityRevision += 1
    }

    /// Chromium's own reported viewport, sent with every frame. Input is mapped through this
    /// rather than through the image's pixel size, so it stays correct under any scaling.
    private(set) var viewport: CGSize = .zero

    /// The address actually loaded in the remote browser, reported by Chromium.
    ///
    /// Shown to the user, and never sourced from the agent. If we ask someone to type a
    /// password into this view, they must be able to see whether it is really Discord — with
    /// no address bar, a page the agent was induced to visit is indistinguishable from the
    /// real one, which is the hole #979 was parked over.
    private(set) var currentURL: URL?

    /// Latches once the agent uses the browser in this conversation, and drives the collapsed
    /// card in chat. It stays on after the tool call finishes on purpose: the browser is still
    /// sitting on that page, and "what did Rem just do on the web" is worth a tap for longer
    /// than the half-second the call was in flight.
    var agentHasBrowsed = false

    /// Whether the CURRENT OWNER's session has ended — drives the open sheet's frozen "session ended"
    /// still vs a live connection. Derived from the per-conversation `endedConversationKeys` so it
    /// always tracks the owner: reviving one conversation's browser can't flip another's ended-state.
    /// Distinct from `.failed`: there is nothing to retry, so the view freezes on the last frame and
    /// says the session ended rather than offering "Try again".
    var hasEnded: Bool {
        guard let key = lastConversationKey else { return false }
        return endedConversationKeys.contains(key)
    }

    /// Whether the expanded live view is showing. Lives here rather than on the iOS coordinator
    /// so the shared card can present it on either platform.
    var isPresented = false

    /// The remote field the user has focused (by tapping it), so the app can mirror it in a
    /// native editor. `nil` when the focus isn't an editable field — a tap on a button focuses
    /// something, but not something you type into.
    struct FocusedField: Equatable {
        var value: String
        // A password field. The value IS transmitted (you can't mirror/edit what you don't
        // receive) — it rides the already-authenticated WSS socket and never reaches the model.
        // `isSecure` only drives LOCAL masking (SecureField) + log redaction; it is not "redacted
        // on the wire".
        var isSecure: Bool
        /// When the focused element is a `<select>`, its options — so the app can offer a native
        /// picker (the OS dropdown popup isn't captured in the screencast). `nil` for text fields.
        var options: [Option]?
        struct Option: Equatable, Identifiable {
            var label: String
            var value: String
            var id: String { value }
        }
    }
    private(set) var focusedField: FocusedField?

    /// The remote pointer, in normalised (0...1) coords, so the view can draw a cursor over the
    /// live frame. It reflects the AGENT's pointer (watch it work) as well as the user's touches.
    /// Cleared after a short idle so a parked cursor doesn't linger.
    struct Cursor: Equatable {
        var point: CGPoint
        var isDown: Bool
    }
    private(set) var cursor: Cursor?
    private var cursorIdleGeneration = 0

    /// Open the expanded view and start streaming.
    func present() {
        guard !hasEnded else {
            // A stale live-card render must never turn an ended session back into a live one.
            // Ended sessions have a separate, transport-free presentation path.
            presentEnded()
            return
        }
        isPresented = true
        start()
    }

    /// Hide only the viewer and suspend its screencast. The remote browser session, card
    /// lifecycle, takeover ownership, and any in-flight hand-back authorization remain intact.
    /// `stop()` is intentionally stronger and is reserved for lifecycle/ownership teardown.
    func dismissViewer() {
        isPresented = false
        generation += 1
        transport?.disconnect()
        transport = nil
        phase = .idle
        focusedField = nil
        cursor = nil
    }

    /// The user or agent explicitly closed the browser. End gracefully: keep the last frame for the
    /// review card, stop streaming, and drop the controls. NOT `.failed` — nothing to retry.
    func markSessionEnded() {
        guard !hasEnded else { return }
        if let key = lastConversationKey {
            endedConversationKeys.insert(key) // whose session ended
            onEndedOwnershipChanged?(key)
        }
        generation += 1 // orphan any in-flight decode/close from this session
        transport?.disconnect()
        transport = nil
        invalidateHandBackAuthorization()
        isControlling = false
        focusedField = nil
        cursor = nil
        phase = .idle // not streaming; the ended view is driven by `hasEnded` + the kept frame
    }

    /// The agent started browsing again after a close — clear the ended state so the card returns,
    /// and if the ended still is on screen, reconnect it to the fresh session.
    func noteAgentBrowsing() {
        guard hasEnded else { return }
        // Clear only the owner's ended mark — reviving THIS conversation must not touch another's End.
        if let key = lastConversationKey, endedConversationKeys.remove(key) != nil {
            onEndedOwnershipChanged?(nil)
        }
        if isPresented { start() } // start() is guarded to .idle/.failed, so this is safe to call
    }

    /// Whether the USER has explicitly taken the controls.
    ///
    /// Input is ignored unless this is on. Without it the user and the agent fight over the
    /// same mouse: a stray tap while the agent is mid-flow lands as a real click on a real
    /// page. Taking over is a deliberate act, and handing back is another.
    private(set) var isControlling = false

    /// Signals the chat agent about a change in who holds the browser: `true` = the user took over
    /// (pause the agent so it stops driving the page), `false` = handed back (resume the task).
    /// Wired by the platform (left nil on surfaces that don't coordinate with the agent). Until now
    /// takeover was a purely local flag the agent knew nothing about, so the two fought over the
    /// mouse. The platform COALESCES rapid toggles to the final intent — see
    /// `signalBrowserTakeover` — so a stale abort can't outrace a resume's fresh run.
    var onControlIntentChanged: ((Bool) -> Void)?

    /// Optional app-specific operation that admits and accepts the hand-back's next agent turn.
    /// iOS reserves a request slot and awaits the hidden resume send. The browser remains under user
    /// control while this is pending or denied, so the UI can never claim Rem is driving when no
    /// resume turn was accepted.
    var onRequestHandBack: (@MainActor () async -> HandBackAuthorization)?
    private(set) var isHandBackPending = false
    private(set) var handBackErrorText: String?
    private var handBackGeneration = 0

    func takeControl() {
        guard !isHandBackPending else { return }
        handBackErrorText = nil
        isControlling = true
        onControlIntentChanged?(true) // pause the agent so you two aren't fighting over the mouse
    }

    func handBack() {
        guard isControlling, !isHandBackPending else { return }
        handBackErrorText = nil

        guard let onRequestHandBack else {
            completeHandBack()
            return
        }

        handBackGeneration += 1
        let requestGeneration = handBackGeneration
        isHandBackPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorization = await onRequestHandBack()
            guard requestGeneration == self.handBackGeneration else { return }
            self.isHandBackPending = false
            switch authorization {
            case .authorized:
                self.completeHandBack()
            case .denied(let message):
                self.handBackErrorText = message
            }
        }
    }

    private func completeHandBack() {
        isControlling = false
        focusedField = nil
        handBackErrorText = nil
        onControlIntentChanged?(false) // ask the agent to pick the task back up from where you left it
    }

    private func invalidateHandBackAuthorization() {
        handBackGeneration += 1
        isHandBackPending = false
        handBackErrorText = nil
    }

    /// The conversation that currently OWNS the (single, global) browser — the last one to browse.
    /// There is exactly one browser per gateway, so its retained frame/URL/ended-state belong to one
    /// conversation at a time; the chat view uses this so a card (and its frozen frame) only shows in
    /// the chat that owns the session, never leaking a stale page into an unrelated one.
    private(set) var lastConversationKey: String?
    /// Process-local ownership epoch. It distinguishes an A -> B -> A owner cycle from an unchanged
    /// A owner so retained async hand-back work cannot cross a browser-session replacement boundary.
    private(set) var browserOwnerLifecycleTicket: UInt64 = 0

    private func replaceBrowserOwner(with conversationKey: String?) {
        if lastConversationKey != conversationKey {
            browserOwnerLifecycleTicket &+= 1
            lastConversationKey = conversationKey
        }
    }

    func noteBrowsingConversation(_ key: String, restartViewerIfNeeded: Bool = true) {
        let previousOwner = lastConversationKey
        replaceBrowserOwner(with: key)
        // Same conversation keeps its live session untouched. A DIFFERENT conversation taking the
        // single global browser must inherit NONE of the previous owner's session — otherwise chat B
        // renders chat A's page (an email, Notion, a logged-in dashboard). Three ways it would leak,
        // all closed by tearing the old session down:
        guard let previousOwner, previousOwner != key else { return }
        // The persisted receipt represents the latest owner only. A fresh owner invalidates the
        // previous review card before any new pixels or URL are allowed to arrive.
        onEndedOwnershipChanged?(nil)
        let wasStreaming = transport != nil
        // `stop()` bumps `generation` (so an in-flight decode/close still queued for the PREVIOUS
        // owner fails decode()'s epoch guard instead of repainting `.live` back to their page — the
        // exact leak this method fixes), drops the transport, and resets isControlling/focus/cursor
        // to .idle (so the new conversation can't inherit a live takeover it never asked for and land
        // a real click with its first tap). It intentionally KEEPS the last frame for the ended-still,
        // so clear the retained still/URL ourselves — it belongs to the old owner.
        stop()
        frame = nil
        viewport = .zero
        currentURL = nil
        // If the sheet is still on screen, reconnect fresh: the new owner gets a clean waking→live of
        // the browser's CURRENT page rather than a blank panel or the old owner's frozen frame.
        if wasStreaming, isPresented, restartViewerIfNeeded { start() }
    }

    /// Restore the smallest sufficient cold-launch state. The transcript remains authoritative for
    /// whether the conversation actually contains browser activity; this receipt only restores the
    /// owner predicate that lets that history render its ended review card.
    func restoreEndedOwnership(_ conversationKey: String) {
        guard !conversationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replaceBrowserOwner(with: conversationKey)
        endedConversationKeys = [conversationKey]
        userEndedConversationKeys.removeAll()
        userEndedRunIDsByConversation.removeAll()
        agentHasBrowsed = false
        browserActivityRevision += 1
    }

    /// Hard authenticated-boundary teardown. Unlike ordinary `stop()`, this clears every retained
    /// frame, URL, owner, run, and takeover bit so a new account/gateway can inherit nothing. It does
    /// not publish a receipt deletion: returning accounts keep their scoped ended-card doorway.
    func terminateAuthenticatedSession() {
        stop()
        isPresented = false
        frame = nil
        viewport = .zero
        currentURL = nil
        agentHasBrowsed = false
        replaceBrowserOwner(with: nil)
        endedConversationKeys.removeAll()
        userEndedConversationKeys.removeAll()
        userEndedRunIDsByConversation.removeAll()
        browserRunEvidenceByConversation.removeAll()
        browserTranscriptAnchorByConversation.removeAll()
        browserEvidenceGeneration += 1
        browserActivityRevision += 1
    }

    /// The conversations whose (single, global) browser session has explicitly ENDED and is now
    /// frozen. User End and agent browser stop/close insert the owner's key; finishing a run or
    /// dismissing the viewer does not. A new real browser action removes that owner's marker.
    private(set) var endedConversationKeys: Set<String> = []

    /// The conversations the USER explicitly ended (the sheet's "End" button). This remains separate
    /// from agent stop/close so an aborted run cannot claim a live card while it winds down. A new run
    /// lifts this hard suppress, while `endedConversationKeys` remains until a real browser action.
    private(set) var userEndedConversationKeys: Set<String> = []

    /// The user ended the session from the sheet's "End" button. This genuinely ENDS the session
    /// (not just closes the view): pause the agent, and mark it ended so re-opening shows the frozen
    /// "session ended" still rather than reconnecting live. We do NOT kill Chromium — it's a
    /// wrapper-owned singleton that auto-restarts — but the *session* is over.
    func endByUser() {
        onControlIntentChanged?(true) // pause the agent
        if let key = lastConversationKey {
            userEndedConversationKeys.insert(key) // hard suppress until the next begin-run edge
            if var runs = browserRunEvidenceByConversation[key] {
                let activeRunIDs = Set(runs.compactMap { runID, evidence in
                    evidence.runIsActive && runID != Self.localPendingRunID ? runID : nil
                })
                if !activeRunIDs.isEmpty {
                    userEndedRunIDsByConversation[key, default: []].formUnion(activeRunIDs)
                }
                for runID in runs.keys {
                    runs[runID]?.markBrowserExplicitlyClosed()
                }
                browserRunEvidenceByConversation[key] = runs
                browserActivityRevision += 1
            }
        }
        markSessionEnded() // hasEnded = true, keep the last frame, stop the stream
    }

    /// A fresh agent run started in `key`, so the conversation-wide user-End suppress is lifted.
    /// Captured ids from the aborted run remain blocked until their lifecycle-end event arrives.
    /// The actual ended marker is cleared by `noteAgentBrowsing` once fresh browsing resumes.
    func clearUserEnded(for key: String) {
        userEndedConversationKeys.remove(key)
    }

    /// Reopen the sheet onto the ENDED session — the frozen last frame, not a fresh live connect.
    /// Distinct from `present()` (which clears `hasEnded` and reconnects). Used by the re-entry card
    /// after the session has ended.
    func presentEnded() {
        isPresented = true
        // Leave `hasEnded`/`frame` intact so the sheet renders the frozen "session ended" view.
        // Never connect here. Re-entry through an ended card is review-only and must not wake or
        // create a browser. If no frame was observed while the viewer was open, the ended sheet
        // truthfully has no retained preview rather than manufacturing a new session to fetch one.
    }

    private var transport: (any BrowserFrameTransport)?
    private let makeTransport: () -> (any BrowserFrameTransport)?

    /// Bumped by every `start()`/`stop()`. Work started for an older generation — an in-flight
    /// frame decode, a close callback from a socket we already dropped — is ignored.
    ///
    /// Without it, a `Task.detached` decode that lands ~ms after `stop()` sets `phase = .live`
    /// with `transport == nil`, which permanently wedges the session: `start()` guards on
    /// `.idle || isFailed`, so it returns immediately and no connection is ever attempted,
    /// while the sheet happily renders a stale frame under a "Live" badge.
    private var generation = 0

    init(makeTransport: @escaping () -> (any BrowserFrameTransport)?) {
        self.makeTransport = makeTransport
    }

    func start() {
        guard phase == .idle || isFailed else { return }
        guard let transport = makeTransport() else {
            phase = .failed("Rem doesn't have a browser yet.")
            return
        }
        generation += 1
        let epoch = generation
        self.transport = transport
        phase = .waking
        transport.connect(
            onMessage: { [weak self] message in
                guard let self, epoch == self.generation else { return }
                self.handle(message)
            },
            onClose: { [weak self] _ in
                guard let self, epoch == self.generation else { return } // we stopped it; not a fault
                // A drop AFTER pixels is the dangerous case, not a benign one: the sheet would
                // keep showing the last frame under a "Live" badge and a trusted address bar,
                // while taps go into a dead socket. A frozen photo of Discord's login page
                // wearing a `discord.com` chrome is exactly the confusion the address bar
                // exists to prevent — so surface it and offer a retry, always.
                self.phase = .failed("Lost the connection to Rem's browser.")
            }
        )
    }

    func stop() {
        generation += 1 // orphan any in-flight decode/close from this session
        transport?.disconnect()
        transport = nil
        phase = .idle
        invalidateHandBackAuthorization()
        // Taking over is a deliberate act, so it must be re-taken deliberately. Otherwise the
        // agent's next `canvas.present` puts a sheet on screen with the user already holding
        // live controls, and their first reflexive tap lands as a real click on a real page.
        isControlling = false
        focusedField = nil
        cursor = nil
        // `frame` is deliberately KEPT. It's the last thing the browser was showing, which is
        // exactly what the collapsed card should picture, and what the view should show after a
        // session ends — a still of where Rem got to beats an empty state, since we already have
        // the pixels. Streaming stops either way; this is one image, not a live feed.
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    // MARK: Frames

    private func handle(_ message: BrowserWireMessage) {
        switch message {
        case .frame(let jpeg):
            decode(jpeg)
        case .control(let data):
            handleControl(data)
        }
    }

    /// url / meta / error — the JSON text channel.
    private func handleControl(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["t"] as? String
        else { return }

        switch type {
        case "meta":
            if let w = root["deviceWidth"] as? Double, let h = root["deviceHeight"] as? Double,
               w > 0, h > 0 {
                viewport = CGSize(width: w, height: h)
            }
        case "url":
            currentURL = (root["url"] as? String).flatMap(URL.init(string:))
        case "cursor":
            if let x = root["x"] as? Double, let y = root["y"] as? Double {
                let kind = root["kind"] as? String
                cursor = Cursor(point: CGPoint(x: x, y: y), isDown: kind == "down")
                scheduleCursorFade()
            }
        case "focus":
            // The reply to inspectFocus: what the user just tapped into. An editable field or a
            // <select> becomes something to interact with; a tap on a button reports neither.
            let isSelect = root["select"] as? Bool == true
            if root["editable"] as? Bool == true || isSelect {
                let options = (root["options"] as? [[String: Any]])?.compactMap { o -> FocusedField.Option? in
                    guard let value = o["value"] as? String else { return nil }
                    return FocusedField.Option(label: (o["label"] as? String) ?? value, value: value)
                }
                focusedField = FocusedField(
                    value: root["value"] as? String ?? "",
                    isSecure: root["secure"] as? Bool ?? false,
                    options: isSelect ? (options ?? []) : nil
                )
            } else {
                focusedField = nil
            }
        case "error":
            phase = .failed((root["message"] as? String) ?? "Rem's browser isn't available.")
        default:
            break
        }
    }

    /// Clear the cursor after a short idle, so a parked pointer fades rather than sitting there.
    private func scheduleCursorFade() {
        cursorIdleGeneration += 1
        let epoch = cursorIdleGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, epoch == self.cursorIdleGeneration else { return }
            self.cursor = nil
        }
    }

    private func decode(_ jpeg: Data) {
        let epoch = generation
        // Off the main actor: this runs per frame, and JPEG decode on the main thread would
        // stutter the UI exactly while the user is trying to tap something.
        Task.detached(priority: .userInitiated) {
            guard let image = BrowserPlatformImage(data: jpeg) else { return }
            await MainActor.run { [weak self] in
                guard let self, epoch == self.generation else { return } // stopped mid-decode
                self.frame = image
                self.phase = .live
            }
        }
    }

    // MARK: Input

    /// All input is sent in normalised (0...1) coordinates and mapped to the real viewport on
    /// the far side, so nothing here depends on how large the view happens to be drawn.
    ///
    /// Gated on `isControlling` HERE rather than in the view, so no future caller can drive the
    /// remote browser without the user having asked to.
    private func send(_ payload: [String: Any]) {
        guard isControlling else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport?.send(data)
    }

    /// A press and release at one point — which is exactly what Chromium turns into a click.
    ///
    /// A tap also focuses whatever is under it, so we immediately ask what got focused: if it's a
    /// text field, the app mirrors its value into a native editor. The remote focus needs a beat
    /// to settle after the click, hence the small delay.
    func tap(at point: CGPoint) {
        send(["t": "mouse", "type": "mousePressed", "x": clamp(point.x), "y": clamp(point.y)])
        send(["t": "mouse", "type": "mouseReleased", "x": clamp(point.x), "y": clamp(point.y)])
        // Don't pre-clear focusedField here — doing so dismissed the editor/keyboard on EVERY
        // tap, then the probe reply raised it again, a visible flicker. Let the probe reply be
        // the single source of truth: it sets the new field, or clears to nil for a non-editable
        // tap. The remote focus needs a beat to settle after the click, hence the small delay.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.inspectFocus()
        }
    }

    /// Ask the far side what field is focused, so it can be mirrored locally.
    func inspectFocus() {
        send(["t": "inspectFocus"])
    }

    /// Replace the focused remote field's whole value. This is what makes delete/edit work: the
    /// user edits a native iOS field and the result is pushed here, rather than poking a remote
    /// cursor with append + backspace.
    func setFocusedValue(_ value: String) {
        send(["t": "setValue", "value": value])
    }

    /// Choose an option in the focused `<select>` — the app shows a native picker because the OS
    /// dropdown popup isn't in the screencast.
    func selectOption(_ value: String) {
        // Reflect the choice in the picker label immediately: the remote page updates, but the app
        // only re-reads focus on a tap, so without this the menu would keep showing the old option.
        focusedField?.value = value
        send(["t": "selectOption", "value": value])
    }

    func scroll(at point: CGPoint, by delta: CGSize) {
        send([
            "t": "scroll", "x": clamp(point.x), "y": clamp(point.y),
            "dx": delta.width, "dy": delta.height,
        ])
    }


    func pressKey(_ key: String) {
        send(["t": "key", "key": key])
    }

    private func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }
}
