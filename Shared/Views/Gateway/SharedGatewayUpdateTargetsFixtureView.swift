import SwiftUI

#if DEBUG
/// DEBUG screenshot route for managed gateway update readiness. This is not a
/// primary Wave 2 product surface until managed updates are productized.
struct SharedGatewayUpdateTargetsFixtureView: View {
    private let presentation = GatewayUpdateReadinessPresentation.from(
        config: GatewayConfig(
            id: "fixture-cloud-gateway",
            url: "https://fixture-gateway.rem.local",
            token: "fixture-token",
            provider: .fly,
            displayName: "Cloud Gateway",
            isActive: true,
            transport: .manual
        ),
        backendReadiness: GatewayUpdateReadiness(
            canUpdate: false,
            status: .managedFlyPreflightRequired,
            hostingProvider: "fly",
            gatewayUrl: "https://fixture-gateway.rem.local",
            managedFlyAppName: "fixture-gateway",
            message: "Gateway updates require a tested backup, same-gateway deploy target, health check, and rollback path before they can be enabled.",
            requiredChecks: [
                "same_gateway_target",
                "backup_or_snapshot",
                "approved_gateway_image",
                "post_update_health_check",
                "rollback_path",
            ],
            preflightChecks: [
                GatewayUpdatePreflightCheck(
                    id: "same_gateway_target",
                    label: "Same Gateway Target",
                    status: .ready,
                    message: "Managed Fly app fixture-gateway is known. Machine and volume checks still need to run before updates can be enabled."
                ),
                GatewayUpdatePreflightCheck(
                    id: "backup_or_snapshot",
                    label: "Backup Or Snapshot",
                    status: .blocked,
                    message: "A tested gateway backup or volume snapshot is required before Rem can expose an in-app update action."
                ),
                GatewayUpdatePreflightCheck(
                    id: "approved_gateway_image",
                    label: "Approved Gateway Image",
                    status: .ready,
                    message: "The stable OpenClaw gateway image is approved for preflight display, but installation remains disabled until every safety gate passes."
                ),
                GatewayUpdatePreflightCheck(
                    id: "post_update_health_check",
                    label: "Post-Update Health Check",
                    status: .notRun,
                    message: "A post-update health probe has not run for this gateway and must pass before updates can be enabled."
                ),
                GatewayUpdatePreflightCheck(
                    id: "rollback_path",
                    label: "Rollback Path",
                    status: .blocked,
                    message: "A tested rollback path is required before Rem can offer managed gateway updates."
                ),
            ],
            approvedTargets: [
                GatewayUpdateApprovedTarget(
                    id: "openclaw-stable",
                    label: "OpenClaw stable",
                    channel: "stable",
                    image: "ghcr.io/rem-assistant/openclaw-gateway:stable",
                    requiredCapabilities: ["skills.search"],
                    enabled: false,
                    disabledReason: "Not installable yet. Safe in-app updates require backup/snapshot, same-gateway targeting, health check, and rollback preflight."
                ),
            ]
        )
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("Updates") {
                    LabeledContent("Update Status", value: presentation.status)
                        .accessibilityIdentifier("gateway-update-status-row")

                    Label {
                        Text(presentation.message)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: presentation.icon)
                            .foregroundStyle(presentation.tint)
                    }
                    .accessibilityIdentifier("gateway-update-readiness-message")

                    GatewayVersionTargetsView(targets: presentation.versionTargets)
                }
            }
            .navigationTitle("Gateway Updates")
        }
    }
}

#Preview("Gateway Update Targets — Preflight") {
    SharedGatewayUpdateTargetsFixtureView()
}
#endif
