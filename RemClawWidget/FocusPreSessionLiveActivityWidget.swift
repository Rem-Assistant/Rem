import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct FocusPreSessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusPreSessionActivityAttributes.self) { context in
            FocusPreSessionLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AppIconView(size: 24, cornerRadius: 8)
                        .padding(.leading, 8)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Spacer()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("UPCOMING FOCUS")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))

                                Text(context.attributes.taskTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }

                            Spacer()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("STARTS IN")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))

                                Text(FocusPreSessionHelpers.timeUntilStartString(from: context.state.timeUntilStart))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                        }

                        if context.state.canStart {
                            Link(destination: FocusDeepLinkHelper.startFromPreSessionURL(
                                taskId: context.attributes.taskId,
                                taskTitle: context.attributes.taskTitle,
                                duration: context.attributes.duration
                            )) {
                                HStack {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Start Focus Session")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                AppIconView(size: 16, cornerRadius: 4)
            } compactTrailing: {
                Text(FocusPreSessionHelpers.timeUntilStartString(from: context.state.timeUntilStart))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "clock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Lock Screen View

@available(iOS 16.1, *)
private struct FocusPreSessionLockScreenView: View {
    let context: ActivityViewContext<FocusPreSessionActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        AppIconView(size: 20, cornerRadius: 8)

                        Text("UPCOMING FOCUS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text(context.attributes.taskTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("STARTS IN")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))

                    Text(FocusPreSessionHelpers.timeUntilStartString(from: context.state.timeUntilStart))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                Text(scheduledTimeString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            if context.state.canStart {
                Link(destination: FocusDeepLinkHelper.startFromPreSessionURL(
                    taskId: context.attributes.taskId,
                    taskTitle: context.attributes.taskTitle,
                    duration: context.attributes.duration
                )) {
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Start Focus Session")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(10)
                }
            }
        }
        .padding(16)
    }

    private var scheduledTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: context.attributes.scheduledStartDate)
    }
}

// MARK: - Helpers

@available(iOS 16.1, *)
enum FocusPreSessionHelpers {
    static func timeUntilStartString(from timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        guard totalSeconds > 0 else {
            return "Now"
        }

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: ":%02d", seconds)
        }
    }
}

#else

struct FocusPreSessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "focusPreSessionLiveActivityFallback", provider: FallbackTimelineProvider()) { _ in
            Text("Focus")
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
