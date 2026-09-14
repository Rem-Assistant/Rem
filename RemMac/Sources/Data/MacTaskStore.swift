import Foundation
import os

private let log = Logger(subsystem: "app.remclaw.mac", category: "tasks")

/// Lightweight task model for the Mac app.
/// Mirrors the essential fields from the iOS TaskEvent without SwiftData dependency.
struct MacTask: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let category: String?
    let startDate: Date?
    let endDate: Date?
    let dueDate: Date?
    let notes: String?
    /// The USER's half of the co-authored description (backend migration 120) — the
    /// context every agent run reads. Distinct from `notes`, which the backend never
    /// stored. Read-only on Mac today; iOS owns the editor.
    let taskDescription: String?
    /// REM's half: the current state the last run recorded. Always read-only — the
    /// merge that keeps the two authors apart lives on the backend.
    let agentContext: String?
    let isEvent: Bool
    let priority: String?
    let createdAt: Date?
    let updatedAt: Date?
    /// Structured agent run-state (backend `tasks.run_status`, migration 019). DISTINCT
    /// from `status` — see `TaskRunStatus`. Backend is the source of truth; the Mac app
    /// only reads these. `nil` = no run has touched this task.
    var runStatus: String?
    var runId: String?
    var sessionKey: String?
    var runStartedAt: Date?
    /// Backend `tasks.stale_at` (migration 116). Non-nil ⟺ the brief asked three times and got no
    /// answer, so it stopped asking. ORTHOGONAL to `status` — a task can be blocked AND stale — so
    /// it is read alongside it, never folded into it. Backend is the source of truth; the Mac app
    /// only reads it, and any user action clears it there.
    var staleAt: Date?

    var isCompleted: Bool { status == "completed" }
    var isScheduled: Bool { startDate != nil }
}

/// Observable store that fetches tasks from the backend HTTP API.
/// Uses the same REST endpoints as iOS (GET/POST/PATCH/DELETE /api/v1/tasks).
@MainActor @Observable
final class MacTaskStore {
    // MARK: - State

    private(set) var allTasks: [MacTask] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastSyncDate: Date?

    // MARK: - Computed Filters

    /// Tasks with no start date (inbox items).
    var unscheduledTasks: [MacTask] {
        allTasks.filter { !$0.isCompleted && $0.startDate == nil }
    }

    /// Tasks scheduled for a specific date.
    func tasks(for date: Date) -> [MacTask] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return allTasks
            .filter { task in
                guard !task.isCompleted, let taskDate = task.startDate else { return false }
                return calendar.startOfDay(for: taskDate) == startOfDay
            }
            .sorted { lhs, rhs in
                (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
            }
    }

    /// Completed tasks.
    var completedTasks: [MacTask] {
        allTasks.filter { $0.isCompleted }
    }

    // MARK: - Fetch from Backend API

    /// Fetches tasks via the backend REST API (GET /api/v1/tasks).
    func fetchTasks() async {
        isLoading = true
        lastError = nil

        do {
            let (data, http) = try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/tasks?limit=200&offset=0",
                method: "GET"
            )

            guard (200...299).contains(http.statusCode) else {
                lastError = "Failed to fetch tasks (status \(http.statusCode))"
                isLoading = false
                return
            }

            let tasks = try parseTasks(from: data)
            allTasks = tasks
            lastSyncDate = Date()
        } catch {
            lastError = error.localizedDescription
            log.error("fetch failed: \(error)")
        }

