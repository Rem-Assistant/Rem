import SwiftUI
import SwiftData

public struct TaskStatusIndicator: View {
    @Bindable var task: TaskEvent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.taskSyncService) private var taskSyncService

    @State private var statusUpdateDebouncer = StatusUpdateDebouncer()

    public var body: some View {
        Menu {
            if task.isEvent {
                // Events have no "in progress" phase, but they CAN be blocked (waiting
                // on info) or completed — so Blocked is offered, In Progress is not.
                statusButton(for: .scheduled, label: "Scheduled", icon: "circle")
                statusButton(for: .completed, label: "Completed", icon: "checkmark.circle.fill")
                statusButton(for: .blocked, label: "Blocked", icon: "exclamationmark.octagon")
                statusButton(for: .rescheduled, label: "Rescheduled", icon: "clock.arrow.circlepath")
            } else {
                statusButton(for: .todo, label: "To Do", icon: "circle.dashed")
                statusButton(for: .inProgress, label: "In Progress", icon: "circle.lefthalf.filled")
                statusButton(for: .blocked, label: "Blocked", icon: "exclamationmark.octagon")
                statusButton(for: .completed, label: "Completed", icon: "checkmark.circle.fill")
            }
        } label: {
            statusIcon
                .font(DesignTokens.Typography.title1)
                .foregroundColor(statusColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func statusButton(for status: TaskStatus, label: String, icon: String) -> some View {
        Button {
            Task { @MainActor in
                if let taskSyncService {
                    await statusUpdateDebouncer.debounce(delay: 0.3) { @MainActor in
                        try await taskSyncService.updateTaskStatus(task, to: status, modelContext: modelContext)
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: icon)
                Text(label)
                if task.statusEnum == status {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.statusEnum {
        case .todo, .unscheduled, .scheduled:
            Image(systemName: "circle.dashed")
        case .inProgress:
            Image(systemName: "circle.lefthalf.filled")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
        case .blocked:
            Image(systemName: "exclamationmark.octagon")
        case .rescheduled:
            Image(systemName: "clock.arrow.circlepath")
        }
    }

    private var statusColor: Color {
        DesignTokens.Color.labelPrimary
    }
}

// MARK: - Status Update Debouncer

actor StatusUpdateDebouncer {
    private var task: Task<Void, Never>?

    func debounce(delay: TimeInterval, action: @escaping @MainActor () async throws -> Void) async {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled {
                try? await action()
            }
        }
    }
}
