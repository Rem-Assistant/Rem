import SwiftUI

// MARK: - Contained Icon

/// App-wide iOS Settings-style icon tile: rounded rect + white SF Symbol.
///
/// Use this anywhere a row needs a compact branded/icon color well. `SettingsIcon`
/// remains as a compatibility alias for older call sites, but new shared UI
/// should prefer `ContainedIcon`.
struct ContainedIcon: View {
    let icon: String
    var color: Color = .blue

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 28, height: 28)
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

typealias SettingsIcon = ContainedIcon

// MARK: - OpenClaw Runtime Icon

/// The downloaded OpenClaw vector, shared by the iOS and macOS Settings roots.
/// Unlike `ContainedIcon`, this preserves the mark's own red and cyan colors.
struct OpenClawRuntimeIcon: View {
    var body: some View {
        Image("OpenClawLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Contained Icons") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
            ContainedIcon(icon: "server.rack", color: .orange)
            ContainedIcon(icon: "hand.raised.fill", color: .blue)
            ContainedIcon(icon: "puzzlepiece.extension.fill", color: .purple)
            ContainedIcon(icon: "info.circle.fill", color: .gray)
        }
        HStack(spacing: 12) {
            SettingsIcon(icon: "calendar", color: .red)
            Text("SettingsIcon compatibility alias")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
}
#endif