        isLoading = false
    }

    // MARK: - Task Actions (Backend API)

    /// Mark a task as completed via PATCH /api/v1/tasks/:id.
    func completeTask(_ task: MacTask) async {
        lastError = nil
        guard let result = await patchTask(id: task.id, body: ["status": "completed"]) else { return }
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = result
        }
    }

    /// Commit a status proposed in the task collaboration thread (CONTRACT §4 —
    /// accepting a proposal is a separate write from the comment that proposed it).
    /// PATCHes the backend `tasks` table so the cloud agent and other devices see
    /// the same canonical state. Mirrors iOS `TaskEventViewModel.commitCollaborationStatus`.
    /// `status` is already in backend form ("pending" | "in_progress" | "completed").
    func commitCollaborationStatus(_ status: String, for task: MacTask) async {
        lastError = nil
        guard let result = await patchTask(id: task.id, body: ["status": status]) else { return }
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = result
        }
    }

    /// Delete a task via DELETE /api/v1/tasks/:id.
    func deleteTask(_ task: MacTask) async {
        lastError = nil
        do {
            let (_, http) = try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/tasks/\(task.id)",
                method: "DELETE"
            )
            if (200...299).contains(http.statusCode) {
                allTasks.removeAll { $0.id == task.id }
            } else {
                lastError = "Failed to delete task (status \(http.statusCode))"
            }
        } catch {
            lastError = "Failed to delete task: \(error.localizedDescription)"
        }
    }

    /// Snooze a task by updating its start date to now + minutes.
    func snoozeTask(_ task: MacTask, minutes: Int = 15) async {
        lastError = nil
        let newDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let dateStr = Self.isoFormatter.string(from: newDate)
        guard let result = await patchTask(id: task.id, body: ["start_date": dateStr]) else { return }
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = result
        }
    }

    /// Schedule or reschedule a task to a specific start date.
    @discardableResult
    func scheduleTask(_ task: MacTask, startDate: Date) async -> Bool {
        lastError = nil
        let dateStr = Self.isoFormatter.string(from: startDate)
        guard let result = await patchTask(id: task.id, body: ["start_date": dateStr]) else { return false }
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = result
        }
        return true
    }

    @discardableResult
    func scheduleSuggestionTask(
        _ task: MacTask,
        startDate: Date,
        authority: MacAuthenticatedHttpClient.RequestAuthority
    ) async -> MacTask? {
        lastError = nil
        let dateStr = Self.isoFormatter.string(from: startDate)
        return await patchTask(
            id: task.id,
            body: ["start_date": dateStr],
            authority: authority
        )
    }

    /// Move a task back to the inbox by clearing its schedule.
    func clearSchedule(for task: MacTask) async {
        lastError = nil
        guard let result = await patchTask(
            id: task.id,
            body: [
                "start_date": NSNull(),
                "end_date": NSNull(),
                "status": "pending"
            ]
        ) else { return }
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = result
        }
    }

    /// Create a task via POST /api/v1/tasks.
    func createTask(_ params: [String: Any]) async -> MacTask? {
        await createTask(
            params,
            authority: nil,
            reconcileClientPayload: false,
            publishResult: true
        )
    }

    /// Suggestion acceptance uses a stable client UUID. Always PATCH the accepted payload after
    /// POST so a retry that receives a row committed before a lost acknowledgement cannot dismiss
    /// the proposal while retaining stale title/schedule fields.
    func createSuggestionTask(
        _ params: [String: Any],
        authority: MacAuthenticatedHttpClient.RequestAuthority
    ) async -> MacTask? {
        await createTask(
            params,
            authority: authority,
            reconcileClientPayload: true,
            publishResult: false
        )
    }

    /// Apply a suggestion mutation after its window-owned scope/generation has been revalidated.
    /// This is synchronous on the main actor so no account change can interleave with publication.
    func publishSuggestionMutation(_ task: MacTask) {
        if let index = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[index] = task
        } else {
            allTasks.append(task)
        }
    }

    private func createTask(
        _ params: [String: Any],
        authority: MacAuthenticatedHttpClient.RequestAuthority?,
        reconcileClientPayload: Bool,
        publishResult: Bool
    ) async -> MacTask? {
        do {
            let body = try JSONSerialization.data(withJSONObject: params)
            let (data, http) = if let authority {
                try await MacAuthenticatedHttpClient.request(
                    path: "/api/v1/tasks", method: "POST", body: body, authority: authority
                )
            } else {
                try await MacAuthenticatedHttpClient.request(
                    path: "/api/v1/tasks", method: "POST", body: body
                )
            }
            guard (200...299).contains(http.statusCode) else {
                lastError = "Failed to create task (status \(http.statusCode))"
                return nil
            }
            var task = try parseTask(from: data)
            if reconcileClientPayload,
               let id = params["id"] as? String,
               let authority {
                var patch = params
                patch.removeValue(forKey: "id")
                guard let reconciled = await patchTask(id: id, body: patch, authority: authority) else {
                    return nil
                }
                task = reconciled
            }
            if publishResult {
                allTasks.append(task)
            }
            return task
        } catch {
            lastError = "Failed to create task: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Private Helpers

    private func patchTask(id: String, body: [String: Any]) async -> MacTask? {
        await patchTask(id: id, body: body, authority: nil)
    }

    private func patchTask(
        id: String,
        body: [String: Any],
        authority: MacAuthenticatedHttpClient.RequestAuthority?
    ) async -> MacTask? {
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let (data, http) = if let authority {
                try await MacAuthenticatedHttpClient.request(
                    path: "/api/v1/tasks/\(id)", method: "PATCH", body: bodyData,
                    authority: authority
                )
            } else {
                try await MacAuthenticatedHttpClient.request(
                    path: "/api/v1/tasks/\(id)", method: "PATCH", body: bodyData
                )
            }
            guard (200...299).contains(http.statusCode) else {
                lastError = "Failed to update task (status \(http.statusCode))"
                return nil
            }
            return try parseTask(from: data)
        } catch {
            lastError = "Failed to update task: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Parsing

    private func parseTasks(from data: Data) throws -> [MacTask] {
        let json = try JSONSerialization.jsonObject(with: data)

        // Backend returns { "tasks": [...], "pagination": {...} }
        let taskArray: [[String: Any]]
        if let dict = json as? [String: Any], let tasks = dict["tasks"] as? [[String: Any]] {
            taskArray = tasks
        } else if let array = json as? [[String: Any]] {
            taskArray = array
        } else {
            return []
        }

        return taskArray.compactMap { parseTaskDict($0) }
    }

    private func parseTask(from data: Data) throws -> MacTask {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any], let task = parseTaskDict(dict) else {
            throw NSError(domain: "MacTaskStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid task response"])
        }
        return task
    }

    private func parseTaskDict(_ dict: [String: Any]) -> MacTask? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else { return nil }

        let taskType = dict["type"] as? String ?? "task"

        return MacTask(
            id: id,
            title: title,
            status: dict["status"] as? String ?? "pending",
            category: dict["category"] as? String,
            startDate: parseDate(dict["start_date"] ?? dict["startDate"]),
            endDate: parseDate(dict["end_date"] ?? dict["endDate"]),
            dueDate: parseDate(dict["due_date"] ?? dict["dueDate"]),
            notes: dict["notes"] as? String,
            // Co-authored description (migration 120). The backend serializes the halves
            // pre-split, so the block delimiter is never parsed on the client.
            taskDescription: dict["description_user"] as? String,
            agentContext: dict["description_agent"] as? String,
            isEvent: taskType == "calendar_event" || (dict["is_event"] as? Bool ?? false),
            priority: dict["priority"] as? String,
            createdAt: parseDate(dict["created_at"] ?? dict["createdAt"]),
            updatedAt: parseDate(dict["updated_at"] ?? dict["updatedAt"]),
            // Agent run-state (migration 019) — read-only from backend, distinct from status.
            runStatus: dict["run_status"] as? String,
            runId: dict["run_id"] as? String,
            sessionKey: dict["session_key"] as? String,
            runStartedAt: parseDate(dict["run_started_at"]),
            // Staleness (migration 116) — read-only from backend, distinct from status.
            staleAt: parseDate(dict["stale_at"])
        )
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String, !str.isEmpty else { return nil }

        // Try with fractional seconds first, then without (ISO 8601 gotcha from CLAUDE.md)
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: str) { return d }

        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        return withoutFrac.date(from: str)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
