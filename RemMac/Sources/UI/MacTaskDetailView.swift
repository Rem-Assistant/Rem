import SwiftUI

/// Mac task/event detail, aligned with iOS `TaskEventView` + `EditTaskDestination` (read surface + actions).
/// Editing uses HTTP-backed `MacTaskStore` only; there is no SwiftData / calendar inspector on Mac.
struct MacTaskDetailView: View {
    let task: MacTask
    let taskStore: MacTaskStore

    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var showDeleteConfirmation = false
    @State private var isEditingSchedule = false
    @State private var selectedScheduleDate = Date()
    @State private var isScheduleAnyTime = false
    @State private var actionError: String?

    private var navTitle: String {
        task.isEvent ? "Event Details" : "Task Details"
    }

    var body: some View {
        Form {
            titleStatusSection
            whenSection
            descriptionSection
            notesSection
            collaborationSection
            if canSnooze {
                quickSnoozeSection
            }
        }
        .formStyle(.grouped)
        .disabled(isProcessing)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle(navTitle)
        .toolbar {
            if !task.isEvent, !task.isCompleted {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        markComplete()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Mark Complete")
                    .accessibilityLabel("Mark Complete")
                    .disabled(isProcessing)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !task.isEvent, !task.isCompleted {
                        Button {
                            beginScheduleEditing()
                        } label: {
                            Label(rescheduleLabel, systemImage: "calendar.badge.clock")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(
                            task.isEvent ? "Remove" : "Delete",
                            systemImage: task.isEvent ? "calendar.badge.minus" : "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(task.isEvent ? "Event Actions" : "Task Actions")
                .disabled(isProcessing)
            }
        }
        .confirmationDialog(
            task.isEvent ? "Remove" : "Delete Task",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(task.isEvent ? "Remove" : "Delete", role: .destructive) {
                performDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                task.isEvent
                    ? "Are you sure you want to remove this event? This can’t be undone."
                    : "Are you sure you want to delete this task? This action cannot be undone."
            )
        }
        .alert("Unable to Complete Action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Title & status (cf. iOS `titleRow` + status)

    @ViewBuilder
    private var titleStatusSection: some View {
        Section {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: statusIconName)
                    .font(DesignTokens.Typography.title1)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(DesignTokens.Typography.title1Bold)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusLabel)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(DesignTokens.Color.backgroundPrimary)

            if hasMetadata {
                if let p = task.priority, !p.isEmpty {
                    LabeledContent("Priority", value: p)
                }
                if let c = task.category, !c.isEmpty {
                    LabeledContent("Category", value: c)
                }
            }
        } header: {
            Text(task.isEvent ? "Event" : "Task")
        }
    }

    // MARK: - When (cf. iOS `EditableTaskDetailsSection` + `DateInfoSection`)

    @ViewBuilder
    private var whenSection: some View {
        let lines = whenLines
        Section {
            if isEditingSchedule {
                Toggle("Any Time", isOn: $isScheduleAnyTime)
                DatePicker(
                    "Start Date",
                    selection: $selectedScheduleDate,
                    displayedComponents: isScheduleAnyTime ? [.date] : [.date, .hourAndMinute]
                )

                HStack {
                    Button("Cancel") {
                        cancelScheduleEditing()
                    }
                    .disabled(isProcessing)

                    Spacer()

                    Button("Save") {
                        saveSchedule()
                    }
                    .fontWeight(.semibold)
                    .disabled(isProcessing)
                }

                if task.startDate != nil {
                    Button(role: .destructive) {
                        clearSchedule()
                    } label: {
                        Label("Move to Inbox", systemImage: "tray")
                    }
                    .disabled(isProcessing)
                }
            } else {
                if lines.isEmpty {
                    Text(task.isEvent ? "No start time" : "Not scheduled")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: line.icon)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                            Text(line.text)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if canReschedule {
                    Button {
                        beginScheduleEditing()
                    } label: {
                        Label(rescheduleLabel, systemImage: "calendar.badge.clock")
                    }
                }
            }
        } header: {
            Text("When")
        }
    }

    private var whenLines: [WhenLine] {
        var result: [WhenLine] = []
        if let s = task.startDate {
            if task.isEvent, let e = task.endDate {
                result.append(WhenLine(icon: "clock", text: eventRangeString(start: s, end: e)))
            } else {
                result.append(WhenLine(icon: "clock", text: "Starts \(dateTimeString(s))"))
            }
        } else if task.isEvent {
            return []
        }
        if let d = task.dueDate, !task.isEvent {
            result.append(WhenLine(icon: "flag", text: "Due \(dateTimeString(d))"))
        }
        return result
    }

    private struct WhenLine {
        let icon: String
        let text: String
    }

    // MARK: - Description (co-authored with Rem — backend migration 120)

    /// "What I know now": the user's own context plus the current state Rem's last run
    /// recorded. Read-only here, mirroring the rest of this screen — iOS owns the editor,
    /// and the Mac shows the same facts rather than a second writer for the same column.
    @ViewBuilder
    private var descriptionSection: some View {
        if task.taskDescription?.isEmpty == false || task.agentContext?.isEmpty == false {
            Section {
                if let description = task.taskDescription, !description.isEmpty {
                    Text(description)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let context = task.agentContext, !context.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("What Rem knows")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                        Text(context)
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Color.labelPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Description")
            }
        }
    }

    // MARK: - Notes (cf. iOS `notesSection`)

    @ViewBuilder
    private var notesSection: some View {
        Section {
            if let notes = task.notes, !notes.isEmpty {
                Text(notes)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Add your notes here")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Notes")
        }
    }

    // MARK: - Comments (cf. iOS `TaskCommentsSection` host in TaskEventView)

    /// Inline task comments — attributed notes from the human, Rem Cloud (GMI
    /// AgentBox), and the local device. Hosts the cross-platform
    /// `TaskCommentsSection` (Shared/Views/Tasks) and wires its `commitStatus`
    /// closure to the Mac task store's `PATCH /tasks/:id`, mirroring the iOS host.
    @ViewBuilder
    private var collaborationSection: some View {
        Section {
            TaskCommentsSection(
                taskId: task.id,
                commitStatus: { status in
                    await taskStore.commitCollaborationStatus(status, for: task)
                }
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Comments")
        }
    }

    // MARK: - Snooze (list/mac quick actions, complements iOS swipe)

    private var canSnooze: Bool {
        !task.isEvent && !task.isCompleted
    }

    private var canReschedule: Bool {
        !task.isEvent && !task.isCompleted
    }

    private var rescheduleLabel: String {
        task.startDate == nil ? "Schedule" : "Reschedule"
    }

    private var normalizedScheduleDate: Date {
        isScheduleAnyTime ? Calendar.current.startOfDay(for: selectedScheduleDate) : selectedScheduleDate
    }

    @ViewBuilder
    private var quickSnoozeSection: some View {
        Section {
            Button {
                snooze(minutes: 15)
            } label: {
                snoozeButtonLabel("In 15 minutes", "clock.arrow.circlepath")
            }
            Button {
                snooze(minutes: 60)
            } label: {
                snoozeButtonLabel("In 1 hour", "clock.arrow.circlepath")
            }
            Button {
                snoozeTomorrowMorning()
            } label: {
                snoozeButtonLabel("Tomorrow morning", "sun.horizon")
            }
        } header: {
            Text("Snooze")
        } footer: {
            Text("Updates the task start time, like quick snooze on iOS.")
                .font(.caption)
        }
    }

    private func snoozeButtonLabel(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }

    // MARK: - Helpers

    private var hasMetadata: Bool {
        (task.priority != nil && !(task.priority?.isEmpty ?? true))
        || (task.category != nil && !(task.category?.isEmpty ?? true))
    }

    private var statusLabel: String {
        if task.isCompleted { return "Completed" }
        if task.isEvent { return "Scheduled" }
        switch task.status.lowercased() {
        case "in_progress", "in progress": return "In progress"
        case "blocked": return "Blocked"
        case "rescheduled": return "Rescheduled"
        default: return "To do"
        }
    }

    private var statusIconName: String {
        if task.isCompleted || task.isEvent && (task.status).lowercased() == "completed" {
            return "checkmark.circle.fill"
        }
        if !task.isEvent {
            switch task.status.lowercased() {
            case "in_progress", "in progress": return "circle.lefthalf.filled"
            case "blocked": return "exclamationmark.octagon"
            case "rescheduled": return "clock.arrow.circlepath"
            default: return "circle.dashed"
            }
        }
        return "circle"
    }

    private let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func dateTimeString(_ date: Date) -> String {
        let cal = Calendar.current
        let usesTime = cal.component(.hour, from: date) != 0
            || cal.component(.minute, from: date) != 0
        return usesTime ? mediumDateTime.string(from: date) : mediumDate.string(from: date)
    }

    private func eventRangeString(start: Date, end: Date) -> String {
        let cal = Calendar.current
        let sameDay = cal.isDate(start, inSameDayAs: end)
        if sameDay {
            return "\(mediumDate.string(from: start)) · \(timeOnly.string(from: start)) – \(timeOnly.string(from: end))"
        }
        return "\(mediumDateTime.string(from: start)) – \(mediumDateTime.string(from: end))"
    }

    private let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // MARK: - Actions

    private func snooze(minutes: Int) {
        Task {
            isProcessing = true
            await taskStore.snoozeTask(task, minutes: minutes)
            isProcessing = false
            if taskStore.lastError != nil { actionError = taskStore.lastError; return }
            dismiss()
        }
    }

    private func snoozeTomorrowMorning() {
        Task {
            isProcessing = true
            let tomorrowNine = Calendar.current.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            ) ?? Date().addingTimeInterval(24 * 3600)
            let minutes = max(1, Int(tomorrowNine.timeIntervalSince(Date()) / 60))
            await taskStore.snoozeTask(task, minutes: minutes)
            isProcessing = false
            if taskStore.lastError != nil { actionError = taskStore.lastError; return }
            dismiss()
        }
    }

    private func markComplete() {
        Task {
            isProcessing = true
            await taskStore.completeTask(task)
            isProcessing = false
            if taskStore.lastError != nil { actionError = taskStore.lastError; return }
            dismiss()
        }
    }

    private func performDelete() {
        Task {
            isProcessing = true
            await taskStore.deleteTask(task)
            isProcessing = false
            if taskStore.lastError != nil { actionError = taskStore.lastError; return }
            dismiss()
        }
    }

    private func saveSchedule() {
        Task {
            isProcessing = true
            await taskStore.scheduleTask(task, startDate: normalizedScheduleDate)
            isProcessing = false
            if let lastError = taskStore.lastError {
                actionError = lastError
                return
            }
            isEditingSchedule = false
            dismiss()
        }
    }

    private func clearSchedule() {
        Task {
            isProcessing = true
            await taskStore.clearSchedule(for: task)
            isProcessing = false
            if let lastError = taskStore.lastError {
                actionError = lastError
                return
            }
            isEditingSchedule = false
            dismiss()
        }
    }

    private func beginScheduleEditing() {
        selectedScheduleDate = task.startDate ?? Calendar.current.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: Date()
        ) ?? Date()
        isScheduleAnyTime = task.startDate.map(macTaskRescheduleIsStartOfDay) ?? false
        isEditingSchedule = true
    }

    private func cancelScheduleEditing() {
        isEditingSchedule = false
    }
}

private func macTaskRescheduleIsStartOfDay(_ date: Date) -> Bool {
    Calendar.current.startOfDay(for: date) == date
}

#if DEBUG
struct MacTaskDetailChromeFixtureView: View {
    @State private var taskStore = MacTaskStore()

    var body: some View {
        NavigationStack {
            MacTaskDetailView(task: .fixtureOpenTask, taskStore: taskStore)
        }
        .frame(width: 360, height: 560)
    }
}

private extension MacTask {
    static let fixtureOpenTask = MacTask(
        id: "fixture-task-detail",
        title: "Review connector authorization copy",
        status: "pending",
        category: "Product",
        startDate: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()),
        endDate: nil,
        dueDate: nil,
        notes: "Make sure the Mac detail toolbar remains legible at narrow widths.",
        taskDescription: "Copy lives in ConnectorAuthorizationSheet. Legal signed off on the wording.",
        agentContext: "Read the current copy and drafted two alternatives; waiting on which tone you prefer.",
        isEvent: false,
        priority: "High",
        createdAt: nil,
        updatedAt: nil
    )
}
#endif
