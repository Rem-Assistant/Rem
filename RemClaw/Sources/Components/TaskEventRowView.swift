import SwiftUI
import SwiftData

// MARK: - Time Indicator Width

struct TimeIndicatorWidthCalculator {
    static let shared = TimeIndicatorWidthCalculator()
    let width: CGFloat

    private init() {
        // Fixed width matching the time indicator layout
        self.width = 64
    }
}

// MARK: - TaskEventRowView

public struct TaskEventRowView: View {
    @Bindable var task: TaskEvent
    var calendarColor: Color?
    var calendarName: String?
    var onSchedule: ((Date) -> Void)?
    var hideLeftIndicator: Bool
    var agendaDate: Date?

    @State private var showTimePicker = false
    @State private var pickerTime: Date = Date()

    /// All Lists in the local cache, used to resolve `task.listID` → List name
    /// for the row badge. Mirrors the `@Query` lookup pattern in `TasksByListView`.
    @Query(sort: [SortDescriptor(\TaskList.sortOrder), SortDescriptor(\TaskList.createdAt)])
    private var lists: [TaskList]

    /// The name of the List this task belongs to, if any. `nil` for events,
    /// unfiled tasks, or a dangling `listID` with no matching List.
    private var listName: String? {
        guard !task.isEvent, let listID = task.listID else { return nil }
        return lists.first(where: { $0.id == listID })?.name
    }

    public init(
        task: TaskEvent,
        calendarColor: Color? = nil,
        calendarName: String? = nil,
        onSchedule: ((Date) -> Void)? = nil,
        hideLeftIndicator: Bool = false,
        agendaDate: Date? = nil
    ) {
        self.task = task
        self.calendarColor = calendarColor
        self.calendarName = calendarName
        self.onSchedule = onSchedule
        self.hideLeftIndicator = hideLeftIndicator
        self.agendaDate = agendaDate
    }

    private var timeIndicatorWidth: CGFloat {
        TimeIndicatorWidthCalculator.shared.width
    }

    private func getCalendarColor() -> Color {
        calendarColor ?? DesignTokens.Color.labelSecondary
    }

    public var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if !hideLeftIndicator {
                leftIndicator
                    .frame(width: timeIndicatorWidth, alignment: .leading)
            }

            if task.isEvent {
                eventContent
            } else {
                taskContent
            }

