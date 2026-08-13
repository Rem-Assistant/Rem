import Foundation
import OpenClawKit

/// One voice returned by the gateway's active speech provider.
///
/// Provider ids and implementation details intentionally stay out of the UI. The
/// gateway is the source of truth for the dynamic catalog; Rem only turns that
/// catalog into stable, user-facing names.
struct VoiceSettingsVoice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let category: String?
    let description: String?
    let locale: String?
    let gender: String?
    let personalities: [String]?

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        return Self.humanizeVoiceID(id)
    }

    var displayDetail: String? {
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDescription.isEmpty { return trimmedDescription }

        let traits = personalities?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " · ") ?? ""
        return traits.isEmpty ? nil : traits
    }

    private static func humanizeVoiceID(_ raw: String) -> String {
        let separated = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = separated.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "Voice" }
        return words.map { word in
            let text = String(word)
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }
}

struct TalkVoicesResponse: Decodable, Sendable {
    let provider: String
    let voices: [VoiceSettingsVoice]
}

struct TalkCatalogResponse: Decodable, Sendable {
    struct Speech: Decodable, Sendable {
        struct Provider: Decodable, Sendable {
            let id: String
            let configured: Bool
        }

        let activeProvider: String?
        let providers: [Provider]
    }

    let speech: Speech
}

enum VoiceSettingsCatalogPolicy {
    /// `configured` is discovery metadata, not the authority for whether the active provider can
    /// serve voices. Existing gateways can report a stale false value while `talk.voices` and
    /// `talk.speak` are operational. Use the catalog/config only to identify the expected provider;
    /// the provider-specific `talk.voices` response remains the readiness authority.
    static func providerToLoad(
        catalog: TalkCatalogResponse,
        selection: VoiceSettingsSelection?
    ) -> String? {
        let catalogProvider = catalog.speech.activeProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let catalogProvider, !catalogProvider.isEmpty {
            return catalogProvider
        }
        let configuredProvider = selection?.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return configuredProvider?.isEmpty == false ? configuredProvider : nil
    }
}

struct VoiceSettingsSelection: Equatable, Sendable {
    let provider: String
    let voiceID: String?
    let modelID: String?
    let outputFormat: String?

    func matches(provider expectedProvider: String, voiceID expectedVoiceID: String) -> Bool {
        provider.caseInsensitiveCompare(expectedProvider) == .orderedSame
            && voiceID == expectedVoiceID
    }
}

enum VoiceSettingsConfigParser {
    /// Parses the normalized, non-secret `talk.config` response. Legacy flat
    /// `talk.voiceId` values are deliberately not accepted: Voice Settings writes
    /// and reads the canonical `talk.providers.<provider>` structure only.
    static func selection(from data: Data) throws -> VoiceSettingsSelection? {
        try selection(from: data, allowLegacyFallback: false)
    }

    /// Runtime compatibility accepts the old flat Talk shape only when no
    /// canonical provider payload exists. Canonical selected-provider values
    /// always win, so stale flat values can never shadow a nested selection.
    static func runtimeSelection(from data: Data) throws -> VoiceSettingsSelection? {
        try selection(from: data, allowLegacyFallback: true)
    }

    private static func selection(
        from data: Data,
        allowLegacyFallback: Bool
    ) throws -> VoiceSettingsSelection? {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = root["config"] as? [String: Any],
            let talk = config["talk"] as? [String: Any]
        else { return nil }

        let bridged = TalkConfigParsing.bridgeFoundationDictionary(talk)
        if let resolved = TalkConfigParsing.selectProviderConfig(
            bridged,
            defaultProvider: "elevenlabs",
            allowLegacyFallback: false
        ) {
            return makeSelection(provider: resolved.provider, config: resolved.config)
        }

        if let provider = trimmedString(talk["provider"] as? String),
           let providers = talk["providers"] as? [String: Any],
           let selected = providers.first(where: {
               $0.key.caseInsensitiveCompare(provider) == .orderedSame
           })?.value as? [String: Any]
        {
            return makeSelection(
                provider: provider,
                config: TalkConfigParsing.bridgeFoundationDictionary(selected) ?? [:]
            )
        }

        let hasCanonicalPayload = talk["provider"] != nil || talk["providers"] != nil
        guard allowLegacyFallback, !hasCanonicalPayload else { return nil }
        return makeSelection(provider: "elevenlabs", config: bridged ?? [:])
    }

