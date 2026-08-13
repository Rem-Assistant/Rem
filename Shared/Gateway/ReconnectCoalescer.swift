import Foundation

/// Coalesces gateway reconnect requests so that independent triggers — a
/// background→foreground flap, a keepalive probe, the grace-period retry, the
/// exponential-backoff ladder — cannot stack N concurrent reconnects on top of
/// one another.
///
/// Each stacked reconnect opens a fresh node+operator WebSocket pair, so
/// uncoordinated triggers are the mechanism behind the observed connection
/// churn ("~8 health probes/sec across ~4 live sockets" while the Fly machine
/// was healthy). This value type is the single "one reconnect owner at a time"
/// gate the session manager consults before starting one.
///
/// Design invariants:
/// - **Self-expiring, never wedging.** `begin` refuses a new reconnect only
///   while one is genuinely in flight AND within `safetyExpiry` of when it
///   started. If a reconnect task dies without calling `end()`, the next
///   request past `safetyExpiry` is admitted — a stuck flag can never
///   permanently block reconnection (the failure mode we must avoid: a guard
///   that deadlocks a legitimate reconnect).
/// - **Two entry classes.** Manual / foreground reconnects pass
///   `debounce: true`, adding a short window so a rapid flap collapses to a
///   single reconnect. The backoff-ladder / keepalive path passes
///   `debounce: false` so a scheduled retry after a sub-`debounceWindow` backoff
///   isn't swallowed — only a genuinely in-flight reconnect blocks it.
///
/// Pure value type: all timing is injected via `now` (a
/// `CFAbsoluteTimeGetCurrent()`-domain value), so the predicate is unit-tested
/// without a real clock.
///
/// Release is **generation-guarded** for reclaim-safety: `begin` returns an
/// opaque token, and `end(token)` frees the slot only if that token still owns
/// it. So if a competing reconnect claims the slot between an owner settling and
/// its (now-stale) `end` running, the stale `end` is a no-op and can't free the
/// freshly-claimed slot — no transient double-reconnect.
struct ReconnectCoalescer {
    /// True once `begin` has admitted a reconnect and before the matching
    /// `end(token)` / `reset()`.
    private(set) var inFlight = false

    /// Timestamp of the most recently admitted reconnect (same domain as the
    /// `now` passed to `begin`).
    private(set) var lastStart: CFAbsoluteTime = 0

    /// Monotonic ownership counter. Bumped on every admitted `begin`; `end`
    /// releases only when the caller's token equals this.
    private var generation: UInt64 = 0

    /// A reconnect held in-flight longer than this is assumed dead, so a new
    /// one may proceed. Longer than one full connect attempt (a ~10s connect
    /// timeout plus disconnect) but short enough to self-heal well within a
    /// user's session.
    let safetyExpiry: CFAbsoluteTime

    /// Rapid manual/foreground triggers within this window collapse to one
    /// reconnect. Kept short so a deliberate re-tap after a pause still works.
    let debounceWindow: CFAbsoluteTime

    init(safetyExpiry: CFAbsoluteTime = 30, debounceWindow: CFAbsoluteTime = 3) {
        self.safetyExpiry = safetyExpiry
        self.debounceWindow = debounceWindow
    }

    /// Attempt to claim the single reconnect slot.
    ///
    /// - Parameters:
    ///   - now: current time in the `CFAbsoluteTimeGetCurrent()` domain.
    ///   - debounce: `true` for user/foreground-initiated reconnects (adds the
    ///     short flap-collapse window on top of the in-flight guard); `false`
    ///     for the backoff-ladder / keepalive path (in-flight guard only).
    /// - Returns: a non-nil ownership token (and marks the slot in-flight) if a
    ///   reconnect may start now; `nil` if the caller should skip because one is
    ///   already owned or the trigger was debounced. Pass the token to
    ///   `end(_:)` when the reconnect settles.
    mutating func begin(now: CFAbsoluteTime, debounce: Bool) -> UInt64? {
        if inFlight && (now - lastStart) < safetyExpiry {
            return nil
        }
        if debounce && (now - lastStart) < debounceWindow {
            return nil
        }
        generation &+= 1
        inFlight = true
        lastStart = now
        return generation
    }

    /// Release the reconnect slot once the attempt settles — but ONLY if
    /// `token` still owns it. A stale token (a newer `begin` has since
    /// re-claimed) is a no-op, so a delayed/duplicate `end` can never free a
    /// slot it no longer owns. Safe to call more than once with the same token
    /// (the second call is a no-op once released).
    mutating func end(_ token: UInt64) {
        guard inFlight, token == generation else { return }
        inFlight = false
    }

    /// Hard reset — clears in-flight regardless of ownership. For teardown
    /// (e.g. `clearConfiguration`), not a normal settle. Bumps the generation so
    /// any outstanding token is invalidated and can't later free a new claim.
    mutating func reset() {
        inFlight = false
        generation &+= 1
    }
}
