import AppIntents
import Foundation
import WidgetKit

struct ToggleVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Voice Session"
    static var description = IntentDescription("Start or stop a Rem voice session")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Is Active")
    var isActive: Bool

    init() {
        self.isActive = false
    }

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func perform() async throws -> some IntentResult {
        let action = isActive ? "stop" : "start"
        VoiceSessionSharedState.pendingAction = action

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://voice/\(action)")!
        )

        ControlCenter.shared.reloadControls(
            ofKind: "com.remapp.rem.VoiceSessionControl"
        )

        return .result()
    }
}

struct StartVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Session"
    static var description = IntentDescription("Start a new Rem voice session")
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        VoiceSessionSharedState.pendingAction = "start"

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://voice/start")!
        )

        return .result()
    }
}

struct StopVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Voice Session"
    static var description = IntentDescription("Stop the current Rem voice session")
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        VoiceSessionSharedState.pendingAction = "stop"

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://voice/stop")!
        )

        ControlCenter.shared.reloadControls(
            ofKind: "com.remapp.rem.VoiceSessionControl"
        )

        return .result()
    }
}
