import AppKit
import Foundation
import OSLog

/// Observes local key events so the push-to-talk trigger (spacebar) can drive
/// `RemMacTalkModeManager` start/stop (#321 PR 3).
///
/// Scope: **app-focus only**, using `NSEvent.addLocalMonitorForEvents`. We
/// intentionally do NOT register a global monitor — global hotkeys require
/// Accessibility permission on Mac and are out of scope per #321 PR 3 locked
/// design #5. If the Rem app is not frontmost, PTT will not fire — this
/// mirrors the "scoped to app focus" constraint called out in the orchestrator
/// brief.
///
/// We also swallow the spacebar `keyDown`/`keyUp` while voice is active in PTT
/// mode, returning `nil` from the monitor so the event doesn't propagate to
/// focused views (text fields etc.). When voice is off or mode is VAD, the
/// monitor passes the event through untouched.
///
/// Source of truth: the monitor token (`keyMonitor`). State is transient;
/// pressed state is tracked so auto-repeat `keyDown` events don't re-trigger
/// capture start.
@MainActor
final class PushToTalkKeyMonitor {
    /// Called when the PTT key goes down (first press — auto-repeat filtered).
    var onKeyDown: (() -> Void)?
    /// Called when the PTT key goes up.
    var onKeyUp: (() -> Void)?
    /// Gate set by the manager. When `false`, the monitor is a pass-through.
    /// We still keep the monitor installed so enabling doesn't require a
    /// re-install round-trip.
    var isActive: Bool = false

    private var keyMonitor: Any?
    private var isKeyHeld: Bool = false

    /// Hardcoded to spacebar per #321 PR 3 locked design #1. Configurable key
    /// binding is deliberately out of scope.
    private let keyCode: UInt16 = 49 // kVK_Space

    private let logger = Logger(subsystem: "com.remapp.rem.mac", category: "PTTKeyMonitor")

    /// Installs the local event monitor. Safe to call repeatedly — reinstall
    /// is a no-op if already installed.
    func install() {
        guard keyMonitor == nil else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        self.keyMonitor = monitor
        self.logger.info("installed PTT local key monitor (spacebar)")
    }

    /// Removes the monitor and clears transient state. Called from manager
    /// `stop()` so we don't leak monitors across voice sessions.
    func uninstall() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        isKeyHeld = false
    }

    deinit {
        // Deinit can't touch `@MainActor` state safely without a Task; callers
        // must call `uninstall()` before the instance is torn down. The
        // manager does this in `stop()`.
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Pass-through when disabled (voice off or VAD mode selected).
        guard isActive else { return event }

        // Guard against PTT being hijacked when the user is typing. If the
        // first responder is a text input, defer to the text field so the
        // user can still type a space. The app-focus scoping already limits
        // us to Rem's windows; this extra check lets users type spaces in
        // the composer even while voice is enabled.
        if Self.firstResponderIsTextInput() { return event }

        guard event.keyCode == keyCode else { return event }

        switch event.type {
        case .keyDown:
            // `isARepeat` fires keyDown repeatedly while held; we only care
            // about the initial press.
            if event.isARepeat { return nil }
            if !isKeyHeld {
                isKeyHeld = true
                onKeyDown?()
            }
            return nil // swallow so focused views don't see the space
        case .keyUp:
            if isKeyHeld {
                isKeyHeld = false
                onKeyUp?()
            }
            return nil
        default:
            return event
        }
    }

    /// Returns true if the current first responder is a text input. Mirrors
    /// the common Mac pattern for "don't hijack keys while typing."
    private static func firstResponderIsTextInput() -> Bool {
        guard let window = NSApplication.shared.keyWindow,
              let responder = window.firstResponder else { return false }
        if responder is NSTextView { return true }
        // NSTextField's field editor appears in the responder chain as an
        // NSTextView; the above covers that case. Controls that opt into
        // custom text editing can still swallow the space — acceptable.
        return false
    }
}
