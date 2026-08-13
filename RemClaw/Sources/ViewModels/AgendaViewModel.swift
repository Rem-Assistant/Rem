import Foundation
import SwiftUI
import SwiftData
import Combine

struct AgendaAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Non-secret ownership fence for a rendered suggestion snapshot. Actions must remain inside the
/// same authenticated account, backend, and gateway scope from tap through durable dismissal.
struct AgendaSuggestionMutationScope: Sendable, Hashable {
    let accountID: String
    let backendURL: String
    let gatewayURL: String

    init?(accountID: String?, backendURL: String?, gatewayURL: String?) {
        guard let accountID = Self.normalized(accountID), !accountID.isEmpty else { return nil }
        self.accountID = accountID
        self.backendURL = Self.normalized(backendURL) ?? ""
        self.gatewayURL = Self.normalized(gatewayURL) ?? ""
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Ordering for the agenda's items. `time` is the default chronological order;
/// `list` orders by the List a task belongs to; `status` groups by task status
/// (the in-agenda replacements for the removed "View by List" menu item). Menu /
/// `allCases` order is List → Status → Time.
enum AgendaSortMode: String, CaseIterable, Identifiable {
    case list
    case status
    case time

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .status: return "Status"
        case .time: return "Time"
        }
    }

    var icon: String {
        switch self {
        case .list: return "rectangle.stack"
        case .status: return "circle.dashed"
        case .time: return "clock"
        }
    }
}

/// Status buckets for the "Status" grouped rendering, ordered by how much
/// attention each needs: overdue first, completed last. TaskEvent has no
/// "blocked" field (that's a server-side Daily Brief concept), so overdue is the
/// most urgent bucket we can derive locally.
enum AgendaStatusBucket: Int, CaseIterable, Identifiable {
    case overdue
    case inProgress
    case toDo
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .inProgress: return "In Progress"
        case .toDo: return "To Do"
        case .done: return "Done"
        }
    }
}

/// One List's worth of agenda items, for the "By List" grouped rendering. `id` is
/// the List's UUID string, or `"unfiled"` for events / tasks with no List.
struct AgendaTaskListGroup: Identifiable {
    let id: String
    let title: String
    var tasks: [TaskEvent]
}

/// One status bucket's worth of agenda items, for the "Status" grouped rendering.
/// `id` is the bucket's raw value so groups stay in `AgendaStatusBucket` order.
struct AgendaTaskStatusGroup: Identifiable {
    let id: Int
    let title: String
    var tasks: [TaskEvent]
}

enum AgendaDeleteTarget {
    case task(TaskEvent)
    case calendarEvent(DeviceCalendarEventSummary)
}

struct AgendaRecurringDeleteRequest: Identifiable {
    let id = UUID()
    let target: AgendaDeleteTarget
    let title: String
}

enum AgendaCalendarRecoveryState: Equatable {
    case permissionNeeded

    var title: String {
        "Calendar access needed"
    }

    var message: String {
        "Allow local Calendar access in Settings to show events alongside your tasks."
    }

    var actionTitle: String {
        "Review Calendar Settings"
    }

    static func from(error: Error) -> AgendaCalendarRecoveryState? {
        guard let calendarError = error as? CalendarError else { return nil }
        switch calendarError {
        case .permissionDenied, .setupFailed:
            return .permissionNeeded
        case .unknown, .eventNotFound, .noCalendarAccount:
            return nil
        }
    }
}

enum AgendaCalendarMirrorVisibility {
    static func shouldShow(
        task: TaskEvent,
        currentCalendarEventIDs: Set<String>,
        calendarRecoveryState: AgendaCalendarRecoveryState? = nil
    ) -> Bool {
        // When local Calendar access is unavailable, hide Calendar-backed
        // rows we cannot verify instead of mixing stale events with recovery UI.
        if calendarRecoveryState != nil,
           task.isEvent,
           task.calendarEventID != nil {
            return false
        }

        guard task.isCalendarOnlyMirror == true else { return true }
        guard let eventID = task.calendarEventID else { return false }
        return currentCalendarEventIDs.contains(eventID)
    }
}

/// ViewModel for AgendaView — manages date selection, task filtering, and calendar info caching.
/// Simplified from OpenclawTestBed: no CalendarLazyLoadService or EKEvent dependency (Phase B).
@MainActor
public class AgendaViewModel: ObservableObject {
    public typealias BriefHistoryProvider = @MainActor (String) async throws -> Data
    public typealias BriefLoader = @MainActor () async throws -> DailyBrief
    typealias SuggestionDismissal = @MainActor (
        String,
        AuthenticatedHttpClient.RequestAuthority
    ) async throws -> Void
    public typealias BriefRetryDelay = @MainActor () async -> Void
    public typealias BriefContextClearer = @MainActor (String) -> Void
    /// Backend JWT subject of the signed-in account, used to scope the published brief
    /// headline. Injected rather than read globally so the view model stays testable and so
    /// the identity comes from the SAME source the readers use
    /// (`GatewaySessionProviding.authenticatedAccountIDForRecovery`).
    public typealias BriefAccountIDProvider = @MainActor () -> String?
    public typealias SuggestionNow = @MainActor () -> Date
    public typealias SuggestionCalendar = @MainActor () -> Calendar
    typealias SuggestionMutationScope = @MainActor () -> AgendaSuggestionMutationScope?
    typealias SuggestionRequestAuthority = @MainActor (AgendaSuggestionMutationScope) -> AuthenticatedHttpClient.RequestAuthority?
    public typealias SuggestionLocalSaver = @MainActor () throws -> Void
    private struct SuggestionActionAuthority: Sendable {
        let scope: AgendaSuggestionMutationScope
        let snapshotID: String
        let suggestion: TaskSuggestion
        let requestAuthority: AuthenticatedHttpClient.RequestAuthority
    }
    struct ExplicitBriefRefresh: Sendable {
        fileprivate let generation: UInt64
        let brief: DailyBrief
    }
    // MARK: - Published State

    @Published var selectedDate: Date = Date()
    @Published var showTaskSelector: Bool = false
    @Published var showCalendar: Bool = false
    @Published var calendarInfoCache: [String: CalendarInfo] = [:]
    @Published var calendarEventAccessCache: [String: CalendarEventAccess] = [:]
    @Published var deviceCalendarEvents: [DeviceCalendarEventSummary] = []
    @Published var calendarRecoveryState: AgendaCalendarRecoveryState?
    @Published var alert: AgendaAlert?
    @Published var recurringDeleteRequest: AgendaRecurringDeleteRequest?

    // MARK: - Daily Brief (orchestrator surface)

