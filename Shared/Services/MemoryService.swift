import Foundation

/// Read/write surface for "What Rem remembers about you" — the simple "Dreaming" memory store.
///
/// Canonical store is the backend `user_memory` table; this hits the REST endpoints under
/// `/api/v1/memory`. In this first slice the list is user-managed; auto-extraction is the
/// follow-up (the API already accepts a `source`).
@MainActor
public protocol MemoryProviding: AnyObject {
    /// List the user's facts (newest first).
    func memories() async throws -> [UserMemory]
    /// Add a fact. `source` attributes how the fact was captured (nil/"user" = user-typed,
    /// "onboarding" = conversational capture, "auto" = extractor). Returns the persisted row.
    func addMemory(fact: String, source: String?) async throws -> UserMemory
    /// Edit a fact. Returns the updated row.
    func updateMemory(id: String, fact: String) async throws -> UserMemory
    /// Delete a fact.
    func deleteMemory(id: String) async throws
}

public extension MemoryProviding {
    /// Convenience for the common user-typed path (source defaults to `nil` → "user").
    func addMemory(fact: String) async throws -> UserMemory {
        try await addMemory(fact: fact, source: nil)
    }
}

// MARK: - Concrete (backend REST)

/// Talks to the RemClaw Express backend memory endpoints. Reuses the app's existing
/// authenticated HTTP client for base-URL + JWT + 401-refresh, exactly like
/// `TaskCommentService` — the same `#if os(iOS)` split, no new auth path:
/// - iOS:   `AuthenticatedHttpClient.request(...)`
/// - macOS: `MacAuthenticatedHttpClient.request(...)`
@MainActor
public final class MemoryService: MemoryProviding {

    private let decoder: JSONDecoder = {
        // No `.convertFromSnakeCase` — UserMemory declares explicit CodingKeys
        // (created_at, updated_at); a global strategy would conflict (same gotcha as
        // TaskCommentService / RemTaskApiService).
        JSONDecoder()
    }()

    public init() {}

    private let basePath = "/api/v1/memory"

    // MARK: MemoryProviding

    public func memories() async throws -> [UserMemory] {
        let (data, http) = try await Self.request(path: basePath, method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(MemoriesEnvelope.self, from: data).memories
    }

    public func addMemory(fact: String, source: String?) async throws -> UserMemory {
        // Backend POST /memory accepts `{ fact, source? }` (see user-memory.routes.ts →
        // normalizeSource). Conversational onboarding capture stamps source="onboarding"
        // so the agent + Memory screen can attribute where the fact came from.
        var payload: [String: String] = ["fact": fact]
        if let source, !source.isEmpty { payload["source"] = source }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await Self.request(path: basePath, method: "POST", body: body)
        try Self.check(http, data: data)
        return try decoder.decode(UserMemory.self, from: data)
    }

    public func updateMemory(id: String, fact: String) async throws -> UserMemory {
        let body = try JSONSerialization.data(withJSONObject: ["fact": fact])
        let (data, http) = try await Self.request(path: "\(basePath)/\(id)", method: "PATCH", body: body)
        try Self.check(http, data: data)
        return try decoder.decode(UserMemory.self, from: data)
    }

    public func deleteMemory(id: String) async throws {
        let (data, http) = try await Self.request(path: "\(basePath)/\(id)", method: "DELETE")
        try Self.check(http, data: data)
    }

    // MARK: Transport (platform-split, mirrors TaskCommentService)

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
            throw MemoryServiceError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }

    /// `GET /memory` returns `{ "memories": [...] }`.
    private struct MemoriesEnvelope: Decodable {
        let memories: [UserMemory]
    }
}

public enum MemoryServiceError: LocalizedError {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

// MARK: - Mock (previews)

/// In-memory `MemoryProviding` seeded with a few sample facts, for SwiftUI previews.
@MainActor
public final class MockMemoryService: MemoryProviding {
    public private(set) var store: [UserMemory]
    public var simulatedDelay: Duration

    public init(store: [UserMemory]? = nil, simulatedDelay: Duration = .milliseconds(250)) {
        self.store = store ?? MockMemoryService.sample()
        self.simulatedDelay = simulatedDelay
    }

    public func memories() async throws -> [UserMemory] {
        try? await Task.sleep(for: simulatedDelay)
        return store
    }

    public func addMemory(fact: String, source: String?) async throws -> UserMemory {
        try? await Task.sleep(for: simulatedDelay)
        let memory = UserMemory(id: UUID().uuidString, fact: fact, source: source ?? "user")
        store.insert(memory, at: 0)
        return memory
    }

    public func updateMemory(id: String, fact: String) async throws -> UserMemory {
        try? await Task.sleep(for: simulatedDelay)
        let updated = UserMemory(id: id, fact: fact, source: "user")
        if let idx = store.firstIndex(where: { $0.id == id }) { store[idx] = updated }
        return updated
    }

    public func deleteMemory(id: String) async throws {
        try? await Task.sleep(for: simulatedDelay)
        store.removeAll { $0.id == id }
    }

    public static func sample() -> [UserMemory] {
        [
            UserMemory(id: "m1", fact: "Prefers morning workouts before 8am", source: "user"),
            UserMemory(id: "m2", fact: "Has two cats, Mochi and Soba", source: "user"),
            UserMemory(id: "m3", fact: "Calls mom every Sunday evening", source: "user"),
        ]
    }
}
