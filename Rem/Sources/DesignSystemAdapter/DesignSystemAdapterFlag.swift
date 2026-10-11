import Foundation

/// The one DEBUG launch flag behind every design-system surface (`Rem/Sources/DesignSystemAdapter/`):
/// ordinary and task chat (`RemChatScreenAdapter`), Agent activity (from the chat header) and the Inbox
/// (`RemInboxScreenAdapter`). Release builds never read it and always use the classic surfaces.
/// `nonisolated` (the app module defaults to `@MainActor`): plain constants, readable anywhere.
nonisolated enum DesignSystemAdapterFlag {
    /// Product → Scheme → Edit Scheme → Run → Arguments.
    static let launchArgument = "--rem-ds-chat"

    static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        false
        #endif
    }()
}
