import SwiftUI
import SwiftData

struct TaskEventView: View {
    @Environment(\.dismiss) private var dismiss

    // StateObject persists the ViewModel across parent re-renders.
    // With @ObservedObject, the parent creating TaskEventViewModel(...)
    // inline caused a new instance on every body evaluation, so .task
    // and .onAppear operated on a discarded instance.
    @StateObject var viewModel: TaskEventViewModel
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isNotesFocused: Bool
    @State private var showInspectorSheet = false
    @State private var showFocusSetup = false
    @State private var showCreateListSheet = false
    @State private var commentsModel = TaskCommentsModel()

    /// Backs the "New List…" action in the list-chip picker — creating a List
    /// inline writes through the same optimistic local + backend path as the
    /// Tasks tab's create sheet.
    private let organizationApiService = OrganizationApiService()

    /// Lists the task can be filed into, for the list chip's picker. Read from the local
    /// SwiftData cache (synced by `OrganizationSyncManager`), same source as `TasksByListView`.
    @Query(sort: [SortDescriptor(\TaskList.sortOrder), SortDescriptor(\TaskList.createdAt)])
    private var availableLists: [TaskList]

    var onTaskAddedToInbox: (() -> Void)?
    var onStartFocusSession: ((FocusSession) -> Void)?
    /// Tapping an Activity row asks the host to open the chat session that produced
    /// the comment. The host owns the NavigationStack + chat ViewModel, so it
    /// resolves `TaskComment.sessionId` to a `ChatDestination` (or falls back when
    /// the comment has no session). Default no-op for previews/fixtures.
    var onOpenSession: ((TaskComment) -> Void)?

    /// "View history" asks the host to open the full activity/comment thread for the
    /// task (a read-focused list with its own doorway into the task-scoped chat).
    /// The host pushes the dedicated history destination keyed by this task id.
    var onOpenHistory: ((String) -> Void)?

    /// The bottom composer is the doorway into the **task-scoped chat** (founder's
    /// unblock surface): the host opens a continuation chat seeded with the task's
    /// context (title + latest activity), carrying whatever the user typed. Passes
    /// the task id, the latest comment (so the seed can quote Rem's last update), and
    /// the current draft.
    var onOpenTaskChat: ((_ taskId: String, _ latest: TaskComment?, _ draft: String) -> Void)?

