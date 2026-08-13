import SwiftUI

struct GatewayUpdateReadinessPresentation {
    let status: String
    let message: String
    let icon: String
    let tint: Color
    let versionTargets: [GatewayVersionTargetPresentation]

    static func from(
        config: GatewayConfig,
        backendReadiness: GatewayUpdateReadiness?
    ) -> GatewayUpdateReadinessPresentation {
        if let backendReadiness,
           config.provider == .fly,
           backendReadiness.matches(config: config) {
            return from(backendReadiness: backendReadiness)
        }

        switch config.provider {
        case .fly:
            return GatewayUpdateReadinessPresentation(
                status: "Preflight required",
                message: "Managed cloud gateway updates are not enabled yet. Rem must first confirm this exact gateway can be backed up, updated in place, restarted, and health-checked.",
                icon: "shield.lefthalf.filled",
                tint: .blue,
                versionTargets: .managedFlyPreflightRequired(managedFlyAppName: nil)
            )
        case .local:
            return GatewayUpdateReadinessPresentation(
                status: "Manual update",
                message: "This Mac gateway runs locally. Update it from the Mac app or OpenClaw tooling; Rem will not mutate local runtime files from this gateway detail screen.",
                icon: "desktopcomputer",
                tint: .secondary,
                versionTargets: .manualUpdate(providerName: "Local Mac")
            )
        case .manual:
            return GatewayUpdateReadinessPresentation(
                status: "Manual update",
                message: "This gateway was added manually. Rem cannot verify ownership, backups, or rollback for it, so updates must happen outside the app.",
                icon: "wrench.and.screwdriver",
                tint: .secondary,
                versionTargets: .manualUpdate(providerName: "Manual gateway")
            )
        }
    }

    private static func from(backendReadiness: GatewayUpdateReadiness) -> GatewayUpdateReadinessPresentation {
        switch backendReadiness.status {
        case .noGateway:
            return GatewayUpdateReadinessPresentation(
                status: "No gateway",
                message: backendReadiness.message,
                icon: "server.rack",
                tint: .secondary,
                versionTargets: .unavailable(reason: "No managed gateway is available for update selection.")
            )
        case .managedFlyPreflightRequired:
            return GatewayUpdateReadinessPresentation(
                status: "Preflight required",
                message: backendReadiness.message,
                icon: "shield.lefthalf.filled",
                tint: .blue,
                versionTargets: .managedFlyPreflightRequired(
                    managedFlyAppName: backendReadiness.managedFlyAppName,
                    approvedTargets: backendReadiness.approvedTargets,
                    requiredChecks: backendReadiness.requiredChecks,
                    preflightChecks: backendReadiness.preflightChecks
                )
            )
        case .manualUpdate:
            return GatewayUpdateReadinessPresentation(
                status: "Manual update",
                message: backendReadiness.message,
                icon: "wrench.and.screwdriver",
                tint: .secondary,
                versionTargets: .manualUpdate(providerName: backendReadiness.hostingProvider.displayNameForGatewayUpdate)
            )
        case .unknown:
            return GatewayUpdateReadinessPresentation(
                status: "Update unavailable",
                message: backendReadiness.message,
                icon: "questionmark.circle",
                tint: .secondary,
                versionTargets: .unavailable(reason: "Rem cannot match this backend update status to an approved OpenClaw release yet.")
            )
        }
    }
}

struct GatewayVersionTargetsView: View {
    let targets: [GatewayVersionTargetPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenClaw Versions")
                .font(DesignTokens.Typography.caption1.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(targets) { target in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: target.icon)
                        .foregroundStyle(target.tint)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(target.title)
                                .font(DesignTokens.Typography.caption1.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(target.status)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(target.tint)
                        }

                        Text(target.detail)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(target.accessibilityIdentifier)
            }

            Text("Managed updates are in-place upgrades for the same gateway identity and data. Rem will not replace this connection with a new deployment from this screen.")
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("gateway-update-in-place-note")
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("gateway-update-version-list")
    }
}

