import Foundation
import OpenClawKit
import OpenClawProtocol

/// Redacted, UI-safe observability entry for the session preview feed.
///
/// This is the data contract from `docs/product/SESSION_PREVIEW_CONTRACT.md`:
/// preview starts as activity/tool-phase observability, not remote desktop.
public struct SessionPreviewEntry: Codable, Equatable, Identifiable, Sendable {
    public enum GatewayProvider: String, Codable, Sendable {
        case mac
        case cloud
        case manual
        case unknown

        fileprivate var macLocalUnavailableSubject: String {
            switch self {
            case .cloud: "Cloud gateway"
            case .unknown: "Unknown gateway"
            case .manual: "Manual gateway"
            case .mac: "Mac gateway"
            }
        }
    }

    public enum Mode: String, Codable, Sendable {
        case activity
        case toolPhase
        case gatewayDevice
        case screenshotThumbnail
        case appMetadata
        case browserPreview
        case blocked
    }

    public enum Capability: String, Codable, Sendable {
        case chat
        case shell
        case files
        case clipboard
        case screenContext
        case browserAutomation
        case gatewayConfig
    }

    public enum Status: String, Codable, Sendable {
        case unavailable
        case needsApproval
        case awaitingApproval
        case running
        case succeeded
        case failed
        case blocked
        case logged
    }

    public enum ApprovalClass: String, Codable, Sendable {
        case unavailable
        case askEveryTime
        case allowOnce
        case allowForSession
        case persistentScopedAllow
        case blockedByPolicy
    }

    public enum Retention: String, Codable, Sendable {
        case transient
        case actionLogMetadata
        case explicitlySavedEvidence
    }

