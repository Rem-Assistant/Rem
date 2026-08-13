#if os(iOS)
import SwiftUI

struct CloudGatewayDeploySheet<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    var isRepair: Bool = false
    var onConfigured: (GatewayConfig) -> Void = { _ in }
    var onComplete: (GatewayConfig) -> Void
    var onCancel: () -> Void

    @State private var deployPhase = "creating_project"
    @State private var deployError: String?
    @State private var deployStartDate: Date?
    @State private var deployAttempt = 0
    @State private var isComplete = false
    @State private var canRetryDeploy = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.top, DesignTokens.Spacing.sm)

                Spacer()

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Image(systemName: isComplete ? "checkmark.seal.fill" : (isRepair ? "arrow.clockwise.icloud.fill" : "cloud.fill"))
                        .font(.system(size: 40))
                        .foregroundColor(isComplete ? DesignTokens.Color.systemGreen : DesignTokens.Color.buttonBackground)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(isComplete ? "Gateway Ready" : (isRepair ? "Repairing Cloud Gateway" : "Deploying Cloud Gateway"))
                            .font(DesignTokens.Typography.largeTitle.weight(.semibold))
                            .foregroundColor(DesignTokens.Color.labelPrimary)

                        Text(isComplete ? "Your cloud gateway is connected." : progressDescription)
                            .font(DesignTokens.Typography.title1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                            .padding(.top, DesignTokens.Spacing.xs)
                    }

                    phaseList

                    if let deployError {
                        errorBlock(deployError)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.md)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(deployError == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if deployError != nil && canRetryDeploy {
                        Button("Retry") {
                            deployAttempt += 1
                        }
                    }
                }
            }
            .task(id: deployAttempt) {
                await startDeploy()
            }
            .interactiveDismissDisabled(deployError == nil)
        }
    }

    private var progressBar: some View {
        let progress = isComplete ? 1.0 : CloudGatewayDeployPhaseInfo.progress(for: deployPhase)
        return VStack(spacing: DesignTokens.Spacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Color.systemGreen.opacity(0.35))
                        .frame(height: 4)

                    Capsule()
                        .fill(DesignTokens.Color.systemGreen)
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 4)

            HStack {
                Text("This may take a minute or two")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelTertiary)

                Spacer()

                if let start = deployStartDate, !isComplete {
                    CloudGatewayElapsedTimeLabel(since: start)
                }
            }
        }
    }

    private var progressDescription: String {
        if isRepair {
            return "Reconnecting your existing Fly.io gateway. This will not create a new cloud gateway."
        }
        return "Creating a Fly.io gateway for this device."
    }

    private var phaseList: some View {
        let hasError = deployError != nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(CloudGatewayDeployPhaseInfo.allPhases.enumerated()), id: \.element.id) { index, phase in
                let state = phase.state(current: deployPhase, hasError: hasError)
                let isLast = index == CloudGatewayDeployPhaseInfo.allPhases.count - 1
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    VStack(spacing: 0) {
                        phaseIcon(state)
                            .frame(width: 20, height: 20)
                        if !isLast {
                            Rectangle()
                                .fill(
                                    state == .done
                                        ? DesignTokens.Color.systemGreen.opacity(0.35)
                                        : state == .failed
                                            ? DesignTokens.Color.systemRed.opacity(0.35)
                                            : DesignTokens.Color.separator
                                )
                                .frame(width: 2, height: 32)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.label)
                            .font(.headline)
                            .foregroundColor(state == .pending ? DesignTokens.Color.labelTertiary : DesignTokens.Color.labelPrimary)
                        Text(phase.subLabel(current: deployPhase))
                            .font(DesignTokens.Typography.footnote)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                    .padding(.bottom, isLast ? 0 : DesignTokens.Spacing.sm)
                }
            }
        }
    }

    @ViewBuilder
    private func phaseIcon(_ state: CloudGatewayDeployPhaseInfo.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DesignTokens.Color.systemGreen)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(DesignTokens.Color.systemRed)
        case .pending:
            Circle()
                .stroke(DesignTokens.Color.separator, lineWidth: 2)
                .frame(width: 16, height: 16)
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(canRetryDeploy ? "Deployment failed" : "Connection not ready")
                .font(.headline)
                .foregroundColor(DesignTokens.Color.systemRed)
            Text(error)
                .font(.callout)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.systemRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func startDeploy() async {
        deployPhase = "creating_project"
        deployError = nil
        deployStartDate = Date()
        isComplete = false
        canRetryDeploy = true

        do {
            try await CloudGatewayDeployClient.validateBackendAccount()
            let result = try await CloudGatewayDeployClient.startDeploy(forceRedeploy: isRepair)
            if try await handleStatus(result.status) {
                return
            }
            try await pollStatus(deployId: result.deployId)
        } catch is CancellationError {
            return
        } catch {
            deployError = error.localizedDescription
        }
    }

    private func pollStatus(deployId: String) async throws {
        while true {
            try await Task.sleep(for: .seconds(1))
            let status = try await CloudGatewayDeployClient.getDeployStatus(deployId: deployId)
            if try await handleStatus(status) {
                return
            }
        }
    }

    @discardableResult
    private func handleStatus(_ status: CloudGatewayDeployClient.StatusResponse) async throws -> Bool {
        deployPhase = status.phase

        switch CloudGatewayDeployStatusDecision.resolve(status) {
        case .configure(let config):
            gateway.configure(gatewayURL: config.url, gatewayToken: config.token)
            onConfigured(config)
            let connectionState = try await waitForConnection(timeout: 75)
            try Task.checkCancellation()
            switch CloudGatewayDeployConnectionDecision.resolve(connectionState) {
            case .complete:
                isComplete = true
                onComplete(config)
            case .notReady(let message):
                canRetryDeploy = false
                deployError = message
            }
            return true
        case .missingCredentials:
            throw CloudGatewayDeployError.missingCredentials
        case .failed(let message):
            deployError = message
            return true
        case .continuePolling:
            return false
        }
    }

    private func waitForConnection(timeout: TimeInterval) async throws -> GatewayConnectionState {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: .milliseconds(500))
            if gateway.connectionState.isConnected {
                try await Task.sleep(for: .seconds(1))
                return gateway.connectionState
            }
        }
        return gateway.connectionState
    }
}

