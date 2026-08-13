import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// The only projection boundary for unknown tool output. It separates safe,
/// renderable images from adjacent text and conservatively suppresses arbitrary
/// structured envelopes before any top-level, inline, or fallback UI sees them.
struct UnknownToolContentProjection: Equatable {
    struct JSONContainerScan: Equatable {
        let containsStructuredContainer: Bool
        let bytesVisited: Int
        let parseAttempts: Int
    }

    let imageMarkdown: String?
    let safeDetail: String?
    let residualIsUnsafe: Bool

    private static let sensitiveResidualKeyPattern = #"(?i)(?:\"|\b)(?:node(?:[_-]?id)?|runtime(?:[_-]?id)?|request(?:[_-]?id)?|tool[_-]?call(?:[_-]?id)?|session(?:[_-]?id)?|run(?:[_-]?id)?|idempotency(?:[_-]?(?:key|token|id))?|(?:access|refresh|auth|api)[_-]?(?:token|key|credential|id)|token|credential|secret|password|command|payload)(?:\"|\b)\s*[:=]"#
    private static let credentialHeaderPattern = #"(?i)\b(?:authorization|proxy[_-]?authorization)\s*:\s*(?:bearer|basic|digest)\s+\S+|\b(?:cookie|set[_-]?cookie)\s*:\s*[^\s=;,]+=[^\s;,]+"#

    static func project(_ text: String) -> Self {
        // Cleaning is the trust boundary. Never extract an image from raw
        // inbound metadata or an untrusted trailing context block.
        let cleaned = MessageCleaner.cleanAssistantMessage(text).displayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSegments = AssistantMarkdownParser.parse(cleaned)
        let images = cleanedSegments.compactMap { segment -> String? in
            guard case .image(let alt, let url) = segment else { return nil }
            return "![\(alt)](\(url))"
        }
        let residual = cleanedSegments.contains(where: {
            if case .image = $0 { return true }
            return false
        }) ? residualText(from: cleanedSegments) : cleaned

        // MessageCleaner first removes recognized untrusted-metadata wrappers.
        // The structural policy then evaluates exactly the residual that could
        // render; stripped metadata cannot taint adjacent explicit safe prose.
        let residualIsUnsafe = !residual.isEmpty && (
            SharedChatDiagnosticDisplay.isRuntimeDiagnostic(residual)
                || containsStructuredEnvelope(residual)
        )
        let safeDetail: String?
        if residual.isEmpty || residualIsUnsafe {
            safeDetail = nil
        } else {
            safeDetail = residual
        }

        return Self(
            imageMarkdown: images.isEmpty ? nil : images.joined(separator: "\n"),
            safeDetail: safeDetail,
            residualIsUnsafe: residualIsUnsafe
        )
    }

