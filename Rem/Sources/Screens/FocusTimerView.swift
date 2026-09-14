import SwiftUI
import SwiftData

@MainActor
struct FocusTimerView<Manager: FocusTimerProvider>: View {
    @ObservedObject var manager: Manager
    let session: FocusSession
    let onStartNewSession: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.taskSyncService) private var taskSyncService
    @State private var showAddTimeOptions = false
    @State private var showCompletionDialog = false
    @State private var completedSession: FocusSession?
    @State private var isDismissingCompletion = false

    init(
        manager: Manager,
        session: FocusSession,
        onStartNewSession: (() -> Void)? = nil
    ) {
        self.manager = manager
        self.session = session
        self.onStartNewSession = onStartNewSession
    }

    var body: some View {
        mainContent
            .confirmationDialog("Add Time", isPresented: $showAddTimeOptions) {
                addTimeButtons
            } message: {
                Text("How much time would you like to add to your session?")
            }
            .onChange(of: manager.currentSession?.status) { oldStatus, newStatus in
                handleStatusChange(oldStatus: oldStatus, newStatus: newStatus)
            }
            .onChange(of: manager.currentSession) { oldSession, newSession in
                handleSessionChange(oldSession: oldSession, newSession: newSession)
            }
            .onAppear {
                checkForCompletedSession()
            }
            .confirmationDialog("Session Complete", isPresented: $showCompletionDialog) {
                completionDialogButtons
            } message: {
                if completedSession != nil {
                    Text("Great work! What would you like to do next?")
                }
            }
    }

    private var mainContent: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 12) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)

                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                                .frame(width: 44, height: 44)
                        }

                        Spacer()

                        Text("Focus Session")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(DesignTokens.Color.labelPrimary)

                        Spacer()

                        Button {
                            Task {
                                await manager.stopSession()
                                dismiss()
                            }
                        } label: {
                            Text("End")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.red)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer()

                VStack(spacing: 8) {
                    Text(headerText)
                        .font(.system(size: 17))
                        .foregroundColor(DesignTokens.Color.labelSecondary)

                    Text(session.taskTitle)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if manager.currentSession?.status == .warmingUp {
                    VStack(spacing: 24) {
                        timerCircle(ringColor: DesignTokens.Color.systemOrange)

                        Button {
                            Task {
                                if let mgr = manager as? FocusSessionManager {
                                    await mgr.skipWarmUp()
                                }
                            }
                        } label: {
                            Text("Skip Warm-up")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(DesignTokens.Color.systemBlue)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    timerCircle(ringColor: progressRingColor)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        Task {
                            if manager.currentSession?.status == .paused {
                                await manager.resumeSession()
                            } else {
                                await manager.pauseSession()
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: manager.currentSession?.status == .paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20))
                            Text(manager.currentSession?.status == .paused ? "Resume" : "Pause")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DesignTokens.Color.backgroundSecondary)
                        .cornerRadius(12)
                    }

                    Button {
                        showAddTimeOptions = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 20))
                            Text("Add Time")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DesignTokens.Color.backgroundSecondary)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Timer Circle

    private func timerCircle(ringColor: Color) -> some View {
        ZStack {
            Circle()
                .stroke(DesignTokens.Color.separator, lineWidth: 24)
                .frame(width: 280, height: 280)

            Circle()
                .trim(from: 0, to: manager.progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 24, lineCap: .round))
                .frame(width: 280, height: 280)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: manager.progress)

            Text(timeString(from: manager.timeRemaining))
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .monospacedDigit()
        }
    }

    // MARK: - Dialogs

    @ViewBuilder
    private var addTimeButtons: some View {
        Button("5 minutes") { extendSession(by: 5 * 60) }
        Button("15 minutes") { extendSession(by: 15 * 60) }
        Button("30 minutes") { extendSession(by: 30 * 60) }
        Button("1 hour") { extendSession(by: 60 * 60) }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var completionDialogButtons: some View {
        if let completed = completedSession {
            Button("Mark Task Complete") {
                isDismissingCompletion = true
                let taskToComplete = completed
                completedSession = nil
                showCompletionDialog = false
                Task {
                    await markTaskComplete(for: taskToComplete)
                    manager.clearCompletedSession()
                }
            }
            Button("Add More Time") {
                showAddTimeOptions = true
            }
            Button("Start New Session") {
                isDismissingCompletion = true
                completedSession = nil
                showCompletionDialog = false
                manager.clearCompletedSession()
                dismiss()
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    onStartNewSession?()
                }
            }
            Button("Cancel", role: .cancel) {
                isDismissingCompletion = true
                completedSession = nil
                showCompletionDialog = false
                manager.clearCompletedSession()
            }
        }
    }

    // MARK: - Helpers

    private func extendSession(by additionalTime: TimeInterval) {
        Task { await manager.extendSession(by: additionalTime) }
    }

    private func handleStatusChange(oldStatus: FocusSessionStatus?, newStatus: FocusSessionStatus?) {
        guard !isDismissingCompletion else { return }
        if newStatus == .completed {
            if let completed = manager.currentSession {
                completedSession = completed
                showCompletionDialog = true
            }
        } else if oldStatus == .completed && newStatus == .running {
            showCompletionDialog = false
        }
    }

    private func handleSessionChange(oldSession: FocusSession?, newSession: FocusSession?) {
        guard !isDismissingCompletion, !showCompletionDialog else { return }
        if let oldSession, oldSession.status == .completed, newSession == nil {
            completedSession = oldSession
            showCompletionDialog = true
        }
    }

    private func checkForCompletedSession() {
        guard !isDismissingCompletion else { return }
        if let session = manager.currentSession, session.status == .completed {
            completedSession = session
            showCompletionDialog = true
        }
    }

    private func markTaskComplete(for session: FocusSession) async {
        guard let taskId = session.taskId else { return }
        let descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == taskId })
        guard let task = try? modelContext.fetch(descriptor).first else { return }

        if let taskSyncService {
            try? await taskSyncService.updateTaskStatus(task, to: .completed, modelContext: modelContext)
        } else {
            task.statusEnum = .completed
            task.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private var headerText: String {
        switch manager.currentSession?.status {
        case .warmingUp: "Warming up for"
        case .paused: "Paused session for"
        default: "Currently focusing on"
        }
    }

    private var progressRingColor: Color {
        switch manager.currentSession?.status {
        case .warmingUp: DesignTokens.Color.systemOrange
        case .paused: DesignTokens.Color.systemYellow
        default: DesignTokens.Color.systemGreen
        }
    }

    private func timeString(from timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
