import SwiftUI

/// Read-only protocol for displaying tasks across iOS and macOS.
/// Both `TaskEvent` (iOS, SwiftData) and `MacTask` (Mac, plain struct) conform.
///
/// Property names prefixed with `display` avoid conflicts with stored properties
/// on concrete types (e.g. TaskEvent.category is non-optional String).
public protocol TaskDisplayable {
    var displayId: String { get }
    var title: String { get }
    var status: String { get }
    var displayCategory: String? { get }
    var startDate: Date? { get }
    var endDate: Date? { get }
    var isEvent: Bool { get }
    var isCompleted: Bool { get }
    var displayPriority: String? { get }
    var notes: String? { get }
    var formattedDuration: String? { get }

    /// Structured agent run-state (backend `tasks.run_status`, migration 019), when the
    /// task carries one. `nil` = no run has touched this task. Raw backend string
    /// (`running`/`review`/`blocked`/`done`/`idle`); resolve to `TaskRunStatus` for a
    /// structured render. DISTINCT from `status` — see `TaskRunStatus` docs.
    var runStatus: String? { get }

    /// Backend `tasks.stale_at` (migration 116). Non-nil ⟺ the brief surfaced this task
    /// `BRIEF_STALE_THRESHOLD` times with no user action, so it stopped asking.
    ///
    /// A SEPARATE FIELD FROM `status`, ON PURPOSE, and read alongside it — never instead of it. A
    /// task can be blocked *and* stale, and a `'stale'` status value would both destroy the real
    /// status and drop the row from the five backend consumers that filter on `status`. Backend is
    /// the source of truth; clients only read it, and any user action clears it there.
    var staleAt: Date? { get }
}

public extension TaskDisplayable {
    /// Default so conformers that don't yet carry run-state (previews, fixtures)
    /// keep compiling. Concrete task models override this with the real value.
    var runStatus: String? { nil }

    /// Default for conformers that predate staleness (previews, fixtures). `nil` = "never nagged
    /// about", which is exactly the state a fresh task is in.
    var staleAt: Date? { nil }

    /// Structured form of `runStatus` when it matches a known case (principle 5).
    /// `nil` when there's no run, or the backend sent a value this client doesn't
    /// recognize yet — the view drops the indicator rather than guessing.
    var resolvedRunStatus: TaskRunStatus? {
        guard let runStatus else { return nil }
        return TaskRunStatus(rawValue: runStatus)
    }

    /// The brief has gone quiet on this task (migration 116).
    var isStale: Bool { staleAt != nil }

    /// Every reason this row should recede, in reading order. Both `blocked` and `stale` can be
    /// present — the view renders both labels so neither hides the other.
    var deemphasisReasons: [TaskDeemphasisReason] {
        TaskDeemphasisReason.reasons(status: status, staleAt: staleAt)
    }

    /// Whether the row gets the de-emphasis treatment at all. Computed ONCE per row and applied
    /// once: two stacked `.opacity(0.55)` modifiers multiply to 0.30, so a blocked-and-stale task
    /// would fade twice as far as either alone and read as an error.
    var isDeemphasized: Bool { !deemphasisReasons.isEmpty }
}

/// Provides task store operations for shared views.
/// Both iOS ViewModels and Mac TaskStore conform.
@MainActor
public protocol TaskStoreProviding: AnyObject, Observable {
    associatedtype TaskItem: TaskDisplayable

    var isLoading: Bool { get }
    var lastSyncDate: Date? { get }

    var unscheduledTasks: [TaskItem] { get }
    func tasks(for date: Date) -> [TaskItem]

    func completeTask(_ task: TaskItem) async
    func deleteTask(_ task: TaskItem) async
    func snoozeTask(_ task: TaskItem) async
    func refresh() async
}
