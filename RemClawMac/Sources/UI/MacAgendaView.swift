import SwiftUI

/// macOS Agenda view — shows tasks and events for the selected date.
/// Mirrors the iOS AgendaView with native macOS styling.
struct MacAgendaView: View {
    @Environment(MacGatewaySessionManager.self) private var session
    let taskStore: MacTaskStore

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showCreateTask = false

    private var tasksForDate: [MacTask] {
        taskStore.tasks(for: selectedDate)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            dateNavigationHeader
            Divider()
            agendaContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshTasks()
        }
        .accessibilityIdentifier("MacAgendaView")
        .sheet(isPresented: $showCreateTask) {
            MacTaskCreateSheet(taskStore: taskStore) {
                showCreateTask = false
            }
            .environment(session)
        }
    }

    // MARK: - Date Navigation

    private var dateNavigationHeader: some View {
        HStack {
            Button(action: navigateToPreviousDay) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("AgendaPreviousDay")

            Spacer()

            VStack(spacing: 2) {
                Text(relativeDateLabel)
                    .font(.title2.bold())
                Text(dayFormatter.string(from: selectedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("AgendaDateLabel")

            Spacer()

            Button(action: navigateToNextDay) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("AgendaNextDay")

            if !isToday {
                Button("Today") {
                    selectedDate = Calendar.current.startOfDay(for: Date())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 8)
            }

            Button {
                showCreateTask = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("AgendaNewTaskButton")

            Button {
                Task { await refreshTasks() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(taskStore.isLoading)
            .accessibilityIdentifier("AgendaRefreshButton")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var agendaContent: some View {
        if taskStore.isLoading && tasksForDate.isEmpty {
            loadingView
        } else if tasksForDate.isEmpty {
            emptyState
        } else {
            taskList
        }
    }

    private var taskList: some View {
        List {
            ForEach(tasksForDate) { task in
                MacTaskRow(task: task)
                    .contextMenu {
                        taskContextMenu(for: task)
                    }
                    .accessibilityIdentifier("AgendaTaskRow_\(task.id)")
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private func taskContextMenu(for task: MacTask) -> some View {
        if !task.isCompleted {
            Button {
                Task {
                    await taskStore.completeTask(task)
                }
            } label: {
                Label("Complete", systemImage: "checkmark.circle")
            }

            Button {
                Task {
                    await taskStore.snoozeTask(task)
                }
            } label: {
                Label("Snooze 15 min", systemImage: "clock.arrow.circlepath")
            }
        }

        Divider()

        Button(role: .destructive) {
            Task {
                await taskStore.deleteTask(task)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
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
        .accessibilityIdentifier("AgendaEmptyState")
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

    // MARK: - Data

    private func refreshTasks() async {
        guard session.isAuthenticated else { return }
        await taskStore.fetchTasks()
    }
}

// MARK: - Task Row

struct MacTaskRow: View {
    let task: MacTask

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Time indicator
            if let startDate = task.startDate {
                Text(Self.timeFormatter.string(from: startDate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text("Anytime")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(task.isEvent ? Color.blue : Color.orange)
                .frame(width: 3, height: 32)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let category = task.category {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if task.isEvent {
                        Label("Event", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let priority = task.priority, priority != "medium" {
                        Text(priority.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(priorityColor(priority).opacity(0.15))
                            .foregroundStyle(priorityColor(priority))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Status indicator
            if task.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "high", "urgent": .red
        case "low": .gray
        default: .blue
        }
    }
}
