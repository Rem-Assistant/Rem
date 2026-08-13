import SwiftUI
import SwiftData

enum AgendaTodayJumpPresentation {
    static func shouldShow(
        selectedDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        !calendar.isDate(selectedDate, inSameDayAs: now)
    }
}

public struct AgendaView: View {
    @ObservedObject var viewModel: AgendaViewModel
    var isHydrating: Bool = false
    var onCreateTask: (() -> Void)?
    var onOpenCalendarSettings: (() -> Void)?
    /// Daily Brief: open the AI-authored brief *chat* (the conversational landing) by
    /// its stable conversation key. The authored summary is content inside that ongoing
    /// conversation; it is not a separate detail surface.
    var onOpenBriefChat: ((String) -> Void)?
    /// Explicit playback keeps opening the orchestrator chat silent by default.
    var isReadingBrief: Bool = false
    var hasCompletedBriefPlayback: Bool = false
    var onReadBrief: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    /// Owned by the screen, not by `SharedSuggestionSection`. Accepting a dated suggestion appends
    /// to the task store synchronously, which flips `hasItemsForSelectedDate` and swaps the null
    /// state for the populated `List` — taking the section with it. The presenter has to outlive
    /// that swap or the sheet closes on the first accept.
    @State private var isShowingAllSuggestions = false

    public init(
        viewModel: AgendaViewModel,
        isHydrating: Bool = false,
        onCreateTask: (() -> Void)? = nil,
        onOpenCalendarSettings: (() -> Void)? = nil,
        onOpenBriefChat: ((String) -> Void)? = nil,
        isReadingBrief: Bool = false,
        hasCompletedBriefPlayback: Bool = false,
        onReadBrief: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.isHydrating = isHydrating
        self.onCreateTask = onCreateTask
        self.onOpenCalendarSettings = onOpenCalendarSettings
        self.onOpenBriefChat = onOpenBriefChat
        self.isReadingBrief = isReadingBrief
        self.hasCompletedBriefPlayback = hasCompletedBriefPlayback
        self.onReadBrief = onReadBrief
    }

    /// What tapping the Daily Brief summary should do. When the backend AI-authored the
    /// brief into a chat, it sends a `brief_session_key`; tapping opens *that chat*.
    /// Older backends can omit the key, so use the durable Today conversation instead of
    /// reviving the retired Daily Brief detail sheet.
    private func handleBriefTap() {
        guard let onOpenBriefChat else { return }
        onOpenBriefChat(viewModel.brief?.briefSessionKey ?? "rem-orchestrator")
    }

    private func handleReadBrief() {
        onReadBrief?()
    }

    private var readBriefAction: (() -> Void)? {
        guard onReadBrief != nil else { return nil }
        return { handleReadBrief() }
    }

    private var isToday: Bool {
        !AgendaTodayJumpPresentation.shouldShow(selectedDate: viewModel.selectedDate)
    }

    public var body: some View {
        agendaContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isToday {
                    jumpToTodayButton
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isToday)
            .task {
                await viewModel.refreshCalendarEvents()
            }
            .task(id: viewModel.selectedDate) {
                await viewModel.refreshCalendarEvents()
                // The Daily Brief is a "today" surface — only load it for today.
                if isToday {
                    await viewModel.refreshBriefAndSuggestions()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remCalendarStoreChanged)) { _ in
                Task { await viewModel.refreshCalendarEvents() }
            }
    }

