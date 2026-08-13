import Foundation
import Combine
import SwiftUI
import SwiftData

#if canImport(ActivityKit) && os(iOS)
@preconcurrency import ActivityKit
#endif

@MainActor
public class FocusSessionManager: ObservableObject, FocusTimerProvider {
    @Published public var currentSession: FocusSession?
    @Published public var timeRemaining: TimeInterval = 0
    @Published public var progress: Double = 0.0

    private var timer: Timer?
    public var modelContext: ModelContext?
    public var taskSyncService: TaskSyncServiceProtocol?

    // MARK: - Live Activity State

    #if canImport(ActivityKit) && os(iOS)
    nonisolated(unsafe) private var liveActivity: Any? // Activity<FocusTimerActivityAttributes>?
    nonisolated(unsafe) private var preSessionLiveActivity: Any? // Activity<FocusPreSessionActivityAttributes>?
    #endif

    private var preSessionUpdateTimer: Timer?
    private var preSessionScheduledTimers: [UUID: Timer] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Session Control

    public func startSession(_ session: FocusSession) async {
        if currentSession != nil {
            await stopSession()
        }

        // End any active pre-session Live Activity for this task
        if let taskId = session.taskId {
            cancelPreSessionLiveActivity(for: taskId)

            #if canImport(ActivityKit) && os(iOS)
            if #available(iOS 16.1, *) {
                if let activity = preSessionLiveActivity as? Activity<FocusPreSessionActivityAttributes>,
                   activity.attributes.taskId == taskId.uuidString {
                    await endPreSessionLiveActivity()
                }
            }
            #endif
        }

        var newSession = session
        newSession.startTime = Date()
        currentSession = newSession

        if session.status == .warmingUp, let warmUpDuration = session.warmUpDuration {
            timeRemaining = warmUpDuration
        } else {
            timeRemaining = session.duration
        }
        progress = 0.0

        if let taskId = session.taskId {
            await markTaskInProgress(taskId: taskId)
        }

