import SwiftUI

enum SessionPreviewSurfaceState: String, CaseIterable, Identifiable, Sendable {
    case unavailable = "Unavailable"
    case needsMac = "Needs Mac"
    case macOffline = "Mac Offline"
    case needsOSPermission = "Needs OS Permission"
    case needsApproval = "Needs Approval"
    case awaitingApproval = "Awaiting Approval"
    case actionFeedOnly = "Action Feed Only"
    case previewAvailable = "Preview Available"
    case blocked = "Blocked"
    case failed = "Failed"
    case running = "Running"
    case logged = "Logged"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .unavailable: "eye.slash"
        case .needsMac: "desktopcomputer.trianglebadge.exclamationmark"
        case .macOffline: "bolt.slash"
        case .needsOSPermission: "hand.raised"
        case .needsApproval: "person.badge.key"
        case .awaitingApproval: "hourglass"
        case .actionFeedOnly: "list.bullet.rectangle"
        case .previewAvailable: "rectangle.on.rectangle"
        case .blocked: "lock.shield"
        case .failed: "exclamationmark.triangle"
        case .running: "waveform.path.ecg"
        case .logged: "checkmark.seal"
        }
    }

    var tint: Color {
        switch self {
        case .previewAvailable, .logged:
            DesignTokens.Color.systemGreen
        case .running, .actionFeedOnly:
            DesignTokens.Color.systemBlue
        case .needsApproval, .awaitingApproval, .needsOSPermission, .macOffline, .needsMac:
            DesignTokens.Color.systemOrange
        case .blocked, .unavailable:
            DesignTokens.Color.systemRed
        case .failed:
            DesignTokens.Color.systemRed
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            "This session has no preview source."
        case .needsMac:
            "Mac-local actions need a paired Mac gateway."
        case .macOffline:
            "The Mac gateway is not reachable."
        case .needsOSPermission:
            "The Mac needs the required system permission first."
        case .needsApproval:
            "A sensitive action needs explicit approval."
        case .awaitingApproval:
            "Rem is waiting for approval before showing more detail."
        case .actionFeedOnly:
            "Showing redacted action metadata without screen content."
        case .previewAvailable:
            "Preview metadata is available for approved session activity."
        case .blocked:
            "Policy blocked this preview action."
        case .failed:
            "The preview action failed before producing metadata."
        case .running:
            "The current tool phase is still running."
        case .logged:
            "This entry was saved as action-log metadata."
        }
    }
}

struct SessionPreviewFeedModel: Equatable, Sendable {
    var state: SessionPreviewSurfaceState
    var gatewayName: String
    var deviceName: String?
    var entries: [SessionPreviewEntry]
    var showsThumbnailPlaceholder: Bool

    init(
        state: SessionPreviewSurfaceState,
        gatewayName: String,
        deviceName: String? = nil,
        entries: [SessionPreviewEntry],
        showsThumbnailPlaceholder: Bool = false
    ) {
        self.state = state
        self.gatewayName = gatewayName
        self.deviceName = deviceName
        self.entries = entries
        self.showsThumbnailPlaceholder = showsThumbnailPlaceholder
    }
}

struct SessionPreviewContext: Equatable, Sendable {
    var gatewayProvider: SessionPreviewEntry.GatewayProvider
    var gatewayName: String
    var gatewayId: String?
    var deviceId: String?
    var deviceName: String?

    init(
        gatewayProvider: SessionPreviewEntry.GatewayProvider = .unknown,
        gatewayName: String = "Active gateway",
        gatewayId: String? = nil,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.gatewayProvider = gatewayProvider
        self.gatewayName = gatewayName
        self.gatewayId = gatewayId
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

struct SharedSessionPreviewFeedView: View {
    let model: SessionPreviewFeedModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header

                if model.showsThumbnailPlaceholder {
                    approvedPreviewPlaceholder
                }

                feedSection
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Session Preview")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                Image(systemName: model.state.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.state.tint)
                    .frame(width: 36, height: 36)
                    .background(model.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state.rawValue)
                        .font(DesignTokens.Typography.title3Bold)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                    Text(model.state.detail)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                sourcePill(icon: "network", text: model.gatewayName)
                if let deviceName = model.deviceName {
                    sourcePill(icon: "macbook.and.iphone", text: deviceName)
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignTokens.Color.separator.opacity(0.7), lineWidth: 1)
        )
    }