    private var jumpToTodayButton: some View {
        Button {
            viewModel.navigateToToday()
        } label: {
            Label("Jump to Today", systemImage: "arrow.uturn.backward")
                .font(DesignTokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .frame(minHeight: 44)
                .contentShape(Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agenda-jump-to-today")
        .accessibilityHint("Returns the agenda to today's date")
    }

    /// Daily Brief card — only on today, only when there's something to surface.
    @ViewBuilder
    private var dailyBriefCard: some View {
        if isToday, let brief = viewModel.brief, brief.hasAgendaSurface {
            DailyBriefCard(
                brief: brief,
                onTap: handleBriefTap,
                isReading: isReadingBrief,
                hasCompletedPlayback: hasCompletedBriefPlayback,
                onRead: readBriefAction
            )
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)
            .transition(.opacity)
        }
    }

    /// The Daily Brief summary as a scrollable List row. Lives inside the List so
    /// it scrolls away with the agenda instead of staying pinned above it (founder
    /// feedback). The horizontal separator below it is a *separate* row
    /// (`dailyBriefDividerRow`) so SwiftUI renders the `Divider()` as its own
    /// full-width row rather than merging it into this row's tuple (which mis-orients
    /// it to a vertical rule).
    @ViewBuilder
    private var dailyBriefSummaryRow: some View {
        if isToday, let brief = viewModel.brief, brief.hasAgendaSurface {
            DailyBriefCard(
                brief: brief,
                onTap: handleBriefTap,
                isReading: isReadingBrief,
                hasCompletedPlayback: hasCompletedBriefPlayback,
                onRead: readBriefAction
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: DesignTokens.Spacing.xs,
                leading: DesignTokens.Spacing.lg,
                bottom: 0,
                trailing: DesignTokens.Spacing.lg
            ))
        }
    }

    /// Horizontal, full-width rule separating the brief summary from the agenda
    /// items below it. Wrapping the `Divider()` in a full-width `VStack` forces a
    /// *horizontal* orientation: a bare `Divider()` dropped into a List row can
    /// collapse to a short, vertical-looking stub on the leading edge (it inherits
    /// the row's intrinsic layout axis). `VStack(spacing: 0)` gives it an explicit
    /// vertical layout context, and `frame(maxWidth: .infinity)` makes it span the
    /// full content width.
    @ViewBuilder
    private var dailyBriefDividerRow: some View {
        if isToday, let brief = viewModel.brief, brief.hasAgendaSurface {
            // A plain Rectangle (not Divider) guarantees a horizontal, full-width 1pt
            // rule; `sm` top/bottom insets give it breathing room between the summary
            // above and the sort control below.
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: DesignTokens.Spacing.sm,
                    leading: DesignTokens.Spacing.lg,
                    bottom: DesignTokens.Spacing.sm,
                    trailing: DesignTokens.Spacing.lg
                ))
        }
    }

    /// A single agenda task/event row. Extracted so both the flat ("Time") and the
    /// grouped ("By List") renderings share identical row chrome and swipe actions.
    @ViewBuilder
    private func agendaTaskRow(_ task: TaskEvent) -> some View {
        NavigationLink(value: task.id) {
            TaskEventRowView(
                task: task,
                calendarColor: viewModel.getCalendarInfo(for: task)?.color,
                calendarName: viewModel.getCalendarInfo(for: task)?.name,
                onSchedule: { date in
                    Task { await viewModel.scheduleTask(task, at: date) }
                },
                agendaDate: viewModel.selectedDate
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Zero the List's default ~11pt vertical insets; the row already carries its
        // own 8pt padding, so this drops the inter-row gap from ~38pt to ~16pt.
        .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.lg, bottom: 0, trailing: DesignTokens.Spacing.lg))
        .swipeActions(edge: .trailing, allowsFullSwipe: viewModel.shouldAllowFullSwipeDelete(for: task)) {
            if viewModel.shouldShowDeleteAction(for: task) {
                Button(role: .destructive) {
                    viewModel.handleDeleteAction(for: task)
                } label: {
                    Label(task.isEvent ? "Remove" : "Delete",
                          systemImage: task.isEvent ? "calendar.badge.minus" : "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !task.isEvent {
                Button {
                    Task { await viewModel.completeTask(task) }
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .tint(DesignTokens.Color.systemGreen)

                Button {
                    Task { await viewModel.snoozeTask(task) }
                } label: {
                    Label("Snooze", systemImage: "clock.arrow.circlepath")
                }
                .tint(.orange)
            }
        }
    }

    /// Shared section-header chrome for the "By List" and "Status" grouped
    /// renderings, so both regroupings read identically.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Typography.footnote.weight(.semibold))
            .foregroundColor(DesignTokens.Color.labelSecondary)
            .textCase(nil)
    }

    @ViewBuilder
    private var agendaContent: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                DateNavigationHeader(viewModel: viewModel)

                if !viewModel.hasItemsForSelectedDate && isHydrating {
                    dailyBriefCard
                    AgendaHydratingView()
                } else if !viewModel.hasItemsForSelectedDate {
                    dailyBriefCard
                    AgendaNullStateView(
                        hasAvailableTasks: viewModel.schedulableUnscheduledCount + viewModel.schedulableOverdueCount > 0,
                        unscheduledCount: viewModel.schedulableUnscheduledCount + viewModel.schedulableOverdueCount,
                        calendarRecoveryState: viewModel.calendarRecoveryState,
                        onAddNewTap: {
                            onCreateTask?()
                        },
                        onScheduleTap: {
                            viewModel.showTaskSelectorSheet()
                        },
                        onCalendarSettingsTap: {
                            onOpenCalendarSettings?()
                        },
                        // Suggestions render INSIDE the null state, directly under the Add New /
                        // Schedule actions and ABOVE its bottom spacer — so they stay anchored to the
                        // empty-state guidance instead of being pushed offscreen on compact screens
                        // (Codex P2 on #1047). Mirrors where they sit at the bottom of the list.
                        // Nil when there are none so the slot reserves no gap under the buttons.
                        belowContent: visibleSuggestions.isEmpty ? nil : AnyView(suggestionStack)
                    )
                } else {
                    List {
                        // The Daily Brief now scrolls *with* the agenda (it is a list
                        // row, not pinned above the List), followed by a horizontal
                        // full-width divider that separates the summary from the items
                        // below. Two separate rows so the Divider renders horizontally.
                        dailyBriefSummaryRow
                        dailyBriefDividerRow

                        sortControlRow

                        calendarRecoveryRow

                        if viewModel.sortMode == .list {
                            // "By List": render one section per List so the regrouping
                            // is *visible* (a pure reorder reads as "nothing changed"
                            // when the day is a single List or all unfiled).
                            ForEach(viewModel.listGroupsForSelectedDate) { group in
                                Section {
                                    ForEach(group.tasks) { task in
                                        agendaTaskRow(task)
                                    }
                                } header: {
                                    sectionHeader(group.title)
                                }
                            }
                        } else if viewModel.sortMode == .status {
                            // "Status": render one section per status bucket so the
                            // regrouping is visible (same treatment as "By List").
                            ForEach(viewModel.statusGroupsForSelectedDate) { group in
                                Section {
                                    ForEach(group.tasks) { task in
                                        agendaTaskRow(task)
                                    }
                                } header: {
                                    sectionHeader(group.title)
                                }
                            }
                        } else {
                            ForEach(viewModel.tasksForSelectedDate) { task in
                                agendaTaskRow(task)
                            }
                        }

                        ForEach(viewModel.calendarOnlyEventsForSelectedDate, id: \.calendarEventID) { event in
                            NavigationLink {
                                let task = viewModel.resolveOrCreateTaskForCalendarEvent(event)
                                TaskEventView(
                                    viewModel: viewModel.makeTaskEventViewModel(for: task)
                                )
                            } label: {
                                DeviceCalendarEventRow(
                                    event: event,
                                    calendarInfo: viewModel.calendarInfoCache[event.calendarEventID]
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.lg, bottom: 0, trailing: DesignTokens.Spacing.lg))
                            .swipeActions(edge: .trailing, allowsFullSwipe: viewModel.shouldAllowFullSwipeDelete(for: event)) {
                                if viewModel.shouldShowDeleteAction(for: event) {
                                    Button(role: .destructive) {
                                        viewModel.handleDeleteAction(for: event)
                                    } label: {
                                        Label("Remove", systemImage: "calendar.badge.minus")
                                    }
                                }
                            }
                        }

                        // Inline action buttons at end of list
                        HStack(spacing: DesignTokens.Spacing.md) {
                            Button {
                                onCreateTask?()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    Text("Add New")
                                }
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                            }
                            .buttonStyle(.borderless)

                            if viewModel.schedulableUnscheduledCount + viewModel.schedulableOverdueCount > 0 {
                                Divider()
                                    .frame(height: 20)

                                Button {
                                    viewModel.showTaskSelectorSheet()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "calendar.badge.clock")
                                        Text("Schedule")
                                        let scheduleCount = viewModel.schedulableUnscheduledCount + viewModel.schedulableOverdueCount
                                        if scheduleCount > 0 {
                                            Text("\(scheduleCount)")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(DesignTokens.Color.labelTertiary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(DesignTokens.Color.labelSecondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, DesignTokens.Spacing.sm)

                        // Suggestions sit at the very bottom — below the day's rows AND below
                        // the "Add New / Schedule" footer actions (proposals, not commitments).
                        suggestionRows
                    }
                    .listStyle(.plain)
                    // Lower the default 44pt min row height so the SHORT rows (divider,
                    // sort control, section headers) collapse to their content + insets —
                    // this is what was inflating divider→sort and header↔row gaps. Task
                    // rows are already taller than this, so they're unaffected.
                    .environment(\.defaultMinListRowHeight, DesignTokens.Spacing.xs)
                    // Compact the gap above each group header ("Other" / "Grocery")
                    // so the section title sits close to the sort control and its
                    // first row — no large empty band in the header strip. An
                    // explicit small value reads denser than `.compact`, which the
                    // founder still found too airy.
                    .listSectionSpacing(DesignTokens.Spacing.xs)
                    .refreshable {
                        await viewModel.pullToRefresh()
                        if isToday {
                            await viewModel.refreshBriefAndSuggestions()
                        }
                    }
                    .task {
                        await viewModel.loadCalendarInfo(for: viewModel.tasksForSelectedDate)
                    }
                }

                Spacer()
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showTaskSelector },
            set: { newValue in
                if newValue { viewModel.showTaskSelectorSheet() }
                else { viewModel.hideTaskSelectorSheet() }
            }
        )) {
            TaskSelectorSheet(
                unscheduledTasks: viewModel.unscheduledTasks,
                overdueTasks: viewModel.overdueTasks,
                selectedDate: viewModel.selectedDate,
                modelContext: modelContext,
                onSchedule: { tasks, date in
                    Task { await viewModel.scheduleTasks(tasks, at: date) }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showCalendar },
            set: { newValue in
                if newValue { viewModel.showCalendarSheet() }
                else { viewModel.hideCalendarSheet() }
            }
        )) {
            CalendarSheet(viewModel: viewModel)
        }
        .suggestionOverflowSheet(
            isPresented: $isShowingAllSuggestions,
            suggestions: visibleSuggestions,
            briefMarkdown: visibleSuggestionsBriefMarkdown,
            onAccept: acceptSuggestion,
            onDismiss: dismissSuggestion
        )
        .onDisappear {
            viewModel.hideTaskSelectorSheet()
        }
        .confirmationDialog(
            "Delete Recurring Event",
            isPresented: Binding(
                get: { viewModel.recurringDeleteRequest != nil },
                set: { if !$0 { viewModel.recurringDeleteRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete This Event", role: .destructive) {
                Task { await viewModel.deleteRecurringRequest(scope: .thisEvent) }
            }
            Button("Delete This and Future Events", role: .destructive) {
                Task { await viewModel.deleteRecurringRequest(scope: .futureEvents) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether to remove just this occurrence or this event going forward.")
        }
        .alert(item: Binding(
            get: { viewModel.alert },
            set: { _ in viewModel.alert = nil }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Sorting control — sits between the brief and the first agenda item. Styled
    /// like the bottom "Add New | Schedule" CTA (borderless, 17pt semibold, secondary
    /// label). Reads "Sort by: <selected>" and offers List / Status / Time; List and
    /// Status regroup the agenda into sections, Time is the flat chronological default.
    @ViewBuilder
    private var sortControlRow: some View {
        Menu {
            Picker("Sort", selection: $viewModel.sortMode) {
                ForEach(AgendaSortMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Sort by: \(viewModel.sortMode.label)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("agenda-sort-control")
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Tight against the brief above and the first section header below — the
        // header strip (summary → sort → group header → first item) reads as one
        // compact block, not four widely-spaced rows.
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: DesignTokens.Spacing.lg,
            bottom: 0,
            trailing: DesignTokens.Spacing.lg
        ))
    }

    @ViewBuilder
    private var calendarRecoveryRow: some View {
        if let calendarRecoveryState = viewModel.calendarRecoveryState {
            AgendaCalendarRecoveryView(
                state: calendarRecoveryState,
                onCalendarSettingsTap: {
                    onOpenCalendarSettings?()
                }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .padding(.top, DesignTokens.Spacing.sm)
            .listRowInsets(EdgeInsets(
                top: DesignTokens.Spacing.sm,
                leading: DesignTokens.Spacing.lg,
                bottom: DesignTokens.Spacing.sm,
                trailing: DesignTokens.Spacing.lg
            ))
        }
    }

    // MARK: - Suggested tasks (WS2, doc 38)

    /// Suggestions are a "today" surface, like the brief — only shown for today.
    private var visibleSuggestions: [TaskSuggestion] {
        guard isToday else { return [] }
        return viewModel.orchestratorSuggestionSnapshot()?.suggestions ?? []
    }

    private func acceptSuggestion(_ suggestion: TaskSuggestion) {
        guard let snapshotID = viewModel.orchestratorSuggestionSnapshot()?.snapshotID else { return }
        Task { await viewModel.acceptSuggestion(suggestion, snapshotID: snapshotID) }
    }

    private func dismissSuggestion(_ suggestion: TaskSuggestion) {
        guard let snapshotID = viewModel.orchestratorSuggestionSnapshot()?.snapshotID else { return }
        Task { await viewModel.dismissSuggestion(suggestion, snapshotID: snapshotID) }
    }

    /// The brief these suggestions sit under, so the bounded inline set can be ordered by what the
    /// brief is actually about rather than by deriver order.
    private var visibleSuggestionsBriefMarkdown: String? {
        guard isToday else { return nil }
        return viewModel.orchestratorSuggestionSnapshot()?.briefMarkdown
    }

    /// The one suggestion section, configured once for both Agenda branches. Was two hand-rolled
    /// `ForEach` blocks with different headers, spacings and insets.
    @ViewBuilder
    private var suggestionSection: some View {
        SharedSuggestionSection(
            suggestions: visibleSuggestions,
            briefMarkdown: visibleSuggestionsBriefMarkdown,
            isShowingAll: $isShowingAllSuggestions,
            onAccept: acceptSuggestion,
            onDismiss: dismissSuggestion
        )
    }

    /// Suggestions for the populated-day List. Rendered at the very bottom — below the day's real
    /// task/event rows AND below the "Add New / Schedule" footer actions (proposals, not
    /// commitments). Now a single list row: the section owns its own header, bounded row set and
    /// "See all" overflow, so the List no longer interleaves them as separate rows.
    @ViewBuilder
    private var suggestionRows: some View {
        if !visibleSuggestions.isEmpty {
            suggestionSection
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: DesignTokens.Spacing.sm,
                    leading: DesignTokens.Spacing.lg,
                    bottom: DesignTokens.Spacing.sm,
                    trailing: DesignTokens.Spacing.lg
                ))
        }
    }

    /// Suggestions for the empty-state branch (no List there). This is the acceptance surface: an
    /// otherwise-empty day still shows what Rem noticed.
    @ViewBuilder
    private var suggestionStack: some View {
        if !visibleSuggestions.isEmpty {
            suggestionSection
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.top, DesignTokens.Spacing.sm)
        }
    }
}

// MARK: - Date Navigation Header

struct DateNavigationHeader: View {
    @ObservedObject var viewModel: AgendaViewModel
    private let horizontalSwipeThreshold: CGFloat = 24
    private let horizontalDominanceRatio: CGFloat = 1.2

    private var isToday: Bool {
        Calendar.current.isDateInToday(viewModel.selectedDate)
    }

    var body: some View {
        HStack {
            Button(action: { viewModel.navigateToPreviousDay() }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .bold))
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                    }
                }
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .opacity(0.5)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: {
                if viewModel.showCalendar { viewModel.hideCalendarSheet() }
                else { viewModel.showCalendarSheet() }
            }) {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if isToday {
                            Image(systemName: "calendar")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(DesignTokens.Color.brandBlue)
                        }
                        Text(relativeDateLabel(for: viewModel.selectedDate))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    }
                    Text(dayFormatter.string(from: viewModel.selectedDate))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: { viewModel.navigateToNextDay() }) {
                HStack(spacing: 3) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 10, height: 4)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22, weight: .bold))
                }
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .contentShape(Rectangle())
        .highPriorityGesture(daySwipeGesture)
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }

    private func relativeDateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        return weekdayFormatter.string(from: date)
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: horizontalSwipeThreshold, coordinateSpace: .local)
            .onEnded { value in
                let horizontalTravel = value.translation.width
                let verticalTravel = value.translation.height
                guard abs(horizontalTravel) >= horizontalSwipeThreshold else { return }
                guard abs(horizontalTravel) > abs(verticalTravel) * horizontalDominanceRatio else { return }

                if horizontalTravel < 0 {
                    viewModel.navigateToNextDay()
                } else {
                    viewModel.navigateToPreviousDay()
                }
            }
    }
}