    private static func residualText(
        from segments: [AssistantMarkdownSegment]
    ) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .image:
                return nil
            case .text(let value):
                return value
            case .code(let language, let value):
                let fence = language.map { "```\($0)" } ?? "```"
                return "\(fence)\n\(value)\n```"
            case .table(let headers, let rows):
                let header = "| " + headers.joined(separator: " | ") + " |"
                let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
                let body = rows.map { "| " + $0.joined(separator: " | ") + " |" }
                return ([header, separator] + body).joined(separator: "\n")
            }
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsStructuredEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(
            of: #"(?is)```\s*json\b.*?```"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if jsonContainerScan(trimmed).containsStructuredContainer { return true }
        if trimmed.range(
            of: sensitiveResidualKeyPattern,
            options: .regularExpression
        ) != nil { return true }
        return trimmed.range(
            of: credentialHeaderPattern,
            options: .regularExpression
        ) != nil
    }

    /// Single-pass, bounded JSON-container detection for prose-adjacent tool
    /// output. Every independently balanced container can be recognized even
    /// when an earlier outer opener never closes. Total scanned and parsed bytes
    /// are capped; exceeding either budget fails closed rather than doing
    /// unbounded work on SwiftUI's render path.
    static func jsonContainerScan(_ text: String) -> JSONContainerScan {
        let maxScanBytes = 64 * 1024
        let maxDepth = 128
        let bytes = Array(text.utf8.prefix(maxScanBytes + 1))
        let scanCount = min(bytes.count, maxScanBytes)
        let inputWasTruncated = bytes.count > maxScanBytes
        var frames: [(start: Int, closer: UInt8)] = []
        var isInString = false
        var isEscaped = false
        var sawContainerWhileInString = false
        var parseAttempts = 0
        var parsedBytes = 0

        for index in 0..<scanCount {
            let byte = bytes[index]
            if isInString {
                if byte == 0x7B || byte == 0x5B || byte == 0x7D || byte == 0x5D {
                    sawContainerWhileInString = true
                }
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C { // backslash
                    isEscaped = true
                } else if byte == 0x22 { // quote
                    isInString = false
                }
                continue
            }

            if byte == 0x22 {
                isInString = true
            } else if byte == 0x7B || byte == 0x5B {
                frames.append((start: index, closer: byte == 0x7B ? 0x7D : 0x5D))
                if frames.count > maxDepth {
                    return .init(
                        containsStructuredContainer: true,
                        bytesVisited: index + 1,
                        parseAttempts: parseAttempts
                    )
                }
            } else if byte == 0x7D || byte == 0x5D {
                guard let frame = frames.last, frame.closer == byte else {
                    return .init(
                        containsStructuredContainer: true,
                        bytesVisited: index + 1,
                        parseAttempts: parseAttempts
                    )
                }
                frames.removeLast()
                let candidateLength = index - frame.start + 1
                guard parseAttempts < 64,
                      parsedBytes + candidateLength <= maxScanBytes
                else {
                    return .init(
                        containsStructuredContainer: true,
                        bytesVisited: index + 1,
                        parseAttempts: parseAttempts
                    )
                }
                parseAttempts += 1
                parsedBytes += candidateLength
                let data = Data(bytes[frame.start...index])
                if let value = try? JSONSerialization.jsonObject(with: data),
                   value is [String: Any] || value is [Any]
                {
                    return .init(
                        containsStructuredContainer: true,
                        bytesVisited: index + 1,
                        parseAttempts: parseAttempts
                    )
                }
                if frames.isEmpty {
                    isInString = false
                    isEscaped = false
                }
            }
        }

        return .init(
            containsStructuredContainer: inputWasTruncated
                || !frames.isEmpty
                || isInString && sawContainerWhileInString,
            bytesVisited: scanCount,
            parseAttempts: parseAttempts
        )
    }
}

/// Routes tool result messages to the appropriate rich card view.
struct ToolResultCardView: View {
    let message: OpenClawChatMessage
    let messages: [OpenClawChatMessage]
    let contentIndexes: Set<Int>?

    init(
        message: OpenClawChatMessage,
        messages: [OpenClawChatMessage],
        contentIndexes: Set<Int>? = nil
    ) {
        self.message = message
        self.messages = messages
        self.contentIndexes = contentIndexes
    }

    @State private var expandedSections: Set<String> = []

    var body: some View {
        ForEach(Array(message.content.enumerated()), id: \.offset) { idx, content in
            let shouldPresent = contentIndexes?.contains(idx) ?? true
            let text = toolResultText(content)
            if shouldPresent, !text.isEmpty {
                let parsed = ToolResultParser.parse(text)
                if parsed.isKnown {
                    if shouldRender(parsed, contentIndex: idx) {
                        cardForResult(
                            parsed,
                            sectionId: "\(message.id)-result-\(idx)",
                            rawText: text,
                            duplicateCount: duplicateCount(for: parsed, contentIndex: idx)
                        )
                    }
                } else {
                    // Unknown output uses the shared safe projection: image
                    // segments remain visible here while safe textual detail is
                    // owned by the turn-level Activity disclosure.
                    cardForResult(
                        parsed,
                        sectionId: "\(message.id)-result-\(idx)",
                        rawText: text,
                        duplicateCount: 1
                    )
                }
            }
        }
    }