    private func sourcePill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(DesignTokens.Typography.caption1)
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            .background(DesignTokens.Color.pillBackground, in: Capsule())
    }

    private var approvedPreviewPlaceholder: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Label("Approved Preview", systemImage: "rectangle.on.rectangle")
                    .font(DesignTokens.Typography.caption1Bold)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Spacer()
                Text("Redacted")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(DesignTokens.Color.backgroundTertiary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "lock.rectangle")
                            .font(.title2)
                        Text("Thumbnail appears only after approval")
                            .font(DesignTokens.Typography.footnote)
                    }
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Action Feed")
                .font(DesignTokens.Typography.caption1Bold)
                .foregroundStyle(DesignTokens.Color.labelSecondary)

            VStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    SessionPreviewEntryRow(entry: entry)
                    if entry.id != model.entries.last?.id {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
            .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignTokens.Color.separator.opacity(0.55), lineWidth: 1)
            )
        }
    }
}

private struct SessionPreviewEntryRow: View {
    let entry: SessionPreviewEntry

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(title)
                        .font(DesignTokens.Typography.bodyBold)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(statusText)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }

                if let target = entry.targetSummary {
                    Text(target)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(2)
                }

                if let result = entry.resultSummary {
                    Text(result)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                        .lineLimit(3)
                }

                HStack(spacing: 6) {
                    metadataPill(modeText)
                    metadataPill(approvalText)
                    metadataPill(retentionText)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    private var title: String {
        switch entry.capability {
        case .chat: "Chat"
        case .shell: "Shell"
        case .files: "Files"
        case .clipboard: "Clipboard"
        case .screenContext: "Screen Context"
        case .browserAutomation: "Browser"
        case .gatewayConfig: "Gateway"
        }
    }

    private var icon: String {
        switch entry.capability {
        case .chat: "bubble.left.and.bubble.right"
        case .shell: "terminal"
        case .files: "folder"
        case .clipboard: "doc.on.clipboard"
        case .screenContext: "rectangle.dashed"
        case .browserAutomation: "globe"
        case .gatewayConfig: "gearshape"
        }
    }

    private var tint: Color {
        switch entry.status {
        case .succeeded, .logged: DesignTokens.Color.systemGreen
        case .running, .awaitingApproval: DesignTokens.Color.systemBlue
        case .needsApproval, .unavailable: DesignTokens.Color.systemOrange
        case .failed, .blocked: DesignTokens.Color.systemRed
        }
    }

    private var statusText: String {
        switch entry.status {
        case .unavailable: "Unavailable"
        case .needsApproval: "Needs approval"
        case .awaitingApproval: "Awaiting approval"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .blocked: "Blocked"
        case .logged: "Logged"
        }
    }

    private var modeText: String {
        switch entry.mode {
        case .activity: "Activity"
        case .toolPhase: "Tool phase"
        case .gatewayDevice: "Gateway device"
        case .screenshotThumbnail: "Screenshot thumbnail"
        case .appMetadata: "App metadata"
        case .browserPreview: "Browser preview"
        case .blocked: "Blocked"
        }
    }

    private var approvalText: String {
        switch entry.approvalClass {
        case .unavailable: "Unavailable"
        case .askEveryTime: "Ask every time"
        case .allowOnce: "Allow once"
        case .allowForSession: "Allowed for session"
        case .persistentScopedAllow: "Scoped allow"
        case .blockedByPolicy: "Blocked by policy"
        }
    }

    private var retentionText: String {
        switch entry.retention {
        case .transient: "Transient"
        case .actionLogMetadata: "Action-log metadata"
        case .explicitlySavedEvidence: "Saved evidence"
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.caption1)
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DesignTokens.Color.pillBackground, in: Capsule())
    }
}

#if DEBUG
struct SharedSessionPreviewFixtureView: View {
    private let models = SessionPreviewFixtureModels.all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.xl) {
                    ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                        SharedSessionPreviewFeedView(model: model)
                            .frame(maxWidth: 720)
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
            .background(DesignTokens.Color.backgroundPrimary)
            .navigationTitle("Session Preview States")
        }
        #if os(macOS)
        .frame(width: 760, height: 760)
        #endif
    }
}