// MARK: - Device Calendar Event Row

private struct DeviceCalendarEventRow: View {
    let event: DeviceCalendarEventSummary
    let calendarInfo: CalendarInfo?

    private var timeIndicatorWidth: CGFloat {
        TimeIndicatorWidthCalculator.shared.width
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            leftIndicator
                .frame(width: timeIndicatorWidth, alignment: .leading)

            HStack(spacing: DesignTokens.Spacing.sm) {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(calendarInfo?.color ?? DesignTokens.Color.labelSecondary)
                    .frame(width: 4, height: 34)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(event.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let calendarInfo {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(calendarInfo.color)
                                    .frame(width: 8, height: 8)
                                Text(calendarInfo.name)
                                    .font(DesignTokens.Typography.caption1)
                                    .foregroundColor(DesignTokens.Color.labelPrimary)
                            }
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(DesignTokens.CornerRadius.xlarge)
                        }

                        Text(durationText)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(DesignTokens.CornerRadius.xlarge)
                    }
                }
            }

            Spacer()
        }
        .padding(6)
    }

    @ViewBuilder
    private var leftIndicator: some View {
        let start = event.startDate
        HStack(spacing: 2) {
            Text(formatHour(start))
                .font(.title2)
            VStack(spacing: 0) {
                Text(formatMinutes(start))
                Text(formatAMPM(start))
            }
            .font(.caption)
        }
    }

    private var durationText: String {
        let minutes = max(event.durationMinutes, 0)
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
        return "\(mins)m"
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

// MARK: - Null State

struct AgendaNullStateView: View {
    let hasAvailableTasks: Bool
    let unscheduledCount: Int
    let calendarRecoveryState: AgendaCalendarRecoveryState?
    let onAddNewTap: () -> Void
    let onScheduleTap: () -> Void
    let onCalendarSettingsTap: () -> Void
    /// Content rendered directly under the Add New / Schedule buttons and ABOVE the bottom spacer,
    /// so it stays anchored to the empty-state guidance instead of being pushed offscreen by that
    /// spacer on compact screens (used for the suggestions stack — Codex P2 on #1047).
    var belowContent: AnyView? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            if let calendarRecoveryState {
                AgendaCalendarRecoveryView(
                    state: calendarRecoveryState,
                    onCalendarSettingsTap: onCalendarSettingsTap
                )
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.top, DesignTokens.Spacing.lg)
            }

            Spacer()

            VStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 64))
                    .foregroundColor(DesignTokens.Color.labelSecondary)

                Text("No agenda yet")
                    .font(DesignTokens.Typography.title1Bold)
                    .foregroundColor(DesignTokens.Color.labelPrimary)

                Text("Create a new task or schedule existing ones")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.Spacing.xl)

                HStack(spacing: DesignTokens.Spacing.md) {
                    Button(action: onAddNewTap) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("Add New")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    }

                    if hasAvailableTasks {
                        Divider()
                            .frame(height: 20)

                        Button(action: onScheduleTap) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.badge.clock")
                                Text("Schedule")
                                if unscheduledCount > 0 {
                                    Text("\(unscheduledCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DesignTokens.Color.labelTertiary)
                                        .clipShape(Capsule())
                                }
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                        }
                    }
                }
                .padding(.top, DesignTokens.Spacing.sm)

                if let belowContent {
                    belowContent
                }
            }

            Spacer()
        }
    }
}

