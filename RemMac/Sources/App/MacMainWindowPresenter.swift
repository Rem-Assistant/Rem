import AppKit
import SwiftUI

@MainActor
enum MacMainWindowPresenter {
    static let mainWindowIdentifier = "main"
    static let mainWindowTitle = "Rem"
    private static var appKitWindow: NSWindow?

    static func prepareForLaunch() {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // #500: stale SwiftUI/AppKit state can restore no main scene at all.
        // Drop only Rem's saved state so each launch can present a Dock window.
        clearSavedWindowState()
    }

    static func presentAfterLaunch(model: MacAppModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ensureMainWindow(model: model)
        }
    }

    static func openMainWindow(
        route: MainWindowScreenRoute,
        openWindow: OpenWindowAction,
        hideNativeSettings: Bool = false
    ) {
        if mainWindow == nil {
            openWindow(id: mainWindowIdentifier)
        }

        DispatchQueue.main.async {
            if mainWindow == nil {
                ensureMainWindow(model: .shared)
            }

            NotificationCenter.default.post(
                name: .openMainWindowScreen,
                object: route.rawValue
            )
            bringMainWindowToFront()

            if hideNativeSettings {
                hideNativeSettingsWindows()
            }
        }
    }

    static func openMainWindow(
        route: MainWindowScreenRoute,
        hideNativeSettings: Bool = false
    ) {
        ensureMainWindow(model: .shared)

        NotificationCenter.default.post(
            name: .openMainWindowScreen,
            object: route.rawValue
        )
        bringMainWindowToFront()

        if hideNativeSettings {
            hideNativeSettingsWindows()
        }
    }

    @discardableResult
    static func bringMainWindowToFront() -> Bool {
        guard let window = mainWindow else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static func hideNativeSettingsWindows() {
        for window in NSApp.windows where window !== mainWindow {
            if window.identifier?.rawValue == MacNativeSettingsTab.fallbackWindowIdentifier
                || MacNativeSettingsTab.legacyWindowTitles.contains(window.title) {
                window.orderOut(nil)
            }
        }
    }

    static func ensureMainWindow(model: MacAppModel) {
        if bringMainWindowToFront() {
            return
        }

        let window = createMainWindow(model: model)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func createMainWindow(model: MacAppModel) -> NSWindow {
        if let appKitWindow {
            return appKitWindow
        }

        let hostingController = NSHostingController(rootView: MacMainWindowRootView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = mainWindowTitle
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 700, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        configureMainWindow(window)
        window.center()
        appKitWindow = window
        return window
    }

    static var mainWindow: NSWindow? {
        if let explicitWindow = NSApp.windows.first(where: isExplicitMainWindowCandidate) {
            configureMainWindow(explicitWindow)
            return explicitWindow
        }

        if let recoveredWindow = NSApp.windows.first(where: isRecoverableMainWindow) {
            configureMainWindow(recoveredWindow)
            return recoveredWindow
        }

        return nil
    }

    private static func isExplicitMainWindowCandidate(_ window: NSWindow) -> Bool {
        let isTaggedAsMain = window.identifier?.rawValue == mainWindowIdentifier
            || window.title == mainWindowTitle
        return isTaggedAsMain && isMainWindowSized(window)
    }

    private static func isRecoverableMainWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible,
              !window.isMiniaturized,
              window.level == .normal
        else { return false }

        return isMainWindowSized(window)
    }

    private static func isMainWindowSized(_ window: NSWindow) -> Bool {
        guard !window.isMiniaturized,
              window.level == .normal
        else { return false }

        let size = window.frame.size
        return size.width >= 600 && size.height >= 400
    }

    static func configureMainWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(mainWindowIdentifier)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = MacMainWindowCloseDelegate.shared
    }

    private static func clearSavedWindowState() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let relativePaths = [
            "Library/Saved Application State/\(bundleIdentifier).savedState",
            "Library/Containers/\(bundleIdentifier)/Data/Library/Saved Application State/\(bundleIdentifier).savedState"
        ]

        for relativePath in relativePaths {
            let url = home.appendingPathComponent(relativePath)
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
final class MacMainWindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = MacMainWindowCloseDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct MacMainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: view.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        MacMainWindowPresenter.configureMainWindow(window)
    }
}
