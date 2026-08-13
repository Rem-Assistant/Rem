import SwiftUI

/// Displays a list of calendar events as a rich card.
/// When `expanded` is provided, the card starts collapsed (header only) and expands on tap.
struct CalendarEventsCard: View {
    let events: [CalendarEventPayload]
    var expanded: Binding<Bool>? = nil

    private let maxVisible = 5

    private var isCollapsible: Bool { expanded != nil }
    private var isExpanded: Bool { expanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? DesignTokens.Spacing.sm : 0) {
            // Header (tappable when collapsible)
            headerView

            // Event rows (only when expanded)
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(Array(events.prefix(maxVisible).enumerated()), id: \.element.eventId) { _, event in
                        eventRow(event)
                    }

                    if events.count > maxVisible {
                        Text("+\(events.count - maxVisible) more")
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
            Image(systemName: "calendar")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.Color.systemRed)
            Text(headerText)
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

    private var headerText: String {
        let count = "\(events.count) event\(events.count == 1 ? "" : "s")"
        if let name = events.first?.calendarName {
            return "\(count) \u{2022} \(name)"
        }
        return count
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEventPayload) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("All day")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                } else {
                    Text(formatTime(event.startDate))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                    Text(formatTime(event.endDate))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
            }
            .frame(width: 56, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(DesignTokens.Color.systemRed)
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .lineLimit(1)
                if let cal = event.calendarName {
                    Text(cal)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Date Formatting

    private func formatTime(_ isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return isoString }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
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
