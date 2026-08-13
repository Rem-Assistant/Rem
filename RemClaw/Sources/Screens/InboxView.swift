import SwiftUI

public struct InboxView: View {
    @ObservedObject var viewModel: InboxViewModel
    var isHydrating: Bool = false

    public init(viewModel: InboxViewModel, isHydrating: Bool = false) {
        self.viewModel = viewModel
        self.isHydrating = isHydrating
    }

    public var body: some View {
        inboxContent
    }

    @ViewBuilder
    private var inboxContent: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                InboxHeader()

                if viewModel.unscheduledTasks.isEmpty && isHydrating {
                    InboxHydratingView()
                } else if viewModel.unscheduledTasks.isEmpty {
                    InboxNullStateView()
                } else {
                    List {
                        ForEach(viewModel.unscheduledTasks) { task in
                            NavigationLink(value: task.id) {
                                TaskEventRowView(
                                    task: task,
                                    calendarColor: viewModel.getCalendarInfo(for: task)?.color,
                                    calendarName: viewModel.getCalendarInfo(for: task)?.name,
                                    onSchedule: { date in
                                        Task { await viewModel.scheduleTask(task, at: date) }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteTask(task) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.pullToRefresh()
                    }
                    .task {
                        await viewModel.loadCalendarInfo(for: viewModel.unscheduledTasks)
                    }
                }

                Spacer()
            }
        }
    }
}

// MARK: - Inbox Header

struct InboxHeader: View {
    var body: some View {
        HStack {
            Text("Inbox")
                .font(DesignTokens.Typography.title1Bold)
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.md)
    }
}

// MARK: - Null State

struct InboxNullStateView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            Spacer()

            VStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "tray")
                    .font(.system(size: 64))
                    .foregroundColor(DesignTokens.Color.labelSecondary)

                Text("Inbox is empty")
                    .font(DesignTokens.Typography.title1Bold)
                    .foregroundColor(DesignTokens.Color.labelPrimary)

                Text("Tasks you capture will appear here")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
            }

            Spacer()
        }
    }
}

// MARK: - Hydrating View

struct InboxHydratingView: View {
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
