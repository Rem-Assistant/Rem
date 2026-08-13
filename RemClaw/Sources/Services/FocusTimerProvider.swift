import Foundation

@MainActor
public protocol FocusTimerProvider: ObservableObject {
    var currentSession: FocusSession? { get }
    var timeRemaining: TimeInterval { get }
    var progress: Double { get }

    func pauseSession() async
    func resumeSession() async
    func stopSession() async
    func extendSession(by additionalTime: TimeInterval) async
    func clearCompletedSession()
}