private struct AgendaCalendarRecoveryView: View {
    let state: AgendaCalendarRecoveryState
    let onCalendarSettingsTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(DesignTokens.Color.systemOrange, DesignTokens.Color.labelSecondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                    Text(state.message)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
            }

            Button {
                onCalendarSettingsTap()
            } label: {
                Text(state.actionTitle)
            }
            .remInlineRecoveryCTA()
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.Color.backgroundSecondary)
        )
    }
}

// MARK: - Task Selector Sheet

struct TaskSelectorSheet: View {
    let unscheduledTasks: [TaskEvent]
    let overdueTasks: [TaskEvent]
    let selectedDate: Date
    let modelContext: ModelContext
    /// Persist + sync the chosen tasks to the given date. Routed through the view
    /// model so the schedule is pushed to the backend, not just saved locally —
    /// otherwise it reverts to unscheduled on the next pull.
    let onSchedule: ([TaskEvent], Date) -> Void

    enum TaskFilter: String, CaseIterable {
        case all = "All"
        case inbox = "Inbox"
        case overdue = "Overdue"
    }

    enum ScheduleStep: Hashable {
        case pickDate
        case pickTime(date: Date)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.taskApiService) private var taskApiService
    @Environment(\.taskSyncService) private var taskSyncService
    @State private var selectedTaskIDs: Set<UUID> = []
    @State private var filter: TaskFilter = .all
    @State private var schedulePath = NavigationPath()

