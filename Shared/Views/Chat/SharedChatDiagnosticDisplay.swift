import Foundation

enum SharedChatDiagnosticDisplay {
    static let runtimePairingActionTitle = "Approve Rem Agent"
    static let runtimePairingActionCaption = "Open Device Connections to review the pending machine request, then retry your message."

    static func isRuntimeDiagnosticLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if normalized.hasPrefix("node command not allowed:") {
            return true
        }
        if normalized == "No connected browser-capable nodes." {
            return true
        }
        if normalized.contains("agent="),
           normalized.contains("gateway="),
           normalized.contains("action=invoke:") {
            return true
        }
        if normalized.contains("pairing required before node invoke") {
            return true
        }
        return false
    }

    static func isRuntimeDiagnostic(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isRuntimeDiagnosticLine(normalized) {
            return true
        }
        return normalized
            .split(whereSeparator: \.isNewline)
            .contains { isRuntimeDiagnosticLine(String($0)) }
    }

    static func needsRuntimePairingApproval(_ text: String) -> Bool {
        guard isRuntimeDiagnostic(text) else { return false }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("pairing required")
    }

    static func collapsedTitle(for text: String, isLive: Bool = false) -> String {
        needsRuntimePairingApproval(text) ? "Machine permission needed" : (isRuntimeDiagnostic(text) ? "Action couldn't run" : (isLive ? "Thinking" : "Thought"))
    }

    static func collapsedIcon(for text: String) -> String {
        isRuntimeDiagnostic(text) ? "exclamationmark.triangle" : "brain"
    }
}
