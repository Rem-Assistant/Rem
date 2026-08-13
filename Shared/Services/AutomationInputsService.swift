import Foundation

/// Read surface for an automation's **derived** input contract.
///
/// `GET /api/v1/automations/:kind/inputs` reports what the runner can actually read right now:
/// the server joins its own connector descriptors against this user's ACTIVE Composio accounts and
/// the last collect recorded in `daily_brief_artifacts.input_manifest`. The app renders that answer
/// and never authors it — a hand-written Swift array cannot observe a connector that started
/// failing, which is exactly how a six-times-failing Gmail collect kept rendering as "Included".
///
/// Reuses the app's authenticated HTTP client for base-URL + JWT + 401-refresh, exactly like
/// `CheckinsService` and `ComposioService` (same `#if os(iOS)` transport split, no new auth path).
@MainActor
public protocol AutomationInputsProviding: AnyObject {
    /// Derived input rows for one automation kind (`AutomationInputsKind.dailyBrief`).
    func inputs(kind: String) async throws -> [AutomationInputRow]
}

/// Wire values for the `:kind` path segment. Kept as constants rather than an enum so an unknown
/// kind is a caller mistake, not a decode failure.
public enum AutomationInputsKind {
    public static let dailyBrief = "daily-brief"
}

// MARK: - Wire models (pinned contract)

/// Which family of input a row describes.
///
/// Decoded as a STRING with an `unrecognized` fallback: a newer server must not break an older
/// client, and an unknown code must never be coerced into a friendlier known one.
public enum AutomationInputCapability: Sendable, Equatable, Hashable {
    case remTasks
    case remCalendarItems
    case connector
    case cloudBrowser
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "rem_tasks": self = .remTasks
        case "rem_calendar_items": self = .remCalendarItems
        case "connector": self = .connector
        case "cloud_browser": self = .cloudBrowser
        default: self = .unrecognized(wireValue)
        }
    }

    /// The exact string this case came from (or would be sent as). Unknown codes keep their raw
    /// text so identity stays stable across a refresh.
    public var wireValue: String {
        switch self {
        case .remTasks: return "rem_tasks"
        case .remCalendarItems: return "rem_calendar_items"
        case .connector: return "connector"
        case .cloudBrowser: return "cloud_browser"
        case let .unrecognized(raw): return raw
        }
    }

    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

extension AutomationInputCapability: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Whether this input is feeding the automation right now — server-derived, never hand-written.
///
/// Decoded as a STRING with an `unrecognized` fallback for the same reason as
/// ``AutomationInputCapability``: silently mapping an unknown state onto `.included` would
/// reintroduce the "claims Included while failing" bug this whole surface replaces.
public enum AutomationInputState: Sendable, Equatable, Hashable {
    /// A descriptor exists and the user has at least one ACTIVE account for it.
    case included
    /// A descriptor exists but there is no ACTIVE account. The row is a call to action.
    case notConnected
    /// Connected, but the most recent collect recorded an `unavailableReason`.
    case unavailable
    /// No descriptor exists yet for this capability.
    case comingSoon
    /// A state this build of Rem does not know about. Rendered honestly, never as `.included`.
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "included": self = .included
        case "not_connected": self = .notConnected
        case "unavailable": self = .unavailable
        case "coming_soon": self = .comingSoon
        default: self = .unrecognized(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .included: return "included"
        case .notConnected: return "not_connected"
        case .unavailable: return "unavailable"
        case .comingSoon: return "coming_soon"
        case let .unrecognized(raw): return raw
        }
    }

    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

extension AutomationInputState: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The connector a `connector` row is about. `source` is the same identifier the backend's
/// `NormalizedSignal.source` and `ConnectorSignalDescriptor.source` use — no renaming between
/// layers, so a row can be correlated with its collect evidence.
public struct AutomationInputConnector: Codable, Sendable, Equatable, Hashable {
    public let source: String
    public let displayName: String

    public init(source: String, displayName: String) {
        self.source = source
        self.displayName = displayName
    }
}

/// One derived input row. Every nullable field in the wire contract is Optional here.
public struct AutomationInputRow: Codable, Sendable, Equatable, Identifiable {
    public let capability: AutomationInputCapability
    public let state: AutomationInputState
    /// One sentence, server-authored. The app does not compose this copy.
    public let detail: String
    /// Present for `connector` rows; `nil` for first-party capabilities.
    public let connector: AutomationInputConnector?
    /// ISO 8601. May or may not carry fractional seconds — parse both forms.
    public let lastCollectedAt: String?
    public let lastItemCount: Int?
    public let lastUnavailableReason: String?

