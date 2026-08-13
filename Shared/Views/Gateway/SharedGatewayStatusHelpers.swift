import SwiftUI

// MARK: - Connection Status Helpers

let cloudRecoveryGraceDuration: TimeInterval = 90

/// Shared helpers for gateway connection status display.
enum GatewayStatusHelper {
    struct Presentation {
        let text: String
        let detail: String?
        let color: Color
    }

    static func icon(for state: GatewayConnectionState) -> String {
        switch state {
        case .connected: "checkmark.circle"
        case .connecting: "ellipsis.circle"
        case .disconnected: "circle.slash"
        case .unauthorized: "lock.circle"
        case .pairingRequired: "person.badge.key"
        case .unreachable: "exclamationmark.triangle"
        }
    }

    static func presentation(
        for state: GatewayConnectionState,
        provider: GatewayProvider,
        isWithinRecoveryGrace: Bool,
        supportsExplicitPairingApproval: Bool = false,
        isAutoRePairing: Bool,
        isUserRePairing: Bool
    ) -> Presentation {
        if isAutoRePairing || isUserRePairing {
            return Presentation(
                text: "Finishing connection",
                detail: trustRefreshDetail(for: provider),
                color: .blue
            )
        }

        if provider == .fly, isWithinRecoveryGrace {
            switch state {
            case .connecting, .unreachable:
                return Presentation(
                    text: "Finishing connection",
                    detail: cloudWakeDetail,
                    color: .orange
                )
            case .pairingRequired:
                return Presentation(
                    text: "Waiting for approval",
                    detail: supportsExplicitPairingApproval
                        ? "Rem is waiting for this device to be approved for the cloud machine."
                        : "Rem is waiting for approval before marking this machine connected.",
                    color: .orange
                )
            default:
                break
            }
        }

        if provider == .fly, case .pairingRequired = state {
            return Presentation(
                text: "Approval needs attention",
                detail: supportsExplicitPairingApproval
                    ? "This is taking longer than expected. Check approval from this status card."
                    : "This is taking longer than expected. Open Machine Connections to check the pending request.",
                color: .orange
            )
        }

        return Presentation(
            text: state.statusText,
            detail: nil,
            color: color(for: state)
        )
    }

    static func color(for state: GatewayConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .pairingRequired: .yellow
        case .unauthorized, .unreachable: .red
        case .disconnected: .gray
        }
    }

    static func trustRefreshDetail(for provider: GatewayProvider) -> String {
        switch provider {
        case .local:
            return "Rem is refreshing this device's trust with your Mac machine. Mac-local actions still need that Mac running and reachable."
        case .fly:
            return "Rem is refreshing this device's trust with your cloud machine."
        default:
            return "Rem is refreshing device trust and reconnecting to this machine."
        }
    }

    static let cloudWakeDetail = "Your cloud machine is waking up or reconnecting."

    static func connectionRecoverySubtitle(
        for state: GatewayConnectionState,
        provider: GatewayProvider
    ) -> String {
        switch state {
        case .connected:
            return "You can continue using Rem."
        case .connecting:
            switch provider {
            case .local:
                return "Rem is trying to reach the private machine on your Mac. Mac-local actions need this Mac running and reachable."
            case .fly:
                return "Your cloud machine may be waking up or checking approval."
            default:
                return "Rem is trying to reach this machine."
            }
        case .disconnected:
            return "Try connecting again, or open Machine Connections if this device is not trusted."
        case .unauthorized:
            return "The saved device trust is no longer accepted. Re-pairing keeps the same machine and asks it to trust this device again."
        case .pairingRequired:
            return provider == .fly
                ? "Check approval for this managed cloud machine, or open Machine Connections to inspect pending devices. This only approves cloud machine access."
                : "Open Machine Connections on the private machine to approve this device. Mac-local actions require the Mac machine that owns them."
        case .unreachable(let detail):
            if let detail, !detail.isEmpty {
                return detail
            }
            switch provider {
            case .local:
                return "Turn on your Mac, keep Rem running, then try connecting again. Cloud machines cannot perform Mac-local actions for this machine."
            case .fly:
                return "Check whether the cloud machine is still starting, unreachable, or waiting for approval."
            default:
                return "Check whether this machine is still starting, unreachable, or waiting for approval."
            }
        }
    }
}