    public var id: String
    public var createdAt: Date
    public var sessionId: String?
    public var gatewayId: String?
    public var gatewayProvider: GatewayProvider
    public var deviceId: String?
    public var mode: Mode
    public var capability: Capability
    public var status: Status
    public var targetSummary: String?
    public var resultSummary: String?
    public var approvalClass: ApprovalClass
    public var retention: Retention

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        sessionId: String?,
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        deviceId: String? = nil,
        mode: Mode,
        capability: Capability,
        status: Status,
        targetSummary: String? = nil,
        resultSummary: String? = nil,
        approvalClass: ApprovalClass,
        retention: Retention = .actionLogMetadata
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sessionId = Self.redactIdentifier(sessionId)
        self.gatewayId = Self.redactIdentifier(gatewayId)
        self.gatewayProvider = gatewayProvider
        self.deviceId = Self.redactIdentifier(deviceId)
        self.mode = mode
        self.capability = capability
        self.status = status
        self.targetSummary = Self.redactedSummary(targetSummary)
        self.resultSummary = Self.redactedSummary(resultSummary)
        self.approvalClass = approvalClass
        self.retention = retention
    }

    public static func fromChatState(
        _ state: String?,
        sessionId: String?,
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        deviceId: String? = nil,
        now: Date = Date()
    ) -> SessionPreviewEntry {
        let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status: Status
        switch normalized {
        case "final", "done", "complete", "completed":
            status = .succeeded
        case "error", "failed", "failure":
            status = .failed
        case "blocked":
            status = .blocked
        case "approval", "awaiting_approval", "awaiting-approval", "approval_pending":
            status = .awaitingApproval
        default:
            status = .running
        }

        return SessionPreviewEntry(
            createdAt: now,
            sessionId: sessionId,
            gatewayId: gatewayId,
            gatewayProvider: gatewayProvider,
            deviceId: deviceId,
            mode: .activity,
            capability: .chat,
            status: status,
            resultSummary: normalized.map { "Chat \($0)" } ?? "Chat activity",
            approvalClass: .allowForSession
        )
    }

    public static func fromAgentEvent(
        stream: String,
        runId: String?,
        data: [String: String],
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        deviceId: String? = nil,
        now: Date = Date()
    ) -> SessionPreviewEntry {
        let capability = inferCapability(stream: stream, data: data)
        let status = inferStatus(stream: stream, data: data)

        if requiresMacLocalGateway(capability),
           gatewayProvider == .cloud || gatewayProvider == .unknown {
            return SessionPreviewEntry(
                createdAt: now,
                sessionId: runId,
                gatewayId: gatewayId,
                gatewayProvider: gatewayProvider,
                deviceId: deviceId,
                mode: .blocked,
                capability: capability,
                status: .unavailable,
                targetSummary: "\(capability.rawValue) requires paired Mac",
                resultSummary: "\(gatewayProvider.macLocalUnavailableSubject) cannot inspect Mac-local screen, files, clipboard, or shell context.",
                approvalClass: .unavailable
            )
        }

        let mode: Mode = capability == .chat ? .activity : .toolPhase
        let approvalClass: ApprovalClass
        switch capability {
        case .chat:
            approvalClass = .allowForSession
        case .screenContext, .browserAutomation, .shell, .files, .clipboard, .gatewayConfig:
            approvalClass = status == .blocked ? .blockedByPolicy : .askEveryTime
        }

        return SessionPreviewEntry(
            createdAt: now,
            sessionId: runId,
            gatewayId: gatewayId,
            gatewayProvider: gatewayProvider,
            deviceId: deviceId,
            mode: mode,
            capability: capability,
            status: status,
            targetSummary: targetSummary(stream: stream, data: data),
            resultSummary: resultSummary(stream: stream, data: data),
            approvalClass: approvalClass
        )
    }

    public static func fromPendingTool(
        name: String,
        args: OpenClawKit.AnyCodable?,
        toolCallId: String?,
        sessionId: String?,
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        deviceId: String? = nil,
        now: Date = Date()
    ) -> SessionPreviewEntry {
        var data = pendingToolData(name: name, args: args)
        data["phase"] = "running"

        return fromAgentEvent(
            stream: "tool",
            runId: toolCallId ?? sessionId,
            data: data,
            gatewayId: gatewayId,
            gatewayProvider: gatewayProvider,
            deviceId: deviceId,
            now: now
        )
    }

    public static func fromCompletedTool(
        name: String,
        resultStatus: String? = nil,
        toolCallId: String?,
        sessionId: String?,
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        deviceId: String? = nil,
        now: Date = Date()
    ) -> SessionPreviewEntry {
        let normalizedStatus = resultStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phase = normalizedStatus == "error" || normalizedStatus == "failed" || normalizedStatus == "failure"
            ? "failed"
            : "complete"
        var entry = fromAgentEvent(
            stream: "tool",
            runId: toolCallId ?? sessionId,
            data: [
                "tool": name,
                "phase": phase,
                "message": phase == "failed" ? "failed" : "completed",
            ],
            gatewayId: gatewayId,
            gatewayProvider: gatewayProvider,
            deviceId: deviceId,
            now: now
        )

        if entry.status == .succeeded {
            entry.status = .logged
        }
        entry.retention = .actionLogMetadata
        return entry
    }

    public static func unsupportedMacLocalPreview(
        sessionId: String?,
        gatewayId: String? = nil,
        gatewayProvider: GatewayProvider,
        requestedMode: Mode,
        now: Date = Date()
    ) -> SessionPreviewEntry {
        SessionPreviewEntry(
            createdAt: now,
            sessionId: sessionId,
            gatewayId: gatewayId,
            gatewayProvider: gatewayProvider,
            mode: .blocked,
            capability: .screenContext,
            status: .unavailable,
            targetSummary: "Mac-local \(requestedMode.rawValue)",
            resultSummary: "Requires a reachable paired Mac; cloud gateway cannot inspect Mac-local screen, app, browser, files, clipboard, or shell context.",
            approvalClass: .unavailable,
            retention: .actionLogMetadata
        )
    }

    public static func redactedSummary(_ value: String?, limit: Int = 160) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(token["'\s:=]+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(api[_-]?key["'\s:=]+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(setup[_-]?password["'\s:=]+)[^\s,;]+"#,
            #"(?i)(password["'\s:=]+)[^\s,;]+"#,
            #"(?i)(secret["'\s:=]+)[A-Za-z0-9._~+/=-]{8,}"#,
        ]

        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1[redacted]",
                options: .regularExpression
            )
        }

        value = value.replacingOccurrences(
            of: #"(?i)(https?://)([^/\s?#]+)([^\s]*)"#,
            with: "[redacted URL]",
            options: .regularExpression
        )

        if value.count > limit {
            let end = value.index(value.startIndex, offsetBy: limit)
            value = String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return value
    }

    private static func requiresMacLocalGateway(_ capability: Capability) -> Bool {
        switch capability {
        case .screenContext, .shell, .files, .clipboard:
            return true
        case .chat, .browserAutomation, .gatewayConfig:
            return false
        }
    }

    private static func redactIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.count <= 12 { return value }
        return "\(value.prefix(6))...\(value.suffix(4))"
    }

    private static func inferCapability(stream: String, data: [String: String]) -> Capability {
        let haystack = ([stream] + data.keys + data.values)
            .joined(separator: " ")
            .lowercased()

        if haystack.contains("browser") || haystack.contains("url") {
            return .browserAutomation
        }
        if haystack.contains("screen")
            || haystack.contains("screenshot")
            || haystack.contains("window")
            || haystack.contains("app-context")
            || haystack.contains("accessibility")
        {
            return .screenContext
        }
        if haystack.contains("shell")
            || haystack.contains("exec")
            || haystack.contains("command")
            || haystack.contains("terminal")
        {
            return .shell
        }
        if haystack.contains("file") || haystack.contains("path") || haystack.contains("folder") {
            return .files
        }
        if haystack.contains("clipboard") {
            return .clipboard
        }
        if haystack.contains("gateway") || haystack.contains("mcp") || haystack.contains("config") {
            return .gatewayConfig
        }
        return stream.localizedCaseInsensitiveContains("tool") ? .shell : .chat
    }

    private static func inferStatus(stream: String, data: [String: String]) -> Status {
        let statusText = [
            data["status"],
            data["state"],
            data["phase"],
            stream,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if statusText.contains("await") && statusText.contains("approval") {
            return .awaitingApproval
        }
        if statusText.contains("need") && statusText.contains("approval") {
            return .needsApproval
        }
        if statusText.contains("blocked") || statusText.contains("denied") || statusText.contains("policy") {
            return .blocked
        }
        if statusText.contains("fail") || statusText.contains("error") {
            return .failed
        }
        if statusText.contains("done") || statusText.contains("complete") || statusText.contains("success") {
            return .succeeded
        }
        return .running
    }

    private static func targetSummary(stream: String, data: [String: String]) -> String {
        for key in ["tool", "name", "command", "url", "path", "app", "window", "target"] {
            if let value = redactedSummary(data[key]) {
                return value
            }
        }
        return redactedSummary(stream) ?? "Session activity"
    }

    private static func resultSummary(stream: String, data: [String: String]) -> String {
        for key in ["summary", "message", "result", "status", "state", "phase"] {
            if let value = redactedSummary(data[key]) {
                return value
            }
        }
        return redactedSummary(stream) ?? "Session activity"
    }

    private static func pendingToolData(name: String, args: OpenClawKit.AnyCodable?) -> [String: String] {
        var data = ["tool": name]

        for key in ["action", "command", "target", "app", "window", "url", "path", "node", "nodeId"] {
            if let value = stringArg(args, key: key) {
                data[key] = value
            }
        }

        return data
    }

    private static func stringArg(_ args: OpenClawKit.AnyCodable?, key: String) -> String? {
        guard let args else { return nil }
        if let dict = args.value as? [String: Any],
           let value = dict[key] as? String {
            return value
        }
        if let dict = args.value as? [String: OpenClawKit.AnyCodable],
           let value = dict[key]?.value as? String {
            return value
        }
        return nil
    }
}
