import SwiftUI

/// Cross-platform task row used in both Agenda and Inbox views.
/// Renders time indicator, color bar, title, and metadata pills.
struct SharedTaskRow<T: TaskDisplayable>: View {
    let task: T
    var calendarColor: Color?
    var calendarName: String?
    var showTimeIndicator: Bool = true

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if showTimeIndicator {
                timeIndicator
                    .frame(width: 64, alignment: .leading)
            }

            if task.isEvent {
                eventColorBar
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                titleRow
                metadataPills
            }

            Spacer()

            if task.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    // MARK: - Time Indicator

    @ViewBuilder
    private var timeIndicator: some View {
        if let startDate = task.startDate {
            Text(Self.timeFormatter.string(from: startDate))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Anytime")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Color Bar

    private var eventColorBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(calendarColor ?? DesignTokens.Color.systemBlue)
            .frame(width: 4, height: 34)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if !task.isEvent && !task.isCompleted {
                Image(systemName: "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            } else if !task.isEvent && task.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            }

            Text(task.title)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)
                .strikethrough(task.isCompleted, color: .secondary)
        }
        .taskDeemphasized(task.isDeemphasized)
    }

    // MARK: - Metadata Pills

    @ViewBuilder
    private var metadataPills: some View {
        // A live/attention-needing run is worth showing even on an otherwise bare row —
        // it's the P1 "this task is being worked / needs attention" surface.
        let runStatus = task.resolvedRunStatus
        let showsRun = runStatus != nil && runStatus != .idle
        // Blocked and/or stale (migration 116). Read from `status` AND `stale_at` together, so a
        // task that is both shows both.
        let deemphasisReasons = task.deemphasisReasons
        let hasPills = showsRun || !deemphasisReasons.isEmpty || calendarName != nil
            || task.formattedDuration != nil || task.displayPriority != nil || isOverdue
        if hasPills {
            HStack(spacing: DesignTokens.Spacing.xs) {
                // First, and at FULL opacity: on a dimmed row this is the only thing saying why.
                TaskDeemphasisBadges(reasons: deemphasisReasons)

                Group {
                    if let runStatus, runStatus != .idle {
                        TaskRunStatusBadge(runStatus: runStatus, compact: true)
                    }

                    if let name = calendarName, let color = calendarColor {
                        calendarPill(name: name, color: color)
                    }

                    if let duration = task.formattedDuration {
                        SharedPillView(text: duration)
                    }

                    if let priority = task.displayPriority, priority != "medium" {
                        priorityPill(priority)
                    }

                    if isOverdue {
                        SharedOverduePillView()
                    }
                }
                // One application for the whole group: stacking `.taskDeemphasized` per pill would
                // be identical here, but grouping keeps the "apply once" rule visible.
                .taskDeemphasized(task.isDeemphasized)
            }
        }
    }

    private var isOverdue: Bool {
        guard !task.isEvent, !task.isCompleted else { return false }
        guard let taskDate = task.startDate else { return false }
        return taskDate < Calendar.current.startOfDay(for: Date())
    }

    // MARK: - Pill Components

    private func calendarPill(name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(DesignTokens.Color.pillBackground)
        .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }

    private func priorityPill(_ priority: String) -> some View {
        Text(priority.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor(priority).opacity(0.15))
            .foregroundStyle(priorityColor(priority))
            .clipShape(Capsule())
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "high", "urgent": .red
        case "low": .gray
        default: .blue
        }
    }
}

// MARK: - Shared Pill Views

struct SharedPillView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.caption1)
            .foregroundColor(DesignTokens.Color.labelPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            .background(DesignTokens.Color.pillBackground)
            .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}

struct SharedOverduePillView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var overduePillBackground: Color {
        switch colorScheme {
        case .light:
            Color(red: 1.0, green: 0.92, blue: 0.92)
        case .dark:
            Color(red: 0.35, green: 0.12, blue: 0.12)
        @unknown default:
            DesignTokens.Color.pillBackground
        }
    }

    var body: some View {
        Text("Overdue")
            .font(DesignTokens.Typography.caption1)
            .foregroundColor(.red)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            .background(overduePillBackground)
            .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}

#if DEBUG
#Preview("Task Row — Variants") {
    List {
        SharedTaskRow(task: PreviewTaskStore.Task(
            displayId: "preview-task",
            title: "Prepare launch recovery screenshots",
            status: "pending",
            displayCategory: "task",
            startDate: Date().addingTimeInterval(60 * 60),
            endDate: Date().addingTimeInterval(90 * 60),
            isEvent: false,
            isCompleted: false,
            displayPriority: "high",
            notes: nil
        ))

        SharedTaskRow(task: PreviewTaskStore.Task(
            displayId: "preview-event",
            title: "Portfolio review",
            status: "confirmed",
            displayCategory: "event",
            startDate: Date().addingTimeInterval(3 * 60 * 60),
            endDate: Date().addingTimeInterval(4 * 60 * 60),
            isEvent: true,
            isCompleted: false,
            displayPriority: nil,
            notes: nil
        ), calendarColor: .blue, calendarName: "Work")

        SharedTaskRow(task: PreviewTaskStore.Task(
            displayId: "preview-completed",
            title: "Archive old agent worktrees",
            status: "completed",
            displayCategory: "task",
            startDate: nil,
            endDate: nil,
            isEvent: false,
            isCompleted: true,
            displayPriority: "low",
            notes: nil
        ), showTimeIndicator: false)

        // Stale only: real status still `pending`, the row recedes, the badge says why.
        SharedTaskRow(task: PreviewTaskStore.Task(
            displayId: "preview-stale",
            title: "Renew the domain",
            status: "pending",
            displayCategory: "task",
            startDate: nil,
            endDate: nil,
            isEvent: false,
            isCompleted: false,
            displayPriority: nil,
            notes: nil,
            staleAt: Date()
        ), showTimeIndicator: false)

        // Blocked AND stale: two independent facts, two badges, ONE dimming.
        SharedTaskRow(task: PreviewTaskStore.Task(
            displayId: "preview-blocked-stale",
            title: "Send the signed contract back",
            status: "blocked",
            displayCategory: "task",
            startDate: nil,
            endDate: nil,
            isEvent: false,
            isCompleted: false,
            displayPriority: "high",
            notes: nil,
            staleAt: Date()
        ), showTimeIndicator: false)
    }
}
#endif