#if DEBUG
#Preview("Gateway Status Presentations") {
    VStack(alignment: .leading, spacing: 14) {
        GatewayStatusPresentationPreviewRow(
            title: "Connected",
            presentation: GatewayStatusHelper.presentation(
                for: .connected,
                provider: .fly,
                isWithinRecoveryGrace: false,
                isAutoRePairing: false,
                isUserRePairing: false
            )
        )
        GatewayStatusPresentationPreviewRow(
            title: "Cloud waking",
            presentation: GatewayStatusHelper.presentation(
                for: .connecting,
                provider: .fly,
                isWithinRecoveryGrace: true,
                isAutoRePairing: false,
                isUserRePairing: false
            )
        )
        GatewayStatusPresentationPreviewRow(
            title: "Approval",
            presentation: GatewayStatusHelper.presentation(
                for: .pairingRequired,
                provider: .fly,
                isWithinRecoveryGrace: true,
                supportsExplicitPairingApproval: true,
                isAutoRePairing: false,
                isUserRePairing: false
            )
        )
        GatewayStatusPresentationPreviewRow(
            title: "Unreachable",
            presentation: GatewayStatusHelper.presentation(
                for: .unreachable("Gateway did not respond."),
                provider: .fly,
                isWithinRecoveryGrace: false,
                isAutoRePairing: false,
                isUserRePairing: false
            )
        )
    }
    .padding()
}

private struct GatewayStatusPresentationPreviewRow: View {
    let title: String
    let presentation: GatewayStatusHelper.Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(presentation.color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.text)
            }
            if let detail = presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
    }
}
#endif

enum SharedGatewaySettingsStore {
    static var keychainService: String {
        #if os(macOS)
        "app.remclaw.mac"
        #else
        "app.remclaw"
        #endif
    }

    @MainActor
    static func makeMigratedStore<Gateway: GatewaySessionProviding>(
        gateway: Gateway
    ) -> GatewayConfigStore {
        let store = GatewayConfigStore(keychainService: keychainService)
        store.migrateFromLegacy(
            url: gateway.storedGatewayURL,
            token: gateway.storedGatewayToken,
            provider: .fly,
            displayName: "Cloud Gateway"
        )
        upsertActiveLocalGateway(
            in: store,
            url: gateway.activeLocalGatewayURL,
            token: gateway.activeLocalGatewayToken
        )
        return store
    }

    @MainActor
    static func upsertActiveLocalGateway(
        in store: GatewayConfigStore,
        url: String?,
        token: String?
    ) {
        guard let url, !url.isEmpty,
              let token, !token.isEmpty
        else { return }

        if let existing = store.configs.first(where: { config in
            config.provider == .local && config.url == url
        }) {
            store.setActive(id: existing.id)
            return
        }

        store.save(
            GatewayConfig(
                url: url,
                token: token,
                provider: .local,
                displayName: "Local Gateway",
                isActive: true
            )
        )
    }
}

enum SharedGatewaySettingsResolver {
    static func sortedConfigs(_ configs: [GatewayConfig]) -> [GatewayConfig] {
        configs.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.displayName < rhs.displayName
        }
    }

    static func preferredLandingConfig(from configs: [GatewayConfig]) -> GatewayConfig? {
        configs.first(where: \.isActive) ?? configs.first
    }

    static func showsMacHardwareControls(for config: GatewayConfig) -> Bool {
        config.provider == .local
    }

    static func switcherTitle(for config: GatewayConfig, in configs: [GatewayConfig]) -> String {
        let matchingNames = configs.filter { $0.displayName == config.displayName }
        guard matchingNames.count > 1 else { return config.displayName }

        if let host = config.hostDisplay {
            let matchingHosts = matchingNames.filter { $0.hostDisplay == host }
            if matchingHosts.count == 1 {
                return "\(config.displayName) (\(host))"
            }
        }

        let matchingProviders = matchingNames.filter { $0.provider == config.provider }
        if matchingProviders.count == 1 {
            return "\(config.displayName) (\(config.provider.displayName))"
        }

        return "\(config.displayName) (\(config.id.prefix(6)))"
    }

    static func reusingExistingID(for config: GatewayConfig, in configs: [GatewayConfig]) -> GatewayConfig {
        guard let existing = configs.first(where: { $0.url.normalizedGatewayURL == config.url.normalizedGatewayURL }) else {
            return config
        }

        return GatewayConfig(
            id: existing.id,
            url: config.url,
            token: config.token,
            provider: config.provider,
            displayName: existing.displayName.isEmpty ? config.displayName : existing.displayName,
            macAddress: existing.macAddress,
            isActive: true,
            transport: config.transport ?? existing.transport,
            tailscaleURL: config.tailscaleURL ?? existing.tailscaleURL,
            sshLocalPort: config.sshLocalPort ?? existing.sshLocalPort,
            isBootstrap: config.isBootstrap ?? existing.isBootstrap
        )
    }
}

extension String {
    var normalizedGatewayURL: String {
        var normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }
}
