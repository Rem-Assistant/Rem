import Foundation

/// One global daily check-in slot — the founder's simplified routines model.
///
/// Instead of a per-task schedule, the user sets up to three GLOBAL daily check-in times —
/// morning / midday / night — each independently toggleable with its own delivery hour. At
/// each enabled slot's local hour the backend scheduler builds the user's Daily Brief over
/// ALL their tasks and sends a push that deep-links into the brief (see backend
/// `daily-checkins.ts` + `checkin.routes.ts`). Connectors stay global and agent instructions
/// live on the tasks; the only schedule is these three slots.
///
/// Mirrors one entry of `GET /api/v1/checkins` (keys are already camelCase from the backend's
/// `formatCheckin`, so no decoding strategy is needed). `lastRunAt` is kept as a String so
/// decoding never depends on a JSONDecoder dateStrategy (see CLAUDE.md ISO 8601 gotcha).
public struct Checkin: Codable, Identifiable, Sendable, Hashable {
    /// Fixed slot id: "morning" | "midday" | "night".
    public let slot: String
    /// Whether this check-in fires.
    public var enabled: Bool
    /// Local hour-of-day (0–23) the check-in fires, resolved against `timezone`.
    public var deliveryHour: Int
    /// Local minute-of-hour (0–59) the check-in fires, resolved against `timezone`.
    /// Paired with `deliveryHour` so the time picker holds the full chosen time (e.g. 8:10).
    public var deliveryMinute: Int
    /// IANA timezone the delivery hour is interpreted in, e.g. "America/Los_Angeles".
    public var timezone: String
    /// ISO-8601 string of the last delivery, or nil. Never decoded as a Date.
    public let lastRunAt: String?

    public var id: String { slot }

    /// The three slots in chronological order — drives row ordering in settings.
    public static let slotOrder = ["morning", "midday", "night"]

    /// Human label for the settings row.
    public var displayName: String {
        switch slot {
        case "morning": return "Morning"
        case "midday": return "Midday"
        case "night": return "Night"
        default: return slot.capitalized
        }
    }

    /// SF Symbol for the row icon.
    public var icon: String {
        switch slot {
        case "morning": return "sunrise.fill"
        case "midday": return "sun.max.fill"
        case "night": return "moon.stars.fill"
        default: return "clock.fill"
        }
    }

    public init(
        slot: String,
        enabled: Bool,
        deliveryHour: Int,
        deliveryMinute: Int = 0,
        timezone: String,
        lastRunAt: String? = nil
    ) {
        self.slot = slot
        self.enabled = enabled
        self.deliveryHour = deliveryHour
        self.deliveryMinute = deliveryMinute
        self.timezone = timezone
        self.lastRunAt = lastRunAt
    }

    private enum CodingKeys: String, CodingKey {
        case slot, enabled, deliveryHour, deliveryMinute, timezone, lastRunAt
    }

    /// Custom decode so `deliveryMinute` tolerates an older backend that predates the
    /// column (migration 032): it defaults to :00 rather than failing the whole decode
    /// during a mixed-version rollout. Every other field decodes as synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.slot = try c.decode(String.self, forKey: .slot)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.deliveryHour = try c.decode(Int.self, forKey: .deliveryHour)
        self.deliveryMinute = try c.decodeIfPresent(Int.self, forKey: .deliveryMinute) ?? 0
        self.timezone = try c.decode(String.self, forKey: .timezone)
        self.lastRunAt = try c.decodeIfPresent(String.self, forKey: .lastRunAt)
    }
}
