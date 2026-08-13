import SwiftUI

/// Reusable card row for `SharedChooseGatewayView` and platform-specific
/// chooser flows. Extracted from `RemClawMac/Sources/UI/GatewayChoiceView.swift`
/// so iOS and Mac render the same card.
struct SharedGatewayChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(disabled ? .secondary : .blue)
                .frame(width: 40)

            VStack(alignment: .leading) {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(disabled ? .secondary : .primary)

                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            if disabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(disabled ? 0.02 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview("Gateway Choice Card — Recommended") {
    SharedGatewayChoiceCard(
        icon: "cloud.fill",
        title: "Deploy to Cloud",
        subtitle: "Create your Rem cloud gateway on Fly.io. Reachable from any device.",
        badge: "Recommended"
    )
    .padding()
}

#Preview("Gateway Choice Card — Current") {
    SharedGatewayChoiceCard(
        icon: "cloud.fill",
        title: "Cloud Gateway Connected",
        subtitle: "Your existing cloud gateway is already connected.",
        badge: "Current",
        disabled: true
    )
    .padding()
}
#endif
