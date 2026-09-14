import SwiftUI
import SwiftData

/// Tasks grouped by **List**, with Lists grouped under their **Folder** (Sorted-style).
///
/// Layout (top → bottom):
///   • each Folder → its Lists → each List's tasks
///   • ungrouped Lists (no Folder) → their tasks
///   • "No List" → tasks not filed into any List (the inbox spill-over)
///
/// Foundation slice: read-only grouping over local SwiftData with swipe-to-delete for
/// Lists/Folders. Creating Tasks/Lists/Folders happens through the "+" menu.
struct TasksByListView: View {
    let apiService: OrganizationApiService
    var onOpenTask: ((UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\TaskFolder.sortOrder), SortDescriptor(\TaskFolder.createdAt)])
    private var folders: [TaskFolder]

    @Query(sort: [SortDescriptor(\TaskList.sortOrder), SortDescriptor(\TaskList.createdAt)])
    private var lists: [TaskList]

    @Query(sort: [SortDescriptor(\TaskEvent.createdAt, order: .reverse)])
    private var tasks: [TaskEvent]

    private var ungroupedLists: [TaskList] { lists.filter { $0.folderID == nil } }
    private var unfiledTasks: [TaskEvent] { tasks.filter { $0.listID == nil && $0.isEvent == false } }

    private func lists(in folder: TaskFolder) -> [TaskList] {
        lists.filter { $0.folderID == folder.id }
    }

    private func tasks(in list: TaskList) -> [TaskEvent] {
        tasks.filter { $0.listID == list.id }
    }

    var body: some View {
        Group {
            if lists.isEmpty && folders.isEmpty && unfiledTasks.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await OrganizationSyncManager(apiService: apiService, modelContext: modelContext)
                .syncFromBackend()
        }
    }

    private var listContent: some View {
        List {
            ForEach(folders) { folder in
                Section {
                    let folderLists = lists(in: folder)
                    if folderLists.isEmpty {
                        Text("No lists yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(folderLists) { list in
                            listGroup(list)
                        }
                    }
                } header: {
                    Label(folder.name, systemImage: "folder")
                }
            }

            if !ungroupedLists.isEmpty {
                Section("Lists") {
                    ForEach(ungroupedLists) { list in
                        listGroup(list)
                    }
                }
            }

            if !unfiledTasks.isEmpty {
                Section("No List") {
                    ForEach(unfiledTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - List group (a List header + its tasks)

    @ViewBuilder
    private func listGroup(_ list: TaskList) -> some View {
        let listTasks = tasks(in: list)
        DisclosureGroup {
            if listTasks.isEmpty {
                Text("No tasks")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(listTasks) { task in
                    taskRow(task)
                }
            }
        } label: {
            HStack {
                Label(list.name, systemImage: "list.bullet")
                    .font(DesignTokens.Typography.bodyBold)
                Spacer()
                Text("\(listTasks.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteList(list) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func taskRow(_ task: TaskEvent) -> some View {
        Button {
            onOpenTask?(task.id)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? DesignTokens.Color.brandBlue : .secondary)
                Text(task.title)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelPrimary)
                    .strikethrough(task.isCompleted, color: .secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No lists yet")
                .font(.title2.bold())
            Text("Use the + button to create a List or Folder, then file tasks into them.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mutations

    private func deleteList(_ list: TaskList) {
        // Un-file member tasks locally (matches backend ON DELETE SET NULL).
        for task in tasks(in: list) { task.listID = nil }
        let id = list.id.uuidString
        modelContext.delete(list)
        try? modelContext.save()
        Task { try? await apiService.deleteList(id: id) }
    }
}
