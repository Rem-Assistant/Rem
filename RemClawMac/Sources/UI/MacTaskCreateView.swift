import SwiftUI

/// Task creation form for macOS.
/// Creates tasks via the backend REST API (POST /api/v1/tasks).
struct MacTaskCreateSheet: View {
    @Environment(MacGatewaySessionManager.self) private var session
    let taskStore: MacTaskStore
    let onDismiss: () -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var hasSchedule = false
    @State private var startDate = Date()
    @State private var priority = "medium"
    @State private var category = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let priorities = ["low", "medium", "high", "urgent"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(priorities, id: \.self) { p in
                            Text(p.capitalized).tag(p)
                        }
                    }

                    TextField("Category (optional)", text: $category)
                }

                Section {
                    Toggle("Schedule", isOn: $hasSchedule)

                    if hasSchedule {
                        DatePicker("Start", selection: $startDate)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Color.backgroundPrimary)
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createTask() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    .fontWeight(.semibold)
                }
            }
        }
        .frame(minWidth: 420, minHeight: hasSchedule ? 420 : 360)
    }

    private func createTask() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isCreating = true
        errorMessage = nil

        // Build JSON params
        var params: [String: Any] = ["title": trimmedTitle]
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { params["notes"] = trimmedNotes }
        if priority != "medium" { params["priority"] = priority }
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCategory.isEmpty { params["category"] = trimmedCategory }

        if hasSchedule {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            params["start_date"] = formatter.string(from: startDate)
        }

        let result = await taskStore.createTask(params)
        if result != nil {
            onDismiss()
        } else {
            errorMessage = taskStore.lastError ?? "Failed to create task"
        }

        isCreating = false
    }
}
