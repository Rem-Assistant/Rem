import Foundation
import Observation

/// Pure presentation for the server-derived Inputs rows. No SwiftUI here on purpose: every rule
/// that decides what the user is told about a source is a plain function a test can call.
///
/// The one rule this file exists to enforce: a state the app does not recognize renders as
/// *unknown*, and a connected-but-failing source renders as *Unavailable* — never as "Included".
/// A row that claims Included while silently failing is the bug this surface replaces.
enum AutomationInputsPresentation {

    /// How prominently a row should read. Kept semantic so color choices stay in the view layer.
    enum Emphasis: Equatable {
        /// Feeding the automation right now.
        case active
        /// Connected but not delivering — must be visible, not quietly gray.
        case attention
        /// Not contributing, and not a failure: not connected, coming soon, or unknown.
        case muted
    }

    // MARK: Identity

    static func title(for row: AutomationInputRow) -> String {
        switch row.capability {
        case .remTasks: return "Rem tasks"
        case .remCalendarItems: return "Calendar items in Rem"
        case .connector: return row.connector?.displayName ?? "App connector"
        case .cloudBrowser: return "Cloud browser"
        case let .unrecognized(raw):
            // A capability family this build has never heard of. Prefer the server's own display
            // name; otherwise show its code humanized rather than inventing a friendly label.
            return row.connector?.displayName ?? humanized(raw)
        }
    }

    static func icon(for row: AutomationInputRow) -> String {
        switch row.capability {
        case .remTasks: return "checklist"
        case .remCalendarItems: return "calendar"
        case .connector:
            guard let source = row.connector?.source else { return "link" }
            return ComposioToolkitPresentation.iconName(for: source)
        case .cloudBrowser: return "globe"
        case .unrecognized: return "questionmark.circle"
        }
    }

    // MARK: State

    static func statusLabel(for state: AutomationInputState) -> String {
        switch state {
        case .included: return "Included"
        case .notConnected: return "Not connected"
        case .unavailable: return "Unavailable"
        case .comingSoon: return "Coming soon"
        case .unrecognized: return "Unknown"
        }
    }

    static func emphasis(for state: AutomationInputState) -> Emphasis {
        switch state {
        case .included: return .active
        case .unavailable: return .attention
        case .notConnected, .comingSoon, .unrecognized: return .muted
        }
    }

    /// Only a `not_connected` row is a call to action, and only Connectors can resolve it. An
    /// `unavailable` row is already connected — sending the user to Connectors would be a dead end.
    static func opensConnectors(_ row: AutomationInputRow) -> Bool {
        row.state == .notConnected
    }

    // MARK: Evidence line

    /// The quiet second line: what the last collect for this source actually produced.
    /// `nil` when the server reported no collect evidence at all.
    ///
    /// Today a six-times-failing connector looked identical to a working one in the UI. This is
    /// the line that makes the difference visible in the app instead of only in SQL.
    ///
    /// `state` decides whether the reason is rendered at all. This used to branch on
    /// `lastUnavailableReason` being non-nil and never consulted `state` — but the server
    /// deliberately emits a non-null reason on rows whose state is FINE (a recorded
    /// `no_active_connection` that a live ACTIVE account has since superseded still travels on an
    /// `.included` row, because the field reports the last collect, not the current verdict). A
    /// healthy Gmail row therefore read "No connected account" underneath the word "Included".
    ///
    /// The reason is diagnostic detail for a row the server already called `.unavailable`; it is
    /// never the thing that decides the row is bad.
    static func secondaryLine(for row: AutomationInputRow, now: Date = Date()) -> String? {
        var components: [String] = []

        if !row.state.isRecognized {
            // Don't echo the unknown code back at the user; say what they can do about it.
            components.append("Needs a newer Rem")
        }

        let reason = row.lastUnavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.state == .unavailable, let reason, !reason.isEmpty {
            components.append(failureDescription(reason))
        } else if let count = row.lastItemCount {
            components.append(itemCountDescription(count))
        }

        if let raw = row.lastCollectedAt,
           let collected = DailyBriefAutomationPresentation.parseISO8601(raw) {
            components.append(relativeTime(from: collected, to: now))
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    static func itemCountDescription(_ count: Int) -> String {
        switch count {
        case ...0: return "No items"
        case 1: return "1 item"
        default: return "\(count) items"
        }
    }

    /// `unavailableReason` is a machine code, not prose (`connector_unavailable`, `timeout`).
    /// Known codes get product copy. An unrecognized *code-shaped* value is humanized so support
    /// can still read it; anything longer or free-form is replaced, because a provider error
    /// message is not something to paste into the UI.
    static func failureDescription(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "connector_unavailable": return "Connector didn't respond"
        case "timeout": return "Timed out"
        case "not_connected", "no_accounts": return "No connected account"
        case "not_configured": return "Not configured on the server"
        default:
            guard isCodeShaped(trimmed) else { return "Last run didn't complete" }
            return humanized(trimmed)
        }
    }

    /// Compact, locale-stable relative time. `RelativeDateTimeFormatter` would give a different
    /// string per locale and per OS version, which a presentation test cannot pin.
    static func relativeTime(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // Clock skew (or a collect recorded a moment ahead of this device) must not read as
        // "-1h ago".
        guard seconds >= 45 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: Helpers

    private static func isCodeShaped(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        return value.lowercased().unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func humanized(_ code: String) -> String {
        let spaced = code
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return code }
        return first.uppercased() + spaced.dropFirst()
    }
}

/// Read-only state for one automation's derived Inputs section.
///
/// Source of truth: the backend. `rows` is a cache of the last successful
/// `GET /api/v1/automations/:kind/inputs`, never authored locally.
/// Transitions: `load` → success replaces `rows` and clears `loadError`; failure keeps already
/// renderable rows and only surfaces an error when there is nothing to show. Recovery: the section
/// offers Try Again, and every appearance re-reads. Non-goal: writing anything back — this
/// surface has no mutations.
@MainActor
@Observable
final class AutomationInputsStore {
    let service: any AutomationInputsProviding
    let kind: String

    private(set) var rows: [AutomationInputRow]
    private(set) var isLoading: Bool = false
    private(set) var loadError: Error?
    /// Distinguishes "the server reported no inputs" from "we have not asked yet". Without it an
    /// empty array and an unstarted load render identically, and the empty state would lie.
    private(set) var hasLoaded: Bool = false

    private var generation: UInt64 = 0

    init(
        service: any AutomationInputsProviding,
        kind: String = AutomationInputsKind.dailyBrief,
        rows: [AutomationInputRow] = []
    ) {
        self.service = service
        self.kind = kind
        self.rows = rows
    }

    func load(showSkeleton: Bool) async {
        generation &+= 1
        let current = generation
        if showSkeleton { isLoading = true }

        // Clear on any newest-generation completion, not only on the call that raised it: a
        // silent refresh that supersedes an in-flight skeleton load still has to end the shimmer,
        // or the section stays loading forever.
        defer {
            if current == generation { isLoading = false }
        }

        do {
            let fetched = try await service.inputs(kind: kind)
            guard current == generation else { return }
            rows = fetched
            hasLoaded = true
            loadError = nil
        } catch {
            guard current == generation else { return }
            // A refresh failure must not replace already-renderable authoritative rows with an
            // error card — but it must not silently keep claiming they are current either, so the
            // error is still recorded once there is nothing else to show.
            if rows.isEmpty { loadError = error }
        }
    }
}