    private static func makeSelection(
        provider: String,
        config: [String: AnyCodable]
    ) -> VoiceSettingsSelection {
        return VoiceSettingsSelection(
            provider: provider,
            voiceID: trimmedString(config["voiceId"]?.stringValue),
            modelID: trimmedString(config["modelId"]?.stringValue),
            outputFormat: trimmedString(config["outputFormat"]?.stringValue)
        )
    }

    static func patch(provider: String, voiceID: String) -> [String: JSONValue] {
        [
            "talk": .object([
                "provider": .string(provider),
                "providers": .object([
                    provider: .object([
                        "voiceId": .string(voiceID)
                    ])
                ])
            ])
        ]
    }

    static func encodePatch(provider: String, voiceID: String) throws -> String {
        let data = try JSONEncoder().encode(patch(provider: provider, voiceID: voiceID))
        guard let raw = String(data: data, encoding: .utf8) else {
            throw VoiceSettingsModelError.invalidPatchEncoding
        }
        return raw
    }

    /// Builds a write from the snapshot returned immediately before the patch.
    /// Keeping this here makes the fresh-hash requirement independently testable.
    static func patchParams(
        snapshotData: Data,
        provider: String,
        voiceID: String
    ) throws -> ConfigPatchParams {
        let snapshot = try JSONDecoder().decode(ConfigGetResponse.self, from: snapshotData)
        return ConfigPatchParams(
            raw: try encodePatch(provider: provider, voiceID: voiceID),
            baseHash: snapshot.patchBaseHash
        )
    }

    private static func trimmedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum VoicePreviewPhase: Equatable, Sendable {
    case idle
    case loading(voiceID: String)
    case playing(voiceID: String)

    var activeVoiceID: String? {
        switch self {
        case .idle: nil
        case .loading(let voiceID), .playing(let voiceID): voiceID
        }
    }
}

enum VoicePreviewTapAction: Equatable, Sendable {
    case start(voiceID: String)
    case stop
}

struct VoicePreviewStateMachine: Equatable, Sendable {
    private(set) var phase: VoicePreviewPhase = .idle

    mutating func tap(voiceID: String) -> VoicePreviewTapAction {
        if phase.activeVoiceID == voiceID {
            phase = .idle
            return .stop
        }
        phase = .loading(voiceID: voiceID)
        return .start(voiceID: voiceID)
    }

    mutating func didStartPlaying(voiceID: String) {
        guard phase.activeVoiceID == voiceID else { return }
        phase = .playing(voiceID: voiceID)
    }

    mutating func stop() {
        phase = .idle
    }

    func buttonEnabled(for voiceID: String, isSaving: Bool) -> Bool {
        guard !isSaving else { return false }
        return phase.activeVoiceID == nil || phase.activeVoiceID == voiceID
    }
}

struct VoicePreviewCommandToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case replace
        case stop
    }

    fileprivate let generation: Int
    fileprivate let kind: Kind
    fileprivate let cancelPreviewIDs: [String]
    fileprivate let startPreviewID: String?
}

/// Serializes gateway preview replacement around the cancellation acknowledgement.
///
/// The main-actor tap path claims a monotonic token synchronously before spawning
/// async work. Task scheduling can therefore never reorder commands: a cancelled
/// older task that starts late is rejected before it mutates state or calls the
/// gateway, and every command is checked again after an awaited cancellation.
@MainActor
final class VoicePreviewRequestGate {
    private var generation = 0
    private var currentPreviewID: String?
    private var pendingCancellationIDs: [String] = []

    func claimReplacement(previewID: String) -> VoicePreviewCommandToken {
        if let currentPreviewID {
            appendPendingCancellation(currentPreviewID)
        }
        currentPreviewID = previewID
        return claim(.replace, startPreviewID: previewID)
    }

    func claimStop() -> VoicePreviewCommandToken {
        if let currentPreviewID {
            appendPendingCancellation(currentPreviewID)
        }
        currentPreviewID = nil
        return claim(.stop, startPreviewID: nil)
    }

    func executeReplacement(
        _ token: VoicePreviewCommandToken,
        cancelCurrent: (String) async -> Void,
        startNext: (String) async -> Void
    ) async {
        guard isCurrent(token, kind: .replace), !Task.isCancelled else { return }
        for previewID in token.cancelPreviewIDs {
            guard isCurrent(token, kind: .replace), !Task.isCancelled else { return }
            await cancelCurrent(previewID)
            markCancellationSettled(previewID)
        }
        guard isCurrent(token, kind: .replace), !Task.isCancelled else { return }
        guard let startPreviewID = token.startPreviewID else { return }
        await startNext(startPreviewID)
    }