    /// A tool-result content block usually carries its payload in `text`, but
    /// OpenClaw also emits blocks that place the payload in the generic `content`
    /// field (string, or a nested `{ text: … }` shape). Fall back to those so a
    /// file-read result isn't silently empty and mis-routed.
    private func toolResultText(_ content: OpenClawChatMessageContent) -> String {
        if let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let value = content.content {
            if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
            if let nested = value.dictionaryValue?["text"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !nested.isEmpty {
                return nested
            }
        }
        return ""
    }

    private func shouldRender(_ result: ParsedToolResult, contentIndex: Int) -> Bool {
        guard let key = result.consolidationKey else { return true }

        for priorIndex in 0..<contentIndex {
            let text = (message.content[priorIndex].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if ToolResultParser.parse(text).consolidationKey == key {
                return false
            }
        }

        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            return true
        }

        guard messageIndex > messages.startIndex else {
            return true
        }

        var cursor = messages.index(before: messageIndex)
        while cursor >= messages.startIndex {
            let previous = messages[cursor]
            if previous.role == "user" { break }
            if messageContainsConsolidatedResult(previous, key: key) {
                return false
            }
            if cursor == messages.startIndex { break }
            cursor = messages.index(before: cursor)
        }

        return true
    }

    private func duplicateCount(for result: ParsedToolResult, contentIndex: Int) -> Int {
        guard let key = result.consolidationKey,
              let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            return 1
        }

        var count = 1

        if contentIndex < message.content.index(before: message.content.endIndex) {
            for nextContentIndex in message.content.index(after: contentIndex)..<message.content.endIndex {
                let text = (message.content[nextContentIndex].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if ToolResultParser.parse(text).consolidationKey == key {
                    count += 1
                }
            }
        }

        var cursor = messages.index(after: messageIndex)
        while cursor < messages.endIndex {
            let next = messages[cursor]
            if next.role == "user" { break }
            count += messageResultCount(next, key: key)
            cursor = messages.index(after: cursor)
        }

        return max(count, 1)
    }

    private func messageContainsConsolidatedResult(_ message: OpenClawChatMessage, key: String) -> Bool {
        messageResultCount(message, key: key) > 0
    }

    private func messageResultCount(_ message: OpenClawChatMessage, key: String) -> Int {
        message.content.reduce(into: 0) { count, content in
            let text = (content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            if ToolResultParser.parse(text).consolidationKey == key {
                count += 1
                return
            }

            let cleaned = MessageCleaner.cleanAssistantMessage(text).displayText
            guard cleaned != text else { return }
            if ToolResultParser.parse(cleaned).consolidationKey == key {
                count += 1
            }
        }
    }

    @ViewBuilder
    private func cardForResult(
        _ result: ParsedToolResult,
        sectionId: String,
        rawText: String,
        duplicateCount: Int = 1
    ) -> some View {
        switch result {
        case .calendarEvents(let events):
            CalendarEventsCard(events: events)
        case .calendarAdd(_, let title):
            ConfirmationCard(icon: "calendar.badge.checkmark", title: countedTitle("Event Created", plural: "Events Created", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .calendarUpdate(_, let title):
            ConfirmationCard(icon: "calendar.badge.clock", title: countedTitle("Event Updated", plural: "Events Updated", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .calendarDelete(_, let title):
            ConfirmationCard(icon: "calendar.badge.minus", title: countedTitle("Event Deleted", plural: "Events Deleted", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .remindersList(let reminders):
            RemindersCard(reminders: reminders)
        case .remindersAdd(_, let title):
            ConfirmationCard(icon: "asset.apple-reminders-logo", title: countedTitle("Reminder Set", plural: "Reminders Set", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .remindersUpdate(_, let title):
            ConfirmationCard(icon: "asset.apple-reminders-logo", title: countedTitle("Reminder Updated", plural: "Reminders Updated", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .remindersDelete(_, let title):
            ConfirmationCard(icon: "trash.circle.fill", title: countedTitle("Reminder Deleted", plural: "Reminders Deleted", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .deviceStatus(let payload):
            DeviceStatusCard(status: payload)
        case .deviceInfo(let payload):
            DeviceInfoCard(info: payload)
        case .taskCreate(let title):
            ConfirmationCard(icon: "checklist", title: countedTitle("Task Created", plural: "Tasks Created", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemBlue)
        case .taskUpdate(let title):
            ConfirmationCard(icon: "pencil.circle.fill", title: countedTitle("Task Updated", plural: "Tasks Updated", count: duplicateCount), subtitle: title, tint: DesignTokens.Color.systemBlue)
        case .taskDelete:
            ConfirmationCard(icon: "trash.circle.fill", title: countedTitle("Task Deleted", plural: "Tasks Deleted", count: duplicateCount), tint: DesignTokens.Color.systemRed)
        case .notifySuccess:
            ConfirmationCard(icon: "bell.badge.fill", title: "Notification Sent", tint: DesignTokens.Color.systemGreen)
        case .error(_, let errorMessage):
            ErrorResultCard(message: errorMessage)
        case .unknown:
            UnknownToolResultFallback(
                text: rawText
            )
        }
    }

    private func countedTitle(_ singular: String, plural: String, count: Int) -> String {
        count > 1 ? "\(count) \(plural)" : singular
    }
}

// MARK: - Inline Tool Result Card (for JSON results embedded in assistant text blocks)

/// Parses a single JSON text and renders the appropriate card.
/// List cards start collapsed; compact cards are always visible.
struct InlineToolResultCard: View {
    let text: String
    let sectionId: String
    var duplicateCount: Int = 1

    @State private var isExpanded = false
    @State private var expandedSections: Set<String> = []

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else {
            let parsed = ToolResultParser.parse(trimmed)
            cardContent(parsed)
        }
    }

    @ViewBuilder
    private func cardContent(_ parsed: ParsedToolResult) -> some View {
        switch parsed {
        // List cards — single card with built-in expand/collapse
        case .calendarEvents(let events):
            CalendarEventsCard(events: events, expanded: $isExpanded)
        case .remindersList(let reminders):
            RemindersCard(reminders: reminders, expanded: $isExpanded)
        // Compact cards — always visible
        case .calendarAdd(_, let title):
            ConfirmationCard(icon: "calendar.badge.checkmark", title: countedTitle("Event Created", plural: "Events Created"), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .calendarUpdate(_, let title):
            ConfirmationCard(icon: "calendar.badge.clock", title: countedTitle("Event Updated", plural: "Events Updated"), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .calendarDelete(_, let title):
            ConfirmationCard(icon: "calendar.badge.minus", title: countedTitle("Event Deleted", plural: "Events Deleted"), subtitle: title, tint: DesignTokens.Color.systemRed)
        case .remindersAdd(_, let title):
            ConfirmationCard(icon: "asset.apple-reminders-logo", title: countedTitle("Reminder Set", plural: "Reminders Set"), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .remindersUpdate(_, let title):
            ConfirmationCard(icon: "asset.apple-reminders-logo", title: countedTitle("Reminder Updated", plural: "Reminders Updated"), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .remindersDelete(_, let title):
            ConfirmationCard(icon: "trash.circle.fill", title: countedTitle("Reminder Deleted", plural: "Reminders Deleted"), subtitle: title, tint: DesignTokens.Color.systemOrange)
        case .taskCreate(let title):
            ConfirmationCard(icon: "checklist", title: countedTitle("Task Created", plural: "Tasks Created"), subtitle: title, tint: DesignTokens.Color.systemBlue)
        case .taskUpdate(let title):
            ConfirmationCard(icon: "pencil.circle.fill", title: countedTitle("Task Updated", plural: "Tasks Updated"), subtitle: title, tint: DesignTokens.Color.systemBlue)
        case .taskDelete:
            ConfirmationCard(icon: "trash.circle.fill", title: countedTitle("Task Deleted", plural: "Tasks Deleted"), tint: DesignTokens.Color.systemRed)
        case .deviceStatus(let payload):
            DeviceStatusCard(status: payload)
        case .deviceInfo(let payload):
            DeviceInfoCard(info: payload)
        case .notifySuccess:
            ConfirmationCard(icon: "bell.badge.fill", title: "Notification Sent", tint: DesignTokens.Color.systemGreen)
        case .error(_, let errorMessage):
            ErrorResultCard(message: errorMessage)
        case .unknown:
            UnknownToolResultFallback(
                text: text
            )
        }
    }

    private func countedTitle(_ singular: String, plural: String) -> String {
        duplicateCount > 1 ? "\(duplicateCount) \(plural)" : singular
    }
}

private struct UnknownToolResultFallback: View {
    let text: String

    var body: some View {
        let projection = UnknownToolContentProjection.project(text)

        if let imageMarkdown = projection.imageMarkdown {
            AssistantMarkdownView(markdown: imageMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if projection.safeDetail == nil {
            EmptyView()
        }
    }
}

// MARK: - Confirmation Card

struct ConfirmationCard: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            confirmationIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(minHeight: 58)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.fillTertiary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    @ViewBuilder
    private var confirmationIcon: some View {
        if icon == "asset.apple-reminders-logo" {
            Image("AppleRemindersLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
        }
    }
}

// MARK: - Error Result Card (lightweight, expandable)

struct ErrorResultCard: View {
    let message: String
    @State private var isExpanded = false

    static func privacyProjectedMessage(_ raw: String) -> String {
        guard let detail = UnknownToolContentProjection.project(raw).safeDetail else {
            return "The action couldn't be completed."
        }
        let sanitized = ActionLifecycleDisplay.sanitizeLabel(detail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "The action couldn't be completed." : sanitized
    }

    private var displayMessage: String { Self.privacyProjectedMessage(message) }

    /// Short preview: first line, truncated.
    private var preview: String {
        let first = displayMessage.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? displayMessage
        if first.count > 80 { return String(first.prefix(77)) + "…" }
        return first
    }

    private var isLong: Bool { displayMessage.count > 80 || displayMessage.contains("\n") }

    private var collapsedLabel: String {
        isLong ? preview : displayMessage
    }

    var body: some View {
        // Same collapsible chrome as "Thought" / "Tool result" so error rows
        // match the rest of the transcript. Short errors are non-collapsible:
        // the message itself is the header, with no chevron.
        SharedChatCollapsibleSection(
            icon: "exclamationmark.triangle",
            title: isExpanded ? "Error" : collapsedLabel,
            isCollapsible: isLong,
            isExpanded: $isExpanded
        ) {
            // Long errors (multi-line stack traces) get the same bounded scroll
            // as `FallbackResultCard` so they don't dump full-length. Short
            // errors stay unaffected — the cap only engages past `maxHeight`.
            BoundedToolResultScroll {
                Text(displayMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Fallback Result Card (collapsible raw text)

struct FallbackResultCard: View {
    let text: String
    let sectionId: String
    @Binding var expandedSections: Set<String>

    /// Derive a short label from JSON or show truncated text.
    private var previewLabel: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{"),
           let data = t.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Use command name from envelope if present
            if let command = json["command"] as? String {
                return "Tool result \u{2022} \(command)"
            }
            return "Tool result"
        }
        // Non-JSON payloads (e.g. a file read's YAML frontmatter + markdown body)
        // shouldn't leak their raw first line into the collapsed header — show a
        // generic summary and keep the full text behind the disclosure.
        if t.contains("\n") || t.count > 80 {
            return "Tool result"
        }
        return t
    }

    var body: some View {
        // Reuse the same collapsible chrome as the assistant "Thought" block so
        // a "Tool result" row is visually identical (width, insets, header row,
        // fonts, chevron) — see `SharedChatCollapsibleSection`.
        SharedChatCollapsibleSection(
            icon: "checkmark.circle",
            title: previewLabel,
            sectionId: sectionId,
            expandedSections: $expandedSections
        ) {
            // A long payload (e.g. a `task.list` dump with many rows) is capped
            // to a bounded, internally-scrollable area rather than dumping
            // full-length into the transcript. Short results are unaffected —
            // the cap only engages once the body overflows `maxHeight`.
            BoundedToolResultScroll {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Device Status Card

struct DeviceStatusCard: View {
    let status: DeviceStatusPayload

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(batteryColor)
                Text("Device Status")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
            }

            // Status pills
            HStack(spacing: DesignTokens.Spacing.sm) {
                statusPill(label: "\(Int(status.batteryLevel * 100))%", color: batteryColor)
                statusPill(label: status.batteryState.capitalized, color: DesignTokens.Color.labelSecondary)
                if status.thermalState != "nominal" {
                    statusPill(label: status.thermalState.capitalized, color: DesignTokens.Color.systemOrange)
                }
                if status.lowPowerMode {
                    statusPill(label: "Low Power", color: DesignTokens.Color.systemYellow)
                }
            }

            // Disk space (if available)
            if let total = status.diskTotalBytes, let available = status.diskAvailableBytes {
                let usedGB = Double(total - available) / 1_073_741_824
                let totalGB = Double(total) / 1_073_741_824
                Text(String(format: "Storage: %.1f / %.1f GB used", usedGB, totalGB))
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.fillTertiary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    private var batteryIcon: String {
        let level = status.batteryLevel
        if status.batteryState == "charging" { return "battery.100.bolt" }
        if level > 0.75 { return "battery.100" }
        if level > 0.5 { return "battery.75" }
        if level > 0.25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        let level = status.batteryLevel
        if status.batteryState == "charging" { return DesignTokens.Color.systemGreen }
        if level > 0.5 { return DesignTokens.Color.systemGreen }
        if level > 0.2 { return DesignTokens.Color.systemYellow }
        return DesignTokens.Color.systemRed
    }

    private func statusPill(label: String, color: Color) -> some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Device Info Card

struct DeviceInfoCard: View {
    let info: DeviceInfoPayload

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: deviceIcon)
                .font(.title2)
                .foregroundStyle(DesignTokens.Color.systemBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                Text("\(info.model) \u{2022} \(info.systemName) \(info.systemVersion)")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.fillTertiary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    private var deviceIcon: String {
        let model = info.model.lowercased()
        if model.contains("iphone") { return "iphone" }
        if model.contains("ipad") { return "ipad" }
        if model.contains("mac") { return "desktopcomputer" }
        return "laptopcomputer"
    }
}

// MARK: - Bounded Tool Result Body

/// Caps a long expanded tool-result body (e.g. a raw `task.list` dump with many
/// rows, or a multi-line error) at a max height with its own internal vertical
/// scroll, so a long payload is contained to a bounded, scrollable area instead
/// of dumping full-length into the transcript.
///
/// Mirrors the transcript's "Thought" collapsible fixed-height scroll pattern
/// (`SharedChatThinkingContent` in `SharedRemChatView`): a `ScrollView` capped
/// with `.frame(maxHeight:)` plus `onScrollGeometryChange`-driven top/bottom
/// edge fades. Crucially the cap only *engages* on overflow — a vertical
/// `ScrollView` proposed an unconstrained height (as transcript rows are)
/// reports its content's height, so a SHORT result sizes below `maxHeight` and
/// is visually unchanged (no scroll, no fade). The fades are gated behind the
/// same `onScrollGeometryChange` availability as the Thought block; on older
/// OSes the body is still bounded and scrollable, just without the fades.
///
/// Deliberately NOT reimplemented with `PreferenceKey`/coordinate-space, which
/// silently fails in this transcript (see MEMORY: chat-fidelity + fade).
struct BoundedToolResultScroll<Content: View>: View {
    var maxHeight: CGFloat = 320
    @ViewBuilder var content: () -> Content

    @State private var fadeState = ScrollEdgeFadeState()

    var body: some View {
        let scrollView = ScrollView {
            content()
        }
        .frame(maxHeight: maxHeight)
        .scrollIndicators(.hidden)

        if #available(iOS 18.0, macOS 15.0, *) {
            scrollView
                .onScrollGeometryChange(for: ScrollEdgeFadeState.self) { geometry in
                    ScrollEdgeFadeState.from(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        offsetY: geometry.contentOffset.y
                    )
                } action: { _, newValue in
                    fadeState = newValue
                }
                .boundedResultVerticalFades(fadeState)
        } else {
            scrollView
        }
    }
}

/// Pure, testable description of which vertical edge fades a capped scroll body
/// should show. Extracted so the overflow/threshold logic can be unit-tested
/// without a running view (mirrors the `ThinkingFadeState` computation).
struct ScrollEdgeFadeState: Equatable {
    var showsTop = false
    var showsBottom = false

    /// A 1pt slack absorbs sub-pixel rounding so a body that exactly fills the
    /// cap doesn't flicker a fade.
    static func from(contentHeight: CGFloat, containerHeight: CGFloat, offsetY: CGFloat) -> ScrollEdgeFadeState {
        let hasOverflow = contentHeight > containerHeight + 1
        let visibleMaxY = offsetY + containerHeight
        return ScrollEdgeFadeState(
            showsTop: hasOverflow && offsetY > 1,
            showsBottom: hasOverflow && contentHeight > visibleMaxY + 1
        )
    }
}

private extension View {
    func boundedResultVerticalFades(_ state: ScrollEdgeFadeState) -> some View {
        overlay(alignment: .top) {
            if state.showsTop {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary,
                        DesignTokens.Color.backgroundPrimary.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if state.showsBottom {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary.opacity(0),
                        DesignTokens.Color.backgroundPrimary
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
        }
    }
}
