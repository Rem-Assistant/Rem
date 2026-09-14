import Foundation
import SwiftUI
import SwiftData
import Combine

/// ViewModel for FocusSessionTaskPickerSheet — task selection and filtering for focus sessions.
/// Filters to tasks only (excludes calendar events).
@MainActor
class FocusSessionTaskPickerViewModel: ObservableObject {
    // MARK: - Published State

    @Published var searchText: String = ""
    @Published var selectedTask: TaskEvent?
    @Published var selectedFilter: TaskFilter = .all

    // MARK: - Enums

    enum TaskFilter: String, CaseIterable, Identifiable {
        case inProgress = "In Progress"
        case recent = "Recent"
        case all = "All"

        var id: String { rawValue }
    }

    // MARK: - Dependencies

    var allTasks: [TaskEvent] = [] {
        didSet {
            updateFilteredTasks()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(selectedTask: TaskEvent? = nil) {
        self.selectedTask = selectedTask
        setupObservers()
    }

    // MARK: - Setup

    private func setupObservers() {
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredTasks()
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    var recentTasks: [TaskEvent] {
        allTasks
            .filter { !$0.isEvent && !$0.isCompleted }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { $0 }
    }

    var inProgressTasks: [TaskEvent] {
        allTasks
            .filter { !$0.isEvent && $0.statusEnum == .inProgress }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var filteredTasks: [TaskEvent] {
        let nonEventTasks = allTasks.filter { !$0.isEvent && !$0.isCompleted }

        let filteredByType: [TaskEvent]
        switch selectedFilter {
        case .inProgress:
            filteredByType = nonEventTasks.filter { $0.statusEnum == .inProgress }
        case .recent:
            filteredByType = Array(nonEventTasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
        case .all:
            filteredByType = nonEventTasks
        }

        if searchText.isEmpty {
            return filteredByType.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            return filteredByType
                .filter { $0.title.localizedCaseInsensitiveContains(searchText) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: - Methods

    func selectTask(_ task: TaskEvent) {
        selectedTask = task
    }

    private func updateFilteredTasks() {
        objectWillChange.send()
    }
}
