import Foundation

/// Read/update surface for Check-ins — the user's up-to-three GLOBAL daily check-in times
/// (morning / midday / night). The backend owns the schedule and delivery: at each enabled
/// slot's local hour it builds the Daily Brief over ALL the user's tasks and sends a push
/// (see backend `daily-checkins.ts`). This protocol just hits the REST endpoints under
/// `/api/v1/checkins` to read and toggle/configure the three slots.
@MainActor
public protocol CheckinsProviding: AnyObject {
    /// The three slots, with defaults filled for slots the user has never configured.
    func checkins() async throws -> [Checkin]
    /// Upsert one slot. Returns the stored slot. `timezone` defaults to the device's current
    /// IANA timezone so a freshly-enabled slot fires at the user's wall-clock time.
    func update(
        slot: String, enabled: Bool, deliveryHour: Int, deliveryMinute: Int, timezone: String
    ) async throws -> Checkin
}

public extension CheckinsProviding {
    /// Convenience: upsert a slot using the device's current timezone.
    func update(
        slot: String, enabled: Bool, deliveryHour: Int, deliveryMinute: Int
    ) async throws -> Checkin {
        try await update(
            slot: slot, enabled: enabled, deliveryHour: deliveryHour,
            deliveryMinute: deliveryMinute, timezone: TimeZone.current.identifier)
    }
}

// MARK: - Concrete (backend REST)

/// Talks to the RemClaw Express backend check-in endpoints. Reuses the app's authenticated
/// HTTP client for base-URL + JWT + 401-refresh, exactly like `ComposioService` — the same
/// `#if os(iOS)` transport split, no new auth path.
@MainActor
public final class CheckinsService: CheckinsProviding {

    private let decoder = JSONDecoder() // Backend returns camelCase keys; no strategy needed.

    public init() {}

    private let basePath = "/api/v1/checkins"

    public func checkins() async throws -> [Checkin] {
        let (data, http) = try await Self.request(path: basePath, method: "GET")
        try Self.check(http, data: data)
        let slots = try decoder.decode(CheckinsEnvelope.self, from: data).checkins
        // Keep chronological order regardless of backend row order.
        return slots.sorted { lhsIndex($0) < lhsIndex($1) }
    }

    public func update(
        slot: String, enabled: Bool, deliveryHour: Int, deliveryMinute: Int, timezone: String
    ) async throws -> Checkin {
        // Backend PUT /checkins/:slot accepts `{ enabled, deliveryHour, deliveryMinute, timezone }`.
        let body = try JSONSerialization.data(withJSONObject: [
            "enabled": enabled,
            "deliveryHour": deliveryHour,
            "deliveryMinute": deliveryMinute,
            "timezone": timezone,
        ])
        let (data, http) = try await Self.request(
            path: "\(basePath)/\(slot)", method: "PUT", body: body)
        try Self.check(http, data: data)
        return try decoder.decode(Checkin.self, from: data)
    }

    private func lhsIndex(_ c: Checkin) -> Int {
        Checkin.slotOrder.firstIndex(of: c.slot) ?? Int.max
    }

    // MARK: Transport (platform-split, mirrors ComposioService)

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
            throw CheckinsServiceError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }

    /// `GET /checkins` returns `{ "checkins": [...] }`.
    private struct CheckinsEnvelope: Decodable {
        let checkins: [Checkin]
    }
}

public enum CheckinsServiceError: LocalizedError {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

// MARK: - Mock (previews)

/// In-memory `CheckinsProviding` seeded with the three default slots, for SwiftUI previews.
@MainActor
public final class MockCheckinsService: CheckinsProviding {
    public private(set) var store: [Checkin]
    public var simulatedDelay: Duration

    public init(store: [Checkin]? = nil, simulatedDelay: Duration = .milliseconds(200)) {
        self.store = store ?? MockCheckinsService.sample()
        self.simulatedDelay = simulatedDelay
    }

    public func checkins() async throws -> [Checkin] {
        try? await Task.sleep(for: simulatedDelay)
        return store
    }

    public func update(
        slot: String, enabled: Bool, deliveryHour: Int, deliveryMinute: Int, timezone: String
    ) async throws -> Checkin {
        try? await Task.sleep(for: simulatedDelay)
        let priorLastRunAt = store.first(where: { $0.slot == slot })?.lastRunAt
        let updated = Checkin(
            slot: slot, enabled: enabled, deliveryHour: deliveryHour,
            deliveryMinute: deliveryMinute, timezone: timezone,
            lastRunAt: priorLastRunAt)
        if let idx = store.firstIndex(where: { $0.slot == slot }) {
            store[idx] = updated
        }
        return updated
    }

    public static func sample() -> [Checkin] {
        let tz = TimeZone.current.identifier
        return [
            Checkin(slot: "morning", enabled: true, deliveryHour: 8, timezone: tz),
            Checkin(slot: "midday", enabled: false, deliveryHour: 12, timezone: tz),
            Checkin(slot: "night", enabled: false, deliveryHour: 20, timezone: tz),
        ]
    }
}