    /// Today's brief from GET /api/v1/brief. Nil until first load. Dynamic: reload
    /// after task actions / refresh so the card reflects the latest agent runs.
    ///
    /// Every assignment republishes the artifact's authored headline to `BriefContext`, which is
    /// where the orchestrator chat reads its title from. The chat has no `/brief` payload of its
    /// own, so this is the single hand-off that keeps the card header and the chat title on one
    /// field instead of two independent derivations.
    @Published var brief: DailyBrief? {
        didSet {
            BriefContext.setOrchestratorHeadline(brief?.briefHeadline, accountID: briefAccountID())
        }
    }
    @Published var isBriefLoading: Bool = false

    // MARK: - Suggested tasks (WS2, doc 38)

    /// Current suggestions from GET /api/v1/suggestions — signals we already have (upcoming
    /// events, overdue tasks) converted into acceptable actions. Best-effort: empty on failure,
    /// never blocks the agenda. Accept performs the action locally + dismisses; dismiss hides.
    @Published var suggestions: [TaskSuggestion] = []
    /// Exact authored brief identity under which `suggestions` was fetched. The chat surface reads
    /// only a coherent, current-local-day snapshot; a newer brief or failed refresh clears this
    /// binding before any stale Add/Move action can render beneath another artifact.
    @Published private var suggestionsBriefIdentity: OrchestratorSuggestionBriefIdentity?
    @Published private var suggestionsSnapshotID: String?
    @Published private var suggestionsMutationScope: AgendaSuggestionMutationScope?
    private var suggestionActionIDsInFlight: Set<String> = []

    // MARK: - Sorting

