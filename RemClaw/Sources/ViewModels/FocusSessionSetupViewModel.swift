import Foundation
import SwiftUI
import Combine

/// ViewModel for FocusSessionSetupView — focus session duration, warm-up, and task selection.
@MainActor
class FocusSessionSetupViewModel: ObservableObject {
    // MARK: - Published State

    @Published var task: TaskEvent
    @Published var selectedDuration: TimeInterval = 25 * 60
    @Published var customDuration: TimeInterval = 25 * 60
    @Published var showCustomDurationPicker = false

    @Published var warmUpEnabled = false
    @Published var warmUpDuration: TimeInterval = 1 * 60
    @Published var customWarmUpDuration: TimeInterval = 1 * 60
    @Published var showCustomWarmUpPicker = false

    @Published var showTaskPicker = false

    @Published var selectedDurationOption: DurationOption = .twentyFive
    @Published var selectedWarmUpOption: WarmUpOption = .one

    /// Dynamic options for the segmented picker. The last slot is either a
    /// preset (if it matches) or the task's own duration formatted as a label.
    @Published var durationOptions: [DurationOption] = []

    // MARK: - Duration Option

    struct DurationOption: Identifiable, Hashable {
        let id: String
        let label: String
        let timeInterval: TimeInterval?

        static let fifteen = DurationOption(id: "15m", label: "15m", timeInterval: 15 * 60)
        static let twentyFive = DurationOption(id: "25m", label: "25m", timeInterval: 25 * 60)
        static let fortyFive = DurationOption(id: "45m", label: "45m", timeInterval: 45 * 60)
        static let sixty = DurationOption(id: "1h", label: "1h", timeInterval: 60 * 60)
        static let custom = DurationOption(id: "custom", label: "Custom", timeInterval: nil, isEditable: true)

        var isEditable: Bool = false

        static func taskDuration(_ interval: TimeInterval) -> DurationOption {
            DurationOption(id: "task_\(Int(interval))", label: formatDuration(interval), timeInterval: interval, isEditable: true)
        }

        static let presets: [DurationOption] = [.fifteen, .twentyFive, .fortyFive, .sixty]

        private static func formatDuration(_ d: TimeInterval) -> String {
            let h = Int(d) / 3600
            let m = (Int(d) % 3600) / 60
            if h > 0 && m > 0 { return "\(h)h \(m)m" }
            if h > 0 { return "\(h)h" }
            return "\(m)m"
        }
    }

    // MARK: - Warm-Up Option

    enum WarmUpOption: String, CaseIterable, Identifiable {
        case one = "1m"
        case two = "2m"
        case three = "3m"
        case five = "5m"
        case custom = "Custom"

        var id: String { rawValue }

        var timeInterval: TimeInterval? {
            switch self {
            case .one: return 1 * 60
            case .two: return 2 * 60
            case .three: return 3 * 60
            case .five: return 5 * 60
            case .custom: return nil
            }
        }
    }

    // MARK: - Callbacks

    var onStart: ((FocusSession) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(task: TaskEvent, onStart: @escaping (FocusSession) -> Void) {
        self.task = task
        self.onStart = onStart

        let taskTime = task.estimatedDuration ?? task.duration
        let (options, defaultOption, defaultDuration) = Self.buildDurationOptions(taskTime: taskTime)
        self.durationOptions = options
        self.selectedDurationOption = defaultOption
        self.selectedDuration = defaultDuration
        self.customDuration = defaultDuration

        setupObservers()
    }

    // MARK: - Build Options

    private static func buildDurationOptions(taskTime: TimeInterval?) -> ([DurationOption], DurationOption, TimeInterval) {
        let presets = DurationOption.presets

        guard let taskTime, taskTime > 0 else {
            return (presets + [.custom], .twentyFive, 25 * 60)
        }

        if let match = presets.first(where: { $0.timeInterval == taskTime }) {
            return (presets + [.custom], match, taskTime)
        }

        let taskOption = DurationOption.taskDuration(taskTime)
        return (presets + [taskOption], taskOption, taskTime)
    }

    // MARK: - Setup

    private func setupObservers() {
        $selectedDurationOption
            .dropFirst()
            .sink { [weak self] option in
                guard let self else { return }
                if let duration = option.timeInterval {
                    self.selectedDuration = duration
                } else {
                    self.showCustomDurationPicker = true
                }
            }
            .store(in: &cancellables)

        $selectedWarmUpOption
            .dropFirst()
            .sink { [weak self] option in
                guard let self else { return }
                if let duration = option.timeInterval {
                    self.warmUpDuration = duration
                } else {
                    self.showCustomWarmUpPicker = true
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    var isReadyToStart: Bool {
        selectedDuration > 0
    }

    // MARK: - Methods

    func updateTask(_ newTask: TaskEvent) {
        task = newTask
        let taskTime = newTask.estimatedDuration ?? newTask.duration
        let (options, defaultOption, defaultDuration) = Self.buildDurationOptions(taskTime: taskTime)
        durationOptions = options
        selectedDurationOption = defaultOption
        selectedDuration = defaultDuration
    }

    func setCustomDuration(_ duration: TimeInterval) {
        customDuration = duration
        selectedDuration = duration

        let newOption = DurationOption.taskDuration(duration)
        if let lastIndex = durationOptions.indices.last, durationOptions[lastIndex].isEditable {
            durationOptions[lastIndex] = newOption
        }
        selectedDurationOption = newOption
    }

    func setCustomWarmUpDuration(_ duration: TimeInterval) {
        customWarmUpDuration = duration
        warmUpDuration = duration
        selectedWarmUpOption = .custom
    }

    func startFocusSession() {
        let session = FocusSession(
            taskId: task.id,
            taskTitle: task.title,
            duration: selectedDuration,
            warmUpDuration: warmUpEnabled ? warmUpDuration : nil,
            startTime: Date(),
            status: warmUpEnabled ? .warmingUp : .running
        )
        onStart?(session)
    }
}