    func executeStop(
        _ token: VoicePreviewCommandToken,
        cancelCurrent: (String) async -> Void
    ) async {
        guard isCurrent(token, kind: .stop), !Task.isCancelled else { return }
        for previewID in token.cancelPreviewIDs {
            guard isCurrent(token, kind: .stop), !Task.isCancelled else { return }
            await cancelCurrent(previewID)
            markCancellationSettled(previewID)
        }
    }

    private func claim(
        _ kind: VoicePreviewCommandToken.Kind,
        startPreviewID: String?
    ) -> VoicePreviewCommandToken {
        generation += 1
        return VoicePreviewCommandToken(
            generation: generation,
            kind: kind,
            cancelPreviewIDs: pendingCancellationIDs,
            startPreviewID: startPreviewID
        )
    }

    private func isCurrent(
        _ token: VoicePreviewCommandToken,
        kind: VoicePreviewCommandToken.Kind
    ) -> Bool {
        token.generation == generation && token.kind == kind
    }

    private func appendPendingCancellation(_ previewID: String) {
        guard !pendingCancellationIDs.contains(previewID) else { return }
        pendingCancellationIDs.append(previewID)
    }

    private func markCancellationSettled(_ previewID: String) {
        pendingCancellationIDs.removeAll { $0 == previewID }
    }
}

nonisolated enum VoiceSettingsRecoveryAction: Equatable, Sendable {
    case retry
    case reconnect
    case openManagedGatewayUpdate
    case openSelfManagedUpdate
    case repairManagedConfiguration
    case openProviderSetup

    var destination: VoiceSettingsRecoveryDestination? {
        switch self {
        case .openManagedGatewayUpdate:
            return .managedGatewayDetail
        case .openSelfManagedUpdate:
            return .selfManagedUpdateInstructions
        case .openProviderSetup:
            return .providerSetup
        case .retry, .reconnect, .repairManagedConfiguration:
            return nil
        }
    }
}

nonisolated enum VoiceSettingsRecoveryDestination: Equatable, Sendable {
    case managedGatewayDetail
    case selfManagedUpdateInstructions
    case providerSetup
}

nonisolated struct VoiceSettingsFailurePresentation: Equatable, Sendable {
    let message: String
    let action: VoiceSettingsRecoveryAction
}

nonisolated enum VoiceConfigurationRecoveryOutcome: String, Decodable, Equatable, Sendable {
    case alreadyConfigured = "already_configured"
    case repaired
    case subscriptionRequired = "subscription_required"
    case userCredentialsRequired = "user_credentials_required"
}

nonisolated struct VoiceConfigurationRecoveryResponse: Decodable, Equatable, Sendable {
    let outcome: VoiceConfigurationRecoveryOutcome
}

/// Opaque account-bound request captured synchronously at the recovery button tap.
///
/// The shared view can deduplicate by account without ever receiving the bearer token. Platform
/// implementations capture immutable authorization inside `performOperation`, so a task retained
/// across navigation cannot start later under a different signed-in account.
struct VoiceConfigurationRecoveryRequest {
    let accountID: String
    private let performOperation: @MainActor @Sendable () async throws -> VoiceConfigurationRecoveryResponse

    init(
        accountID: String,
        performOperation: @escaping @MainActor @Sendable () async throws -> VoiceConfigurationRecoveryResponse
    ) {
        self.accountID = accountID
        self.performOperation = performOperation
    }

    @MainActor
    func perform() async throws -> VoiceConfigurationRecoveryResponse {
        try await performOperation()
    }
}

nonisolated enum VoiceConfigurationRecoveryRequestPolicy {
    /// The synchronous backend endpoint has about 490 seconds of explicit worst-case work across
    /// two fail-fast ownership checks, Fly wake/readiness, Talk RPC, and activated config patch.
    /// Leave more than 100 seconds for ordinary database and network scheduling overhead. Both
    /// clients must use this same value so one platform cannot abandon an in-flight mutation.
    static let timeoutSeconds: TimeInterval = 600
}

/// Owns managed Voice reconciliation independently of the settings view lifecycle.
///
/// The backend operation can legitimately take several minutes while a Fly gateway wakes and
/// restarts. Navigating away must stop view updates, not cancel a mutation the server has already
/// accepted. A later Voice screen joins the same account-scoped task instead of launching a
/// duplicate request while the first one is still running. Each view owns only a continuation;
/// cancellation removes and resumes that waiter immediately without retaining its view state.
@MainActor
final class VoiceConfigurationRecoveryCoordinator {
    static let shared = VoiceConfigurationRecoveryCoordinator()