    /// How the agenda's items are ordered. Default time-based; "by List" groups the
    /// day's items by the List they belong to (replaces the old "View by List" menu).
    /// Persisted so the choice sticks across launches.
    @Published var sortMode: AgendaSortMode = AgendaViewModel.loadSortMode() {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: AgendaViewModel.sortModeKey) }
    }

    private static let sortModeKey = "rem.agenda.sortMode.v1"
    private static func loadSortMode() -> AgendaSortMode {
        AgendaSortMode(rawValue: UserDefaults.standard.string(forKey: sortModeKey) ?? "") ?? .time
    }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let calendarService: CalendarSyncService?
    private let taskApiService: TaskApiServiceProtocol?
    private let taskSyncService: TaskSyncServiceProtocol?
    private let briefHistoryProvider: BriefHistoryProvider?
    private let briefLoader: BriefLoader
    private let suggestionDismissal: SuggestionDismissal
    private let briefRetryDelay: BriefRetryDelay
    private let briefContextClearer: BriefContextClearer
    /// `var`, not `let`: `ContentView.mainContent` is at the compiler's type-checking limit, so
    /// the app assigns this after construction instead of passing one more initializer
    /// argument. Tests still inject it through `init`.
    var briefAccountID: BriefAccountIDProvider
    private let suggestionNow: SuggestionNow
    private let suggestionCalendar: SuggestionCalendar
    private let suggestionMutationScope: SuggestionMutationScope
    private let suggestionRequestAuthority: SuggestionRequestAuthority
    private let suggestionLocalSaver: SuggestionLocalSaver
    private var pendingBriefReconciliation: DailyBrief?
    private var isBriefReconciliationInFlight = false
    private var operatorReadyRecoveryQueued = false
    private var delayedBriefRetryScheduled = false
    private var delayedBriefRetryTask: Task<Void, Never>?
    private var briefRequestGeneration: UInt64 = 0
    let taskStore: TaskStore

    private var cancellables = Set<AnyCancellable>()

    /// Convenience accessor — reads from the shared TaskStore.
    var allTasks: [TaskEvent] { taskStore.allTasks }

    // MARK: - Initialization

    init(
        modelContext: ModelContext,
        taskStore: TaskStore,
        calendarService: CalendarSyncService? = nil,
        taskApiService: TaskApiServiceProtocol? = nil,
        taskSyncService: TaskSyncServiceProtocol? = nil,
        briefHistoryProvider: BriefHistoryProvider? = nil,
        briefLoader: BriefLoader? = nil,
        suggestionDismissal: SuggestionDismissal? = nil,
        briefRetryDelay: @escaping BriefRetryDelay = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        },
        briefContextClearer: BriefContextClearer? = nil,
        briefAccountID: BriefAccountIDProvider? = nil,
        suggestionNow: @escaping SuggestionNow = Date.init,
        suggestionCalendar: @escaping SuggestionCalendar = { .current },
        suggestionMutationScope: @escaping SuggestionMutationScope = { nil },
        suggestionRequestAuthority: @escaping SuggestionRequestAuthority = { scope in
            AuthenticatedHttpClient.captureRequestAuthority(expectedBackendURL: scope.backendURL)
        },
        suggestionLocalSaver: SuggestionLocalSaver? = nil
    ) {
        self.modelContext = modelContext
        self.taskStore = taskStore
        self.calendarService = calendarService
        self.taskApiService = taskApiService
        self.taskSyncService = taskSyncService
        self.briefHistoryProvider = briefHistoryProvider
        self.briefLoader = briefLoader ?? { try await RemBriefApiService().fetchBrief() }
        self.suggestionDismissal = suggestionDismissal ?? { key, authority in
            try await SuggestionsApiService().dismiss(key: key, authority: authority)
        }
        self.briefRetryDelay = briefRetryDelay
        self.briefContextClearer = briefContextClearer ?? {
            BriefContext.setMarkdown(nil, for: $0)
        }
        // Fails CLOSED when unset: no account means no published headline, so the chat shows the
        // plain "Rem" title rather than risking another account's prose.
        self.briefAccountID = briefAccountID ?? { nil }
        self.suggestionNow = suggestionNow
        self.suggestionCalendar = suggestionCalendar
        self.suggestionMutationScope = suggestionMutationScope
        self.suggestionRequestAuthority = suggestionRequestAuthority
        self.suggestionLocalSaver = suggestionLocalSaver ?? { try modelContext.save() }

        self.selectedDate = Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Computed Properties

    /// Tasks scheduled for the selected date, ordered per `sortMode`.
    var tasksForSelectedDate: [TaskEvent] {
        let calendar = Calendar.current
        let startOfSelectedDay = calendar.startOfDay(for: selectedDate)
        let currentCalendarEventIDs = Set(deviceCalendarEvents.map(\.calendarEventID))
        // Calendar-event backing tasks (#872/#881) exist only to host a calendar
        // event's Activity thread + agent runs — they are NOT their own agenda item.
        // Each is referenced by its calendar event's `workBackingTaskID`, so exclude
        // any task an event points at; otherwise the event renders twice (the visible
        // calendar mirror PLUS its backing task, which mirrors the same
        // `calendarEventID`). Real app tasks and genuine user-created calendar events
        // are never referenced this way (a user-created event carries a
        // `calendarEventID` but no event points at it), so they stay visible.
        let backingTaskIDs = Set(allTasks.compactMap { $0.workBackingTaskID })
        let filtered = allTasks
            .filter { task in
                if backingTaskIDs.contains(task.id) { return false }
                guard AgendaCalendarMirrorVisibility.shouldShow(
                    task: task,
                    currentCalendarEventIDs: currentCalendarEventIDs,
                    calendarRecoveryState: calendarRecoveryState
                ) else {
                    return false
                }
                guard let taskDate = task.startDate else { return false }
                return calendar.startOfDay(for: taskDate) == startOfSelectedDay
            }

        switch sortMode {
        case .time:
            return filtered.sorted(by: Self.timeOrder)
        case .list:
            // Group by List name, unfiled tasks last; within a List fall back to
            // time order so each group still reads chronologically.
            let names = listNamesByID()
            return filtered.sorted { lhs, rhs in
                let lKey = Self.listSortKey(for: lhs, names: names)
                let rKey = Self.listSortKey(for: rhs, names: names)
                if lKey != rKey { return lKey < rKey }
                return Self.timeOrder(lhs, rhs)
            }
        case .status:
            // Group by status bucket (overdue → in progress → to do → done);
            // within a bucket fall back to time order so each group reads
            // chronologically.
            let now = Date()
            return filtered.sorted { lhs, rhs in
                let lKey = Self.statusBucket(for: lhs, now: now).rawValue
                let rKey = Self.statusBucket(for: rhs, now: now).rawValue
                if lKey != rKey { return lKey < rKey }
                return Self.timeOrder(lhs, rhs)
            }
        }
    }

    /// Classify a task/event into a status bucket. Completed → done; in-progress →
    /// inProgress; otherwise an incomplete item whose start time has already passed
    /// is overdue, and everything else is upcoming (toDo). `now` is passed in so a
    /// single sort pass uses one stable clock.
    static func statusBucket(for task: TaskEvent, now: Date) -> AgendaStatusBucket {
        if task.statusEnum == .completed { return .done }
        if task.statusEnum == .inProgress { return .inProgress }
        if let start = task.startDate, start < now { return .overdue }
        return .toDo
    }

    /// Chronological order: timed items first (earliest first), undated/any-time after.
    private static func timeOrder(_ lhs: TaskEvent, _ rhs: TaskEvent) -> Bool {
        let lhsHasTime = lhs.startDate != nil && !lhs.isAnyTime
        let rhsHasTime = rhs.startDate != nil && !rhs.isAnyTime
        switch (lhsHasTime, rhsHasTime) {
        case (true, true):
            return (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        case (true, false): return true
        case (false, true): return false
        case (false, false): return false
        }
    }

    /// Sort key for "by List" mode: the List's name (case-insensitive), or a
    /// sentinel that sorts unfiled tasks and events to the end.
    private static func listSortKey(for task: TaskEvent, names: [UUID: String]) -> String {
        guard let listID = task.listID, let name = names[listID], !name.isEmpty else {
            return "\u{10FFFF}" // last
        }
        return name.lowercased()
    }

    /// Resolve `TaskList.id → name` from local SwiftData for "by List" sorting.
    /// Mirrors the `@Query` lookup used by `TaskEventRowView`'s list badge.
    private func listNamesByID() -> [UUID: String] {
        let descriptor = FetchDescriptor<TaskList>()
        guard let lists = try? modelContext.fetch(descriptor) else { return [:] }
        return Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })
    }

    static let unfiledGroupID = "unfiled"

    /// The selected day's items grouped by their List, for the "By List" sort mode.
    /// Groups follow the same ordering as `tasksForSelectedDate` (list name A→Z,
    /// unfiled/events last); each group keeps its tasks in chronological order.
    /// Rendering these as section headers is what makes "By List" *visibly* regroup
    /// the agenda — a pure reorder reads as "nothing changed" when the day is one
    /// List or all unfiled (founder report).
    var listGroupsForSelectedDate: [AgendaTaskListGroup] {
        let names = listNamesByID()
        var groups: [AgendaTaskListGroup] = []
        for task in tasksForSelectedDate {
            let listID = task.isEvent ? nil : task.listID
            let name = listID.flatMap { names[$0] }
            let filed = (name?.isEmpty == false)
            let key = filed ? listID!.uuidString : Self.unfiledGroupID
            let title = filed ? name! : "Other"
            if var last = groups.last, last.id == key {
                last.tasks.append(task)
                groups[groups.count - 1] = last
            } else {
                groups.append(AgendaTaskListGroup(id: key, title: title, tasks: [task]))
            }
        }
        return groups
    }

    /// The selected day's items grouped by their status bucket, for the "Status"
    /// sort mode. Groups follow the same ordering as `tasksForSelectedDate`
    /// (overdue → in progress → to do → done); each group keeps its tasks in
    /// chronological order. Rendering these as section headers is what makes
    /// "Status" *visibly* regroup the agenda, mirroring the "By List" treatment.
    var statusGroupsForSelectedDate: [AgendaTaskStatusGroup] {
        let now = Date()
        var groups: [AgendaTaskStatusGroup] = []
        for task in tasksForSelectedDate {
            let bucket = Self.statusBucket(for: task, now: now)
            if var last = groups.last, last.id == bucket.rawValue {
                last.tasks.append(task)
                groups[groups.count - 1] = last
            } else {
                groups.append(AgendaTaskStatusGroup(id: bucket.rawValue, title: bucket.title, tasks: [task]))
            }
        }
        return groups
    }

    var unscheduledTasks: [TaskEvent] {
        taskStore.unscheduledTasks
    }

    /// Schedulable tasks that match what `TaskSelectorSheet` actually shows.
    /// Excludes calendar events because the sheet's "Inbox" filter does
    /// (calendar events are already scheduled by definition).
    var schedulableUnscheduledCount: Int {
        unscheduledTasks.filter { !$0.isEvent }.count
    }

    var calendarOnlyEventsForSelectedDate: [DeviceCalendarEventSummary] {
        let existingEventIDs = Set(tasksForSelectedDate.compactMap(\.calendarEventID))
        return deviceCalendarEvents
            .filter { !existingEventIDs.contains($0.calendarEventID) }
            .sorted { $0.startDate < $1.startDate }
    }

    var hasItemsForSelectedDate: Bool {
        !tasksForSelectedDate.isEmpty || !calendarOnlyEventsForSelectedDate.isEmpty
    }

    var overdueTasks: [TaskEvent] {
        let calendar = Calendar.current
        return allTasks.filter { task in
            guard let taskDate = task.startDate else { return false }
            return taskDate < calendar.startOfDay(for: Date()) && task.statusEnum != .completed
        }
    }

    /// Schedulable overdue tasks. Mirrors `TaskSelectorSheet`'s filter that
    /// excludes calendar events.
    var schedulableOverdueCount: Int {
        overdueTasks.filter { !$0.isEvent }.count
    }

    // MARK: - Navigation

    func navigateToDate(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
    }

    func navigateToToday(now: Date = Date()) {
        selectedDate = Calendar.current.startOfDay(for: now)
    }

    func navigateToPreviousDay() {
        if let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: selectedDate)) {
            selectedDate = previousDay
        }
    }

    func navigateToNextDay() {
        if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: selectedDate)) {
            selectedDate = nextDay
        }
    }

    // MARK: - Sheet Management

    func showTaskSelectorSheet() { showTaskSelector = true }
    func hideTaskSelectorSheet() { showTaskSelector = false }
    func showCalendarSheet() { showCalendar = true }
    func hideCalendarSheet() { showCalendar = false }

    // MARK: - Calendar Info

    func loadCalendarInfo(for tasks: [TaskEvent]) async {
        guard let syncService = calendarService else { return }

        var newCache: [String: CalendarInfo] = calendarInfoCache
        var newAccessCache = calendarEventAccessCache

        for task in tasks where task.isEvent {
            var eventID = task.calendarEventID

            if eventID == nil, let startDate = task.startDate {
                if let foundEventID = await syncService.findEventID(title: task.title, startDate: startDate) {
                    eventID = foundEventID
                    task.calendarEventID = foundEventID
                }
            }

            if let eventID,
               let calendarInfo = await syncService.getCalendarInfo(forEvent: eventID) {
                newCache[eventID] = calendarInfo
                newAccessCache[eventID] = await syncService.getEventAccess(forEvent: eventID)
            }
        }

        calendarInfoCache = newCache
        calendarEventAccessCache = newAccessCache
    }

    func getCalendarInfo(for task: TaskEvent) -> CalendarInfo? {
        guard let eventID = task.calendarEventID else { return nil }
        return calendarInfoCache[eventID]
    }

    func resolveOrCreateTaskForCalendarEvent(_ event: DeviceCalendarEventSummary) -> TaskEvent {
        if let existing = allTasks.first(where: { $0.calendarEventID == event.calendarEventID }) {
            return existing
        }

        let eventID = event.calendarEventID
        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate { $0.calendarEventID == eventID }
        )
        if let existingInStore = try? modelContext.fetch(descriptor).first {
            taskStore.appendIfMissing(existingInStore)
            return existingInStore
        }

        let duration = TimeInterval(max(event.durationMinutes, 0) * 60)
        let mirroredTask = TaskEvent(
            title: event.title,
            category: "Calendar",
            startDate: event.startDate,
            endDate: event.endDate,
            duration: duration,
            notes: nil,
            isEvent: true,
            isBusy: true,
            isAnyTime: false,
            priority: .medium,
            status: .scheduled,
            calendarEventID: event.calendarEventID,
            isCalendarOnlyMirror: true
        )

        modelContext.insert(mirroredTask)
        try? modelContext.save()
        taskStore.appendIfMissing(mirroredTask)
        return mirroredTask
    }

    func makeTaskEventViewModel(for task: TaskEvent) -> TaskEventViewModel {
        let viewModel = TaskEventViewModel(
            modelContext: modelContext,
            task: task,
            calendarService: calendarService,
            taskApiService: taskApiService,
            taskSyncService: taskSyncService
        )
        viewModel.onDelete = { [weak self] in
            guard let self else { return }
            Task { await self.refreshCalendarEvents() }
        }
        return viewModel
    }

    func refreshCalendarEvents() async {
        guard let calendarService else {
            deviceCalendarEvents = []
            return
        }

        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        do {
            let events = try await calendarService.fetchEventsFromDevice(start: dayStart, end: dayEnd)
            deviceCalendarEvents = events
            calendarRecoveryState = nil

            var mergedCache = calendarInfoCache
            var mergedAccess = calendarEventAccessCache
            for event in events {
                if let info = await calendarService.getCalendarInfo(forEvent: event.calendarEventID) {
                    mergedCache[event.calendarEventID] = info
                }
                mergedAccess[event.calendarEventID] = await calendarService.getEventAccess(forEvent: event.calendarEventID)
            }
            calendarInfoCache = mergedCache
            calendarEventAccessCache = mergedAccess
        } catch {
            // If permission is denied or EventKit fails, keep task list functional.
            deviceCalendarEvents = []
            calendarRecoveryState = AgendaCalendarRecoveryState.from(error: error)
        }
    }

    // MARK: - Pull-to-Refresh

    @Published var isRefreshing: Bool = false

    func pullToRefresh() async {
        isRefreshing = true
        await taskStore.sync()
        await refreshCalendarEvents()
        isRefreshing = false
    }

    // MARK: - Task Actions

    func completeTask(_ task: TaskEvent) async {
        do {
            try await taskSyncService?.updateTaskStatus(task, to: .completed, modelContext: modelContext)
            TaskNotificationService.shared.cancelNotification(for: task.id)
        } catch {
            print("[Agenda] Failed to complete task: \(error.localizedDescription)")
        }
    }

    // MARK: - Daily Brief

    /// Load today's brief from the backend. Best-effort: a failure leaves the prior brief in
    /// place (or nil) and never blocks the agenda. A successful fallback-only payload remains
    /// hidden until exact durable-history reconciliation installs the canonical transcript.
    @MainActor
    @discardableResult
    func loadBrief() async -> Bool {
        let requestGeneration = beginBriefRequest()
        invalidateSuggestionSnapshot()
        isBriefLoading = true
        defer { isBriefLoading = false }
        do {
            let payload = try await briefLoader()
            guard !Task.isCancelled, requestGeneration == briefRequestGeneration else { return false }
            // API transcript fields are only a cache hint: an older backend can populate them
            // from the latest ordinary assistant reply rather than the authored brief artifact.
            // Strip them at the trust boundary. Only an exact durable-history match below may
            // install transcript prose for Summary, playback, or read receipts.
            let cached = sanitizedBriefPayloadPreservingCanonicalTranscript(payload)
            delayedBriefRetryTask?.cancel()
            delayedBriefRetryTask = nil
            delayedBriefRetryScheduled = false
            brief = cached
            publishAtomicSuggestions(from: cached)
            pendingBriefReconciliation = cached
            await drainBriefReconciliation()
            return true
        } catch {
            print("[Agenda] Failed to load brief: \(error.localizedDescription)")
            return false
        }
    }

    /// Refetch the backend-authored brief immediately before an explicit Read action.
    ///
    /// Agenda may have been visible while a newer check-in was authored and delivered into the
    /// durable Today transcript. Playback must therefore establish a fresh `/brief` identity before
    /// exact-matching history; reusing the card's pre-tap markdown can reject the real newest brief
    /// or narrate an obsolete summary.
    @MainActor
    func fetchBriefForExplicitPlayback() async throws -> ExplicitBriefRefresh {
        let requestGeneration = beginBriefRequest()
        let payload = try await briefLoader()
        guard !Task.isCancelled, requestGeneration == briefRequestGeneration else {
            throw CancellationError()
        }
        let refreshed = sanitizedBriefPayloadPreservingCanonicalTranscript(payload)
        return ExplicitBriefRefresh(generation: requestGeneration, brief: refreshed)
    }

    /// API transcript fields remain untrusted, but a refresh of the exact canonical authored
    /// artifact must not make an already-reconciled Agenda doorway disappear while history is
    /// temporarily unavailable. Preservation is fenced on both briefs authorizing the durable
    /// session and the refreshed authored markdown matching the currently reconciled identity.
    /// Any artifact or session change strips transcript state until fresh history reconciliation.
    @MainActor
    private func sanitizedBriefPayloadPreservingCanonicalTranscript(
        _ payload: DailyBrief
    ) -> DailyBrief {
        let sanitized = payload.replacingTranscriptProse(markdown: nil, summary: nil)
        guard let current = brief,
              current.hasAgendaSurface,
              DailyBriefTranscriptReconciler.backendAuthorizedCanonicalMarkdown(
                  from: sanitized
              ) != nil,
              let refreshedMarkdown = sanitized.briefMarkdown,
              DailyBriefTranscriptReconciler.isCurrentAuthoredArtifact(
                  expectedMarkdown: refreshedMarkdown,
                  currentBrief: current
              )
        else { return sanitized }

        return sanitized.replacingTranscriptProse(
            markdown: current.transcriptMarkdown,
            summary: current.transcriptSummary
        )
    }

    /// Commit a fetched explicit-playback snapshot only after ContentView has revalidated the
    /// initiating account and playback request. This synchronous phase cannot yield between that
    /// privacy check and publication. A newer ordinary/explicit load supersedes the snapshot.
    @MainActor
    func commitBriefForExplicitPlayback(_ refresh: ExplicitBriefRefresh) -> DailyBrief? {
        guard !Task.isCancelled, refresh.generation == briefRequestGeneration else { return nil }
        delayedBriefRetryTask?.cancel()
        delayedBriefRetryTask = nil
        delayedBriefRetryScheduled = false
        brief = refresh.brief
        pendingBriefReconciliation = refresh.brief
        return refresh.brief
    }

    @MainActor
    private func beginBriefRequest() -> UInt64 {
        briefRequestGeneration &+= 1
        return briefRequestGeneration
    }

    /// Retry a cached brief's transcript after the operator connection becomes
    /// ready. If readiness arrives during an in-flight cold-start request, queue
    /// exactly one follow-up attempt rather than leaving stale prose indefinitely.
    @MainActor
    func recoverBriefAfterOperatorReady() async {
        guard pendingBriefReconciliation != nil else { return }
        operatorReadyRecoveryQueued = true
        await drainBriefReconciliation()
    }

    @MainActor
    private func drainBriefReconciliation() async {
        guard !isBriefReconciliationInFlight else { return }
        isBriefReconciliationInFlight = true
        defer { isBriefReconciliationInFlight = false }

        var consumedQueuedRetry = false
        while let cached = pendingBriefReconciliation {
            guard let briefHistoryProvider else {
                pendingBriefReconciliation = nil
                return
            }

            operatorReadyRecoveryQueued = false
            var deliveredTranscript: String?
            var deliveredSessionKey: String?
            // The backend advertises `rem-orchestrator` only after the exact current gateway
            // artifact revision is delivered there. Deterministic fallback markdown is still
            // present in every `/brief` response, so equality with an older transcript occurrence
            // must not promote it into durable Agenda/read-receipt state when that authority is
            // withheld.
            guard let authoredMarkdown = DailyBriefTranscriptReconciler
                .backendAuthorizedCanonicalMarkdown(from: cached) else {
                pendingBriefReconciliation = nil
                return
            }
            for sessionKey in DailyBriefTranscriptReconciler.historySessionKeys(
                advertisedSessionKey: cached.briefSessionKey
            ) {
                do {
                    let history = try await briefHistoryProvider(sessionKey)
                    guard pendingBriefReconciliation == cached else { break }
                    if let artifact = DailyBriefTranscriptReconciler.currentBackendAuthorizedArtifact(
                        from: history,
                        for: cached
                    ) {
                        deliveredTranscript = artifact.markdown
                        deliveredSessionKey = sessionKey
                        break
                    }
                } catch {
                    // If the durable route is not ready, keep the cached payload hidden and use the
                    // bounded retry. Never substitute a different conversation's prose.
                    print("[Agenda] Failed to reconcile brief transcript for \(sessionKey): \(error.localizedDescription)")
                }
            }

            guard pendingBriefReconciliation == cached else { continue }
            if let deliveredTranscript, let deliveredSessionKey {
                applyDurableBriefTranscript(
                    deliveredTranscript,
                    sessionKey: deliveredSessionKey,
                    expectedAuthoredMarkdown: authoredMarkdown
                )
            } else {
                // Keep `/brief` as an internal fallback while visible delivery is unavailable.
                // A later operator-ready edge or one bounded delayed attempt retries this exact
                // cached snapshot without refetching the backend.
                scheduleDelayedBriefRetryIfNeeded(for: cached)
            }

            guard pendingBriefReconciliation == cached else { continue }
            guard operatorReadyRecoveryQueued, !consumedQueuedRetry else { return }
            consumedQueuedRetry = true
        }
    }

    /// Adopts a transcript already resolved by Agenda reconciliation or explicit playback.
    /// This keeps the compact Summary and its playback receipt on one durable artifact.
    @MainActor
    @discardableResult
    func applyDurableBriefTranscript(
        _ transcript: String,
        sessionKey: String,
        expectedAuthoredMarkdown: String
    ) -> Bool {
        guard let current = brief else { return false }
        guard DailyBriefTranscriptReconciler.isCurrentAuthoredArtifact(
            expectedMarkdown: expectedAuthoredMarkdown,
            currentBrief: current
        ) else { return false }
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        brief = current.replacingTranscriptProse(
            markdown: cleaned,
            summary: DailyBriefTranscriptReconciler.summaryExcerpt(from: cleaned)
        )
        pendingBriefReconciliation = nil
        delayedBriefRetryTask?.cancel()
        delayedBriefRetryTask = nil
        delayedBriefRetryScheduled = false
        briefContextClearer(sessionKey)
        return true
    }

    /// A transient history failure can happen after the operator is already ready,
    /// so no future readiness edge would arrive to recover the cached prose. Schedule
    /// exactly one delayed attempt for this snapshot; a newer brief cancels it, and
    /// an operator-edge success makes it a harmless no-op.
    @MainActor
    private func scheduleDelayedBriefRetryIfNeeded(for cached: DailyBrief) {
        guard !delayedBriefRetryScheduled else { return }
        delayedBriefRetryScheduled = true
        delayedBriefRetryTask = Task { [weak self] in
            guard let self else { return }
            await self.briefRetryDelay()
            guard !Task.isCancelled, self.pendingBriefReconciliation == cached else { return }
            await self.drainBriefReconciliation()
        }
    }

    /// Deterministic test seam: production callers never await the background retry.
    @MainActor
    func waitForScheduledBriefRetryForTesting() async {
        await delayedBriefRetryTask?.value
    }

    // MARK: - Suggested tasks

    /// Refresh the backend's one atomic brief + suggestions snapshot. Older backends omit the
    /// negotiated identity fields, which intentionally leaves suggestions hidden.
    @MainActor
    func refreshBriefAndSuggestions() async {
        _ = await loadBrief()
    }

    func orchestratorSuggestionSnapshot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OrchestratorSuggestionSnapshot? {
        guard let identity = suggestionsBriefIdentity,
              identity == currentSuggestionBriefIdentity(),
              let suggestionsSnapshotID,
              suggestionsMutationScope == suggestionMutationScope(),
              identity.isCurrentLocalDay(now: now, calendar: calendar)
        else { return nil }
        return OrchestratorSuggestionSnapshot(
            identity: identity,
            snapshotID: suggestionsSnapshotID,
            briefMarkdown: brief?.displayedBriefMarkdown,
            suggestions: suggestions
        )
    }

    private func currentSuggestionBriefIdentity() -> OrchestratorSuggestionBriefIdentity? {
        OrchestratorSuggestionBriefIdentity(
            generatedAt: brief?.generatedAt,
            authoredMarkdown: brief?.briefMarkdown,
            authoredRevision: brief?.briefRevision
        )
    }

    private func publishAtomicSuggestions(from brief: DailyBrief) {
        guard let scope = suggestionMutationScope(),
        let identity = OrchestratorSuggestionBriefIdentity(
            generatedAt: brief.generatedAt,
            authoredMarkdown: brief.briefMarkdown,
            authoredRevision: brief.briefRevision
        ),
        identity.isCurrentLocalDay(now: suggestionNow(), calendar: suggestionCalendar()),
        let snapshot = OrchestratorSuggestionSnapshot(
            identity: identity,
            snapshotID: brief.suggestionSnapshotID,
            briefMarkdown: brief.displayedBriefMarkdown,
            suggestions: brief.suggestions
        ) else { return }
        suggestions = snapshot.suggestions
        suggestionsBriefIdentity = snapshot.identity
        suggestionsSnapshotID = snapshot.snapshotID
        suggestionsMutationScope = scope
    }

    private func invalidateSuggestionSnapshot() {
        suggestions = []
        suggestionsBriefIdentity = nil
        suggestionsSnapshotID = nil
        suggestionsMutationScope = nil
    }

    /// Auth/backend/gateway transitions retire every rendered action immediately. The dynamic
    /// authority check also fails closed before this lifecycle callback is delivered.
    func invalidateSuggestionAuthority() {
        invalidateSuggestionSnapshot()
        suggestionActionIDsInFlight.removeAll()
    }

    /// Accept a suggestion: perform its action through the app's own task path (so the app stays
    /// the source of truth), then durably dismiss it so it won't re-derive. Optimistically drops
    /// it from the list up front; on failure it reappears on the next load.
    @MainActor
    func acceptSuggestion(_ suggestion: TaskSuggestion, snapshotID: String) async {
        guard let authority = beginSuggestionAction(suggestion, snapshotID: snapshotID) else { return }
        defer { suggestionActionIDsInFlight.remove(suggestion.actionId) }
        // Optimistic removal for a snappy tap; an authoritative pair refresh restores it if the
        // action or durable dismissal fails, so nothing disappears without a recoverable outcome.
        suggestions.removeAll { $0.key == suggestion.key }

        let didAct = await performAccept(suggestion, authority: authority)
        guard isCurrent(authority) else { return }
        if didAct {
            // Only dismiss once the action actually happened — otherwise a card would vanish
            // permanently with no task created/rescheduled.
            if !(await dismissOnBackend(suggestion.key, authority: authority.requestAuthority)) {
                await refreshBriefAndSuggestions()
            }
        } else {
            // The action fell through (e.g. reschedule target not local yet). Re-establish the
            // canonical brief before restoring it; a suggestion-only retry could bind to stale prose.
            await refreshBriefAndSuggestions()
        }
    }

    /// Perform an accepted suggestion's action locally. Returns whether it actually did something
    /// (so the caller knows whether it's safe to durably dismiss).
    @MainActor
    private func performAccept(
        _ suggestion: TaskSuggestion,
        authority: SuggestionActionAuthority
    ) async -> Bool {
        guard isCurrent(authority) else { return false }
        let start = suggestion.action.startDate.flatMap { TaskComment.parseISO8601($0) }

        switch suggestion.action.kind {
        case "createTask":
            guard let stableTaskID = UUID(uuidString: suggestion.actionId) else { return false }
            let title = suggestion.action.taskTitle ?? suggestion.title
            // Guard against a duplicate prep task if this suggestion is accepted twice (e.g. a
            // dropped dismiss let it re-derive). The backend also excludes events that already
            // have a "Prep for X" task; this is the local half of that dedup.
            if let existingTask = allTasks.first(where: {
                TaskSuggestionCreateDeduplication.matchesExistingTask(
                    for: suggestion,
                    taskID: $0.id.uuidString
                )
            }) {
                guard isCurrent(authority),
                      let taskSyncService = taskSyncService as? ScopedSuggestionTaskSyncServiceProtocol
                else { return false }
                let durable = await taskSyncService.ensureSuggestionTaskCreateIsDurable(
                    existingTask,
                    authority: authority.requestAuthority
                )
                return durable && isCurrent(authority)
            }
            let newTask = TaskEvent(
                id: stableTaskID,
                title: title,
                startDate: start,
                status: start == nil ? .todo : .scheduled
            )
            modelContext.insert(newTask)
            do {
                try suggestionLocalSaver()
            } catch {
                modelContext.rollback()
                print("[Agenda] accept(create) local save failed: \(error.localizedDescription)")
                return false
            }
            taskStore.appendIfMissing(newTask)
            guard isCurrent(authority),
                  let taskSyncService = taskSyncService as? ScopedSuggestionTaskSyncServiceProtocol
            else { return false }
            let durable = await taskSyncService.ensureSuggestionTaskCreateIsDurable(
                newTask,
                authority: authority.requestAuthority
            )
            return durable && isCurrent(authority)

        case "rescheduleTask":
            // Move an existing overdue task onto today. If the target isn't in the local store
            // yet (e.g. created server-side, not synced down), do NOT dismiss — report no-op so
            // the card is restored and the user can retry after it syncs.
            guard
                let idString = suggestion.action.targetTaskId,
                let uuid = UUID(uuidString: idString),
                let task = allTasks.first(where: { $0.id == uuid }),
                let newStart = start
            else {
                print("[Agenda] accept(reschedule): target not local / no start — leaving suggestion")
                return false
            }
            // Only the schedule moves — the task keeps its existing status. Moving `startDate`
            // onto today is what lifts it out of "overdue".
            task.startDate = newStart
            task.updatedAt = Date()
            do {
                try suggestionLocalSaver()
            } catch {
                modelContext.rollback()
                print("[Agenda] accept(reschedule) local save failed: \(error.localizedDescription)")
                return false
            }
            guard isCurrent(authority),
                  let taskSyncService = taskSyncService as? ScopedSuggestionTaskSyncServiceProtocol
            else { return false }
            let durable = await taskSyncService.ensureSuggestionTaskUpdateIsDurable(
                task,
                authority: authority.requestAuthority
            )
            return durable && isCurrent(authority)

        default:
            print("[Agenda] accept: unknown action kind \(suggestion.action.kind)")
            return false
        }
    }

    /// Dismiss a suggestion — durable so it never comes back (doc 38 §6). Optimistic removal.
    @MainActor
    func dismissSuggestion(_ suggestion: TaskSuggestion, snapshotID: String) async {
        guard let authority = beginSuggestionAction(suggestion, snapshotID: snapshotID) else { return }
        defer { suggestionActionIDsInFlight.remove(suggestion.actionId) }
        suggestions.removeAll { $0.key == suggestion.key }
        let dismissed = await dismissOnBackend(
            suggestion.key,
            authority: authority.requestAuthority
        )
        guard isCurrent(authority) else { return }
        if !dismissed {
            await refreshBriefAndSuggestions()
        }
    }

    private func beginSuggestionAction(
        _ suggestion: TaskSuggestion,
        snapshotID: String
    ) -> SuggestionActionAuthority? {
        guard let snapshot = orchestratorSuggestionSnapshot(
            now: suggestionNow(),
            calendar: suggestionCalendar()
        ),
              let scope = suggestionsMutationScope,
              scope == suggestionMutationScope(),
              let requestAuthority = suggestionRequestAuthority(scope),
              snapshot.snapshotID == snapshotID,
              snapshot.suggestions.contains(suggestion),
              suggestionActionIDsInFlight.insert(suggestion.actionId).inserted
        else { return nil }
        return SuggestionActionAuthority(
            scope: scope,
            snapshotID: snapshotID,
            suggestion: suggestion,
            requestAuthority: requestAuthority
        )
    }

    private func isCurrent(_ authority: SuggestionActionAuthority) -> Bool {
        guard suggestionsMutationScope == authority.scope,
              suggestionMutationScope() == authority.scope,
              suggestionsSnapshotID == authority.snapshotID,
              let identity = suggestionsBriefIdentity,
              identity == currentSuggestionBriefIdentity(),
              identity.isCurrentLocalDay(now: suggestionNow(), calendar: suggestionCalendar())
        else { return false }
        return true
    }

    private func dismissOnBackend(
        _ key: String,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async -> Bool {
        do {
            try await suggestionDismissal(key, authority)
            return true
        } catch {
            print("[Agenda] dismiss failed for \(key): \(error.localizedDescription)")
            return false
        }
    }

    /// Resolve a brief item back to the local `TaskEvent` it refers to (events and
    /// already-synced tasks share the backend id). Nil for items not in the store.
    func taskEvent(for item: BriefItem) -> TaskEvent? {
        guard let uuid = item.taskUUID else { return nil }
        return allTasks.first { $0.id == uuid }
    }

    /// Mark a brief item done, then refresh the brief so the buckets reflect it.
    @MainActor
    func completeBriefItem(_ item: BriefItem) async {
        guard let task = taskEvent(for: item) else { return }
        await completeTask(task)
        await loadBrief()
    }

    /// Schedule an overdue / unscheduled brief item onto today (next top of the hour),
    /// then refresh the brief. Heavier date-picking stays in the existing scheduler.
    @MainActor
    func scheduleBriefItemForToday(_ item: BriefItem) async {
        guard let task = taskEvent(for: item) else { return }
        let cal = Calendar.current
        let now = Date()
        let nextHour = cal.date(bySetting: .minute, value: 0, of: cal.date(byAdding: .hour, value: 1, to: now) ?? now) ?? now
        await scheduleTask(task, at: nextHour)
        await loadBrief()
    }

    func scheduleTask(_ task: TaskEvent, at date: Date) async {
        task.startDate = date
        task.isAnyTime = false
        task.updatedAt = Date()
        try? modelContext.save()
        try? await taskSyncService?.syncTaskToBackendImmediately(task)
    }

    /// Batch-schedule the tasks chosen in the "Schedule (N)" multi-select sheet.
    ///
    /// IMPORTANT: this MUST push each task to the backend (like `scheduleTask`
    /// above). The earlier multi-select path only mutated SwiftData locally and
    /// never synced, so the backend's `start_date` stayed NULL. Any time local
    /// state was rebuilt from the backend (fresh install, second device, cache
    /// reset, or a pull that didn't carry the date) the task came back
    /// unscheduled and dropped into the inbox bucket again — the
    /// "won't stay scheduled / reverts on refresh" bug.
    func scheduleTasks(_ tasks: [TaskEvent], at date: Date) async {
        guard !tasks.isEmpty else { return }
        for task in tasks {
            task.startDate = date
            task.isAnyTime = false
            task.updatedAt = Date()
            if let duration = task.duration {
                task.endDate = date.addingTimeInterval(duration)
            }
        }
        try? modelContext.save()
        for task in tasks {
            try? await taskSyncService?.syncTaskToBackendImmediately(task)
        }
    }

    func snoozeTask(_ task: TaskEvent, minutes: Int = 15) async {
        let newAlertTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        task.alertTime = newAlertTime
        task.updatedAt = Date()
        try? modelContext.save()
        await TaskNotificationService.shared.snoozeNotification(
            taskId: task.id,
            taskTitle: task.title
        )
        try? await taskSyncService?.syncTaskToBackendImmediately(task)
    }

    func deleteTask(_ task: TaskEvent) async {
        if task.isEvent {
            let result = await deleteEventTask(task, scope: .thisEvent)
            if result {
                await refreshCalendarEvents()
            }
            return
        }

        guard await deleteTaskFromBackendIfNeeded(task) else { return }
        TaskNotificationService.shared.cancelNotification(for: task.id)
        modelContext.delete(task)
        try? modelContext.save()
    }

    /// Removes a calendar-only event (one that exists in EventKit but not in SwiftData).
    func deleteCalendarOnlyEvent(_ event: DeviceCalendarEventSummary) async {
        let result = await calendarService?.deleteEventFromCalendar(calendarEventID: event.calendarEventID, scope: .thisEvent)
            ?? CalendarDeleteResult(deleted: false, eventID: event.calendarEventID, title: event.title, failureReason: .unknown, message: "Calendar service unavailable.")

        if shouldPruneLocalRecord(for: result) {
            await refreshCalendarEvents()
            return
        }

        presentDeleteError(result.message ?? "This event can't be deleted from Rem.")
    }

    func shouldShowDeleteAction(for task: TaskEvent) -> Bool {
        guard task.isEvent else { return true }
        guard let eventID = task.calendarEventID else { return true }
        if let access = calendarEventAccessCache[eventID],
           !access.canDelete && !access.allowsLocalCleanup {
            return false
        }
        return true
    }

    func shouldShowDeleteAction(for event: DeviceCalendarEventSummary) -> Bool {
        guard let access = calendarEventAccessCache[event.calendarEventID] else { return true }
        return access.canDelete || access.allowsLocalCleanup
    }

    func shouldAllowFullSwipeDelete(for task: TaskEvent) -> Bool {
        guard let eventID = task.calendarEventID,
              let access = calendarEventAccessCache[eventID] else { return true }
        return !access.isRecurring
    }

    func shouldAllowFullSwipeDelete(for event: DeviceCalendarEventSummary) -> Bool {
        guard let access = calendarEventAccessCache[event.calendarEventID] else { return true }
        return !access.isRecurring
    }

    func handleDeleteAction(for task: TaskEvent) {
        guard task.isEvent else {
            Task { await deleteTask(task) }
            return
        }

        guard let eventID = task.calendarEventID else {
            Task { await deleteTask(task) }
            return
        }

        if calendarEventAccessCache[eventID]?.isRecurring == true {
            recurringDeleteRequest = AgendaRecurringDeleteRequest(target: .task(task), title: task.title)
            return
        }

        Task { await deleteTask(task) }
    }

    func handleDeleteAction(for event: DeviceCalendarEventSummary) {
        if calendarEventAccessCache[event.calendarEventID]?.isRecurring == true {
            recurringDeleteRequest = AgendaRecurringDeleteRequest(target: .calendarEvent(event), title: event.title)
            return
        }

        Task { await deleteCalendarOnlyEvent(event) }
    }

    func deleteRecurringRequest(scope: CalendarDeleteScope) async {
        guard let request = recurringDeleteRequest else { return }
        recurringDeleteRequest = nil

        switch request.target {
        case .task(let task):
            let deleted = await deleteEventTask(task, scope: scope)
            if deleted {
                await refreshCalendarEvents()
            }
        case .calendarEvent(let event):
            let result = await calendarService?.deleteEventFromCalendar(calendarEventID: event.calendarEventID, scope: scope)
                ?? CalendarDeleteResult(deleted: false, eventID: event.calendarEventID, title: event.title, failureReason: .unknown, message: "Calendar service unavailable.")
            if shouldPruneLocalRecord(for: result) {
                await refreshCalendarEvents()
            } else {
                presentDeleteError(result.message ?? "This event can't be deleted from Rem.")
            }
        }
    }

    private func deleteEventTask(_ task: TaskEvent, scope: CalendarDeleteScope) async -> Bool {
        let result: CalendarDeleteResult
        if let calendarEventID = task.calendarEventID {
            result = await calendarService?.deleteEventFromCalendar(calendarEventID: calendarEventID, scope: scope)
                ?? CalendarDeleteResult(deleted: false, eventID: calendarEventID, title: task.title, failureReason: .unknown, message: "Calendar service unavailable.")
        } else if task.isCalendarOnlyMirror == true {
            result = CalendarDeleteResult(
                deleted: false,
                eventID: nil,
                title: task.title,
                failureReason: .eventNotFound,
                message: "This calendar event is no longer available."
            )
        } else {
            result = CalendarDeleteResult(deleted: true, eventID: nil, title: task.title)
        }

        guard shouldPruneLocalRecord(for: result) else {
            presentDeleteError(result.message ?? "This event can't be deleted from Rem.")
            return false
        }

        guard await deleteTaskFromBackendIfNeeded(task) else { return false }
        TaskNotificationService.shared.cancelNotification(for: task.id)
        modelContext.delete(task)
        try? modelContext.save()
        return true
    }

    private func deleteTaskFromBackendIfNeeded(_ task: TaskEvent) async -> Bool {
        guard task.isCalendarOnlyMirror != true else { return true }
        if let apiService = taskApiService {
            do {
                try await apiService.deleteTask(id: task.id.uuidString)
                if let taskSyncService,
                   await taskSyncService.recordConfirmedDelete(for: task.id) == false {
                    presentDeleteError("Rem couldn't save this deletion locally. The task was kept on this device.")
                    return false
                }
            } catch {
                guard await taskSyncService?.queueOperation(operationType: "delete", taskId: task.id, taskData: nil) == true else {
                    presentDeleteError("Rem couldn't save this deletion for retry. The task was kept on this device.")
                    return false
                }
                print("[Agenda] Backend delete failed: \(error.localizedDescription)")
            }
        } else if await taskSyncService?.queueOperation(
            operationType: "delete", taskId: task.id, taskData: nil
        ) != true {
            presentDeleteError("Rem couldn't save this deletion for retry. The task was kept on this device.")
            return false
        }
        return true
    }

    private func shouldPruneLocalRecord(for result: CalendarDeleteResult) -> Bool {
        result.deleted || result.failureReason == .eventNotFound
    }

    private func presentDeleteError(_ message: String) {
        alert = AgendaAlert(title: "Unable to Delete Event", message: message)
    }
}
