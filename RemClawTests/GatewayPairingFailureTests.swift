import Foundation
import Testing
import OpenClawKit
@testable import RemClaw

/// Tests for `GatewayPairingFailure` — the auto-vs-user trigger classifier
/// that decides whether to silently re-pair or surface a user-tap CTA.
///
/// Fixtures use reason / detail values pulled directly from the gateway
/// source so substring drift between gateway versions is caught here:
/// - `openclaw/src/gateway/protocol/connect-error-details.ts` — wire codes
/// - `openclaw/src/gateway/server/ws-connection/message-handler.ts` — message text
/// - `openclaw/src/gateway/server/ws-connection/auth-messages.ts` — auth messages
///
/// See #306 (Pairing recovery UX epic) review feedback: previous
/// substring-only classifier silently failed to reach `.scopeUpgrade`
/// (carried in `details.reason`, not the message) and `.deviceIdMismatch`
/// (gateway emits "device identity mismatch", not "device id mismatch").
struct GatewayPairingFailureTests {

    // MARK: - Auto-recoverable failures

    @Test func scopeUpgradeFromTypedError() throws {
        // Gateway emits PAIRING_REQUIRED with details.reason = "scope-upgrade"
        // when the operator scope set has widened (most common cause: we
        // shipped a new permission). Auto-re-pair is correct here.
        let error = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false,
            detailsReason: "scope-upgrade")

