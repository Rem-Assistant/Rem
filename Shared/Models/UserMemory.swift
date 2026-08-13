import Foundation

/// A single durable fact Rem remembers about the user — the "Dreaming" memory store.
///
/// Mirrors the backend `user_memory` row (see backend `020_create_user_memory.sql`).
/// Canonical store is backend Postgres, so iOS and Mac render the identical list.
///
/// In this first slice the list is entirely **user-managed** (added / edited / deleted in
/// Settings). Auto-extraction — writing 2-3 facts after each chat/session and stamping
/// `source` for attribution — is the follow-up; the model already carries `source`.
public struct UserMemory: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let fact: String
    /// How the fact was captured: `nil`/"user" = user-typed; a future extractor would
    /// stamp e.g. "chat"/"session". Used only for attribution; not shown in this slice.
    public let source: String?
    /// ISO-8601 strings from the backend. Kept as String so decoding never depends on a
    /// JSONDecoder dateStrategy (see CLAUDE.md ISO 8601 gotcha).
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fact
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        fact: String,
        source: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.fact = fact
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when Rem wrote this fact itself via the scheduled extractor (source == "auto"),
    /// vs the user typing it (source nil / "user"). Lets the UI badge auto-captured facts and
    /// communicate the auto-schedule. See backend scripts/extract-memories.ts.
    public var isAutoCaptured: Bool { source == "auto" }
}

public extension Sequence where Element == UserMemory {
    /// The most recent `createdAt` among auto-captured facts, parsed to a `Date` — the basis for
    /// a "Rem last refreshed this …" line on the Memory screen. `nil` when nothing was
    /// auto-captured yet. Parses ISO-8601 with and without fractional seconds (CLAUDE.md gotcha).
    var lastAutoCapturedAt: Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        func parse(_ s: String) -> Date? { withFrac.date(from: s) ?? withoutFrac.date(from: s) }

        return self
            .filter { $0.isAutoCaptured }
            .compactMap { $0.createdAt.flatMap(parse) }
            .max()
    }
}