struct GatewayVersionTargetPresentation: Identifiable {
    let id: String
    let title: String
    let status: String
    let detail: String
    let icon: String
    let tint: Color

    var accessibilityIdentifier: String {
        "gateway-update-target-\(id)"
    }
}

extension Array where Element == GatewayVersionTargetPresentation {
    static func managedFlyPreflightRequired(
        managedFlyAppName: String?,
        approvedTargets: [GatewayUpdateApprovedTarget] = [],
        requiredChecks: [String] = [
            "same_gateway_target",
            "backup_or_snapshot",
            "approved_gateway_image",
            "post_update_health_check",
            "rollback_path",
        ],
        preflightChecks: [GatewayUpdatePreflightCheck] = []
    ) -> [GatewayVersionTargetPresentation] {
        let approvedRows = approvedTargets.isEmpty
            ? [
                GatewayVersionTargetPresentation(
                    id: "approved",
                    title: "Next Rem-approved release",
                    status: "Preflight required",
                    detail: "Available only after backup or snapshot, same-gateway target, approved image, health check, and rollback checks are satisfied.",
                    icon: "shield.lefthalf.filled",
                    tint: .blue
                ),
            ]
            : approvedTargets.map { target in
                GatewayVersionTargetPresentation(
                    id: "approved-\(target.id)",
                    title: target.label,
                    status: "Preflight required",
                    detail: target.updateTargetDetail,
                    icon: "shield.lefthalf.filled",
                    tint: .blue
                )
            }

        let preflightRows = preflightChecks.isEmpty
            ? requiredChecks.map { check in
                GatewayVersionTargetPresentation(
                    id: "preflight-\(check)",
                    title: check.gatewayPreflightTitle,
                    status: "Required",
                    detail: check.gatewayPreflightDetail,
                    icon: "checklist",
                    tint: .secondary
                )
            }
            : preflightChecks.map { check in
                GatewayVersionTargetPresentation(
                    id: "preflight-\(check.id)",
                    title: check.label,
                    status: check.status.presentationLabel,
                    detail: check.message,
                    icon: check.status.presentationIcon,
                    tint: check.status.presentationTint
                )
            }

        return [
            GatewayVersionTargetPresentation(
                id: "current",
                title: "Current OpenClaw",
                status: "Current",
                detail: "This is the existing gateway Rem will update in place after readiness checks pass\(managedFlyAppName.map { " for \($0)" } ?? "").",
                icon: "checkmark.circle.fill",
                tint: .green
            ),
        ] + approvedRows + preflightRows + [
            GatewayVersionTargetPresentation(
                id: "unsupported",
                title: "Unapproved builds",
                status: "Disabled",
                detail: "Arbitrary images, commits, and replacement deployments are not installable from Gateway Detail.",
                icon: "nosign",
                tint: .secondary
            ),
        ]
    }

    static func manualUpdate(providerName: String) -> [GatewayVersionTargetPresentation] {
        [
            GatewayVersionTargetPresentation(
                id: "current",
                title: "Current OpenClaw",
                status: "Manual",
                detail: "\(providerName) updates are managed outside Rem; this screen will not change runtime files or deployment targets.",
                icon: "wrench.and.screwdriver",
                tint: .secondary
            ),
            GatewayVersionTargetPresentation(
                id: "approved",
                title: "Rem-managed releases",
                status: "Unavailable",
                detail: "Managed version selection is reserved for Rem-owned cloud gateways with verified backup and rollback support.",
                icon: "cloud.slash",
                tint: .secondary
            ),
            GatewayVersionTargetPresentation(
                id: "unsupported",
                title: "Replacement deployments",
                status: "Disabled",
                detail: "Gateway Detail cannot replace this connection with a new deployment.",
                icon: "nosign",
                tint: .secondary
            ),
        ]
    }

