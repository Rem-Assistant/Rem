import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct FocusTimerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusTimerActivityAttributes.self) { context in
            FocusTimerLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded leading: App icon
                DynamicIslandExpandedRegion(.leading) {
                    AppIconView(size: 24, cornerRadius: 8)
                        .padding(.leading, 8)
                }

                // Expanded trailing
                DynamicIslandExpandedRegion(.trailing) {
                    Spacer()
                }

                // Expanded bottom: Task info, timer, progress, controls
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Task title and time
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FOCUSING ON")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))

                                Text(context.attributes.taskTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("TIME LEFT")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))

                                Text(FocusTimerHelpers.timeString(from: context.state.timeRemaining))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                        }

                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.2))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.green)
                                    .frame(width: geometry.size.width * context.state.progress)
                            }
                        }
                        .frame(height: 6)
                        .padding(.horizontal, 4)
                    }
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                // Compact leading: App icon
                AppIconView(size: 16, cornerRadius: 4)
            } compactTrailing: {
                // Compact trailing: Timer
                Text(FocusTimerHelpers.timeString(from: context.state.timeRemaining))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            } minimal: {
                // Minimal: Timer icon with status color
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(
                        context.state.status == .running
                            ? .green
                            : .white.opacity(0.6)
                    )
            }
        }
    }
}

// MARK: - Lock Screen View

@available(iOS 16.1, *)
private struct FocusTimerLockScreenView: View {
    let context: ActivityViewContext<FocusTimerActivityAttributes>

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        AppIconView(size: 20, cornerRadius: 8)

                        Text("FOCUSING ON")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text(context.attributes.taskTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("TIME LEFT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))

                    Text(FocusTimerHelpers.timeString(from: context.state.timeRemaining))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(.green)
                        .frame(width: geometry.size.width * context.state.progress)
                }
            }
            .frame(height: 8)

            // Control buttons — use Link (deep link URL) so the action
            // is delivered to the main app via onOpenURL, not executed
            // in the widget extension process.
            HStack(spacing: 12) {
                // Pause/Resume button
                if context.state.status == .paused {
                    Link(destination: URL(string: "remclaw://focus/resume?sessionId=\(context.attributes.sessionId)")!) {
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Resume")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(10)
                    }
                } else {
                    Link(destination: URL(string: "remclaw://focus/pause?sessionId=\(context.attributes.sessionId)")!) {
                        HStack {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Pause")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(10)
                    }
                }

                // Stop button
                Link(destination: URL(string: "remclaw://focus/stop?sessionId=\(context.attributes.sessionId)")!) {
                    HStack {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Stop")
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
        .padding(16)
    }
}

// MARK: - Helpers

@available(iOS 16.1, *)
enum FocusTimerHelpers {
    static func timeString(from timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#else

struct FocusTimerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "focusTimerLiveActivityFallback", provider: FallbackTimelineProvider()) { _ in
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