        startTimer()
        await startLiveActivity()
        print("Focus session started: \(session.taskTitle) for \(Int(session.duration/60)) minutes")
    }

    public func pauseSession() async {
        guard var session = currentSession, session.status != .paused else { return }

        session.status = .paused
        session.pausedAt = Date()
        currentSession = session
        stopTimer()
        await updateLiveActivity()
    }

    public func resumeSession() async {
        guard var session = currentSession, session.status == .paused else { return }

        if let pausedAt = session.pausedAt {
            session.totalPausedDuration += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        }

        session.status = .running
        currentSession = session
        startTimer()
        await updateLiveActivity()
    }

    public func stopSession() async {
        guard var session = currentSession else { return }

        session.status = .cancelled
        session.endTime = Date()
        stopTimer()
        await endLiveActivity()
        saveSession(session)

        currentSession = nil
        timeRemaining = 0
        progress = 0.0
    }

    public func skipWarmUp() async {
        guard var session = currentSession, session.status == .warmingUp else { return }

        session.status = .running
        session.startTime = Date()
        currentSession = session
        timeRemaining = session.duration
        progress = 0.0
        await updateLiveActivity()
    }

    public func extendSession(by additionalTime: TimeInterval) async {
        guard var session = currentSession else { return }

        if session.status == .completed {
            session.status = .running
        }

        session.duration += additionalTime
        currentSession = session

        let elapsed = Date().timeIntervalSince(session.startTime) - session.totalPausedDuration
        timeRemaining = max(0, session.duration - elapsed)
        progress = min(1.0, elapsed / session.duration)

        if session.status == .running {
            startTimer()
        }

        await updateLiveActivity()
    }

    public func clearCompletedSession() {
        if let session = currentSession, session.status == .completed {
            currentSession = nil
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateProgress()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() async {
        guard var session = currentSession else { return }

        let elapsed = Date().timeIntervalSince(session.startTime) - session.totalPausedDuration

        if session.status == .warmingUp, let warmUpDuration = session.warmUpDuration {
            let warmUpRemaining = max(0, warmUpDuration - elapsed)
            timeRemaining = warmUpRemaining
            progress = min(1.0, elapsed / warmUpDuration)

            if warmUpRemaining <= 0 {
                session.status = .running
                session.startTime = Date()
                currentSession = session
                timeRemaining = session.duration
                progress = 0.0
            }

            await updateLiveActivity()
            return
        }

        guard session.status == .running else { return }

        let remaining = max(0, session.duration - elapsed)
        timeRemaining = remaining
        progress = min(1.0, elapsed / session.duration)

        await updateLiveActivity()

        if remaining <= 0 {
            await completeSession()
        }
    }

    private func completeSession() async {
        guard var session = currentSession else { return }

        session.status = .completed
        session.endTime = Date()
        stopTimer()
        await endLiveActivity(finalStatus: "Completed!")
        saveSession(session)

        currentSession = session
        timeRemaining = 0
        progress = 1.0
    }

    // MARK: - Live Activity (Active Session)

    private func startLiveActivity() async {
        #if canImport(ActivityKit) && os(iOS)
        guard let session = currentSession else { return }

        if #available(iOS 16.1, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

            let attributes = FocusTimerActivityAttributes(
                sessionId: session.id.uuidString,
                taskTitle: session.taskTitle,
                duration: session.duration
            )

            let initialState = FocusTimerActivityAttributes.ContentState(
                timeRemaining: session.duration,
                progress: 0.0,
                status: session.status == .warmingUp ? .warmingUp : .running
            )

            do {
                let content = ActivityContent(state: initialState, staleDate: nil)
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                liveActivity = activity
                print("Live Activity started for focus session: \(activity.id)")
            } catch {
                print("Error starting focus Live Activity: \(error)")
            }
        }
        #endif
    }

    private func updateLiveActivity() async {
        #if canImport(ActivityKit) && os(iOS)
        guard let session = currentSession else { return }

        if #available(iOS 16.1, *) {
            guard let activity = liveActivity as? Activity<FocusTimerActivityAttributes> else { return }

            let status: FocusTimerActivityAttributes.ContentState.FocusStatus
            switch session.status {
            case .warmingUp: status = .warmingUp
            case .running:   status = .running
            case .paused:    status = .paused
            case .completed: status = .completed
            case .cancelled: status = .completed
            }

            let newState = FocusTimerActivityAttributes.ContentState(
                timeRemaining: timeRemaining,
                progress: progress,
                status: status
            )

            let content = ActivityContent(state: newState, staleDate: nil)
            await activity.update(content)
        }
        #endif
    }

    private func endLiveActivity(finalStatus: String = "Ended") async {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            guard let activity = liveActivity as? Activity<FocusTimerActivityAttributes> else { return }

            let finalState = FocusTimerActivityAttributes.ContentState(
                timeRemaining: 0,
                progress: 1.0,
                status: .completed
            )

            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
            liveActivity = nil
        }
        #endif
    }

    // MARK: - Pre-Session Live Activity

    public func schedulePreSessionLiveActivity(for task: TaskEvent) async {
        guard let startDate = task.startDate else {
            print("Cannot schedule pre-session: task has no startDate")
            return
        }

        let now = Date()
        let fiveMinutesBefore = startDate.addingTimeInterval(-5 * 60)
        let timeUntilPreSession = fiveMinutesBefore.timeIntervalSince(now)

        if timeUntilPreSession <= 0 {
            if startDate > now {
                await startPreSessionLiveActivity(for: task)
            } else {
                print("Task startDate is in the past, not scheduling pre-session")
            }
            return
        }

        cancelPreSessionLiveActivity(for: task.id)

        let timer = Timer.scheduledTimer(withTimeInterval: timeUntilPreSession, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.startPreSessionLiveActivity(for: task)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        preSessionScheduledTimers[task.id] = timer

        print("Pre-session Live Activity scheduled for task '\(task.title)' at \(fiveMinutesBefore)")
    }

    private func startPreSessionLiveActivity(for task: TaskEvent) async {
        #if canImport(ActivityKit) && os(iOS)
        guard let startDate = task.startDate else { return }

        if #available(iOS 16.1, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

            await endPreSessionLiveActivity()

            let attributes = FocusPreSessionActivityAttributes(
                taskId: task.id.uuidString,
                taskTitle: task.title,
                scheduledStartDate: startDate,
                duration: task.duration
            )

            let timeUntilStart = max(0, startDate.timeIntervalSinceNow)
            let initialState = FocusPreSessionActivityAttributes.ContentState(
                timeUntilStart: timeUntilStart,
                canStart: true
            )

            do {
                let content = ActivityContent(state: initialState, staleDate: nil)
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                preSessionLiveActivity = activity

                startPreSessionUpdateTimer(startDate: startDate)

                print("Pre-session Live Activity started for task: \(task.title)")
            } catch {
                print("Error starting pre-session Live Activity: \(error)")
            }
        }
        #endif
    }

    private func startPreSessionUpdateTimer(startDate: Date) {
        stopPreSessionUpdateTimer()

        preSessionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePreSessionLiveActivity(startDate: startDate)
            }
        }

        if let timer = preSessionUpdateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopPreSessionUpdateTimer() {
        preSessionUpdateTimer?.invalidate()
        preSessionUpdateTimer = nil
    }

    private func updatePreSessionLiveActivity(startDate: Date) async {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            guard let activity = preSessionLiveActivity as? Activity<FocusPreSessionActivityAttributes> else { return }

            let timeUntilStart = max(0, startDate.timeIntervalSinceNow)

            if timeUntilStart <= 0 {
                await endPreSessionLiveActivity()
                return
            }

            let newState = FocusPreSessionActivityAttributes.ContentState(
                timeUntilStart: timeUntilStart,
                canStart: true
            )

            let content = ActivityContent(state: newState, staleDate: nil)
            await activity.update(content)
        }
        #endif
    }

    private func endPreSessionLiveActivity() async {
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            guard let activity = preSessionLiveActivity as? Activity<FocusPreSessionActivityAttributes> else { return }

            stopPreSessionUpdateTimer()

            let finalState = FocusPreSessionActivityAttributes.ContentState(
                timeUntilStart: 0,
                canStart: false
            )

            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)

            preSessionLiveActivity = nil
            print("Pre-session Live Activity ended")
        }
        #endif
    }

    public func cancelPreSessionLiveActivity(for taskId: UUID) {
        if let timer = preSessionScheduledTimers[taskId] {
            timer.invalidate()
            preSessionScheduledTimers.removeValue(forKey: taskId)
        }

        Task { @MainActor in
            #if canImport(ActivityKit) && os(iOS)
            if #available(iOS 16.1, *) {
                if let activity = preSessionLiveActivity as? Activity<FocusPreSessionActivityAttributes>,
                   activity.attributes.taskId == taskId.uuidString {
                    await endPreSessionLiveActivity()
                }
            }
            #endif
        }
    }

    private func startSessionFromPreSession(taskId: UUID, taskTitle: String, duration: TimeInterval?) async {
        await endPreSessionLiveActivity()

        guard let modelContext else {
            print("No modelContext available to fetch task")
            return
        }

        do {
            let fetchDescriptor = FetchDescriptor<TaskEvent>(
                predicate: #Predicate { task in
                    task.id == taskId
                }
            )

            let tasks = try modelContext.fetch(fetchDescriptor)

            guard let task = tasks.first else {
                print("Task not found with id: \(taskId)")
                return
            }

            let sessionDuration: TimeInterval
            if let taskDuration = task.duration, taskDuration > 0 {
                sessionDuration = taskDuration
            } else if let estimatedDuration = task.estimatedDuration, estimatedDuration > 0 {
                sessionDuration = estimatedDuration
            } else {
                sessionDuration = 25 * 60 // Default 25 minutes
            }

            let session = FocusSession(
                taskId: task.id,
                taskTitle: task.title,
                duration: sessionDuration,
                warmUpDuration: nil,
                startTime: Date(),
                status: .running
            )

            await startSession(session)
        } catch {
            print("Error fetching task for pre-session start: \(error)")
        }
    }

    // MARK: - Persistence

    private func saveSession(_ session: FocusSession) {
        guard let modelContext else { return }
        let elapsed = (session.endTime ?? Date()).timeIntervalSince(session.startTime) - session.totalPausedDuration
        let stored = StoredFocusSession(
            id: session.id,
            taskId: session.taskId,
            taskTitle: session.taskTitle,
            duration: session.duration,
            startTime: session.startTime,
            endTime: session.endTime ?? Date(),
            completedDuration: min(elapsed, session.duration),
            wasCompleted: session.status == .completed
        )
        modelContext.insert(stored)
        try? modelContext.save()
    }

    // MARK: - Task Status

    private func markTaskInProgress(taskId: UUID) async {
        guard let modelContext else { return }
        do {
            let descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == taskId })
            guard let task = try modelContext.fetch(descriptor).first else { return }

            if let taskSyncService {
                try await taskSyncService.updateTaskStatus(task, to: .inProgress, modelContext: modelContext)
            } else {
                task.statusEnum = .inProgress
                task.updatedAt = Date()
                try modelContext.save()
            }
        } catch {
            print("Error marking task in progress: \(error)")
        }
    }
}