enum CloudGatewayDeployStatusDecision: Equatable {
    case configure(GatewayConfig)
    case missingCredentials
    case failed(String)
    case continuePolling

    static func resolve(_ status: CloudGatewayDeployClient.StatusResponse) -> Self {
        switch status.phase {
        case "complete":
            guard let url = status.gatewayUrl, let token = status.gatewayToken else {
                return .missingCredentials
            }
            return .configure(GatewayConfig(
                url: url,
                token: token,
                provider: .fly,
                displayName: "Cloud Gateway",
                isActive: true
            ))
        case "failed":
            return .failed(status.message)
        default:
            return .continuePolling
        }
    }
}

enum CloudGatewayDeployConnectionDecision: Equatable {
    case complete
    case notReady(String)

    static func resolve(_ connectionState: GatewayConnectionState) -> Self {
        if connectionState.isConnected {
            return .complete
        }
        return .notReady(CloudGatewayDeployError.connectionNotReady(connectionState).localizedDescription)
    }
}

enum CloudGatewayDeployClient {
    struct DeployResponse: Decodable {
        let deployId: String
        let status: StatusResponse
    }

    struct StatusResponse: Decodable {
        let phase: String
        let message: String
        let gatewayUrl: String?
        let gatewayToken: String?
    }

    struct StatusWrapper: Decodable {
        let status: StatusResponse
    }

    static func startDeploy(forceRedeploy: Bool = false) async throws -> DeployResponse {
        let body = try JSONEncoder().encode(DeployRequest(forceRedeploy: forceRedeploy))
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/deploy",
            method: "POST",
            body: body
        )
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudGatewayDeployError.serverError(body, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(DeployResponse.self, from: data)
    }

    static func getDeployStatus(deployId: String) async throws -> StatusResponse {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/deploy/status?id=\(deployId)",
            method: "GET"
        )
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudGatewayDeployError.serverError(body, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(StatusWrapper.self, from: data).status
    }

    private struct DeployRequest: Encodable {
        let forceRedeploy: Bool
    }

    static func validateBackendAccount() async throws {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/me",
            method: "GET",
            timeout: 15
        )
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                AuthenticatedHttpClient.onUnauthorized?()
                throw CloudGatewayDeployError.staleBackendAccount
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudGatewayDeployError.serverError(body, statusCode: http.statusCode)
        }
    }
}

enum CloudGatewayDeployError: LocalizedError {
    case serverError(String, statusCode: Int? = nil)
    case missingCredentials
    case connectionNotReady(GatewayConnectionState)
    case staleBackendAccount

    var errorDescription: String? {
        switch self {
        case .serverError(let message, _):
            return "Server error: \(message)"
        case .missingCredentials:
            return "Deployment completed without gateway credentials. Try again."
        case .connectionNotReady(let state):
            switch state {
            case .pairingRequired:
                return "Gateway deployed, but this device is still waiting for approval. Do not deploy another cloud gateway yet. Open the gateway detail and use the pairing recovery actions, or try reconnecting after a moment."
            case .unreachable(let detail):
                let suffix = detail.map { " (\($0))" } ?? ""
                return "Gateway deployed, but Rem could not connect\(suffix). Do not deploy another cloud gateway yet. Try reconnecting from the gateway detail."
            default:
                return "Gateway deployed, but Rem did not connect yet (\(state.statusText)). Do not deploy another cloud gateway yet. Try reconnecting from the gateway detail."
            }
        case .staleBackendAccount:
            return "Your saved session no longer exists on this backend. Sign in again before repairing your cloud gateway."
        }
    }

