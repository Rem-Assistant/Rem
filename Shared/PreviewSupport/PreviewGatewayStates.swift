import Foundation
import SwiftUI

#if DEBUG
enum PreviewGatewayScenario: CaseIterable {
    case cloudConnected
    case cloudApprovalPending
    case cloudApprovalPendingNoVisibleRequest
    case cloudCheckingApproval
    case cloudWaking
    case cloudUnreachable
    case cloudDisconnected
    case localMacUnavailable
    case deviceNeedsRepair

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        if arguments.contains("--rem-connection-recovery-cloud-waking-fixture") {
            return .cloudWaking
        }
        if arguments.contains("--rem-connection-recovery-local-mac-fixture") {
            return .localMacUnavailable
        }
        if arguments.contains("--rem-connection-recovery-repair-fixture") {
            return .deviceNeedsRepair
        }
        return .cloudApprovalPending
    }

    var config: GatewayConfig {
        switch self {
        case .localMacUnavailable:
            return PreviewGatewayConfigs.localMac
        default:
            return PreviewGatewayConfigs.cloud
        }
    }

    var configID: String { config.id }
    var provider: GatewayProvider { config.provider }
    var displayName: String { config.displayName }
    var url: String { config.url }

    var connectionState: GatewayConnectionState {
        switch self {
        case .cloudConnected:
            return .connected
        case .cloudApprovalPending, .cloudApprovalPendingNoVisibleRequest, .cloudCheckingApproval:
            return .pairingRequired
        case .cloudWaking:
            return .connecting
        case .cloudUnreachable:
            return .unreachable("connect failed: gateway unavailable")
        case .cloudDisconnected:
            return .disconnected
        case .localMacUnavailable:
            return .unreachable(nil)
        case .deviceNeedsRepair:
            return .unauthorized
        }
    }

    var pendingDevices: [PendingDevice] {
        switch self {
        case .cloudApprovalPending, .cloudCheckingApproval:
            return [PreviewDevices.pendingAgent]
        case .cloudApprovalPendingNoVisibleRequest:
            return []
        default:
            return []
        }
    }

    var linkedDevices: [LinkedDevice] {
        switch self {
        case .cloudConnected:
            return [PreviewDevices.pairedAgent, PreviewDevices.pairedIPhone, PreviewDevices.pairedMac]
        case .cloudApprovalPending, .cloudCheckingApproval:
            return [PreviewDevices.currentIPhone]
        case .deviceNeedsRepair:
            return [PreviewDevices.currentIPhone]
        default:
            return []
        }
    }
}

enum PreviewGatewayStates {
    static let gatewayDetail: [PreviewGatewayScenario] = [
        .cloudConnected,
        .cloudApprovalPending,
        .cloudCheckingApproval,
        .cloudUnreachable,
        .cloudDisconnected,
    ]

    static let deviceConnections: [PreviewGatewayScenario] = [
        .cloudConnected,
        .cloudApprovalPending,
        .cloudApprovalPendingNoVisibleRequest,
        .deviceNeedsRepair,
    ]
}

enum PreviewGatewayUpdateReadinessScenario {
    case managedPreflightRequired
    case manualUpdate
    case refreshFallback

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        if arguments.contains("--rem-gateway-update-manual-fixture") {
            return .manualUpdate
        }
        if arguments.contains("--rem-gateway-update-refresh-fallback-fixture") {
            return .refreshFallback
        }
        return .managedPreflightRequired
    }
}
#endif
