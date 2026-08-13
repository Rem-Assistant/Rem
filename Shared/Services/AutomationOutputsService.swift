import Foundation

/// Read surface for an automation's **derived** output contract.
///
/// `GET /api/v1/automations/:kind/outputs` reports what the runner actually produces right now:
/// the server observes its own producers — the authored artifact row, `gatherBrief`'s attention
/// buckets, `deriveSuggestions`' list — and reports what each one emitted for this user.
///
/// This is the second half of the fix `AutomationInputsService` started. Inputs stopped being a
/// Swift literal in #1302; Outputs kept a hand-typed `.planned` on "Suggested tasks" — and that
/// literal had already gone stale in the same direction the connector row did. Suggestions ship
/// today, sourced from overdue work, the calendar, and connected sources, and the app was calling
/// them a future plan. A hand-written array cannot notice that it became wrong.
///
/// Reuses the app's authenticated HTTP client for base-URL + JWT + 401-refresh, exactly like
/// `AutomationInputsService` and `CheckinsService` (same `#if os(iOS)` transport split).
@MainActor
public protocol AutomationOutputsProviding: AnyObject {
    /// Derived output rows for one automation kind (`AutomationInputsKind.dailyBrief`).
    func outputs(kind: String) async throws -> [AutomationOutputRow]
}

// MARK: - Wire models (pinned contract)

/// Which output a row describes.
///
/// Decoded as a STRING with an `unrecognized` fallback: a newer server must not break an older
/// client, and an unknown code must never be coerced into a known one.
public enum AutomationOutputKind: Sendable, Equatable, Hashable {
    case dailyOrientation
    case attentionTriage
    case taskSuggestions
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "daily_orientation": self = .dailyOrientation
        case "attention_triage": self = .attentionTriage
        case "task_suggestions": self = .taskSuggestions
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .dailyOrientation: return "daily_orientation"
        case .attentionTriage: return "attention_triage"
        case .taskSuggestions: return "task_suggestions"
        case let .unrecognized(raw): return raw
        }
    }

    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

extension AutomationOutputKind: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Whether the automation is producing this output — server-derived, never hand-written.
///
/// `idle` is the state that carries the point of this whole surface: an output reads as
/// not-producing because there is no production record, not because someone typed a status.
public enum AutomationOutputState: Sendable, Equatable, Hashable {
    /// A producer is wired and it produced something for this user.
    case included
    /// A producer is wired but it has produced nothing for this user yet.
    case idle
    /// No producer exists for this output.
    case comingSoon
    /// A state this build of Rem does not know about. Rendered honestly, never as `.included`.
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "included": self = .included
        case "idle": self = .idle
        case "coming_soon": self = .comingSoon
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .included: return "included"
        case .idle: return "idle"
        case .comingSoon: return "coming_soon"
        case let .unrecognized(raw): return raw
        }
    }

    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

extension AutomationOutputState: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// One derived output row. Every nullable field in the wire contract is Optional here.
public struct AutomationOutputRow: Codable, Sendable, Equatable, Identifiable {
    public let output: AutomationOutputKind
    public let state: AutomationOutputState
    /// One sentence, server-authored. The app does not compose this copy.
    public let detail: String
    /// ISO 8601. May or may not carry fractional seconds — parse both forms.
    public let lastProducedAt: String?
    /// A real zero is a real answer ("the producer ran and had nothing"); `nil` means this
    /// producer has no meaningful count, which is a different fact entirely.
    public let lastItemCount: Int?

    public var id: String { output.wireValue }

    public init(
        output: AutomationOutputKind,
        state: AutomationOutputState,
        detail: String,
        lastProducedAt: String? = nil,
        lastItemCount: Int? = nil
    ) {
        self.output = output
        self.state = state
        self.detail = detail
        self.lastProducedAt = lastProducedAt
        self.lastItemCount = lastItemCount
    }
}

/// `GET /automations/:kind/outputs` returns `{ "outputs": [...] }`.
public struct AutomationOutputsResponse: Codable, Sendable, Equatable {
    public let outputs: [AutomationOutputRow]

    public init(outputs: [AutomationOutputRow]) {
        self.outputs = outputs
    }
}

// MARK: - Concrete (backend REST)

@MainActor
public final class AutomationOutputsService: AutomationOutputsProviding {

    private let decoder = JSONDecoder() // Backend returns camelCase keys; no strategy needed.
    private let basePath = "/api/v1/automations"

    public init() {}

    public func outputs(kind: String) async throws -> [AutomationOutputRow] {
        let encoded = kind.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind
        let (data, http) = try await Self.request(
            path: "\(basePath)/\(encoded)/outputs", method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(AutomationOutputsResponse.self, from: data).outputs
    }

    // MARK: Transport (platform-split, mirrors AutomationInputsService/CheckinsService)

    private static func request(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS)
        return try await AuthenticatedHttpClient.request(path: path, method: method, body: body)
        #else
        return try await MacAuthenticatedHttpClient.request(path: path, method: method, body: body)
        #endif
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AutomationOutputsServiceError.requestFailed(
                statusCode: response.statusCode, message: message)
        }
    }
}

public enum AutomationOutputsServiceError: LocalizedError, Equatable {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

// MARK: - Mock (previews, fixtures, tests)

/// In-memory `AutomationOutputsProviding`. Seeded rows are returned verbatim so a fixture can show
/// every state — including a state this build does not recognize — without a server.
@MainActor
public final class MockAutomationOutputsService: AutomationOutputsProviding {
    public var rows: [AutomationOutputRow]
    public var simulatedDelay: Duration
    public var failure: Error?
    public private(set) var requestedKinds: [String] = []

    public init(
        rows: [AutomationOutputRow]? = nil,
        simulatedDelay: Duration = .milliseconds(200),
        failure: Error? = nil
    ) {
        self.rows = rows ?? MockAutomationOutputsService.sample()
        self.simulatedDelay = simulatedDelay
        self.failure = failure
    }

    public func outputs(kind: String) async throws -> [AutomationOutputRow] {
        requestedKinds.append(kind)
        try? await Task.sleep(for: simulatedDelay)
        if let failure { throw failure }
        return rows
    }

    /// One row per state, so previews and the fixture route exercise the whole rendering surface.
    public static func sample() -> [AutomationOutputRow] {
        [
            AutomationOutputRow(
                output: .dailyOrientation,
                state: .included,
                detail: "Orients you to what is on deck, overdue, blocked, and already done.",
                lastProducedAt: "2026-08-10T15:15:00.250Z"),
            AutomationOutputRow(
                output: .attentionTriage,
                state: .idle,
                detail: "Nothing is blocked or overdue right now, so there is nothing to surface.",
                lastItemCount: 0),
            AutomationOutputRow(
                output: .taskSuggestions,
                state: .included,
                detail: "Proposes tasks from your overdue work, your calendar, and your connected sources. A suggestion becomes a durable task only after you accept it.",
                lastItemCount: 3),
        ]
    }
}
