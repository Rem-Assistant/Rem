import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
private struct AdaptiveTextWindowView: View {
    let text: String
    let isDynamicIsland: Bool

    var body: some View {
        Text(text)
            .font(.system(size: isDynamicIsland ? 15 : 16, weight: .regular))
            .foregroundColor(.white)
            .lineSpacing(2)
            .lineLimit(isDynamicIsland ? 3 : 5)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.1, *)
struct AppIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    init(size: CGFloat = 24, cornerRadius: CGFloat = 8) {
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Image("RemLogo")
            .resizable()
            .renderingMode(.original)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

@available(iOS 16.1, *)
private enum VoiceSessionHelpers {
    static func displayText(user: String?, assistant: String?) -> String? {
        let assistantTrim = assistant?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assistantTrim, !assistantTrim.isEmpty { return assistantTrim }

        let userTrim = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userTrim, !userTrim.isEmpty { return userTrim }

        return nil
    }

    static func durationString(startedAt: Date) -> String {
        let totalSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func actionURL(isActive: Bool) -> URL {
        URL(string: isActive ? "remclaw://voice/stop" : "remclaw://voice/start")!
    }

    static let openURL = URL(string: "remclaw://voice/open")!
}

@available(iOS 16.1, *)
private struct VoiceSessionLockScreenView: View {
    let context: ActivityViewContext<VoiceSessionActivityAttributes>

    private var isActive: Bool {
        context.state.isListening || context.state.isSpeaking
    }

    private var displayText: String? {
        VoiceSessionHelpers.displayText(
            user: context.state.latestUserMessage,
            assistant: context.state.latestAssistantMessage
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconView(size: displayText == nil ? 32 : 20, cornerRadius: 8)

                if context.state.status == "Ready to chat" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.status)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)

                        Text(VoiceSessionHelpers.durationString(startedAt: context.state.startedAt))
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.65))
                    }
                } else {
                    Text(context.state.status.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .tracking(0.5)
                }

                Spacer()

                Link(destination: VoiceSessionHelpers.actionURL(isActive: isActive)) {
                    Text(isActive ? "End" : "Start")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
            }

            if let displayText {
                AdaptiveTextWindowView(text: displayText, isDynamicIsland: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .activityBackgroundTint(Color(.systemBackground))
        .widgetURL(VoiceSessionHelpers.openURL)
    }
}

@available(iOS 16.1, *)
struct VoiceSessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceSessionActivityAttributes.self) { context in
            VoiceSessionLockScreenView(context: context)
        } dynamicIsland: { context in
            let isActive = context.state.isListening || context.state.isSpeaking
            let displayText = VoiceSessionHelpers.displayText(
                user: context.state.latestUserMessage,
                assistant: context.state.latestAssistantMessage
            )

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if displayText != nil {
                        AppIconView(size: 24, cornerRadius: 8)
                            .padding(.leading, 8)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(VoiceSessionHelpers.durationString(startedAt: context.state.startedAt))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if let displayText {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(context.state.status.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.5))
                                    .tracking(0.5)

                                AdaptiveTextWindowView(text: displayText, isDynamicIsland: true)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .id(displayText)
                            }

                            Link(destination: VoiceSessionHelpers.actionURL(isActive: isActive)) {
                                Text(isActive ? "End" : "Start")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.bottom, 6)
                    } else {
                        HStack(spacing: 8) {
                            AppIconView(size: 32, cornerRadius: 8)

                            if context.state.status == "Ready to chat" {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(context.state.status)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)

                                    Text(VoiceSessionHelpers.durationString(startedAt: context.state.startedAt))
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            } else {
                                Text(context.state.status.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.5))
                                    .tracking(0.5)
                            }

                            Spacer()

                            Link(destination: VoiceSessionHelpers.actionURL(isActive: isActive)) {
                                Text(isActive ? "End" : "Start")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.bottom)
                    }
                }
            } compactLeading: {
                AppIconView(size: 16, cornerRadius: 4)
            } compactTrailing: {
                Text(VoiceSessionHelpers.durationString(startedAt: context.state.startedAt))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .widgetURL(VoiceSessionHelpers.openURL)
        }
    }
}

#else
struct VoiceSessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "voiceSessionLiveActivityFallback", provider: FallbackTimelineProvider()) { _ in
            Text("Voice")
        }
    }

    private struct FallbackEntry: TimelineEntry { let date: Date }
    private struct FallbackTimelineProvider: TimelineProvider {
        func placeholder(in context: Context) -> FallbackEntry { FallbackEntry(date: Date()) }
        func getSnapshot(in context: Context, completion: @escaping (FallbackEntry) -> Void) {
            completion(FallbackEntry(date: Date()))
        }
        func getTimeline(in context: Context, completion: @escaping (Timeline<FallbackEntry>) -> Void) {
            completion(Timeline(entries: [FallbackEntry(date: Date())], policy: .never))
        }
    }
}
#endif
