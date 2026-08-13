import SwiftUI

struct ProgressRing: View {
    let progress: Double
    let color: Color
    let size: CGFloat = 15
    let lineWidth: CGFloat = 3.5
    @State private var animatedProgress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 3)) {
                animatedProgress = progress
            }
        }
    }
}

/// Brief "done" chip. Borrows the task-event-row badge **containment**
/// (`secondarySystemBackground` fill, `CornerRadius.xlarge`) so it matches the
/// agenda badges below it — but keeps the **colored progress ring** and the
/// normal (size-17) font. Founder feedback: gray container, colored ring.
struct ProgressBadgeView: View {
    let value: Double
    let maxValue: Double
    let title: String
    let color: Color

    private var progress: Double {
        min(value / maxValue, 1)
    }

    var body: some View {
        HStack(spacing: 7) {
            ProgressRing(progress: progress, color: color)
            Text("\(Int(value)) \(title)")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(DesignTokens.Color.labelPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}
