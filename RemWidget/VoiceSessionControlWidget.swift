import AppIntents
import SwiftUI
import WidgetKit

struct VoiceSessionControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.remapp.rem.VoiceSessionControl",
            provider: Provider()
        ) { isActive in
            ControlWidgetButton(action: ToggleVoiceSessionIntent(isActive: isActive)) {
                Label(
                    isActive ? "End Chat" : "Voice Chat",
                    systemImage: "message.badge.waveform.fill"
                )
            }
        }
        .displayName("Voice Chat")
        .description("Start or stop a Rem voice session from your Lock Screen")
    }
}

extension VoiceSessionControlWidget {
    struct Provider: ControlValueProvider {
        var previewValue: Bool {
            false
        }

        func currentValue() async throws -> Bool {
            VoiceSessionSharedState.isSessionActive
        }
    }
}
