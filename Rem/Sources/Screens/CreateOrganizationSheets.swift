import SwiftUI
import SwiftData

/// Minimal create sheets for task organization (Sorted-style): a **List** (a project)
/// and a **Folder** (groups Lists). Presented from the "+" menu (minimum-new-UI).
///
/// Each sheet writes to local SwiftData immediately (optimistic, with the same id) and
/// pushes to the backend best-effort, mirroring the task create path.

// MARK: - New List

struct CreateListSheet: View {
    let apiService: OrganizationApiService
    /// Optional hook fired with the new List's id after it's saved. Lets a caller
    /// that opened this sheet inline (e.g. the task list-chip picker's "New List…")
    /// immediately file the current task into the freshly created List.
    var onCreated: ((UUID) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Folders the new List can be filed under. Ungrouped is the default.
    @Query(sort: [SortDescriptor(\TaskFolder.sortOrder), SortDescriptor(\TaskFolder.createdAt)])
    private var folders: [TaskFolder]

    @State private var name: String = ""
    @State private var selectedFolderID: UUID?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("List name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                }

                if !folders.isEmpty {
                    Section("Folder") {
                        Picker("Folder", selection: $selectedFolderID) {
                            Text("None").tag(UUID?.none)
                            ForEach(folders) { folder in
                                Text(folder.name).tag(UUID?.some(folder.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
        // Half-sheet: a single name field doesn't need full height. Medium
        // is the default; user can drag to large if needed.
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let list = TaskList(name: trimmedName, folderID: selectedFolderID)
        modelContext.insert(list)
        try? modelContext.save()

        let payloadName = trimmedName
        let folderID = selectedFolderID?.uuidString
        Task {
            try? await apiService.createList(id: list.id.uuidString, name: payloadName, folderID: folderID)
        }
        onCreated?(list.id)
        dismiss()
    }
}

// MARK: - New Folder

struct CreateFolderSheet: View {
    let apiService: OrganizationApiService

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("Folders group your lists.")
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
        // Half-sheet: a single name field doesn't need full height. Medium
        // is the default; user can drag to large if needed.
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let folder = TaskFolder(name: trimmedName)
        modelContext.insert(folder)
        try? modelContext.save()

        let payloadName = trimmedName
        Task {
            try? await apiService.createFolder(id: folder.id.uuidString, name: payloadName)
        }
        dismiss()
    }
}
