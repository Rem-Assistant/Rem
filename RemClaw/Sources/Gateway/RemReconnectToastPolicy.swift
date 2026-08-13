import Foundation

/// Decides whether a recovery back to `.connected` should surface a transient
/// "Reconnected" toast (`RemToast`).
///
/// The rule has two gates, both required:
///
/// 1. **The user actually SAW the disconnect.** We only toast when the connection
///    reached the *visible* unreachable/backoff state (`RemGatewaySessionManager`
///    sets `sawVisibleDisconnect` in `scheduleReconnect()` — the single chokepoint
///    for "we're now showing the Unreachable banner and backing off"). We do NOT
///    toast for the soft grace-period blip: the first drop of a cycle is masked as
///    `.connecting` ("Connecting…") and reconnects immediately without ever
///    entering backoff, so a transient Fly-proxy / wifi-handoff / background-resume
///    flap never alarms the user and never toasts. Confirming a recovery the user
///    was never shown a problem for would be noise.
///
///    This is a boolean flag rather than a `reconnectAttempt` threshold on purpose:
///    `reconnectDroppedSessions` zeroes `reconnectAttempt` the instant the node
///    socket reconnects — which can land *before* the `.connected` callback reads
///    it — so the attempt counter is unreliable at the moment we'd gate on it. The
///    flag is set at the visible-backoff chokepoint and cleared on connect, so it
///    is race-free.
///
/// 2. **Debounce.** On flaky connectivity a stretch of drop→recover cycles would
///    otherwise stack a "Reconnected" toast per cycle. We collapse them to at most
///    one toast per `debounceWindow` by comparing against the last toast time.
enum RemReconnectToastPolicy {
    /// Suppress a second "Reconnected" toast if the last one fired within this
    /// window. Long enough that a flaky stretch reads as one recovery, short enough
    /// that a genuinely separate outage minutes later still confirms.
    static let debounceWindow: TimeInterval = 30

    /// - Parameters:
    ///   - sawVisibleDisconnect: whether the connection reached the visible
    ///     unreachable/backoff state during this disconnect cycle (not the soft
    ///     grace blip).
    ///   - now: the recovery instant.
    ///   - lastToastAt: when a "Reconnected" toast last fired (`nil` if never).
    /// - Returns: `true` iff both gates pass.
    static func shouldToast(
        sawVisibleDisconnect: Bool,
        now: Date,
        lastToastAt: Date?
    ) -> Bool {
        guard sawVisibleDisconnect else { return false }
        if let lastToastAt, now.timeIntervalSince(lastToastAt) < debounceWindow {
            return false
        }
        return true
    }
}
