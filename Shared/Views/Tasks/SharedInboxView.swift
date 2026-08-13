import SwiftUI

/// Cross-platform Inbox view showing unscheduled tasks.
/// Generic over `TaskStoreProviding` so it works with both iOS and Mac task stores.
struct SharedInboxView<Store: TaskStoreProviding>: View {
    let store: Store
    var onCreateTask: (() -> Void)?
    var onOpenTask: ((Store.TaskItem) -> Void)?

    var body: some View {
        #if os(macOS)
        inboxContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 8) {
                        if store.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let syncDate = store.lastSyncDate {
                            Text("Updated \(syncDate, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .task { await store.refresh() }
        #else
        VStack(spacing: 0) {
            inboxHeader
            Divider()
            inboxContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.refresh() }
        #endif
    }

    // MARK: - Header

    private var inboxHeader: some View {
        HStack {
            Text("Inbox")
                .font(DesignTokens.Typography.title1Bold)
                .foregroundColor(DesignTokens.Color.labelPrimary)

            Spacer()

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let syncDate = store.lastSyncDate {
                Text("Updated \(syncDate, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let onCreateTask {
                Button {
                    onCreateTask()
                } label: {
                    Image(systemName: "plus")
                }
                #if os(macOS)
                .buttonStyle(.bordered)
                .controlSize(.small)
                #else
                .font(.title3)
                #endif
            }

            #if os(iOS)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .font(.title3)
            .disabled(store.isLoading)
            #endif
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Content

    @ViewBuilder
    private var inboxContent: some View {
        if store.isLoading && store.unscheduledTasks.isEmpty {
            loadingView
        } else if store.unscheduledTasks.isEmpty {
            emptyState
        } else {
            taskList
        }
    }

    private var taskList: some View {
        List {
            ForEach(store.unscheduledTasks, id: \.displayId) { task in
                SharedTaskRow(task: task, showTimeIndicator: false)
                    #if os(macOS)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenTask?(task)
                    }
                    #endif
                    #if os(macOS)
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
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Inbox is empty")
                .font(.title2.bold())
            Text("Tasks you capture will appear here.")
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
            Text("Loading tasks...")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Inbox — Empty") {
    NavigationStack {
        SharedInboxView(store: PreviewTaskStore(scenario: .empty))
    }
}

#Preview("Inbox — Tasks") {
    NavigationStack {
        SharedInboxView(store: PreviewTaskStore(scenario: .inbox))
    }
}

#Preview("Inbox — Loading") {
    NavigationStack {
        SharedInboxView(store: PreviewTaskStore(scenario: .loading))
    }
}
#endif
