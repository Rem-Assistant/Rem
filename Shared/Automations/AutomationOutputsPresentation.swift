import Foundation
import Observation

/// Pure presentation for the server-derived Outputs rows. No SwiftUI here on purpose: every rule
/// that decides what the user is told about an output is a plain function a test can call.
///
/// The rule this file exists to enforce: a state the app does not recognize renders as *unknown*,
/// and an output that has produced nothing renders as *Nothing yet* — never as "Included". The
/// row this replaces said "Planned" for an output that had already shipped.
enum AutomationOutputsPresentation {

    /// How prominently a row should read. Kept semantic so color choices stay in the view layer.
    enum Emphasis: Equatable {
        /// Producing right now.
        case active
        /// Wired but with nothing to show, not yet built, or unknown. Never an alarm — an output
        /// with nothing to produce is a quiet fact about today, not a failure.
        case muted
    }

    // MARK: Identity

    static func title(for row: AutomationOutputRow) -> String {
        switch row.output {
        case .dailyOrientation: return "Daily orientation"
        case .attentionTriage: return "Work needing attention"
        case .taskSuggestions: return "Suggested tasks"
        case let .unrecognized(raw):
            // An output family this build has never heard of. Humanize its code rather than
            // inventing a friendly label for something we cannot describe.
            return humanized(raw)
        }
    }

    static func icon(for row: AutomationOutputRow) -> String {
        switch row.output {
        case .dailyOrientation: return "sparkles.rectangle.stack.fill"
        case .attentionTriage: return "exclamationmark.bubble.fill"
        case .taskSuggestions: return "lightbulb.fill"
        case .unrecognized: return "questionmark.circle"
        }
    }

    // MARK: State

    static func statusLabel(for state: AutomationOutputState) -> String {
        switch state {
        case .included: return "Included"
        case .idle: return "Nothing yet"
        case .comingSoon: return "Coming soon"
        case .unrecognized: return "Unknown"
        }
    }

    static func emphasis(for state: AutomationOutputState) -> Emphasis {
        switch state {
        case .included: return .active
        case .idle, .comingSoon, .unrecognized: return .muted
        }
    }

    // MARK: Evidence line

    /// The quiet second line: what this producer actually produced.
    /// `nil` when the server reported no production evidence at all.
    ///
    /// This is the line that makes "Included" checkable. A row that claims to produce something
    /// should be able to say what, and when.
    static func secondaryLine(for row: AutomationOutputRow, now: Date = Date()) -> String? {
        var components: [String] = []

        if !row.state.isRecognized || !row.output.isRecognized {
            // Don't echo the unknown code back at the user; say what they can do about it.
            components.append("Needs a newer Rem")
        }

        if let count = row.lastItemCount {
            components.append(itemCountDescription(count))
        }

        if let raw = row.lastProducedAt,
           let produced = DailyBriefAutomationPresentation.parseISO8601(raw) {
            components.append(relativeTime(from: produced, to: now))
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    static func itemCountDescription(_ count: Int) -> String {
        switch count {
        case ...0: return "Nothing right now"
        case 1: return "1 item"
        default: return "\(count) items"
        }
    }

    /// Compact, locale-stable relative time. `RelativeDateTimeFormatter` would give a different
    /// string per locale and per OS version, which a presentation test cannot pin.
    static func relativeTime(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // Clock skew (or a run recorded a moment ahead of this device) must not read as "-1h ago".
        guard seconds >= 45 else { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: Load failure

    /// An older server has no outputs route at all. Say that, rather than blaming the network.
    ///
    /// Lives here rather than on the view so a test can call it: the equivalent Inputs helpers sit
    /// on a `private` view struct and are therefore unreachable from `RemClawTests`, which is why
    /// the 404-vs-500 distinction has never been asserted.
    static func errorTitle(_ error: Error) -> String {
        isUnsupportedByServer(error) ? "Outputs need a server update" : "Couldn't load outputs"
    }

    static func errorMessage(_ error: Error) -> String {
        isUnsupportedByServer(error)
            ? "This server doesn't report what Daily Brief produces yet. Try again after it updates."
            : "Check your connection and try again."
    }

    static func isUnsupportedByServer(_ error: Error) -> Bool {
        guard let serviceError = error as? AutomationOutputsServiceError,
              case let .requestFailed(statusCode, _) = serviceError
        else { return false }
        return statusCode == 404
    }

    // MARK: Helpers

    private static func humanized(_ code: String) -> String {
        let spaced = code
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return code }
        return first.uppercased() + spaced.dropFirst()
    }
}

/// Read-only state for one automation's derived Outputs section.
///
/// Source of truth: the backend. `rows` is a cache of the last successful
/// `GET /api/v1/automations/:kind/outputs`, never authored locally.
/// Transitions: `load` → success replaces `rows` and clears `loadError`; failure keeps already
/// renderable rows and only surfaces an error when there is nothing to show. Recovery: the section
/// offers Try Again, and every appearance re-reads. Non-goal: writing anything back — this surface
/// has no mutations.
@MainActor
@Observable
final class AutomationOutputsStore {
    let service: any AutomationOutputsProviding
    let kind: String

    private(set) var rows: [AutomationOutputRow]
    private(set) var isLoading: Bool = false
    private(set) var loadError: Error?
    /// Distinguishes "the server reported no outputs" from "we have not asked yet". Without it an
    /// empty array and an unstarted load render identically, and the empty state would lie.
    private(set) var hasLoaded: Bool = false

    private var generation: UInt64 = 0

    init(
        service: any AutomationOutputsProviding,
        kind: String = AutomationInputsKind.dailyBrief,
        rows: [AutomationOutputRow] = []
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
            let fetched = try await service.outputs(kind: kind)
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
