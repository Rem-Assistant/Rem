import SwiftUI
import SwiftData

#if DEBUG

/// Flagship-Agenda README fixture. Drives the REAL `AgendaView` + `AgendaViewModel`
/// with an in-memory store of mock tasks, a mock Daily Brief (header + suggestions),
/// and the REAL main bottom toolbar (`remMainBottomToolbar`, the same controls
/// `RemMainTabView` shows) inside a real `.bottomBar` toolbar group — so the captured
/// screenshot matches the signed-in app (calendar header, brief header, sort control,
/// Overdue section, Add New / Schedule, Suggestions, and the authentic tab bar chrome).
/// 100% mock data: no account, no network, no real names/emails.
///
/// Launch arg: `--rem-agenda-fixture`.
struct ReadmeAgendaFullFixtureView: View {
    @State private var viewModel: AgendaViewModel
    private let container: ModelContainer

    @MainActor
    init() {
        let container = try! ModelContainer(
            for: TaskEvent.self, PendingTaskOperation.self, TaskList.self, TaskFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.container = container
        let context = ModelContext(container)

        let sync = RemTaskSyncService(
            taskApiService: ReadmeStubTaskApiService(),
            modelContext: context
        )
        let store = TaskStore(taskSyncService: sync)
        store.update(Self.mockTasks())

        let brief = Self.mockBrief()
        let vm = AgendaViewModel(
            modelContext: context,
            taskStore: store,
            briefLoader: { brief },
            suggestionMutationScope: {
                AgendaSuggestionMutationScope(
                    accountID: "readme-fixture",
                    backendURL: "https://rem.example",
                    gatewayURL: "https://gateway.example"
                )
            }
        )
        vm.sortMode = .status
        vm.brief = brief
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            AgendaView(
                viewModel: viewModel,
                onCreateTask: {},
                onOpenCalendarSettings: {},
                onOpenBriefChat: { _ in },
                onReadBrief: {}
            )
            .modelContainer(container)
            .toolbar(.hidden, for: .navigationBar)
            // Drive the REAL toolbar the app shows on the Agenda tab (hamburger ·
            // new-chat · plus), not a hand-drawn copy. Agenda tab, no active session,
            // first-use hint suppressed — inert closures (the fixture never navigates).
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    remMainBottomToolbar(
                        selectedTab: .agenda,
                        hasActiveSession: false,
                        firstUseHintPresented: .constant(false),
                        onSelectTab: { _ in },
                        onNewChat: {},
                        onDismissFirstUseHint: {},
                        onCreateTask: {},
                        onNewFolder: {},
                        onNewList: {}
                    )
                }
            }
        }
    }

    // MARK: - Mock data

    @MainActor
    private static func mockTasks() -> [TaskEvent] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
        }
        return [
            // Early-morning start times → these land in the "Overdue" status bucket.
            TaskEvent(
                title: "Reply to the venue about Saturday's set",
                startDate: at(8, 0),
                priority: .high,
                status: .todo
            ),
            TaskEvent(
                title: "Send the updated setlist to the band",
                startDate: at(9, 30),
                priority: .medium,
                status: .todo
            ),
            // Evening event → upcoming ("To do") bucket.
            TaskEvent(
                title: "Coffee chat with a mentor",
                startDate: at(19, 0),
                endDate: at(19, 30),
                isEvent: true,
                status: .todo
            ),
        ]
    }

    private static func isoNow(offsetDays: Int = 0) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date()) ?? Date()
        return ISO8601DateFormatter().string(from: date)
    }

    private static func mockSuggestions() -> [TaskSuggestion] {
        [
            TaskSuggestion(
                key: "cal:readme-1",
                // `OrchestratorSuggestionSnapshot` requires actionId to be a valid UUID.
                actionId: "11111111-1111-1111-1111-111111111111",
                source: "calendar",
                title: "Prep for tomorrow's rehearsal",
                subtitle: "Rehearsal · 6:00 PM · Calendar",
                action: SuggestionAction(
                    kind: "createTask",
                    taskTitle: "Prep for tomorrow's rehearsal",
                    targetTaskId: nil,
                    startDate: isoNow(offsetDays: 1)
                )
            ),
            TaskSuggestion(
                key: "overdue:readme-2",
                actionId: "22222222-2222-2222-2222-222222222222",
                source: "overdue",
                title: "Reschedule to today",
                subtitle: "'Water the plants' · overdue 2d",
                action: SuggestionAction(
                    kind: "rescheduleTask",
                    taskTitle: nil,
                    targetTaskId: "33333333-3333-3333-3333-333333333333",
                    startDate: isoNow()
                )
            ),
        ]
    }

    @MainActor
    private static func mockBrief() -> DailyBrief {
        DailyBrief(
            generatedAt: isoNow(),
            briefRevision: "readme-rev-1",
            suggestionSnapshotID: "readme-snap-1",
            suggestions: mockSuggestions(),
            counts: BriefCounts(
                blocked: 1, overdue: 2, scheduledToday: 3, completedToday: 1, total: 5, done: 1
            ),
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Your evening is quiet — one thread still needs you.",
            summary: "Your evening is quiet — one thread still needs you.",
            headline: "Wednesday Evening",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
    }
}

/// No-op `TaskApiServiceProtocol` for the Agenda fixture — the fixture never syncs or
/// mutates, so every method is inert. Mirrors the shape of the test stubs.
private final class ReadmeStubTaskApiService: TaskApiServiceProtocol {
    func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id ?? UUID().uuidString, title: title)
    }
    func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id ?? UUID().uuidString, title: title)
    }
    func fetchTasks() async throws -> [TaskEventApiResponse] { [] }
    func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse] { [] }
    func getTask(id: String) async throws -> TaskEventApiResponse { TaskEventApiResponse(id: id, title: "") }
    func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?, includeListID: Bool, includeClearedFields: Bool) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id, title: title ?? "")
    }
    func deleteTask(id: String) async throws {}
    func ensureEventBacking(calendarEventID: String, title: String, startDate: Date?, durationMinutes: Int?, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: UUID().uuidString, title: title)
    }
}
#endif
