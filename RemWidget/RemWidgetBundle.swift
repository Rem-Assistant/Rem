import SwiftUI
import WidgetKit

@main
struct RemWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceSessionLiveActivityWidget()
        VoiceSessionControlWidget()
        FocusTimerLiveActivityWidget()
        FocusPreSessionLiveActivityWidget()
    }
}