    static func unavailable(reason: String) -> [GatewayVersionTargetPresentation] {
        [
            GatewayVersionTargetPresentation(
                id: "current",
                title: "Current OpenClaw",
                status: "Unknown",
                detail: reason,
                icon: "questionmark.circle",
                tint: .secondary
            ),
            GatewayVersionTargetPresentation(
                id: "approved",
                title: "Next Rem-approved release",
                status: "Unavailable",
                detail: "Rem will show supported targets here after it can verify this gateway and its update contract.",
                icon: "clock",
                tint: .secondary
            ),
            GatewayVersionTargetPresentation(
                id: "unsupported",
                title: "Unapproved builds",
                status: "Disabled",
                detail: "Unsupported update targets remain blocked.",
                icon: "nosign",
                tint: .secondary
            ),
        ]
    }
}

private extension String {
    var displayNameForGatewayUpdate: String {
        switch lowercased() {
        case "fly": "Fly.io"
        case "local": "Local Mac"
        case "manual": "Manual gateway"
        default: isEmpty ? "Manual gateway" : self
        }
    }

    var gatewayPreflightTitle: String {
        switch self {
        case "same_gateway_target": "Same Gateway Target"
        case "backup_or_snapshot": "Backup or Snapshot"
        case "approved_gateway_image": "Approved Gateway Image"
        case "post_update_health_check": "Post-Update Health Check"
        case "rollback_path": "Rollback Path"
        default: split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    var gatewayPreflightDetail: String {
        switch self {
        case "same_gateway_target":
            return "The update must target this exact gateway app and preserve its identity."
        case "backup_or_snapshot":
            return "Rem must create or verify a restorable backup before changing the runtime."
        case "approved_gateway_image":
            return "Only Rem-tested OpenClaw images can be offered from this screen."
        case "post_update_health_check":
            return "Auth, chat, sessions, and required capabilities must pass after restart."
        case "rollback_path":
            return "Rem needs a tested rollback path before an update action can be enabled."
        default:
            return "This readiness check must pass before managed updates can be enabled."
        }
    }
}

private extension GatewayUpdatePreflightCheckStatus {
    var presentationLabel: String {
        switch self {
        case .ready:
            return "Satisfied"
        case .blocked:
            return "Blocked"
        case .notRun:
            return "Not run"
        case .unknown:
            return "Required"
        }
    }

    var presentationIcon: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        case .notRun:
            return "clock"
        case .unknown:
            return "checklist"
        }
    }

    var presentationTint: Color {
        switch self {
        case .ready:
            return .green
        case .blocked:
            return .orange
        case .notRun, .unknown:
            return .secondary
        }
    }
}

private extension GatewayUpdateApprovedTarget {
    var updateTargetDetail: String {
        let capabilities = requiredCapabilities.isEmpty
            ? "No specific capability requirement is advertised yet."
            : "Requires \(requiredCapabilities.joined(separator: ", "))."
        return "\(capabilities) \(disabledReason)"
    }
}

private extension GatewayUpdateReadiness {
    func matches(config: GatewayConfig) -> Bool {
        guard let gatewayUrl else { return false }
        return gatewayUrl.normalizedGatewayURL == config.url.normalizedGatewayURL
    }
}

#if DEBUG
private struct GatewayUpdateReadinessPreview: View {
    private let presentation = GatewayUpdateReadinessPresentation.from(
        config: PreviewGatewayConfigs.cloud,
        backendReadiness: nil
    )

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Update Status", value: presentation.status)

                Label {
                    Text(presentation.message)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: presentation.icon)
                        .foregroundStyle(presentation.tint)
                }

                GatewayVersionTargetsView(targets: presentation.versionTargets)
            }
        }
    }
}

#Preview("Gateway Update Readiness — Target List") {
    GatewayUpdateReadinessPreview()
}
#endif