    /// A capability can appear more than once (one row per connector), so identity has to include
    /// the source. Unknown capabilities keep their raw code, so identity survives a server that
    /// added a family this build has never heard of.
    public var id: String { "\(capability.wireValue)#\(connector?.source ?? "")" }

    public init(
        capability: AutomationInputCapability,
        state: AutomationInputState,
        detail: String,
        connector: AutomationInputConnector? = nil,
        lastCollectedAt: String? = nil,
        lastItemCount: Int? = nil,
        lastUnavailableReason: String? = nil
    ) {
        self.capability = capability
        self.state = state
        self.detail = detail
        self.connector = connector
        self.lastCollectedAt = lastCollectedAt
        self.lastItemCount = lastItemCount
        self.lastUnavailableReason = lastUnavailableReason
    }
}

/// `GET /automations/:kind/inputs` returns `{ "inputs": [...] }`.
public struct AutomationInputsResponse: Codable, Sendable, Equatable {
    public let inputs: [AutomationInputRow]

    public init(inputs: [AutomationInputRow]) {
        self.inputs = inputs
    }
}

// MARK: - Concrete (backend REST)

@MainActor
public final class AutomationInputsService: AutomationInputsProviding {

    private let decoder = JSONDecoder() // Backend returns camelCase keys; no strategy needed.
    private let basePath = "/api/v1/automations"

    public init() {}

    public func inputs(kind: String) async throws -> [AutomationInputRow] {
        let encoded = kind.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind
        let (data, http) = try await Self.request(
            path: "\(basePath)/\(encoded)/inputs", method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(AutomationInputsResponse.self, from: data).inputs
    }

    // MARK: Transport (platform-split, mirrors CheckinsService/ComposioService)

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
            throw AutomationInputsServiceError.requestFailed(
                statusCode: response.statusCode, message: message)
        }
    }
}

public enum AutomationInputsServiceError: LocalizedError, Equatable {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

// MARK: - Mock (previews, fixtures, tests)

/// In-memory `AutomationInputsProviding`. Seeded rows are returned verbatim so a fixture can show
/// every state — including a state this build does not recognize — without a server.
@MainActor
public final class MockAutomationInputsService: AutomationInputsProviding {
    public var rows: [AutomationInputRow]
    public var simulatedDelay: Duration
    public var failure: Error?
    public private(set) var requestedKinds: [String] = []

    public init(
        rows: [AutomationInputRow]? = nil,
        simulatedDelay: Duration = .milliseconds(200),
        failure: Error? = nil
    ) {
        self.rows = rows ?? MockAutomationInputsService.sample()
        self.simulatedDelay = simulatedDelay
        self.failure = failure
    }

    public func inputs(kind: String) async throws -> [AutomationInputRow] {
        requestedKinds.append(kind)
        try? await Task.sleep(for: simulatedDelay)
        if let failure { throw failure }
        return rows
    }

    /// One row per state, so previews and the fixture route exercise the whole rendering surface.
    public static func sample() -> [AutomationInputRow] {
        [
            AutomationInputRow(
                capability: .remTasks,
                state: .included,
                detail: "Reads scheduled, overdue, blocked, and completed task rows stored by Rem.",
                lastCollectedAt: "2026-08-10T13:05:00.250Z",
                lastItemCount: 14),
            AutomationInputRow(
                capability: .remCalendarItems,
                state: .included,
                detail: "Includes calendar-event rows already available in Rem's task store.",
                lastCollectedAt: "2026-08-10T13:05:00Z",
                lastItemCount: 3),
            AutomationInputRow(
                capability: .connector,
                state: .unavailable,
                detail: "Gmail is connected, but its last collection didn't complete.",
                connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
                lastCollectedAt: "2026-08-10T11:05:00Z",
                lastItemCount: 0,
                lastUnavailableReason: "connector_unavailable"),
            AutomationInputRow(
                capability: .connector,
                state: .notConnected,
                detail: "Connect Slack and Daily Brief can read the last day of messages.",
                connector: AutomationInputConnector(source: "slack", displayName: "Slack")),
            AutomationInputRow(
                capability: .cloudBrowser,
                state: .comingSoon,
                detail: "Cloud-browser findings aren't collected for Daily Brief yet."),
        ]
    }
}
