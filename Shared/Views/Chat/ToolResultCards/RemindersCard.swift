import SwiftUI

/// Displays a list of reminders as a rich card.
/// When `expanded` is provided, the card starts collapsed (header only) and expands on tap.
struct RemindersCard: View {
    let reminders: [ReminderPayload]
    var expanded: Binding<Bool>? = nil

    private let maxVisible = 8

    private var isCollapsible: Bool { expanded != nil }
    private var isExpanded: Bool { expanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? DesignTokens.Spacing.sm : 0) {
            // Header (tappable when collapsible)
            headerView

            // Reminder rows (only when expanded)
            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(Array(reminders.prefix(maxVisible).enumerated()), id: \.element.identifier) { _, reminder in
                        reminderRow(reminder)
                    }

                    if reminders.count > maxVisible {
                        Text("+\(reminders.count - maxVisible) more")
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .padding(isExpanded ? DesignTokens.Spacing.md : DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.fillTertiary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    @ViewBuilder
    private var headerView: some View {
        let header = HStack(spacing: 6) {
            Image("AppleRemindersLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text("\(reminders.count) reminder\(reminders.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            if isCollapsible {
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
        }

        if let expanded {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.wrappedValue.toggle()
                }
            } label: { header }
            .buttonStyle(.plain)
        } else {
            header
        }
    }

    @ViewBuilder
    private func reminderRow(_ reminder: ReminderPayload) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.callout)
                .foregroundStyle(reminder.isCompleted ? DesignTokens.Color.systemGreen : DesignTokens.Color.labelTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .strikethrough(reminder.isCompleted, color: DesignTokens.Color.labelTertiary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let dueDate = reminder.dueDate, let formatted = formatDueDate(dueDate) {
                        Text(formatted)
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                    if let listName = reminder.listName {
                        Text(listName)
                            .font(.footnote)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            if reminder.priority > 0 {
                priorityIndicator(reminder.priority)
            }
        }
    }

    @ViewBuilder
    private func priorityIndicator(_ priority: Int) -> some View {
        let count = min(priority, 3)
        Text(String(repeating: "!", count: count))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(priority >= 3 ? DesignTokens.Color.systemRed : DesignTokens.Color.systemOrange)
    }

    // MARK: - Date Formatting

    private func formatDueDate(_ isoString: String) -> String? {
        guard let date = parseISO8601(isoString) else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.doesRelativeDateFormatting = true
        return fmt.string(from: date)
    }

    private func parseISO8601(_ string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) { return date }

        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        return withoutFrac.date(from: string)
    }
}