        #expect(GatewayPairingFailure.classify(error: error) == .scopeUpgrade)
        #expect(GatewayPairingFailure.classify(error: error).isAutoRecoverable)
    }

    @Test func roleUpgradeFromTypedError() throws {
        // The other side of the pairing-upgrade coin: a new role is being
        // requested by an already-paired device.
        let error = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false,
            detailsReason: "role-upgrade")

        #expect(GatewayPairingFailure.classify(error: error) == .roleUpgrade)
        #expect(GatewayPairingFailure.classify(error: error).isAutoRecoverable)
    }

    @Test func metadataUpgradeFromTypedError() throws {
        let error = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false,
            detailsReason: "metadata-upgrade")

        #expect(GatewayPairingFailure.classify(error: error) == .metadataUpgrade)
        #expect(GatewayPairingFailure.classify(error: error).isAutoRecoverable)
    }

    @Test func signatureExpiredFromTypedError() throws {
        // Gateway emits this after the device-auth signature TTL elapses;
        // the device should silently re-pair rather than show the user a
        // scary error. Source code: `device-signature-stale` →
        // DEVICE_AUTH_SIGNATURE_EXPIRED in connect-error-details.ts:99.
        let error = GatewayConnectAuthError(
            message: "device signature expired",
            detailCode: "DEVICE_AUTH_SIGNATURE_EXPIRED",
            canRetryWithDeviceToken: true)

        #expect(GatewayPairingFailure.classify(error: error) == .signatureExpired)
        #expect(GatewayPairingFailure.classify(error: error).isAutoRecoverable)
    }

    // MARK: - Trust-revocation failures

    @Test func signatureInvalidFromTypedError() throws {
        // Gateway message-handler.ts:673 emits "device signature invalid".
        let error = GatewayConnectAuthError(
            message: "device signature invalid",
            detailCode: "DEVICE_AUTH_SIGNATURE_INVALID",
            canRetryWithDeviceToken: false)

        #expect(GatewayPairingFailure.classify(error: error) == .signatureInvalid)
        #expect(GatewayPairingFailure.classify(error: error).isTrustRevocation)
    }

    @Test func deviceIdMismatchFromTypedError() throws {
        // CRITICAL fixture — message-handler.ts:652 emits "device identity
        // mismatch" (with the word "identity"), NOT "device id mismatch".
        // The previous string-based classifier matched on
        // "device id mismatch" / "device_id_mismatch" — both miss the real
        // wire string. The typed path must catch it via DEVICE_AUTH_DEVICE_ID_MISMATCH.
        let error = GatewayConnectAuthError(
            message: "device identity mismatch",
            detailCode: "DEVICE_AUTH_DEVICE_ID_MISMATCH",
            canRetryWithDeviceToken: false)

        #expect(GatewayPairingFailure.classify(error: error) == .deviceIdMismatch)
        #expect(GatewayPairingFailure.classify(error: error).isTrustRevocation)
    }

    @Test func deviceTokenMismatchFromTypedError() throws {
        // auth-messages.ts:66 surfaces "unauthorized: device token rejected
        // (pair/repair this device, or provide gateway token)" — the substring
        // "rejected" / "unauthorized" was unreachable by the prior
        // `.revoked` classifier (which looked for literal "revoked").
        // Typed code AUTH_DEVICE_TOKEN_MISMATCH is the reliable signal.
        let error = GatewayConnectAuthError(
            message: "unauthorized: device token rejected (pair/repair this device, or provide gateway token)",
            detailCode: "AUTH_DEVICE_TOKEN_MISMATCH",
            canRetryWithDeviceToken: true)

        #expect(GatewayPairingFailure.classify(error: error) == .deviceTokenMismatch)
        #expect(GatewayPairingFailure.classify(error: error).isTrustRevocation)
    }

    @Test func publicKeyInvalidFromTypedError() throws {
        let error = GatewayConnectAuthError(
            message: "device public key invalid",
            detailCode: "DEVICE_AUTH_PUBLIC_KEY_INVALID",
            canRetryWithDeviceToken: false)

        #expect(GatewayPairingFailure.classify(error: error) == .publicKeyInvalid)
        #expect(GatewayPairingFailure.classify(error: error).isTrustRevocation)
    }

    @Test func nonceMismatchFromTypedError() throws {
        let error = GatewayConnectAuthError(
            message: "device nonce mismatch",
            detailCode: "DEVICE_AUTH_NONCE_MISMATCH",
            canRetryWithDeviceToken: true)

        #expect(GatewayPairingFailure.classify(error: error) == .nonceMismatch)
        #expect(GatewayPairingFailure.classify(error: error).isTrustRevocation)
    }

    // MARK: - Unknown / pass-through

    @Test func plainPairingRequiredFallsToUnknown() throws {
        // First-time pairing: `PAIRING_REQUIRED` with no `details.reason`.
        // Should NOT match scope/role/metadata-upgrade — this is a
        // first-pair, not a re-pair. Our classifier returns `.unknown` so
        // the caller falls through to the existing auto-approve path.
        let error = GatewayConnectAuthError(
            message: "pairing required",
            detailCode: "PAIRING_REQUIRED",
            canRetryWithDeviceToken: false)

        let classification = GatewayPairingFailure.classify(error: error)
        // PAIRING_REQUIRED without an upgrade reason maps to .pairingRequired
        // upstream, which our classifier treats as `.unknown` so the caller
        // doesn't mistake it for an upgrade auto-recovery.
        #expect(classification == .unknown)
        #expect(!classification.isAutoRecoverable)
        #expect(!classification.isTrustRevocation)
    }

    @Test func transportErrorFallsToUnknown() throws {
        // Generic transport / network errors aren't pairing failures. Should
        // not trigger any auto-recovery path.
        struct TransportError: Error {}
        let classification = GatewayPairingFailure.classify(error: TransportError())
        #expect(classification == .unknown)
    }

    @Test func nilErrorReturnsUnknown() throws {
        #expect(GatewayPairingFailure.classify(error: nil) == .unknown)
    }

    // MARK: - String fallback (post-connect transport drops)

    @Test func reasonStringFallbackOnlyMatchesUnambiguousCodes() throws {
        // Conservative string fallback used when the disconnect handler
        // gives us a reason string but no structured error. Only matches
        // unambiguous DEVICE_AUTH_* codes plus the exact trust-revocation
        // message observed from OpenClaw disconnects — anything ambiguous
        // returns `.unknown` rather than guessing.

        // Matches:
        #expect(GatewayPairingFailure.from(
            reasonString: "connect failed: device_auth_signature_expired") == .signatureExpired)
        #expect(GatewayPairingFailure.from(
            reasonString: "connect failed: device_auth_signature_invalid") == .signatureInvalid)
        #expect(GatewayPairingFailure.from(
            reasonString: "connect failed: device signature invalid") == .signatureInvalid)
        #expect(GatewayPairingFailure.from(
            reasonString: "device signature invalid") == .signatureInvalid)

        // Does NOT match (ambiguous human strings):
        #expect(GatewayPairingFailure.from(
            reasonString: "device identity mismatch") == .unknown)
        #expect(GatewayPairingFailure.from(
            reasonString: "unauthorized: device token rejected") == .unknown)
        #expect(GatewayPairingFailure.from(
            reasonString: "scope-upgrade required") == .unknown)
        #expect(GatewayPairingFailure.from(
            reasonString: "pairing required") == .unknown)
    }

    @Test func reasonStringFallbackHandlesEmptyAndNil() throws {
        #expect(GatewayPairingFailure.from(reasonString: nil) == .unknown)
        #expect(GatewayPairingFailure.from(reasonString: "") == .unknown)
    }

    @Test func connectionStateOnlyRequestsRepairForTrustRevocation() throws {
        #expect(GatewayConnectionState.pairingRequired.needsDeviceRePair)
        #expect(GatewayConnectionState.unauthorized.needsDeviceRePair)
        #expect(GatewayConnectionState.unreachable("connect failed: device signature invalid").needsDeviceRePair)

        #expect(!GatewayConnectionState.unreachable("connect failed: network is down").needsDeviceRePair)
        #expect(!GatewayConnectionState.unreachable(nil).needsDeviceRePair)
        #expect(!GatewayConnectionState.connected.needsDeviceRePair)
    }

    @Test func cloudGatewayTransientStatesReadAsProgressDuringRecoveryGrace() throws {
        let unreachable = GatewayStatusHelper.presentation(
            for: .unreachable("connect failed"),
            provider: .fly,
            isWithinRecoveryGrace: true,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(unreachable.text == "Finishing connection")
        #expect(unreachable.detail?.contains("waking up or reconnecting") == true)
        #expect(unreachable.detail?.contains("Mac-local actions") == false)

        let approval = GatewayStatusHelper.presentation(
            for: .pairingRequired,
            provider: .fly,
            isWithinRecoveryGrace: true,
            supportsExplicitPairingApproval: true,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(approval.text == "Waiting for approval")
        #expect(approval.detail?.contains("waiting for this device") == true)
    }

    @Test func gatewayRecoveryCopyDistinguishesMacLocalFromManagedCloudFallback() throws {
        let localConnecting = GatewayStatusHelper.connectionRecoverySubtitle(
            for: .connecting,
            provider: .local
        )
        #expect(localConnecting.contains("private machine on your Mac"))
        #expect(localConnecting.contains("Mac-local actions need this Mac running and reachable"))

        let localUnreachable = GatewayStatusHelper.connectionRecoverySubtitle(
            for: .unreachable(nil),
            provider: .local
        )
        #expect(localUnreachable.contains("Cloud machines cannot perform Mac-local actions"))

        let cloudConnecting = GatewayStatusHelper.connectionRecoverySubtitle(
            for: .connecting,
            provider: .fly
        )
        #expect(cloudConnecting.contains("cloud machine"))
        #expect(cloudConnecting.contains("waking up or checking approval"))
        #expect(cloudConnecting.contains("Mac-local actions") == false)

	        let cloudApproval = GatewayStatusHelper.connectionRecoverySubtitle(
	            for: .pairingRequired,
	            provider: .fly
	        )
	        #expect(cloudApproval.contains("managed cloud machine"))
	        #expect(cloudApproval.contains("only approves cloud machine access"))
    }

    @Test func trustRefreshCopyDoesNotImplyCloudCanReplaceMacLocalControl() throws {
        let localTrust = GatewayStatusHelper.trustRefreshDetail(for: .local)
        #expect(localTrust.contains("Mac machine"))
        #expect(localTrust.contains("Mac-local actions still need that Mac running and reachable"))

        let cloudTrust = GatewayStatusHelper.trustRefreshDetail(for: .fly)
        #expect(cloudTrust.contains("cloud machine"))
        #expect(cloudTrust.contains("Mac-local actions") == false)
    }

    @Test func launchRecoveryCopyUsesActiveGatewayProvider() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let onboardingReadme = try read("RemClaw/Sources/Onboarding/README.md", from: projectRoot)
        #expect(onboardingReadme.contains("Launch recovery scope (#284)"))
        #expect(onboardingReadme.contains("The launch screen should explain the selected gateway's recovery state"))
        #expect(onboardingReadme.contains("It should not become a full gateway switcher"))
        #expect(onboardingReadme.contains("silently move Mac-local actions to cloud"))
        #expect(onboardingReadme.contains("Gateway switching belongs in Gateway Detail or contextual chat/gateway recovery surfaces"))

        #expect(GatewayRecoveryCopy.launchConnectingText(provider: .local) == "Connecting to your Mac gateway...")
        #expect(GatewayRecoveryCopy.launchConnectingText(provider: .fly) == "Waking your cloud gateway...")

        let localUnreachable = GatewayRecoveryCopy.launchFailedText(
            for: .unreachable(nil),
            provider: .local
        )
        #expect(localUnreachable == "Your Mac gateway isn't reachable")
        let localUnreachableSubtitle = GatewayRecoveryCopy.launchFailedSubtitle(
            for: .unreachable(nil),
            provider: .local
        )
        #expect(localUnreachableSubtitle.contains("Wake your Mac"))
        #expect(localUnreachableSubtitle.contains("same network"))

        let cloudApproval = GatewayRecoveryCopy.launchFailedText(
            for: .pairingRequired,
            provider: .fly
        )
        #expect(cloudApproval == "Cloud gateway approval needs attention")
        let cloudApprovalSubtitle = GatewayRecoveryCopy.launchFailedSubtitle(
            for: .pairingRequired,
            provider: .fly
        )
        #expect(cloudApprovalSubtitle.contains("cloud gateway"))
        #expect(cloudApprovalSubtitle.contains("before continuing"))
        #expect(cloudApprovalSubtitle.contains("Mac-local actions") == false)

        let localApprovalSubtitle = GatewayRecoveryCopy.launchFailedSubtitle(
            for: .pairingRequired,
            provider: .local
        )
        #expect(localApprovalSubtitle.contains("Open Rem on your Mac"))
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func cloudDeployFixtureKeepsRepairDataContinuityCopy() throws {
        #if os(iOS)
        #expect(CloudGatewayDeployPhaseInfo.progress(for: "waiting_for_healthy") > 0.5)
        #expect(CloudGatewayDeployError.connectionNotReady(.pairingRequired).localizedDescription.contains("Do not deploy another cloud gateway yet"))

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosApp = try read("RemClaw/RemClawApp.swift", from: projectRoot)
        let deploySheet = try read("Shared/Views/Gateway/CloudGatewayDeploySheet.swift", from: projectRoot)
        #expect(iosApp.contains("--rem-cloud-deploy-fixture"))
        #expect(deploySheet.contains("--rem-cloud-deploy-progress-fixture"))
        #expect(deploySheet.contains("--rem-cloud-repair-progress-fixture"))
        #expect(deploySheet.contains("--rem-cloud-deploy-approval-fixture"))
        #expect(deploySheet.contains("This will not create a new cloud gateway"))
        #expect(deploySheet.contains("CloudGatewayDeployFixtureView"))
        #endif
    }

    @Test func bannerRecoveryCopyKeepsCloudAndMacLocalBoundariesSeparate() throws {
        let localConnecting = GatewayRecoveryCopy.bannerSubtitle(
            for: .connecting,
            provider: .local
        )
        #expect(localConnecting.contains("gateway running on your Mac"))
        #expect(localConnecting.contains("Cloud gateways cannot perform Mac-local actions"))

        let cloudUnreachable = GatewayRecoveryCopy.bannerSubtitle(
            for: .unreachable(nil),
            provider: .fly
        )
        #expect(cloudUnreachable.contains("cloud gateway"))
        #expect(cloudUnreachable.contains("Check your connection or retry"))
        #expect(cloudUnreachable.contains("Mac-local actions") == false)

        let cloudAutoRePair = GatewayRecoveryCopy.bannerAutoRePairSubtitle(provider: .fly)
        #expect(cloudAutoRePair.contains("cloud gateway"))
        #expect(cloudAutoRePair.contains("few seconds"))
        #expect(cloudAutoRePair.contains("Mac-local actions") == false)
    }

    #if DEBUG
    @Test @MainActor func launchRecoveryFixtureCanBeConstructedForScreenshotProof() throws {
        let fixture = LaunchRecoveryCopyFixtureView()
        _ = fixture.body
    }

    @Test @MainActor func launchConnectionRecoveryRouteFixtureCanBeConstructedForScreenshotProof() throws {
        let fixture = LaunchConnectionRecoveryRouteFixtureView()
        _ = fixture.body

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureSource = try read("RemClaw/Sources/Onboarding/LaunchRecoveryCopyFixtureView.swift", from: projectRoot)
        #expect(fixtureSource.contains("--rem-launch-connection-recovery-open-fixture"))
        #expect(fixtureSource.contains("--rem-launch-connection-recovery-banner-fixture"))
        #expect(fixtureSource.contains("SharedGatewayRecoveryDestinationFixtureView(scenario: .cloudApprovalPending)"))
    }

    @Test @MainActor func connectionRecoveryFixtureScenariosCanBeConstructedForScreenshotProof() throws {
        for scenario in GatewayConnectionRecoveryFixtureScenario.allCases {
            let fixture = SharedGatewayConnectionRecoveryFixtureView(scenario: scenario)
            _ = fixture.body
        }
    }

    @Test @MainActor func gatewayDetailRecoveryEntryFixturesCanBeConstructedForScreenshotProof() throws {
        let cloudApproval = SharedGatewayDetailFixtureView(
            state: .pairingRequired,
            provider: .fly,
            usesCloudRecoveryGrace: false
        )
        _ = cloudApproval.body

        let localUnavailable = SharedGatewayDetailFixtureView(
            state: .unreachable(nil),
            provider: .local
        )
        _ = localUnavailable.body
    }

    @Test @MainActor func gatewayDetailUpdateReadinessFixturesCanBeConstructedForScreenshotProof() throws {
        let managedPreflight = SharedGatewayDetailFixtureView(
            provider: .fly,
            updateReadinessScenario: .managedPreflightRequired
        )
        _ = managedPreflight.body

        let manualUpdate = SharedGatewayDetailFixtureView(
            provider: .fly,
            updateReadinessScenario: .manualUpdate
        )
        _ = manualUpdate.body

        let refreshFallback = SharedGatewayDetailFixtureView(
            provider: .fly,
            updateReadinessScenario: .refreshFallback
        )
        _ = refreshFallback.body
    }

    @Test @MainActor func devicePairingRecoveryEntryFixturesCanBeConstructedForScreenshotProof() throws {
        let cloudApproval = SharedGatewayDevicePairingFixtureView(scenario: .cloudApprovalPending)
        _ = cloudApproval.body

        let localUnavailable = SharedGatewayDevicePairingFixtureView(scenario: .localMacUnavailable)
        _ = localUnavailable.body
    }

    @Test @MainActor func previewGatewayFixturesCanBeInstantiatedForEveryScenario() throws {
        let store = PreviewGatewayConfigs.store(configs: [
            PreviewGatewayConfigs.cloud,
            PreviewGatewayConfigs.localMac,
            PreviewGatewayConfigs.inactiveManual
        ])
        #expect(store.activeConfig != nil)

        for scenario in PreviewGatewayScenario.allCases {
            let session = PreviewGatewaySession(scenario: scenario)
            #expect(session.connectionState == scenario.connectionState)
            #expect(session.linkedDevices.count == scenario.linkedDevices.count)
            #expect(session.pendingDevices.count == scenario.pendingDevices.count)
        }
    }
    #endif

    @Test func gatewayTransientStatesReturnToRawCopyAfterRecoveryGrace() throws {
        let durableFailure = GatewayStatusHelper.presentation(
            for: .unreachable("connect failed"),
            provider: .fly,
            isWithinRecoveryGrace: false,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(durableFailure.text == "Unreachable: connect failed")
        #expect(durableFailure.detail == nil)

        let manualLocalApproval = GatewayStatusHelper.presentation(
            for: .pairingRequired,
            provider: .local,
            isWithinRecoveryGrace: true,
            supportsExplicitPairingApproval: false,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(manualLocalApproval.text == "Approval Pending")
        #expect(manualLocalApproval.detail == nil)
    }

    @Test func cloudGatewayApprovalNeedsAttentionAfterRecoveryGrace() throws {
        let approval = GatewayStatusHelper.presentation(
            for: .pairingRequired,
            provider: .fly,
            isWithinRecoveryGrace: false,
            supportsExplicitPairingApproval: true,
            isAutoRePairing: false,
            isUserRePairing: false
        )

        #expect(approval.text == "Approval needs attention")
        #expect(approval.detail?.contains("taking longer than expected") == true)
        #expect(approval.detail?.contains("status card") == true)
    }

    @Test func cloudGatewayApprovalCopyDoesNotNameMissingFinishConnectionAction() throws {
        let inGrace = GatewayStatusHelper.presentation(
            for: .pairingRequired,
            provider: .fly,
            isWithinRecoveryGrace: true,
            supportsExplicitPairingApproval: false,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(inGrace.text == "Waiting for approval")
        #expect(inGrace.detail?.contains("Finish Connection") == false)

        let timedOut = GatewayStatusHelper.presentation(
            for: .pairingRequired,
            provider: .fly,
            isWithinRecoveryGrace: false,
            supportsExplicitPairingApproval: false,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(timedOut.text == "Approval needs attention")
        #expect(timedOut.detail?.contains("Finish Connection") == false)
        #expect(timedOut.detail?.contains("Machine Connections") == true)
    }

    @Test func cloudGatewayGraceDoesNotMaskUnauthorizedOrDisconnectedStates() throws {
        let unauthorized = GatewayStatusHelper.presentation(
            for: .unauthorized,
            provider: .fly,
            isWithinRecoveryGrace: true,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(unauthorized.text == "Unauthorized")
        #expect(unauthorized.detail == nil)

        let disconnected = GatewayStatusHelper.presentation(
            for: .disconnected,
            provider: .fly,
            isWithinRecoveryGrace: true,
            isAutoRePairing: false,
            isUserRePairing: false
        )
        #expect(disconnected.text == "Offline")
        #expect(disconnected.detail == nil)
    }

    // MARK: - Telemetry value stability

    @Test func telemetryValuesAreStable() throws {
        // PostHog dashboards key off these strings — changing them silently
        // breaks the funnel. Pin to assert.
        #expect(GatewayPairingFailure.scopeUpgrade.telemetryValue == "scope_upgrade")
        #expect(GatewayPairingFailure.roleUpgrade.telemetryValue == "role_upgrade")
        #expect(GatewayPairingFailure.metadataUpgrade.telemetryValue == "metadata_upgrade")
        #expect(GatewayPairingFailure.signatureExpired.telemetryValue == "signature_expired")
        #expect(GatewayPairingFailure.signatureInvalid.telemetryValue == "signature_invalid")
        #expect(GatewayPairingFailure.deviceIdMismatch.telemetryValue == "device_id_mismatch")
        #expect(GatewayPairingFailure.deviceTokenMismatch.telemetryValue == "device_token_mismatch")
        #expect(GatewayPairingFailure.publicKeyInvalid.telemetryValue == "public_key_invalid")
        #expect(GatewayPairingFailure.nonceMismatch.telemetryValue == "nonce_mismatch")
        #expect(GatewayPairingFailure.unknown.telemetryValue == "unknown")
    }
}