enum SessionPreviewFixtureModels {
    static let all: [SessionPreviewFeedModel] = [
        model(.unavailable, entries: [
            .unsupportedMacLocalPreview(
                sessionId: "fixture-session-unavailable",
                gatewayId: "cloud-gateway-fixture",
                gatewayProvider: .cloud,
                requestedMode: .screenshotThumbnail,
                now: Date(timeIntervalSince1970: 10)
            ),
        ]),
        model(.needsMac, gatewayName: "Cloud Gateway", deviceName: nil, entries: [
            .fromAgentEvent(
                stream: "screen.capture",
                runId: "fixture-needs-mac",
                data: ["phase": "running", "window": "Finder"],
                gatewayProvider: .cloud,
                now: Date(timeIntervalSince1970: 20)
            ),
        ]),
        model(.macOffline, entries: [
            entry(status: .failed, target: "Local Mac gateway", result: "Mac is offline or Rem is not running."),
        ]),
        model(.needsOSPermission, entries: [
            entry(status: .needsApproval, target: "Screen Recording", result: "Grant Screen Recording before screenshot thumbnails can appear."),
        ]),
        model(.needsApproval, entries: [
            entry(status: .needsApproval, target: "Read active window title", result: "Waiting for explicit approval."),
        ]),
        model(.awaitingApproval, entries: [
            entry(status: .awaitingApproval, target: "Open Settings", result: "Approval request sent to paired Mac."),
        ]),
        model(.actionFeedOnly, entries: [
            .fromChatState("final", sessionId: "chat-fixture-action-feed", gatewayProvider: .mac),
            .fromAgentEvent(stream: "tool", runId: "tool-fixture", data: ["tool": "browser.open", "message": "Opened [redacted URL]"], gatewayProvider: .mac),
        ]),
        model(.previewAvailable, entries: [
            entry(status: .succeeded, target: "Approved screenshot thumbnail", result: "Saved redacted thumbnail metadata.", mode: .screenshotThumbnail, retention: .explicitlySavedEvidence),
        ], showsThumbnailPlaceholder: true),
        model(.blocked, entries: [
            .fromAgentEvent(stream: "screen.capture", runId: "blocked-fixture", data: ["phase": "blocked by policy", "window": "Mail - Inbox"], gatewayProvider: .mac),
        ]),
        model(.failed, entries: [
            entry(status: .failed, target: "Screen context request", result: "The paired Mac stopped responding before metadata was saved."),
        ]),
        model(.running, entries: [
            .fromAgentEvent(stream: "tool", runId: "running-fixture", data: ["tool": "terminal", "message": "git status --short"], gatewayProvider: .mac),
        ]),
        model(.logged, entries: [
            entry(status: .logged, target: "Action log", result: "Stored redacted session metadata."),
        ]),
        model(.logged, gatewayName: "Local Mac Gateway", deviceName: "Avery's MacBook Pro", entries: [
            .fromCompletedTool(
                name: "browser.open",
                resultStatus: "ok",
                toolCallId: "fixture-tool-browser",
                sessionId: "fixture-restored-session",
                gatewayId: "fixture-gateway",
                gatewayProvider: .mac,
                deviceId: "fixture-device",
                now: Date(timeIntervalSince1970: 90)
            ),
            .fromCompletedTool(
                name: "shell.run",
                resultStatus: "error",
                toolCallId: "fixture-tool-shell",
                sessionId: "fixture-restored-session",
                gatewayId: "fixture-gateway",
                gatewayProvider: .mac,
                deviceId: "fixture-device",
                now: Date(timeIntervalSince1970: 95)
            ),
            .fromChatState(
                "final",
                sessionId: "fixture-restored-session",
                gatewayId: "fixture-gateway",
                gatewayProvider: .mac,
                deviceId: "fixture-device",
                now: Date(timeIntervalSince1970: 100)
            ),
        ]),
    ]

    private static func model(
        _ state: SessionPreviewSurfaceState,
        gatewayName: String = "Local Mac Gateway",
        deviceName: String? = "Avery's MacBook Pro",
        entries: [SessionPreviewEntry],
        showsThumbnailPlaceholder: Bool = false
    ) -> SessionPreviewFeedModel {
        SessionPreviewFeedModel(
            state: state,
            gatewayName: gatewayName,
            deviceName: deviceName,
            entries: entries,
            showsThumbnailPlaceholder: showsThumbnailPlaceholder
        )
    }

    private static func entry(
        status: SessionPreviewEntry.Status,
        target: String,
        result: String,
        mode: SessionPreviewEntry.Mode = .toolPhase,
        retention: SessionPreviewEntry.Retention = .actionLogMetadata
    ) -> SessionPreviewEntry {
        SessionPreviewEntry(
            sessionId: "fixture-session",
            gatewayId: "fixture-gateway",
            gatewayProvider: .mac,
            deviceId: "fixture-device",
            mode: mode,
            capability: .screenContext,
            status: status,
            targetSummary: target,
            resultSummary: result,
            approvalClass: status == .blocked ? .blockedByPolicy : .askEveryTime,
            retention: retention
        )
    }
}

#Preview("Session Preview States") {
    SharedSessionPreviewFixtureView()
}
#endif