    private var inboxTasks: [TaskEvent] {
        unscheduledTasks.filter { !$0.isEvent }
    }

    private var overdueTasksFiltered: [TaskEvent] {
        overdueTasks.filter { !$0.isEvent }
    }

    private var filteredTasks: [TaskEvent] {
        switch filter {
        case .all: return inboxTasks + overdueTasksFiltered
        case .inbox: return inboxTasks
        case .overdue: return overdueTasksFiltered
        }
    }

    private var allAvailableTasks: [TaskEvent] {
        (unscheduledTasks + overdueTasks).filter { !$0.isEvent }
    }

    var body: some View {
        NavigationStack(path: $schedulePath) {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("Filter", selection: $filter) {
                        ForEach(TaskFilter.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                    if filteredTasks.isEmpty {
                        Text("No tasks")
                            .font(.subheadline)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                    } else {
                        List {
                            ForEach(filteredTasks) { task in
                                Button {
                                    if selectedTaskIDs.contains(task.id) {
                                        selectedTaskIDs.remove(task.id)
                                    } else {
                                        selectedTaskIDs.insert(task.id)
                                    }
                                } label: {
                                    HStack(spacing: DesignTokens.Spacing.sm) {
                                        TaskEventRowView(
                                            task: task,
                                            hideLeftIndicator: true
                                        )

                                        Spacer()

                                        Image(systemName: selectedTaskIDs.contains(task.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(selectedTaskIDs.contains(task.id)
                                                             ? DesignTokens.Color.brandBlue
                                                             : DesignTokens.Color.labelSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if !task.isEvent {
                                        Button(role: .destructive) {
                                            deleteTask(task)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }

                    if !selectedTaskIDs.isEmpty {
                        actionBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedTaskIDs.isEmpty)
            }
            .navigationTitle("Schedule Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: ScheduleStep.self) { step in
                switch step {
                case .pickDate:
                    ScheduleDateStepView(onDateSelected: { date in
                        schedulePath.append(ScheduleStep.pickTime(date: date))
                    })
                case .pickTime(let date):
                    ScheduleTimeStepView(date: date, onDone: { resolvedDate in
                        scheduleSelectedTasksAt(resolvedDate)
                        dismiss()
                    })
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                schedulePath.append(ScheduleStep.pickTime(date: selectedDate))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(addTodayLabel)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(DesignTokens.Color.brandBlue)
                .cornerRadius(10)
            }

            Button {
                schedulePath.append(ScheduleStep.pickDate)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text("Plan")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var addTodayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return "Add to Today"
        } else if calendar.isDateInTomorrow(selectedDate) {
            return "Add to Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Add to \(formatter.string(from: selectedDate))"
        }
    }

    // MARK: - Scheduling

    private func deleteTask(_ task: TaskEvent) {
        selectedTaskIDs.remove(task.id)
        Task {
            if let taskApiService {
                do {
                    try await taskApiService.deleteTask(id: task.id.uuidString)
                    if let taskSyncService,
                       await taskSyncService.recordConfirmedDelete(for: task.id) == false { return }
                } catch {
                    guard await taskSyncService?.queueOperation(operationType: "delete", taskId: task.id, taskData: nil) == true else { return }
                }
            } else {
                guard await taskSyncService?.queueOperation(operationType: "delete", taskId: task.id, taskData: nil) == true else { return }
            }
            TaskNotificationService.shared.cancelNotification(for: task.id)
            modelContext.delete(task)
            try? modelContext.save()
        }
    }

    private func scheduleSelectedTasksAt(_ date: Date) {
        let tasks = selectedTaskIDs.compactMap { taskID in
            allAvailableTasks.first(where: { $0.id == taskID })
        }
        guard !tasks.isEmpty else { return }
        // Delegate persistence + backend sync to the view model. Mutating
        // SwiftData here without pushing to the backend was the unschedule-on-
        // refresh bug: start_date stayed NULL server-side and the next pull
        // dropped the task back into the inbox bucket.
        onSchedule(tasks, date)
    }
}

// MARK: - Schedule Date Step

private struct ScheduleDateStepView: View {
    let onDateSelected: (Date) -> Void
    @State private var selectedDate = Date()

    var body: some View {
        VStack {
            DatePicker(
                "Date",
                selection: $selectedDate,
                in: Date()...,
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Pick a Date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") {
                    onDateSelected(selectedDate)
                }
                .fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Schedule Time Step

private struct ScheduleTimeStepView: View {
    let initialDate: Date
    let onDone: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var selectedTime: Date
    @State private var showDatePicker = false

    init(date: Date, onDone: @escaping (Date) -> Void) {
        self.initialDate = date
        self.onDone = onDone
        _selectedDate = State(initialValue: date)
        let defaultTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        _selectedTime = State(initialValue: defaultTime)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Date row — tappable to expand inline date picker
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showDatePicker.toggle()
                    }
                } label: {
                    HStack {
                        Text("Date")
                            .font(.body)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                        Spacer()
                        Text(formattedDate)
                            .font(.body)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                        Image(systemName: showDatePicker ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(DesignTokens.Color.labelTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)

                // Inline date picker (expands below the date row)
                if showDatePicker {
                    Divider()
                        .padding(.horizontal, 16)

                    DatePicker(
                        "Date",
                        selection: $selectedDate,
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .padding(.horizontal, 16)
                    .padding(.top, showDatePicker ? 0 : 4)

                // Wheel time picker
                DatePicker(
                    "Time",
                    selection: $selectedTime,
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    let calendar = Calendar.current
                    let timeComponents = calendar.dateComponents([.hour, .minute], from: selectedTime)
                    let resolved = calendar.date(
                        bySettingHour: timeComponents.hour ?? 9,
                        minute: timeComponents.minute ?? 0,
                        second: 0,
                        of: selectedDate
                    ) ?? selectedDate
                    onDone(resolved)
                }
                .fontWeight(.semibold)
            }
        }
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        let datePart = formatter.string(from: selectedDate)

        if calendar.isDateInToday(selectedDate) {
            return "Today, \(datePart)"
        } else if calendar.isDateInTomorrow(selectedDate) {
            return "Tomorrow, \(datePart)"
        } else {
            formatter.dateStyle = .medium
            return formatter.string(from: selectedDate)
        }
    }
}

// MARK: - Calendar Sheet

struct CalendarSheet: View {
    @ObservedObject var viewModel: AgendaViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date

    init(viewModel: AgendaViewModel) {
        self.viewModel = viewModel
        _selectedDate = State(initialValue: viewModel.selectedDate)
    }

    var body: some View {
        NavigationView {
            DatePicker(
                "Select Date",
                selection: $selectedDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        viewModel.navigateToDate(selectedDate)
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedDate) { _, newValue in
                viewModel.navigateToDate(newValue)
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Hydrating View

struct AgendaHydratingView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    TaskEventRowSkeleton()
                }
            }
            .padding()
        }
    }
}