    var httpStatusCode: Int? {
        switch self {
        case .serverError(_, let code):
            return code
        case .missingCredentials, .connectionNotReady, .staleBackendAccount:
            return nil
        }
    }
}

struct CloudGatewayDeployPhaseInfo: Identifiable {
    let id: String
    let label: String
    let phases: [String]
    let subLabels: [String: String]
    let defaultSubLabel: String

    enum State { case pending, active, done, failed }

    func state(current: String, hasError: Bool = false) -> State {
        let ordered = Self.orderedPhases
        guard let currentIdx = ordered.firstIndex(of: current) else { return .pending }
        let myIndices = phases.compactMap { ordered.firstIndex(of: $0) }
        guard let myMin = myIndices.min(), let myMax = myIndices.max() else { return .pending }
        if currentIdx > myMax { return .done }
        if currentIdx >= myMin && currentIdx <= myMax {
            return hasError ? .failed : .active
        }
        return .pending
    }

    func subLabel(current: String) -> String {
        guard state(current: current) == .active else { return defaultSubLabel }
        return subLabels[current] ?? defaultSubLabel
    }

    static let orderedPhases = [
        "creating_project", "setting_variables", "deploying",
        "waiting_for_healthy", "running_onboarding", "saving_credentials", "complete"
    ]

    static func progress(for phase: String) -> CGFloat {
        switch phase {
        case "creating_project":    return 0.05
        case "setting_variables":   return 0.15
        case "deploying":           return 0.25
        case "waiting_for_healthy": return 0.55
        case "running_onboarding":  return 0.75
        case "saving_credentials":  return 0.90
        case "complete":            return 0.97
        default:                    return 0.0
        }
    }

    static let allPhases: [CloudGatewayDeployPhaseInfo] = [
        .init(
            id: "create",
            label: "Creating Server",
            phases: ["creating_project", "setting_variables"],
            subLabels: [
                "creating_project": "Setting up your private server",
                "setting_variables": "Preparing secure environment"
            ],
            defaultSubLabel: "Setting up your private server"
        ),
        .init(
            id: "deploy",
            label: "Deploying Server",
            phases: ["deploying", "waiting_for_healthy"],
            subLabels: [
                "deploying": "Launching your server",
                "waiting_for_healthy": "Waiting for server to come online"
            ],
            defaultSubLabel: "Launching your server"
        ),
        .init(
            id: "gateway",
            label: "Configuring Server",
            phases: ["running_onboarding"],
            subLabels: [
                "running_onboarding": "Customizing server for your AI assistant"
            ],
            defaultSubLabel: "Customizing server for your AI assistant"
        ),
        .init(
            id: "finish",
            label: "Finishing Up",
            phases: ["saving_credentials", "complete"],
            subLabels: [
                "saving_credentials": "Saving your connection details",
                "complete": "Your server is ready"
            ],
            defaultSubLabel: "Connecting to your server"
        )
    ]
}

private struct CloudGatewayElapsedTimeLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(formattedElapsed(context.date.timeIntervalSince(since)))
                .font(DesignTokens.Typography.footnote)
                .foregroundColor(DesignTokens.Color.labelTertiary)
                .monospacedDigit()
        }
    }

    private func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

#if DEBUG
struct CloudGatewayDeployFixtureView: View {
    enum Mode {
        case all
        case deploy
        case repair
        case approval