    init(
        viewModel: TaskEventViewModel,
        onTaskAddedToInbox: (() -> Void)? = nil,
        onStartFocusSession: ((FocusSession) -> Void)? = nil,
        onOpenSession: ((TaskComment) -> Void)? = nil,
        onOpenHistory: ((String) -> Void)? = nil,
        onOpenTaskChat: ((_ taskId: String, _ latest: TaskComment?, _ draft: String) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onTaskAddedToInbox = onTaskAddedToInbox
        self.onStartFocusSession = onStartFocusSession
        self.onOpenSession = onOpenSession
        self.onOpenHistory = onOpenHistory
        self.onOpenTaskChat = onOpenTaskChat
    }

    var body: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary
                .edgesIgnoringSafeArea(.all)

            ScrollView {
                if viewModel.isNewTask {
                    editingContent
                } else {
                    mergedEditableContent
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.isNewTask {
                    commentsComposerCard
                }
            }
        }
        .task {
            // Load Activity against the task that owns this thread. A real app task uses
            // its own id; an event already opted into being worked uses its backing task
            // id (migration 024) — both load eagerly. An un-worked but workable calendar
            // event configures the surface *lazily*: it shows the SAME Activity surface as
            // a task (no opt-in card), and #872's backing task is created on first
            // interaction (Run now / reply / open chat) via `ensureWorkBacking`, not an
            // explicit "Let Rem work this" tap (#875).
            if let activityTaskId = viewModel.activityTaskId {
                await configureActivity(taskId: activityTaskId)
            } else if viewModel.canOptEventIntoWork {
                commentsModel.configureLazy(
                    commitStatus: { status in await viewModel.commitCollaborationStatus(status) },
                    resolveBackingTaskId: { await viewModel.ensureWorkBacking() },
                    onStampedSessionKey: { stampedTaskId, sessionKey in
                        viewModel.applyStampedSessionKey(taskId: stampedTaskId, sessionKey: sessionKey)
                    }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.isNewTask {
                    // Create mode: Cancel + Save
                    HStack(spacing: 8) {
                        Button("Cancel") { dismiss() }
                        Button("Save") {
                            Task {
                                if let saved = await viewModel.save() {
                                    if saved.shouldAppearInInbox {
                                        onTaskAddedToInbox?()
                                    }
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(!viewModel.canSaveEvent)
                    }
                } else {
                    // Edit mode: ellipsis menu with Revert + Delete
                    Menu {
                        Button {
                            viewModel.revertChanges()
                        } label: {
                            Label("Revert Changes", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!viewModel.hasChanges)

                        Button(role: .destructive) {
                            viewModel.showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(!viewModel.canDeleteTask)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showFocusSetup) {
            if let task = viewModel.task {
                FocusSessionSetupView(task: task) { session in
                    dismiss()
                    onStartFocusSession?(session)
                }
            }
        }
        .sheet(isPresented: $showCreateListSheet) {
            CreateListSheet(
                apiService: organizationApiService,
                onCreated: { newListID in
                    // File this task into the list the user just created.
                    Task { await viewModel.assignToList(newListID) }
                }
            )
        }
        .sheet(isPresented: $showInspectorSheet) {
            TaskInspectorSheet(
                startDate: $viewModel.startDate,
                endDate: $viewModel.endDate,
                alertTime: $viewModel.alertTime,
                repeatFrequency: $viewModel.repeatFrequency,
                duration: $viewModel.duration,
                isEvent: viewModel.taskType == .event,
                availableCalendars: viewModel.availableCalendars,
                selectedCalendarID: $viewModel.selectedCalendarID,
                calendarColor: $viewModel.calendarColor,
                isAnyTime: $viewModel.isAnyTime
            )
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete Task",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if viewModel.requiresRecurringDeleteConfirmation {
                Button("Delete This Event", role: .destructive) {
                    Task {
                        if await viewModel.deleteTask(scope: .thisEvent) {
                            dismiss()
                        }
                    }
                }
                Button("Delete This and Future Events", role: .destructive) {
                    Task {
                        if await viewModel.deleteTask(scope: .futureEvents) {
                            dismiss()
                        }
                    }
                }
            } else {
                Button("Delete", role: .destructive) {
                    Task {
                        if await viewModel.deleteTask() {
                            dismiss()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.requiresRecurringDeleteConfirmation
                ? "Choose whether to remove just this occurrence or this event going forward."
                : "Are you sure you want to delete this task? This action cannot be undone.")
        }
        .task {
            await viewModel.loadCalendars()
            await viewModel.loadEventAccess()
        }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { viewModel.actionErrorMessage != nil },
            set: { if !$0 { viewModel.actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionErrorMessage ?? "")
        }
        .onAppear {
            if viewModel.isNewTask {
                isTitleFocused = true
            }
        }
        .onChange(of: viewModel.taskType) { _, newValue in
            if newValue == .event && viewModel.startDate == nil {
                viewModel.startDate = Date()
            }
        }
        // Auto-save on field changes (existing tasks only)
        .onChange(of: viewModel.title) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.taskDescription) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.startDate) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.endDate) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.duration) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.alertTime) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.repeatFrequency) { _, _ in viewModel.debouncedSave() }
        .onChange(of: viewModel.isAnyTime) { _, _ in viewModel.debouncedSave() }
    }

    // MARK: - Create Mode Content

    @ViewBuilder
    private var editingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Type picker
            Picker("Type", selection: $viewModel.taskType) {
                ForEach(TaskType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            // Title
            titleRow

            // Calendar chip for events
            if viewModel.taskType == .event {
                calendarChip
            }

            // Date / time details
            EditableTaskDetailsSection(
                startDate: viewModel.startDate,
                endDate: viewModel.endDate,
                alertTime: viewModel.alertTime,
                repeatFrequency: viewModel.repeatFrequency,
                duration: viewModel.duration,
                isEvent: viewModel.taskType == .event,
                isAnyTime: viewModel.isAnyTime,
                onTap: { showInspectorSheet = true }
            )

            // Notes — the single free-text field, which IS the task description
            // (#1367). See `notesSection`.
            notesSection
        }
    }

    // MARK: - Edit Mode Content (always editable, auto-saves)

    @ViewBuilder
    private var mergedEditableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = viewModel.readOnlyCalendarMessage {
                readOnlyCalendarBanner(message: message)
            }

            // Title with interactive status indicator
            titleRow

            // Calendar chip for events
            if viewModel.taskType == .event {
                calendarChip
            }

            // List chip for tasks — file the task into a List (mirrors the calendar chip).
            if viewModel.canAssignList {
                listChip
            }

            // Date / time details
            EditableTaskDetailsSection(
                startDate: viewModel.startDate,
                endDate: viewModel.endDate,
                alertTime: viewModel.alertTime,
                repeatFrequency: viewModel.repeatFrequency,
                duration: viewModel.duration,
                isEvent: viewModel.taskType == .event,
                isAnyTime: viewModel.isAnyTime,
                isReadOnly: viewModel.isReadOnlyCalendarEvent,
                onTap: {
                    guard !viewModel.isReadOnlyCalendarEvent else { return }
                    showInspectorSheet = true
                }
            )

            // Activity log — the primary collaboration surface (Rem's record of
            // what it did/said, plus the human's replies), so it sits ABOVE notes.
            // Stays inline in the scroll; the reply composer docks at the bottom as
            // a card (safeAreaInset below). Both share `commentsModel`.
            // A calendar event detail shows this the SAME as a task (#875): real app
            // tasks and already-worked events load it eagerly; an un-worked but
            // workable calendar event shows it directly too, creating #872's backing
            // task lazily on first interaction (no "Let Rem work this" opt-in card).
            if viewModel.showsActivitySurface {
                TaskCommentsThread(
                    model: commentsModel,
                    onOpenSession: { comment in
                        // The task is the "workboard"; tapping a row drills into the agent
                        // session/chat that produced it (OpenClaw's Workboard → session).
                        // The session handle rides on `comment.sessionId`; the host
                        // (RemMainTabView) owns the NavigationStack + chat ViewModel and
                        // resolves it to a `ChatDestination`, falling back gracefully when
                        // a comment has no session. See `onOpenSession`.
                        onOpenSession?(comment)
                    },
                    // "View history" → the full activity thread (a reliable doorway for
                    // every item, including human comments with no session to drill into).
                    onViewHistory: {
                        if let activityTaskId = viewModel.activityTaskId {
                            onOpenHistory?(activityTaskId)
                        }
                    }
                )
            }

            // Notes / description — the single free-text field ("Add your notes here"),
            // below activity (#1367). See `notesSection`.
            notesSection
        }
    }

    // MARK: - Activity reply composer bottom card

    /// Only the composer docks to the bottom — a card with rounded top corners whose
    /// fill bleeds into the bottom safe area (no bottom shadow), replacing the old
    /// focus-session bottom bar. The Activity log renders inline above.
    @ViewBuilder
    private var commentsComposerCard: some View {
        if viewModel.showsActivitySurface {
            // Doorway mode: the composer OPENS the task-scoped chat (founder: "the
            // composer should open whatever link we already have") seeded with the
            // task's context, instead of posting an inline reply. The draft travels
            // along so nothing the user typed is lost.
            // Opening the chat is a first-interaction for an un-worked event: the model
            // resolves (creating if needed) #872's backing task id, so the handoff has a
            // real task to seed. For a real task / already-worked event the id is already
            // configured and this returns immediately. nil = couldn't create the backing
            // (inline error already surfaced) → don't dead-end into a chat with no task.
            TaskCommentComposer(model: commentsModel, onOpenChat: { draft in
                Task {
                    guard let activityTaskId = await commentsModel.resolveTaskIdForHandoff() else { return }
                    onOpenTaskChat?(activityTaskId, commentsModel.latestComment, draft)
                }
            })
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)
                .background(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                        .fill(DesignTokens.Color.backgroundPrimary)
                        .overlay(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                                .strokeBorder(DesignTokens.Color.separator, lineWidth: 0.5)
                        }
                        .ignoresSafeArea(edges: .bottom)
                }
        }
    }

    // MARK: - Activity configuration

    /// Point the shared Activity model at `taskId` and load its thread. Used on appear
    /// for a real app task / already-worked event. `configure` is idempotent, so repeat
    /// calls are safe. An un-worked but workable calendar event configures *lazily*
    /// instead (see the `.task` modifier + `TaskCommentsModel.configureLazy`).
    private func configureActivity(taskId: String) async {
        commentsModel.configure(
            taskId: taskId,
            commitStatus: { status in await viewModel.commitCollaborationStatus(status) },
            // Apply the backend-stamped session key to the local SwiftData task right
            // after a cloud run so "Open conversation" opens the SAME session (#971
            // follow-up), instead of falling back to `task-<slug>` until the next sync.
            onStampedSessionKey: { stampedTaskId, sessionKey in
                viewModel.applyStampedSessionKey(taskId: stampedTaskId, sessionKey: sessionKey)
            }
        )
        await commentsModel.load()
    }

    // MARK: - Title Row

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if viewModel.taskType == .event {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(viewModel.calendarColor)
                    .frame(width: 4, height: 34)
            } else if let task = viewModel.task {
                TaskStatusIndicator(task: task)
            } else {
                Image(systemName: "circle")
                    .font(DesignTokens.Typography.title1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            TextField("Title", text: $viewModel.title)
                .font(DesignTokens.Typography.title1Bold)
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .focused($isTitleFocused)
                .disabled(viewModel.isReadOnlyCalendarEvent)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - Calendar Chip

    @ViewBuilder
    private var calendarChip: some View {
        CalendarChipMenu(
            availableCalendars: viewModel.availableCalendars,
            selectedCalendarID: $viewModel.selectedCalendarID,
            calendarColor: $viewModel.calendarColor,
            isReadOnly: viewModel.isReadOnlyCalendarEvent
        )
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    // MARK: - List Chip

    /// Files the task into a List. Mirrors the calendar chip's menu pattern: tap to pick
    /// a List (or "No List" to unfile). Tasks only (`canAssignList`); the assignment
    /// PATCHes the backend via the ViewModel.
    @ViewBuilder
    private var listChip: some View {
        TaskListChipMenu(
            availableLists: availableLists,
            selectedListID: viewModel.selectedListID,
            onSelect: { listID in
                Task { await viewModel.assignToList(listID) }
            },
            onCreateList: { showCreateListSheet = true }
        )
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    // MARK: - Notes Section (IS the task description — #1367)

    /// The single free-text field on the task detail. The founder's model (#1367): the
    /// "Add your notes here" field IS the task description — there is no longer a separate
    /// "Description" field above it (that was scope creep from the agent-task-context work,
    /// #1313). So this editor is bound to `taskDescription` (the backend `description`
    /// column, migration 120 — the context every agent run reads), keeping the familiar
    /// "Add your notes here" placeholder.
    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $viewModel.taskDescription)
                .font(DesignTokens.Typography.body)
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .frame(minHeight: 120)
                .focused($isNotesFocused)
                .disabled(viewModel.isReadOnlyCalendarEvent)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if viewModel.taskDescription.isEmpty {
                        Text("Add your notes here")
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private func readOnlyCalendarBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignTokens.Color.labelPrimary)

            Text(message)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

// MARK: - Editable Task Details Section

struct EditableTaskDetailsSection: View {
    let startDate: Date?
    let endDate: Date?
    let alertTime: Date?
    let repeatFrequency: String?
    let duration: TimeInterval?
    let isEvent: Bool
    let isAnyTime: Bool
    /// Read-only calendar event: render the date/time row as a static, dimmed,
    /// non-interactive summary (no button affordance) so it doesn't imply it's editable.
    var isReadOnly: Bool = false
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // Date info or "Set date, time, repeat" button
            if let startDate {
                detailButton {
                    DateInfoSection(
                        startDate: startDate,
                        endDate: endDate,
                        isEvent: isEvent,
                        isAnyTime: isAnyTime
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !isReadOnly {
                detailButton {
                    HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "clock")
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                        Text("Set date, time, repeat")
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Alert / repeat / duration pills
            detailButton {
                EditableAlertRepeatSection(
                    alertTime: alertTime,
                    repeatFrequency: repeatFrequency,
                    duration: duration,
                    startDate: startDate,
                    endDate: endDate,
                    isEvent: isEvent,
                    isAnyTime: isAnyTime
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        // Dim the whole block when read-only to signal "view only, not editable".
        .opacity(isReadOnly ? 0.45 : 1)
    }

    /// Wraps a row in a tap target when editable; when read-only, renders the content
    /// inert (no button, no hit testing) so there's no tap affordance.
    @ViewBuilder
    private func detailButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if isReadOnly {
            content()
                .allowsHitTesting(false)
        } else {
            Button(action: onTap) {
                content()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Date Info Section

struct DateInfoSection: View {
    let startDate: Date
    let endDate: Date?
    let isEvent: Bool
    let isAnyTime: Bool

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = isAnyTime ? .none : .short
        return formatter
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "clock")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundColor(DesignTokens.Color.labelPrimary)

            if isEvent {
                if let endDate {
                    let calendar = Calendar.current
                    let isSameDay = calendar.isDate(startDate, inSameDayAs: endDate)

                    if isAnyTime && isSameDay {
                        Text(dateFormatter.string(from: startDate))
                            .font(DesignTokens.Typography.bodyBold)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    } else {
                        Text("\(dateFormatter.string(from: startDate)) - \(dateFormatter.string(from: endDate))")
                            .font(DesignTokens.Typography.bodyBold)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    }
                } else {
                    Text(dateFormatter.string(from: startDate))
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                }
            } else {
                Text(dateFormatter.string(from: startDate))
                    .font(DesignTokens.Typography.bodyBold)
                    .foregroundColor(DesignTokens.Color.labelPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editable Alert / Repeat / Duration Section

struct EditableAlertRepeatSection: View {
    let alertTime: Date?
    let repeatFrequency: String?
    let duration: TimeInterval?
    let startDate: Date?
    let endDate: Date?
    let isEvent: Bool
    let isAnyTime: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Duration
            if isEvent && isAnyTime {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "alarm")
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text("All day")
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                }
            } else if let duration {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "alarm")
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(formatDuration(duration))
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "alarm")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text("Duration")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
            }

            // Alert
            if let alertTime {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "bell")
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(formatAlertTime(alertTime))
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "bell")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text("No alert")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
            }

            // Repeat
            if let repeatFrequency {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "repeat")
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(repeatFrequency.uppercased())
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "repeat")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Text("No repeat")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    private func formatAlertTime(_ alert: Date) -> String {
        guard let start = startDate else { return "30 minutes before" }
        let timeDiff = start.timeIntervalSince(alert)
        let minutes = Int(timeDiff / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return days == 1 ? "1 day before" : "\(days) days before" }
        if hours >= 1 { return hours == 1 ? "1 hour before" : "\(hours) hours before" }
        if minutes > 0 { return "\(minutes) minutes before" }
        return "At time of event"
    }

}

// MARK: - Calendar Chip Menu

struct CalendarChipMenu: View {
    let availableCalendars: [CalendarInfo]
    @Binding var selectedCalendarID: String?
    @Binding var calendarColor: Color
    /// Read-only calendar event: show the calendar as a static, dimmed label with no
    /// chevron and no menu, so it doesn't look tappable/editable.
    var isReadOnly: Bool = false

    private var selectedCalendar: CalendarInfo? {
        guard let id = selectedCalendarID else { return nil }
        return availableCalendars.first(where: { $0.id == id })
    }

    var body: some View {
        if isReadOnly {
            readOnlyChip
        } else if availableCalendars.isEmpty {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "calendar")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text("No calendars available")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        } else {
            Menu {
                ForEach(availableCalendars) { calendar in
                    Button {
                        selectedCalendarID = calendar.id
                        calendarColor = calendar.color
                    } label: {
                        HStack {
                            Circle()
                                .fill(calendar.color)
                                .frame(width: 12, height: 12)
                            Text(calendar.name)
                            if selectedCalendarID == calendar.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let selected = selectedCalendar {
                        Circle()
                            .fill(selected.color)
                            .frame(width: 12, height: 12)
                        Text(selected.name)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    } else {
                        Circle()
                            .fill(DesignTokens.Color.labelSecondary)
                            .frame(width: 12, height: 12)
                        Text("Select Calendar")
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(DesignTokens.Color.fillTertiary)
                .cornerRadius(DesignTokens.CornerRadius.medium)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
        }
    }

    /// Static, dimmed calendar label for a read-only event — no chevron, no menu,
    /// non-interactive. Matches the chip's fill/shape so it reads as a disabled control.
    @ViewBuilder
    private var readOnlyChip: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if let selected = selectedCalendar {
                Circle()
                    .fill(selected.color)
                    .frame(width: 12, height: 12)
                Text(selected.name)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelPrimary)
            } else {
                Circle()
                    .fill(DesignTokens.Color.labelTertiary)
                    .frame(width: 12, height: 12)
                Text("Calendar")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Color.fillTertiary)
        .cornerRadius(DesignTokens.CornerRadius.medium)
        .opacity(0.55)
        .allowsHitTesting(false)
    }
}

// MARK: - List Chip Menu

/// Files a task into a **List**, mirroring `CalendarChipMenu`: a pill that opens a menu
/// of the user's Lists plus a "No List" option to unfile. The selected List drives the
/// label; selection is reported via `onSelect` (the ViewModel persists it + PATCHes the
/// backend). Tasks only — events use the calendar chip instead.
struct TaskListChipMenu: View {
    let availableLists: [TaskList]
    let selectedListID: UUID?
    let onSelect: (UUID?) -> Void
    /// Optional: create a new List inline from the picker. When set, a "New List…"
    /// action is appended to the menu; the caller presents the create sheet and
    /// files the task into the result.
    var onCreateList: (() -> Void)? = nil

    private var selectedList: TaskList? {
        guard let id = selectedListID else { return nil }
        return availableLists.first(where: { $0.id == id })
    }

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                HStack {
                    Image(systemName: "tray")
                    Text("No List")
                    if selectedListID == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !availableLists.isEmpty {
                Divider()
                ForEach(availableLists) { list in
                    Button {
                        onSelect(list.id)
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet")
                            Text(list.name)
                            if selectedListID == list.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if let onCreateList {
                Divider()
                Button(action: onCreateList) {
                    Label("New List…", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selectedList == nil
                        ? DesignTokens.Color.labelSecondary
                        : DesignTokens.Color.labelPrimary)
                Text(selectedList?.name ?? "No List")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(selectedList == nil
                        ? DesignTokens.Color.labelSecondary
                        : DesignTokens.Color.labelPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(DesignTokens.Color.fillTertiary)
            .cornerRadius(DesignTokens.CornerRadius.medium)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
    }
}

// MARK: - Task Inspector Sheet

struct TaskInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var startDate: Date?
    @Binding var endDate: Date?
    @Binding var alertTime: Date?
    @Binding var repeatFrequency: String?
    @Binding var duration: TimeInterval?
    let isEvent: Bool
    let availableCalendars: [CalendarInfo]
    @Binding var selectedCalendarID: String?
    @Binding var calendarColor: Color
    @Binding var isAnyTime: Bool

    @State private var localStartDate: Date
    @State private var localEndDate: Date
    @State private var localIsAnyTime: Bool
    @State private var localDuration: TimeInterval?
    @State private var alertSelection: String
    @State private var localRepeatFrequency: String
    @State private var isAllDay: Bool
    @State private var showDurationPicker = false

    let repeatOptions = ["None", "Daily", "Weekly", "Monthly", "Yearly"]
    let alertOptions = ["None", "Day before", "30 minutes before"]

    init(
        startDate: Binding<Date?>,
        endDate: Binding<Date?>,
        alertTime: Binding<Date?>,
        repeatFrequency: Binding<String?>,
        duration: Binding<TimeInterval?>,
        isEvent: Bool = false,
        availableCalendars: [CalendarInfo] = [],
        selectedCalendarID: Binding<String?> = .constant(nil),
        calendarColor: Binding<Color> = .constant(DesignTokens.Color.labelSecondary),
        isAnyTime: Binding<Bool> = .constant(false)
    ) {
        self._startDate = startDate
        self._endDate = endDate
        self._alertTime = alertTime
        self._repeatFrequency = repeatFrequency
        self._duration = duration
        self.isEvent = isEvent
        self.availableCalendars = availableCalendars
        self._selectedCalendarID = selectedCalendarID
        self._calendarColor = calendarColor
        self._isAnyTime = isAnyTime

        _localStartDate = State(initialValue: startDate.wrappedValue ?? Date())
        _localEndDate = State(initialValue: endDate.wrappedValue ?? Date().addingTimeInterval(3600))
        _localIsAnyTime = State(initialValue: isAnyTime.wrappedValue)
        _localDuration = State(initialValue: duration.wrappedValue)
        _localRepeatFrequency = State(initialValue: repeatFrequency.wrappedValue ?? "None")
        _alertSelection = State(initialValue: alertTime.wrappedValue == nil ? "None" : "30 minutes before")
        _isAllDay = State(initialValue: isEvent && isAnyTime.wrappedValue && duration.wrappedValue == nil)
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignTokens.Color.backgroundPrimary
                    .edgesIgnoringSafeArea(.all)

                List {
                    if isEvent {
                        eventSections
                    } else {
                        taskSections
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(isEvent ? "Event details" : "Task Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isEvent ? "Cancel" : "Clear") {
                        if isEvent {
                            dismiss()
                        } else {
                            // Clear all fields including dates
                            startDate = nil
                            endDate = nil
                            alertTime = nil
                            repeatFrequency = nil
                            duration = nil
                            isAnyTime = false
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        saveChanges()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showDurationPicker) {
            DurationPickerView(duration: $localDuration)
        }
    }

    // MARK: - Event Sections

    @ViewBuilder
    private var eventSections: some View {
        Section {
            if !availableCalendars.isEmpty {
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(availableCalendars) { calendar in
                        HStack {
                            Circle()
                                .fill(calendar.color)
                                .frame(width: 12, height: 12)
                            Text(calendar.name)
                        }
                        .tag(calendar.id as String?)
                    }
                }
                .font(DesignTokens.Typography.body)
                .onChange(of: selectedCalendarID) { _, newValue in
                    if let calendarID = newValue,
                       let calendar = availableCalendars.first(where: { $0.id == calendarID }) {
                        calendarColor = calendar.color
                    }
                }
            }

            Toggle("All Day", isOn: $isAllDay)
                .font(DesignTokens.Typography.body)

            DatePicker(
                "Starts at",
                selection: $localStartDate,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .font(DesignTokens.Typography.body)

            DatePicker(
                "Ends at",
                selection: $localEndDate,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .font(DesignTokens.Typography.body)
        }

        Section {
            Picker("Repeats", selection: $localRepeatFrequency) {
                ForEach(repeatOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .font(DesignTokens.Typography.body)
        }

        Section {
            Picker("Alert", selection: $alertSelection) {
                ForEach(alertOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .font(DesignTokens.Typography.body)
        }
    }

    // MARK: - Task Sections

    @ViewBuilder
    private var taskSections: some View {
        Section {
            Toggle("Any Time", isOn: $localIsAnyTime)
                .font(DesignTokens.Typography.body)

            DatePicker(
                "Start Date",
                selection: $localStartDate,
                displayedComponents: localIsAnyTime ? [.date] : [.date, .hourAndMinute]
            )
            .font(DesignTokens.Typography.body)
        }

        Section {
            Picker("Alert", selection: $alertSelection) {
                ForEach(alertOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .font(DesignTokens.Typography.body)

            Picker("Repeat", selection: $localRepeatFrequency) {
                ForEach(repeatOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .font(DesignTokens.Typography.body)
        }

        Section {
            Button {
                showDurationPicker = true
            } label: {
                HStack {
                    Text("Duration")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Spacer()
                    Text(localDuration != nil ? formatDuration(localDuration!) : "None")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignTokens.Color.labelTertiary)
                }
            }
        }
    }

    // MARK: - Save

    private func saveChanges() {
        let calendar = Calendar.current

        if isEvent && isAllDay {
            startDate = calendar.startOfDay(for: localStartDate)
            endDate = calendar.startOfDay(for: localEndDate)
            duration = nil
            isAnyTime = true
        } else if localIsAnyTime && !isEvent {
            startDate = calendar.startOfDay(for: localStartDate)
            endDate = nil
            isAnyTime = true
        } else {
            startDate = localStartDate
            if isEvent {
                endDate = localEndDate
                duration = localEndDate.timeIntervalSince(localStartDate)
            }
            isAnyTime = false
        }

        // Duration for tasks
        if !isEvent {
            duration = localDuration
        }

        // Alert
        switch alertSelection {
        case "Day before":
            alertTime = localStartDate.addingTimeInterval(-24 * 3600)
        case "30 minutes before":
            alertTime = localStartDate.addingTimeInterval(-30 * 60)
        default:
            alertTime = nil
        }

        repeatFrequency = localRepeatFrequency == "None" ? nil : localRepeatFrequency

        // Update calendar color
        if let calendarID = selectedCalendarID,
           let cal = availableCalendars.first(where: { $0.id == calendarID }) {
            calendarColor = cal.color
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Duration Picker View

struct DurationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var duration: TimeInterval?

    @State private var selectedHours: Int
    @State private var selectedMinutes: Int

    let hours = Array(0...23)
    let minutes = Array(0...59).filter { $0 % 5 == 0 }

    init(duration: Binding<TimeInterval?>) {
        self._duration = duration
        if let currentDuration = duration.wrappedValue {
            let totalMinutes = Int(currentDuration / 60)
            _selectedHours = State(initialValue: totalMinutes / 60)
            _selectedMinutes = State(initialValue: totalMinutes % 60)
        } else {
            _selectedHours = State(initialValue: 0)
            _selectedMinutes = State(initialValue: 0)
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Spacer()

                    Picker("Hours", selection: $selectedHours) {
                        ForEach(hours, id: \.self) { hour in
                            Text("\(hour)").tag(hour)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)

                    Text("hours")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .padding(.horizontal, 8)

                    Picker("Minutes", selection: $selectedMinutes) {
                        ForEach(minutes, id: \.self) { minute in
                            Text(String(format: "%02d", minute)).tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)

                    Text("min")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .padding(.horizontal, 8)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        duration = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        let totalMinutes = selectedHours * 60 + selectedMinutes
                        duration = totalMinutes > 0 ? TimeInterval(totalMinutes * 60) : nil
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(280)])
    }
}
