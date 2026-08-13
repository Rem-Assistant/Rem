import SwiftUI

/// Cross-platform Agenda view showing tasks for a selected date.
/// Generic over `TaskStoreProviding` so it works with both iOS and Mac task stores.
struct SharedAgendaView<Store: TaskStoreProviding>: View {
    let store: Store
    var onCreateTask: (() -> Void)?
    /// Mac: row tap opens task/event detail in the parent `NavigationStack`.
    var onOpenTask: ((Store.TaskItem) -> Void)? = nil

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    private var tasksForDate: [Store.TaskItem] {
        store.tasks(for: selectedDate)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SharedDateNavigationHeader(
                selectedDate: $selectedDate,
                isToday: isToday,
                isLoading: store.isLoading,
                onCreateTask: onCreateTask,
                onRefresh: { Task { await store.refresh() } },
                showsAuxiliaryControls: false,
                showsTodayButton: false
            )
            #else
            SharedDateNavigationHeader(
                selectedDate: $selectedDate,
                isToday: isToday,
                isLoading: store.isLoading,
                onCreateTask: onCreateTask,
                onRefresh: { Task { await store.refresh() } }
            )
            #endif
            Divider()
            agendaContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .navigationTitle("Agenda")
        .toolbar {
            if !isToday {
                ToolbarItem(placement: .status) {
                    Button("Today") {
                        selectedDate = Calendar.current.startOfDay(for: Date())
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let onCreateTask {
                    Button { onCreateTask() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New task or event")
                }
            }
        }
        #endif
        .task { await store.refresh() }
    }

    // MARK: - Content

    @ViewBuilder
    private var agendaContent: some View {
        if store.isLoading && tasksForDate.isEmpty {
            loadingView
        } else if tasksForDate.isEmpty {
            emptyState
        } else {
            taskList
        }
    }

    private var taskList: some View {
        List {
            ForEach(tasksForDate, id: \.displayId) { task in
                SharedTaskRow(task: task)
                    #if os(macOS)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenTask?(task)
                    }
                    .contextMenu { taskContextMenu(for: task) }
                    #endif
                    #if os(iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await store.deleteTask(task) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if !task.isEvent {
                            Button {
                                Task { await store.completeTask(task) }
                            } label: {
                                Label("Complete", systemImage: "checkmark.circle")
                            }
                            .tint(.green)

                            Button {
                                Task { await store.snoozeTask(task) }
                            } label: {
                                Label("Snooze", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(.orange)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    #endif
            }
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        .listStyle(.plain)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func taskContextMenu(for task: Store.TaskItem) -> some View {
        if !task.isCompleted {
            Button {
                Task { await store.completeTask(task) }
            } label: {
                Label("Complete", systemImage: "checkmark.circle")
            }

            Button {
                Task { await store.snoozeTask(task) }
            } label: {
                Label("Snooze 15 min", systemImage: "clock.arrow.circlepath")
            }
        }

        Divider()

        Button(role: .destructive) {
            Task { await store.deleteTask(task) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    #endif

    // MARK: - Empty / Loading States

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            Spacer()
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No agenda yet")
                .font(.title2.bold())
            Text("Tasks and events scheduled for this day will appear here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading agenda...")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Agenda — Empty") {
    NavigationStack {
        SharedAgendaView(store: PreviewTaskStore(scenario: .empty))
    }
}

#Preview("Agenda — Scheduled") {
    NavigationStack {
        SharedAgendaView(store: PreviewTaskStore(scenario: .scheduled))
    }
}

#Preview("Agenda — Loading") {
    NavigationStack {
        SharedAgendaView(store: PreviewTaskStore(scenario: .loading))
    }
}
#endif

// MARK: - Shared Date Navigation Header

struct SharedDateNavigationHeader: View {
    @Binding var selectedDate: Date
    var isToday: Bool
    var isLoading: Bool
    var onCreateTask: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// When `false` (e.g. Mac toolbar holds + / refresh), only the date stepper is shown.
    var showsAuxiliaryControls: Bool = true
    /// When `false`, hide the inline “Today” control (e.g. Mac uses toolbar `.status` “Today”).
    var showsTodayButton: Bool = true

    var body: some View {
        HStack {
            Button(action: navigateToPreviousDay) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text(relativeDateLabel)
                    .font(.title2.bold())
                Text(dayFormatter.string(from: selectedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: navigateToNextDay) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)

            if showsTodayButton, !isToday {
                Button("Today") {
                    selectedDate = Calendar.current.startOfDay(for: Date())
                }
                #if os(macOS)
                .buttonStyle(.bordered)
                .controlSize(.small)
                #else
                .font(.callout.bold())
                #endif
                .padding(.leading, 8)
            }

            if showsAuxiliaryControls, let onCreateTask {
                Button { onCreateTask() } label: {
                    Image(systemName: "plus")
                }
                #if os(macOS)
                .buttonStyle(.bordered)
                .controlSize(.small)
                #else
                .font(.title3)
                #endif
            }

            if showsAuxiliaryControls, let onRefresh {
                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                #if os(macOS)
                .buttonStyle(.bordered)
                .controlSize(.small)
                #else
                .font(.title3)
                #endif
                .disabled(isLoading)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg + 4)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Navigation

    private func navigateToPreviousDay() {
        if let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) {
            selectedDate = Calendar.current.startOfDay(for: prev)
        }
    }

    private func navigateToNextDay() {
        if let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) {
            selectedDate = Calendar.current.startOfDay(for: next)
        }
    }

    private var relativeDateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return "Today" }
        if calendar.isDateInTomorrow(selectedDate) { return "Tomorrow" }
        if calendar.isDateInYesterday(selectedDate) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: selectedDate)
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }
}
