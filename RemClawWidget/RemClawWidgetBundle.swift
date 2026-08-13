import SwiftUI
import WidgetKit

@main
struct RemClawWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceSessionLiveActivityWidget()
        VoiceSessionControlWidget()
        FocusTimerLiveActivityWidget()
        FocusPreSessionLiveActivityWidget()
    }
}