        static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
            if arguments.contains("--rem-cloud-deploy-progress-fixture") { return .deploy }
            if arguments.contains("--rem-cloud-repair-progress-fixture") { return .repair }
            if arguments.contains("--rem-cloud-deploy-approval-fixture") { return .approval }
            return .all
        }
    }

    private let compact: Bool
    private let mode: Mode

    init(
        mode: Mode = .fromLaunchArguments(),
        compact: Bool = ProcessInfo.processInfo.arguments.contains("--rem-cloud-deploy-compact-fixture")
    ) {
        self.mode = mode
        self.compact = compact
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                fixtureHeader

                if mode == .deploy {
                    deployFixture
                } else if mode == .repair {
                    repairFixture
                } else if mode == .approval {
                    approvalFixture
                } else {
                    deployFixture
                    repairFixture
                    approvalFixture
                }
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .background(DesignTokens.Color.backgroundPrimary)
    }

    private var fixtureHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Cloud Gateway Deploy")
                .font(DesignTokens.Typography.title3Bold)
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Text("Deterministic fixture for Wave 2 cloud deploy, repair, and approval recovery screenshots.")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }

    private var deployFixture: some View {
        fixtureFrame("New cloud gateway deploying") {
            CloudGatewayDeployPhaseFixtureCard(
                title: "Deploying Cloud Gateway",
                subtitle: "Creating a Fly.io gateway for this device.",
                phase: "waiting_for_healthy",
                isRepair: false
            )
        }
    }

    private var repairFixture: some View {
        fixtureFrame("Repair keeps the same gateway") {
            CloudGatewayDeployPhaseFixtureCard(
                title: "Repairing Cloud Gateway",
                subtitle: "Reconnecting your existing Fly.io gateway. This will not create a new cloud gateway.",
                phase: "running_onboarding",
                isRepair: true
            )
        }
    }

    private var approvalFixture: some View {
        fixtureFrame("Connection still needs approval") {
            CloudGatewayDeployPhaseFixtureCard(
                title: "Connection not ready",
                subtitle: "Gateway deployed, but this device is still waiting for approval. Do not deploy another cloud gateway yet. Open the gateway detail and use the pairing recovery actions, or try reconnecting after a moment.",
                phase: "complete",
                isRepair: true,
                errorTitle: "Connection not ready",
                errorMessage: CloudGatewayDeployError.connectionNotReady(.pairingRequired).localizedDescription
            )
        }
    }

    private func fixtureFrame<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)

            content()
                .frame(height: mode == .approval ? 620 : (compact ? 390 : 470))
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
        }
    }
}

#Preview("Cloud Deploy — First Deploy") {
    CloudGatewayDeployFixtureView(mode: .deploy)
}

#Preview("Cloud Deploy — Repair Deploy") {
    CloudGatewayDeployFixtureView(mode: .repair)
}

#Preview("Cloud Deploy — Approval Waiting") {
    CloudGatewayDeployFixtureView(mode: .approval)
}

private struct CloudGatewayDeployPhaseFixtureCard: View {
    let title: String
    let subtitle: String
    let phase: String
    let isRepair: Bool
    var errorTitle: String?
    var errorMessage: String?

    private var progress: CGFloat {
        errorMessage == nil ? CloudGatewayDeployPhaseInfo.progress(for: phase) : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Image(systemName: isRepair ? "arrow.clockwise.icloud.fill" : "cloud.fill")
                    .font(.system(size: 40))
                    .foregroundColor(errorMessage == nil ? DesignTokens.Color.buttonBackground : DesignTokens.Color.systemRed)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(title)
                        .font(DesignTokens.Typography.title1.weight(.semibold))
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(subtitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                phaseList

                if let errorTitle, let errorMessage {
                    errorBlock(title: errorTitle, message: errorMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)

            Spacer(minLength: 0)
        }
        .background(DesignTokens.Color.backgroundPrimary)
    }

    private var progressBar: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Color.systemGreen.opacity(0.35))
                        .frame(height: 4)

                    Capsule()
                        .fill(errorMessage == nil ? DesignTokens.Color.systemGreen : DesignTokens.Color.systemRed)
                        .frame(width: geo.size.width * progress, height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text(errorMessage == nil ? "This may take a minute or two" : "Do not deploy another gateway")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelTertiary)

                Spacer()

                Text(errorMessage == nil ? "1:18" : "Needs approval")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelTertiary)
                    .monospacedDigit()
            }
        }
    }

    private var phaseList: some View {
        let hasError = errorMessage != nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(CloudGatewayDeployPhaseInfo.allPhases.enumerated()), id: \.element.id) { index, item in
                let state = item.state(current: phase, hasError: hasError && item.id == "finish")
                let isLast = index == CloudGatewayDeployPhaseInfo.allPhases.count - 1
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    VStack(spacing: 0) {
                        phaseIcon(state)
                            .frame(width: 20, height: 20)
                        if !isLast {
                            Rectangle()
                                .fill(state == .done ? DesignTokens.Color.systemGreen.opacity(0.35) : DesignTokens.Color.separator)
                                .frame(width: 2, height: 26)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.headline)
                            .foregroundColor(state == .pending ? DesignTokens.Color.labelTertiary : DesignTokens.Color.labelPrimary)
                        Text(item.subLabel(current: phase))
                            .font(DesignTokens.Typography.footnote)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                    .padding(.bottom, isLast ? 0 : DesignTokens.Spacing.sm)
                }
            }
        }
    }

    @ViewBuilder
    private func phaseIcon(_ state: CloudGatewayDeployPhaseInfo.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DesignTokens.Color.systemGreen)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(DesignTokens.Color.systemRed)
        case .pending:
            Circle()
                .stroke(DesignTokens.Color.separator, lineWidth: 2)
                .frame(width: 16, height: 16)
        }
    }

    private func errorBlock(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(.headline)
                .foregroundColor(DesignTokens.Color.systemRed)
            Text(message)
                .font(.callout)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.systemRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif
#endif
