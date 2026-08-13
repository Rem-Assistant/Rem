import Foundation

/// Why a task row RECEDES without being hidden.
///
/// **The founder's decision, verbatim:** staleness gets the *same visual de-emphasis as `blocked`,
/// but a different label*. Reusing `blocked` for both was considered and rejected — same treatment,
/// distinct word. This type is where "same treatment" is expressed once so the two cannot drift.
///
/// **They are two independent facts, and both can be true at once.** `blocked` is the user's own
/// workflow status; `stale` is a separate column that records that Rem stopped asking. A task can be
/// blocked *and* stale, so this resolves to a LIST, not a winner — see `reasons(status:staleAt:)`.
/// Rendering only one of them would hide a fact the user set themselves.
///
/// **Why stale is not a `status` value** (the constraint that makes this type necessary at all):
/// `status` is used as a *filter* in at least five backend consumers, so a `'stale'` status would
/// drop the row from every one of them and the task would vanish from the app. It would also
/// overwrite the real status, and `TaskEvent.statusFromBackend` falls back to `.todo` for unknown
/// values, so the phone would silently render a stale task as an ordinary to-do. The full reasoning
/// lives in `backend/src/db/migrations/116_add_task_staleness.sql`.
public enum TaskDeemphasisReason: String, Sendable, Hashable, CaseIterable, Codable {
    /// The user's own workflow status (`tasks.status = 'blocked'`, migrations 027 / 029). The task
    /// can't proceed — it needs information or is waiting on an input. A REAL status, selectable
    /// from the status menu and applied by an agent run.
    case blocked

    /// `tasks.stale_at` is non-null (migration 116). The brief surfaced this task
    /// `BRIEF_STALE_THRESHOLD` (3) times running and the user never acted, so the brief stopped
    /// handing it to the authoring model. The task is untouched otherwise — visible, readable,
    /// un-deleted, real status intact — and any user action clears it.
    case stale

    /// The pill text. Deliberately the same word the column, the migration and
    /// the product decision use: a UI word that doesn't map back to the stored fact is how
    /// client and server start disagreeing about what the user was told.
    public var label: String {
        switch self {
        case .blocked: "Blocked"
        case .stale: "Stale"
        }
    }

    /// One line of plain language for the places with room for it (task detail, accessibility).
    /// Says what happened, not what the schema is called.
    ///
    /// The stale copy names the actions that ACTUALLY clear `stale_at`, and no others. Exactly three
    /// backend paths reset it: `PATCH /tasks/:id` (any edit — retitle, re-prioritise, reschedule,
    /// complete, re-file), creating a user comment, and dispatching an agent run. **Opening a task
    /// does not** — `GET /tasks/:id` performs no reset, and tapping the row is a navigation, not a
    /// mutation. Earlier copy here said "Touch it to bring it back", which promised behaviour no
    /// code implements; a user who tapped in, saw the badge survive, and tapped again would be
    /// right to conclude the app was lying to them.
    public var detail: String {
        switch self {
        case .blocked: "Waiting on something before it can move."
        case .stale: "Rem stopped bringing this up in your brief. Edit or comment on it to bring it back."
        }
    }

    /// SF Symbol. `blocked` keeps the glyph the status menu already uses
    /// (`TaskStatusIndicator`); `stale` uses the notifications-off glyph because "stopped asking"
    /// is exactly what happened.
    public var systemImage: String {
        switch self {
        case .blocked: "exclamationmark.octagon"
        case .stale: "bell.slash"
        }
    }

    /// Screen-reader text: the label alone ("Stale") does not tell anyone what Rem did.
    public var accessibilityLabel: String { "\(label). \(detail)" }

    /// The raw backend `tasks.status` value that means blocked. Matched EXACTLY (case-insensitively),
    /// never by substring: `status.contains("block")` also matches "unblocked", and a machine
    /// decision made by substring is the wrong layer (principle 5).
    private static let blockedStatus = "blocked"

    /// Resolve both facts, in the order they should read: `blocked` first (it is the status the
    /// user set), `stale` second (it is what Rem did).
    ///
    /// The two surfaces carry staleness differently — `GET /tasks` sends the `stale_at` timestamp,
    /// `GET /brief` sends a derived `is_stale` boolean — so this boolean form is the shared core and
    /// the `staleAt:` overload delegates to it. One resolver, so the two surfaces cannot disagree
    /// about what "stale" looks like.
    ///
    /// - Parameters:
    ///   - status: raw backend `tasks.status` (`pending` / `in_progress` / `completed` / `blocked`).
    ///     Read ALONGSIDE staleness, never instead of it.
    ///   - isStale: whether `tasks.stale_at` is set.
    /// - Returns: `[]` when the task is neither — the overwhelmingly common case, and the one the
    ///   callers use to decide whether to dim at all.
    public static func reasons(status: String?, isStale: Bool) -> [TaskDeemphasisReason] {
        var resolved: [TaskDeemphasisReason] = []
        if let status, status.caseInsensitiveCompare(blockedStatus) == .orderedSame {
            resolved.append(.blocked)
        }
        if isStale {
            resolved.append(.stale)
        }
        return resolved
    }

    /// Timestamp form, for the task surfaces that carry the raw `stale_at` column.
    ///
    /// - Parameter staleAt: raw backend `tasks.stale_at`. Non-nil ⟺ stale. `nil` for every task the
    ///   user has touched, and for every task on a client not yet told about the field.
    public static func reasons(status: String?, staleAt: Date?) -> [TaskDeemphasisReason] {
        reasons(status: status, isStale: staleAt != nil)
    }
}
