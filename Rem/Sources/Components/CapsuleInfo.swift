import SwiftUI

/// Brief summary chip. Borrows the task-event-row badge **containment**
/// (`secondarySystemBackground` fill, `CornerRadius.xlarge`) so the chips read
/// as the same badge family as the agenda rows below them — but keeps each
/// bucket's **colored glyph** (red blocked / orange overdue / blue today) so the
/// summary stays scannable. Founder feedback: gray container, colored icons,
/// normal (size-17) font.
struct CapsuleInfo: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(DesignTokens.Color.labelPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(DesignTokens.CornerRadius.xlarge)
    }
}
