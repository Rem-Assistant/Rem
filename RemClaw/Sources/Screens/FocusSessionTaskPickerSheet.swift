import SwiftUI
import SwiftData

/// Bottom sheet for selecting a task for a focus session.
/// Shows only tasks (no calendar events); used from FocusSessionSetupView.
struct FocusSessionTaskPickerSheet: View {
    @StateObject private var viewModel: FocusSessionTaskPickerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.taskApiService) private var taskApiService
    @Environment(\.taskSyncService) private var taskSyncService
    @Binding var selectedTask: TaskEvent

    @Query(sort: [SortDescriptor(\TaskEvent.createdAt, order: .reverse)], animation: .default)
    private var allTasks: [TaskEvent]

    init(selectedTask: Binding<TaskEvent>) {
        _selectedTask = selectedTask
        _viewModel = StateObject(wrappedValue: FocusSessionTaskPickerViewModel(selectedTask: selectedTask.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Picker("Filter", selection: $viewModel.selectedFilter) {
                            ForEach(FocusSessionTaskPickerViewModel.TaskFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(20)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(viewModel.filteredTasks) { task in
                        Button {
                            viewModel.selectTask(task)
                            selectedTask = task
                            dismiss()
                        } label: {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                TaskEventRowView(
                                    task: task,
                                    hideLeftIndicator: true
                                )

                                Spacer()

                                Image(systemName: viewModel.selectedTask?.id == task.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundColor(viewModel.selectedTask?.id == task.id
                                                     ? DesignTokens.Color.brandBlue
                                                     : DesignTokens.Color.labelSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
            .listSectionSpacing(.compact)
            .searchable(text: $viewModel.searchText, prompt: "Search tasks")
            .navigationTitle("Select Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.allTasks = allTasks
            }
            .onChange(of: allTasks) { _, newTasks in
                viewModel.allTasks = newTasks
            }
        }
    }

    private func deleteTask(_ task: TaskEvent) {
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
}