    private final class InFlightRecovery {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<VoiceConfigurationRecoveryResult, Never>] = [:]

        init(id: UUID) {
            self.id = id
        }
    }

    private var recoveriesByAccount: [String: InFlightRecovery] = [:]

    func recover(
        accountID: String,
        operation: @escaping @MainActor () async throws -> VoiceConfigurationRecoveryResponse
    ) async -> VoiceConfigurationRecoveryResult {
        let recovery: InFlightRecovery
        if let existing = recoveriesByAccount[accountID] {
            recovery = existing
        } else {
            let recoveryID = UUID()
            let created = InFlightRecovery(id: recoveryID)
            recoveriesByAccount[accountID] = created
            created.task = Task { @MainActor [weak self] in
                let result: VoiceConfigurationRecoveryResult
                do {
                    result = .response((try await operation()).outcome)
                } catch {
                    result = .failed
                }
                self?.finish(accountID: accountID, recoveryID: recoveryID, result: result)
            }
            recovery = created
        }

        let waiterID = UUID()
        let recoveryID = recovery.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                recovery.waiters[waiterID] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWaiter(
                    accountID: accountID,
                    recoveryID: recoveryID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelWaiter(accountID: String, recoveryID: UUID, waiterID: UUID) {
        guard let recovery = recoveriesByAccount[accountID], recovery.id == recoveryID else { return }
        recovery.waiters.removeValue(forKey: waiterID)?.resume(returning: .cancelled)
    }

    private func finish(
        accountID: String,
        recoveryID: UUID,
        result: VoiceConfigurationRecoveryResult
    ) {
        guard let recovery = recoveriesByAccount[accountID], recovery.id == recoveryID else { return }
        recoveriesByAccount[accountID] = nil
        let waiters = Array(recovery.waiters.values)
        recovery.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func inFlightWaiterCount(for accountID: String) -> Int {
        recoveriesByAccount[accountID]?.waiters.count ?? 0
    }
}

nonisolated enum VoiceConfigurationRecoveryResult: Equatable, Sendable {
    case response(VoiceConfigurationRecoveryOutcome)
    case failed
    case cancelled
}

nonisolated enum VoiceConfigurationRecoveryCompletion: Equatable, Sendable {
    case reload
    case openProviderSetup
    case showFailure
    case discardAccountChange
}

nonisolated enum VoiceConfigurationRecoveryPolicy {
    static func ownsCurrentAttempt(
        attemptID: UUID,
        currentAttemptID: UUID?
    ) -> Bool {
        attemptID == currentAttemptID
    }

    static func completion(
        for result: VoiceConfigurationRecoveryResult,
        requestAccountID: String,
        currentAccountID: String?
    ) -> VoiceConfigurationRecoveryCompletion {
        guard currentAccountID == requestAccountID else { return .discardAccountChange }
        switch result {
        case .response(.alreadyConfigured), .response(.repaired):
            return .reload
        case .response(.subscriptionRequired), .response(.userCredentialsRequired):
            return .openProviderSetup
        case .failed, .cancelled:
            return .showFailure
        }
    }

    /// A successful repair starts a replacement operator connection. The old connection can still
    /// report ready when `reconnect()` returns, so only a later false-to-true edge authorizes the
    /// readback. A level check (`isReady == true`) would race the fire-and-forget disconnect.
    static func shouldConsumePendingReload(
        wasReady: Bool,
        isReady: Bool,
        reloadPending: Bool
    ) -> Bool {
        reloadPending && !wasReady && isReady
    }
}

nonisolated enum VoiceConfigurationAccountIdentity {
    static func accountID(fromJWT token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String
        else { return nil }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum VoiceConfigurationRecoveryAuthorizationPolicy {
    /// Long-lived recovery may finish after an auth boundary. It may refresh or clear global auth
    /// state only while the currently stored token still belongs to its captured account.
    static func canMutateCurrentAuthentication(
        requestAccountID: String,
        authorityTokens: Set<String>,
        currentToken: String?
    ) -> Bool {
        guard let currentToken, authorityTokens.contains(currentToken) else { return false }
        return VoiceConfigurationAccountIdentity.accountID(fromJWT: currentToken) == requestAccountID
    }
}

enum VoiceSettingsLoadPresentation {
    static let olderGatewayMessage =
        "Voice choices aren't available on this agent yet. Update the agent and try again."

    static func message(for error: Error) -> String {
        presentation(for: error, gatewayProvider: nil).message
    }

    static func missingProvider(gatewayProvider: GatewayProvider?) -> VoiceSettingsFailurePresentation {
        VoiceSettingsFailurePresentation(
            message: "Voice isn't configured for this agent yet.",
            action: configurationAction(gatewayProvider: gatewayProvider)
        )
    }

    static func presentation(
        for error: Error,
        gatewayProvider: GatewayProvider?
    ) -> VoiceSettingsFailurePresentation {
        guard let response = error as? GatewayResponseError else {
            return VoiceSettingsFailurePresentation(
                message: "Couldn't load voice choices. Check the agent connection and try again.",
                action: .retry
            )
        }

        let code = response.code.uppercased()
        let reason = response.detailsReason?.lowercased()
        let method = response.method.lowercased()
        let isVoiceSettingsMethod = ["talk.catalog", "talk.config", "talk.voices"].contains(method)
        // Existing gateways return INVALID_REQUEST for an unknown method. New
        // gateways emit the exact provider capability reason below. Both are
        // structured wire values; user-facing message text is never parsed.
        if isVoiceSettingsMethod && (code == "INVALID_REQUEST" || reason == "provider_unsupported") {
            return VoiceSettingsFailurePresentation(
                message: olderGatewayMessage,
                action: gatewayProvider == .fly
                    ? .openManagedGatewayUpdate
                    : .openSelfManagedUpdate
            )
        }
        if reason == "provider_authentication" {
            return VoiceSettingsFailurePresentation(
                message: "Voice provider authentication needs attention.",
                action: configurationAction(gatewayProvider: gatewayProvider)
            )
        }
        if reason == "provider_rate_limited" || reason == "provider_quota" {
            return VoiceSettingsFailurePresentation(
                message: "Voice choices are temporarily unavailable. Try again shortly.",
                action: .retry
            )
        }
        if reason == "provider_not_configured" || reason == "provider_configuration" {
            return missingProvider(gatewayProvider: gatewayProvider)
        }
        return VoiceSettingsFailurePresentation(
            message: "Couldn't load voice choices. Check the agent connection and try again.",
            action: .retry
        )
    }

    private static func configurationAction(
        gatewayProvider: GatewayProvider?
    ) -> VoiceSettingsRecoveryAction {
        gatewayProvider == .fly ? .repairManagedConfiguration : .openProviderSetup
    }
}

enum VoiceSettingsReadinessPolicy {
    /// Voice settings use operator RPCs. Node health can keep the aggregate
    /// gateway state disconnected even after the operator leg is ready.
    static func canIssueOperatorRequests(
        operatorReady: Bool,
        aggregateConnected _: Bool
    ) -> Bool {
        operatorReady
    }
}

enum VoiceConfigPatchAcknowledgement: Equatable, Sendable {
    case accepted
    case ambiguous
    case rejected
}

enum VoiceConfigReadback: Equatable, Sendable {
    case matched
    case different
    case unavailable
}

struct VoiceSaveDecision: Equatable, Sendable {
    let shouldPoll: Bool
    let isConfirmed: Bool
    let visibleVoiceID: String?
}

enum VoiceSaveLifecyclePolicy {
    static func afterPatch(
        _ acknowledgement: VoiceConfigPatchAcknowledgement,
        previousVoiceID: String?,
        requestedVoiceID: String
    ) -> VoiceSaveDecision {
        switch acknowledgement {
        case .accepted, .ambiguous:
            VoiceSaveDecision(
                shouldPoll: true,
                isConfirmed: false,
                visibleVoiceID: requestedVoiceID
            )
        case .rejected:
            VoiceSaveDecision(
                shouldPoll: false,
                isConfirmed: false,
                visibleVoiceID: previousVoiceID
            )
        }
    }

    static func afterReadback(
        _ readback: VoiceConfigReadback,
        previousVoiceID: String?,
        requestedVoiceID: String
    ) -> VoiceSaveDecision {
        switch readback {
        case .matched:
            VoiceSaveDecision(
                shouldPoll: false,
                isConfirmed: true,
                visibleVoiceID: requestedVoiceID
            )
        case .different, .unavailable:
            VoiceSaveDecision(
                shouldPoll: false,
                isConfirmed: false,
                visibleVoiceID: previousVoiceID
            )
        }
    }
}

private enum VoiceSettingsModelError: LocalizedError {
    case invalidPatchEncoding

    var errorDescription: String? {
        "Could not prepare the voice setting."
    }
}
