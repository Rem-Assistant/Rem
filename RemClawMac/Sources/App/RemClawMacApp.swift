import AppKit
import SwiftUI
import Sparkle

@main
struct RemClawMacApp: App {
    @State private var model = MacAppModel.shared

    private static var isSettingsFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-settings-fixture")
        #else
        false
        #endif
    }

    private static var isConnectorsFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-connectors-fixture")
        #else
        false
        #endif
    }

    private static var isSkillProviderRequirementsFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-skill-provider-requirements-fixture")
        #else
        false
        #endif
    }

    private static var isTaskDetailChromeFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-task-detail-chrome-fixture")
        #else
        false
        #endif
    }

    private static var isPermissionsFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-permissions-fixture")
        #else
        false
        #endif
    }

    private static var isSignInFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-mac-sign-in-fixture")
        #else
        false
        #endif
    }

    private static var isSessionPreviewFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-session-preview-fixture")
        #else
        false
        #endif
    }

    private static var isCollaborationFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-collaboration-fixture")
            || ProcessInfo.processInfo.arguments.contains("--rem-collaboration-empty")
        #else
        false
        #endif
    }

    private static var signInFixtureLaunchState: MacLaunchState? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument == "--rem-mac-launch-state",
               arguments.indices.contains(index + 1) {
                return MacLaunchState(launchArgument: arguments[index + 1])
            }

            let prefix = "--rem-mac-launch-state="
            if argument.hasPrefix(prefix) {
                return MacLaunchState(launchArgument: String(argument.dropFirst(prefix.count)))
            }
        }
        return nil
        #else
        nil
        #endif
    }

    @MainActor
    init() {
        #if DEBUG
        if Self.isSignInFixture {
            MacSignInFixtureWindowPresenter.present(
                launchState: Self.signInFixtureLaunchState,
                model: .shared
            )
            return
        }
        #endif

        guard !Self.isSettingsFixture
            && !Self.isConnectorsFixture
            && !Self.isSkillProviderRequirementsFixture
            && !Self.isTaskDetailChromeFixture
            && !Self.isPermissionsFixture
            && !Self.isSessionPreviewFixture
            && !Self.isCollaborationFixture
        else { return }
        MacMainWindowPresenter.prepareForLaunch()
        MacAppMenuInstaller.install()
        MacMainWindowPresenter.presentAfterLaunch(model: .shared)
    }

    var body: some Scene {
        WindowGroup("Rem", id: MacMainWindowPresenter.mainWindowIdentifier) {
            #if DEBUG
            if Self.isSessionPreviewFixture {
                SharedSessionPreviewFixtureView()
            } else if Self.isSettingsFixture {
                SharedSettingsFixtureView()
            } else if Self.isConnectorsFixture {
                SharedConnectorsFixtureView()
            } else if Self.isSkillProviderRequirementsFixture {
                SharedSkillProviderRequirementsFixtureView()
            } else if Self.isTaskDetailChromeFixture {
                MacTaskDetailChromeFixtureView()
            } else if Self.isCollaborationFixture {
                MacTaskCollaborationFixtureView()
            } else if Self.isPermissionsFixture {
                NavigationStack {
                    PermissionsTab(calendarConnectorDestination: {
                        AnyView(SharedComposioConnectionsView(service: MockComposioService()))
                    })
                }
                .frame(width: 520, height: 640)
            } else if Self.isSignInFixture {
                EmptyView()
            } else {
                MacMainWindowRootView(model: model)
                    .environmentBanner(backendURL: model.sessionManager.backendURL ?? Bundle.main.infoDictionary?["APIBaseURL"] as? String ?? "")
            }
            #else
            MacMainWindowRootView(model: model)
            #endif
        }
        .defaultSize(width: 600, height: 460)
        .defaultLaunchBehavior(.presented)
        .commands {
            MacSettingsCommands()
            SidebarCommands()
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(model.sessionManager)
                .environment(\.localGateway, model.localGateway)
        } label: {
            Label("Rem", systemImage: model.sessionManager.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

    }
}

#if DEBUG
@MainActor
private enum MacSignInFixtureWindowPresenter {
    private static var window: NSWindow?

    static func present(launchState: MacLaunchState?, model: MacAppModel) {
        DispatchQueue.main.async {
            let content = MacSignInView(launchStateOverride: launchState)
                .environment(model.sessionManager)
                .environment(\.localGateway, model.localGateway)

            let hostingController = NSHostingController(rootView: content)
            let fixtureWindow = NSWindow(contentViewController: hostingController)
            fixtureWindow.title = "Rem Sign In Fixture"
            fixtureWindow.setContentSize(NSSize(width: 600, height: 520))
            fixtureWindow.minSize = NSSize(width: 520, height: 460)
            fixtureWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            fixtureWindow.isReleasedWhenClosed = false
            fixtureWindow.center()
            fixtureWindow.makeKeyAndOrderFront(nil)
            fixtureWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window = fixtureWindow
        }
    }
}
#endif

private struct MacSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                MacMainWindowPresenter.openMainWindow(
                    route: .settings,
                    openWindow: openWindow,
                    hideNativeSettings: true
                )
            } label: {
                Label("Settings...", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
private enum MacAppMenuInstaller {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        Task { @MainActor in
            replaceSettingsItemIfNeeded()
        }

        let names: [Notification.Name] = [
            NSApplication.didFinishLaunchingNotification,
            NSApplication.didBecomeActiveNotification,
            NSMenu.didAddItemNotification
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    replaceSettingsItemIfNeeded()
                }
            }
        }
    }

    private static func replaceSettingsItemIfNeeded() {
        guard let appMenu = appMenu(),
              let firstSettingsIndex = settingsItemIndexes(in: appMenu).first
        else { return }

        let settingsIndexes = settingsItemIndexes(in: appMenu)
        if settingsIndexes.count == 1,
           appMenu.item(at: firstSettingsIndex)?.target === MacSettingsMenuAction.shared {
            return
        }

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(MacSettingsMenuAction.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = MacSettingsMenuAction.shared
        settingsItem.keyEquivalentModifierMask = [.command]

        guard let image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings") else { return }
        image.isTemplate = true
        settingsItem.image = image

        for index in settingsIndexes.reversed() {
            appMenu.removeItem(at: index)
        }
        appMenu.insertItem(settingsItem, at: firstSettingsIndex)
    }

    private static func appMenu() -> NSMenu? {
        NSApplication.shared.mainMenu?.items.first?.submenu
    }

    private static func settingsItemIndexes(in menu: NSMenu) -> [Int] {
        menu.items.indices.filter { menu.items[$0].title == "Settings..." }
    }
}

@MainActor
private final class MacSettingsMenuAction: NSObject {
    static let shared = MacSettingsMenuAction()

    @objc func openSettings(_ sender: Any?) {
        MacMainWindowPresenter.openMainWindow(
            route: .settings,
            hideNativeSettings: true
        )
    }
}