            Spacer()
        }
        .padding(6)
        .sheet(isPresented: $showTimePicker) {
            timePickerSheet
        }
    }

    @ViewBuilder
    private var leftIndicator: some View {
        if let scheduledTime = task.startDate, !task.isAnyTime {
            if agendaDate != nil {
                Button {
                    pickerTime = scheduledTime
                    showTimePicker = true
                } label: {
                    timeDisplay(for: scheduledTime)
                }
                .buttonStyle(.plain)
            } else {
                timeDisplay(for: scheduledTime)
            }
        } else {
            Button {
                let baseDate = agendaDate ?? Date()
                let defaultTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: baseDate) ?? baseDate
                pickerTime = defaultTime
                inlineSelectedDate = baseDate
                showInlineDatePicker = false
                showTimePicker = true
            } label: {
                if agendaDate != nil {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func timeDisplay(for date: Date) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(formatHour(date))
                    .font(.title2)
                VStack(spacing: 0) {
                    Text(formatMinutes(date))
                    Text(formatAMPM(date))
                }
                .font(.caption)
            }
        }
    }

    @State private var showInlineDatePicker = false
    @State private var inlineSelectedDate: Date = Date()

    private var timePickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Date row — tappable to expand inline date picker
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showInlineDatePicker.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Date")
                                .font(.body)
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                            Spacer()
                            Text(formattedAgendaDate)
                                .font(.body)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                            Image(systemName: showInlineDatePicker ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(DesignTokens.Color.labelTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)

                    // Inline date picker
                    if showInlineDatePicker {
                        Divider()
                            .padding(.horizontal, 16)

                        DatePicker(
                            "Date",
                            selection: $inlineSelectedDate,
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                        .padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.top, showInlineDatePicker ? 0 : 4)

                    DatePicker(
                        "Time",
                        selection: $pickerTime,
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding(.vertical, 8)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pick a Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTimePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showTimePicker = false
                        let calendar = Calendar.current
                        let timeComponents = calendar.dateComponents([.hour, .minute], from: pickerTime)
                        let resolved = calendar.date(
                            bySettingHour: timeComponents.hour ?? 9,
                            minute: timeComponents.minute ?? 0,
                            second: 0,
                            of: inlineSelectedDate
                        ) ?? inlineSelectedDate
                        onSchedule?(resolved)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var formattedAgendaDate: String {
        let date = inlineSelectedDate
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        let datePart = formatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "Today, \(datePart)"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow, \(datePart)"
        } else {
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }

    @ViewBuilder
    private var taskContent: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if task.isEvent, let color = calendarColor {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(color)
                    .frame(width: 4, height: 34)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    // NOT dimmed: this is the control that changes the status, and a blocked or
                    // stale task must stay fully actionable — tapping it is what un-stales it.
                    TaskStatusIndicator(task: task)

                    Text(task.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .taskDeemphasized(task.isDeemphasized)
                }

                HStack(spacing: DesignTokens.Spacing.xs) {
                    // Blocked and/or stale (migration 116), at FULL opacity: on a dimmed row this
                    // is the only thing that says why. Both render when both are true.
                    TaskDeemphasisBadges(reasons: task.deemphasisReasons)

                    Group {
                        if let name = calendarName, let color = calendarColor {
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
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(DesignTokens.CornerRadius.xlarge)
                        }

                        if let listName {
                            ListBadgeView(name: listName)
                        }

                        if let formattedDuration = formatDurationPill() {
                            PillView(text: formattedDuration)
                        }

                        if isOverdue {
                            OverduePillView()
                        }
                    }
                    .taskDeemphasized(task.isDeemphasized)
                }
            }
        }
    }

    private var isOverdue: Bool {
        guard !task.isEvent else { return false }
        guard let taskDate = task.startDate else { return false }
        return taskDate < Calendar.current.startOfDay(for: Date()) && task.statusEnum != .completed
    }

    @ViewBuilder
    private var eventContent: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .fill(getCalendarColor())
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(task.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let name = calendarName, let color = calendarColor {
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
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(DesignTokens.CornerRadius.xlarge)
                    }

                    if let formattedDuration = formatDurationPill() {
                        PillView(text: formattedDuration)
                    }
                }
            }
        }
    }

    private func formatDurationPill() -> String? {
        guard let duration = task.formattedDuration else { return nil }
        if task.isAnyTime { return duration }
        if let endTime = task.endTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "\(duration) → \(formatter.string(from: endTime))"
        }
        return duration
    }

    private func formatHour(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%02d", displayHour)
    }

    private func formatMinutes(_ date: Date) -> String {
        let minutes = Calendar.current.component(.minute, from: date)
        return String(format: "%02d", minutes)
    }

    private func formatAMPM(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return hour < 12 ? "AM" : "PM"
    }
}

// MARK: - Pill Views

struct PillView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.caption1)
            .foregroundColor(DesignTokens.Color.labelPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}

/// Chip showing the List a task belongs to. Matches the calendar-category badge
/// style (same DesignTokens chip — background, padding, font) with a `list.bullet`
/// glyph standing in for the calendar's color dot.
struct ListBadgeView: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Text(name)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}

struct OverduePillView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var overduePillBackground: Color {
        switch colorScheme {
        case .light:
            Color(red: 1.0, green: 0.92, blue: 0.92)
        case .dark:
            Color(red: 0.35, green: 0.12, blue: 0.12)
        @unknown default:
            Color(uiColor: .secondarySystemBackground)
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
