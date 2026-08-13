import SwiftUI

// MARK: - Gateway Row

struct SharedGatewayRow: View {
    let config: GatewayConfig
    /// Pass the current connection state for active gateways, nil for inactive.
    var connectionState: GatewayConnectionState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
            Image(systemName: config.provider.icon)
                .font(.title3)
                .foregroundStyle(config.isActive ? .blue : .secondary)
                .frame(width: 28)

                Text(config.displayName)
                    .font(.body)
                    .fontWeight(config.isActive ? .semibold : .regular)

            Spacer()

            if config.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }

            Text(config.provider.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
            }

            VStack(alignment: .leading) {
                Text(config.hostDisplay ?? config.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let state = connectionState {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(GatewayStatusHelper.color(for: state))
                            .frame(width: 6, height: 6)
                        Text(state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Gateway Row — Active Cloud") {
    List {
        SharedGatewayRow(
            config: PreviewGatewayConfigs.cloud,
            connectionState: .connected
        )
    }
}

#Preview("Gateway Row — Inactive Manual") {
    List {
        SharedGatewayRow(
            config: PreviewGatewayConfigs.inactiveManual,
            connectionState: nil
        )
    }
}
#endif
