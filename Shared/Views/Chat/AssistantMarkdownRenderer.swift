import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AssistantMarkdownSegment: Equatable {
    case text(String)
    case code(language: String?, text: String)
    /// A standalone markdown image (`![alt](url)`) that renders inline as an
    /// actual image rather than being silently dropped by `LocalizedStringKey`.
    /// Powers the WhatsApp pairing QR (a `data:image/png;base64,…` URL) and
    /// future browser tier-1 screenshots (`https://…`).
    case image(alt: String, url: String)
    /// A GitHub-flavored markdown table (a `| … |` row followed by a `|---|---|` separator).
    /// Rendered as an aligned grid instead of the raw pipe text `LocalizedStringKey` leaves
    /// untouched (the "not a clean table" bug on tabular tool results like Gmail/calendar lists).
    case table(headers: [String], rows: [[String]])
}

enum AssistantMarkdownParser {
    static func parse(_ markdown: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCodeBlock = false

        func flushText() {
            let lines = textLines
            textLines.removeAll()
            // Split the accumulated prose into text runs and GFM tables. A table is a `| … |`
            // row IMMEDIATELY followed by a `|---|---|` separator; consume its body rows too.
            // Tables emit a `.table` segment (aligned grid); everything else stays `.text`.
            var run: [String] = []
            func emitRun() {
                let text = normalizeTextLines(run)
                run.removeAll()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                segments.append(.text(text))
            }
            var idx = 0
            while idx < lines.count {
                if isTableRow(lines[idx]), idx + 1 < lines.count, isTableSeparator(lines[idx + 1]) {
                    emitRun()
                    let headers = parseTableRow(lines[idx])
                    var rows: [[String]] = []
                    var j = idx + 2
                    while j < lines.count, isTableRow(lines[j]) {
                        rows.append(parseTableRow(lines[j]))
                        j += 1
                    }
                    segments.append(.table(headers: headers, rows: rows))
                    idx = j
                } else {
                    run.append(lines[idx])
                    idx += 1
                }
            }
            emitRun()
        }

        func flushCode() {
            let code = trimTrailingNewline(codeLines.joined(separator: "\n"))
            codeLines.removeAll()
            guard !code.isEmpty else { return }
            segments.append(.code(language: codeLanguage, text: code))
            codeLanguage = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            if isFence(line) {
                if insideCodeBlock {
                    flushCode()
                    insideCodeBlock = false
                } else {
                    flushText()
                    insideCodeBlock = true
                    codeLanguage = fenceLanguage(line)
                }
                continue
            }

            if insideCodeBlock {
                codeLines.append(line)
            } else if let image = parseImageInLine(line) {
                // An image ANYWHERE in the line becomes its own image segment, with any
                // prose on that line kept as text around it.
                //
                // This used to require the line to be *only* an image, on the assumption
                // that "QR + screenshots arrive on their own line". True of tool results —
                // the gateway patch emits the data-URL on its own line — but NOT of the
                // assistant, which re-emits the image inside a sentence:
                //   Here's example.com: ![screenshot of example.com](data:image/jpeg;base64,…)
                // That one prefix meant the whole payload fell through to the text branch
                // and the user saw a screenful of raw base64 instead of the page. Verified
                // in-app 2026-07-17 — the very first agent-driven screenshot rendered as
                // "AAAAAAA…".
                flushText()
                if !image.before.isEmpty { textLines.append(image.before); flushText() }
                segments.append(.image(alt: image.alt, url: image.url))
                if !image.after.isEmpty { textLines.append(image.after) }
            } else {
                textLines.append(line)
            }
        }

        if insideCodeBlock {
            flushCode()
        } else {
            flushText()
        }

        return segments
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func fenceLanguage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    /// A candidate table row: contains a pipe (after trimming), not a fence. The separator
    /// lookahead in `flushText` is what actually confirms it's a table, so this stays lenient.
    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.hasPrefix("```")
    }

    /// The `|---|:--:|` delimiter row: only pipes, dashes, colons and spaces, with at least one
    /// dash. This is the strong signal that the preceding `|…|` line is a header, not prose.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split a `| a | b |` row into trimmed cell strings, dropping the empty leading/trailing
    /// cells produced by the border pipes.
    private static func parseTableRow(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        return cells
    }

    /// Parse the first markdown image `![alt](url)` in a line, wherever it sits, returning
    /// any prose before/after it so the caller can preserve ordering.
    ///
    /// The URL ends at the FIRST `)` after `](`, not the last: neither `data:` URLs
    /// (base64 alphabet) nor http(s) URLs contain an unescaped `)`, so the first one is the
    /// real terminator — and taking the *last* would swallow any trailing prose into the
    /// URL and break the image.
    static func parseImageInLine(_ line: String) -> (before: String, alt: String, url: String, after: String)? {
        guard let bang = line.range(of: "![") else { return nil }
        guard let altClose = line.range(of: "](", range: bang.upperBound..<line.endIndex) else {
            return nil
        }
        guard let urlClose = line.range(of: ")", range: altClose.upperBound..<line.endIndex) else {
            return nil
        }
        let url = String(line[altClose.upperBound..<urlClose.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }
        return (
            before: String(line[line.startIndex..<bang.lowerBound]).trimmingCharacters(in: .whitespaces),
            alt: String(line[bang.upperBound..<altClose.lowerBound]),
            url: url,
            after: String(line[urlClose.upperBound..<line.endIndex]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// Back-compat: a line that is *only* an image. Retained for existing callers/tests.
    static func parseStandaloneImage(_ line: String) -> (alt: String, url: String)? {
        guard let parsed = parseImageInLine(line),
              parsed.before.isEmpty, parsed.after.isEmpty else { return nil }
        return (alt: parsed.alt, url: parsed.url)
    }

    private static func normalizeTextLines(_ lines: [String]) -> String {
        lines
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("### ") {
                    return "**" + String(trimmed.dropFirst(4)) + "**"
                } else if trimmed.hasPrefix("## ") {
                    return "**" + String(trimmed.dropFirst(3)) + "**"
                } else if trimmed.hasPrefix("# ") {
                    return "**" + String(trimmed.dropFirst(2)) + "**"
                } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    return ""
                }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingNewline(_ text: String) -> String {
        var result = text
        while result.last == "\n" {
            result.removeLast()
        }
        return result
    }
}

/// Captures the message content width so tables can size columns proportionally.
private struct ContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HorizontalFadeState: Equatable {
    var showsLeading = false
    var showsTrailing = false
}

/// Horizontal scroll container for wide (>3 column) tables that fades whichever end still has
/// off-screen content. Mirrors the thought-collapsible treatment (`SharedChatThinkingContent` +
/// `thinkingVerticalFades`) exactly — `onScrollGeometryChange` drives the state and an overlaid
/// gradient clips the edge — just rotated to the horizontal axis. The earlier PreferenceKey/
/// coordinate-space version never reliably updated its state, so the fade never showed.
private struct TableScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var fade = HorizontalFadeState()

    var body: some View {
        let scroll = ScrollView(.horizontal) { content }
            .scrollIndicators(.hidden)

        if #available(iOS 18.0, macOS 15.0, *) {
            scroll
                .onScrollGeometryChange(for: HorizontalFadeState.self) { geometry in
                    let visibleMinX = geometry.contentOffset.x
                    let visibleMaxX = geometry.contentOffset.x + geometry.containerSize.width
                    let hasOverflow = geometry.contentSize.width > geometry.containerSize.width + 1
                    return HorizontalFadeState(
                        showsLeading: hasOverflow && visibleMinX > 1,
                        showsTrailing: hasOverflow && geometry.contentSize.width > visibleMaxX + 1
                    )
                } action: { _, newValue in
                    fade = newValue
                }
                .horizontalEdgeFades(fade)
        } else {
            // Pre-18: no scroll-geometry callback — the grid still scrolls, just without the fade.
            scroll
        }
    }
}

private extension View {
    /// The horizontal twin of `thinkingVerticalFades`: an overlaid gradient at each scrollable end
    /// that fades the edge content to the chat background, signalling more columns off-screen.
    func horizontalEdgeFades(_ state: HorizontalFadeState) -> some View {
        overlay(alignment: .leading) {
            if state.showsLeading {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary,
                        DesignTokens.Color.backgroundPrimary.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if state.showsTrailing {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary.opacity(0),
                        DesignTokens.Color.backgroundPrimary
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
                .allowsHitTesting(false)
            }
        }
    }
}

struct AssistantMarkdownView: View {
    enum Tone {
        case primary
        case secondary
    }

    let markdown: String
    var tone: Tone = .primary

    /// Content width of the message, captured so table columns can be sized proportionally
    /// (a fixed-fraction grid can't know how wide the bubble is). Same for every segment, so
    /// one measurement serves all tables in the message.
    @State private var contentWidth: CGFloat = 0

    private var segments: [AssistantMarkdownSegment] {
        AssistantMarkdownParser.parse(markdown)
    }

    private var textColor: Color {
        switch tone {
        case .primary: DesignTokens.Color.labelPrimary
        case .secondary: DesignTokens.Color.labelSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(LocalizedStringKey(text))
                        .font(DesignTokens.Typography.chatMessage)
                        .foregroundStyle(textColor)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .code(let language, let text):
                    codeBlock(text: text, language: language)
                case .image(let alt, let url):
                    MarkdownInlineImageView(alt: alt, url: url)
                case .table(let headers, let rows):
                    tableView(headers: headers, rows: rows)
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
    }

    /// Renders a parsed GFM table as a real 1px-gridded table with a shaded header row.
    ///
    /// Two layout modes, chosen by column count because chat width is scarce:
    /// - **≤3 columns → fit-and-wrap**: the table spans the full content width (out to the right
    ///   inset), columns sized *proportionally to their content* (a `#`/status column stays narrow;
    ///   a subject/sender column gets the room) so long unbreakable tokens like
    ///   `notifications@github.com` aren't squeezed into an equal third and broken mid-character.
    ///   Cells wrap to multiple lines. Before the width is measured (first render) columns fall
    ///   back to equal shares.
    /// - **>3 columns → horizontal scroll**: past three columns, fitting everything just wraps
    ///   every cell into an unreadable stack, so each column gets a readable fixed width and the
    ///   whole grid scrolls sideways instead.
    ///
    /// Grid lines are drawn with the "1px gaps over a separator-colored background" trick: the
    /// container is filled with `separator`, rows/cells sit on opaque fills with 1px spacing, so
    /// the background shows through every boundary as a hairline. Header cells use a darker fill;
    /// inline styling (bold/links) inside a cell still works via `LocalizedStringKey`.
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        let scrollable = columnCount > 3
        let line: CGFloat = 1

        // Weight each column by its longest cell, clamped so a single very long cell can't starve
        // its neighbours and an empty column still claims a readable minimum.
        let weights: [CGFloat] = (0..<columnCount).map { c in
            let longest = ([headers] + rows).map { row in c < row.count ? row[c].count : 0 }.max() ?? 1
            return CGFloat(min(max(longest, 3), 28))
        }
        let totalWeight = max(weights.reduce(0, +), 1)
        let usableWidth = contentWidth - line * CGFloat(max(columnCount - 1, 0))

        func padded(_ cells: [String]) -> [String] {
            cells.count >= columnCount ? cells : cells + Array(repeating: "", count: columnCount - cells.count)
        }
        // Every column reserves `minColumnWidth` first (so a 1-char `#`/status column still clears
        // its own 20pt horizontal padding and shows its digit) and the *remaining* width is shared
        // by weight. Without the floor a low-weight column collapses narrower than its padding and
        // the cell renders empty.
        let minColumnWidth: CGFloat = 34
        // Fit mode: floor + weighted remainder (nil until measured → equal shares).
        // Scroll mode: map weight to a readable fixed width so the row overflows and scrolls.
        func columnWidth(_ index: Int) -> CGFloat? {
            if scrollable {
                return min(max(weights[index] * 9, 96), 240)
            }
            guard usableWidth > 0 else { return nil }
            let reserved = minColumnWidth * CGFloat(columnCount)
            let remainder = max(usableWidth - reserved, 0)
            return minColumnWidth + remainder * weights[index] / totalWeight
        }
        @ViewBuilder
        func cellView(_ cell: String, index: Int, header: Bool) -> some View {
            let base = Text(LocalizedStringKey(cell))
                .font(header
                      ? DesignTokens.Typography.chatMessage.weight(.semibold)
                      : DesignTokens.Typography.chatMessage)
                .foregroundStyle(header ? DesignTokens.Color.labelPrimary : textColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Group {
                if let width = columnWidth(index) {
                    base.frame(width: width, alignment: .topLeading)
                } else {
                    base.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(header ? DesignTokens.Color.backgroundSecondary : DesignTokens.Color.backgroundPrimary)
        }
        func rowView(_ cells: [String], header: Bool) -> some View {
            HStack(alignment: .top, spacing: line) {
                ForEach(Array(padded(cells).enumerated()), id: \.offset) { index, cell in
                    cellView(cell, index: index, header: header)
                }
            }
        }
        let grid = VStack(alignment: .leading, spacing: line) {
            rowView(headers, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowView(row, header: false)
            }
        }
        .background(DesignTokens.Color.separator)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DesignTokens.Color.separator, lineWidth: line)
        )
        .textSelection(.enabled)

        return Group {
            if scrollable {
                TableScrollView { grid }
            } else {
                grid.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func codeBlock(text: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let language {
                Text(language)
                    .font(DesignTokens.Typography.chatChrome.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(verbatim: text)
                    .font(DesignTokens.Typography.chatCode)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
        .background(DesignTokens.Color.fillTertiary.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Renders a markdown image inline. Handles two sources:
///
/// - **`data:` URLs** (`data:image/png;base64,…` / jpeg) — decoded locally, no
///   network. This is what the WhatsApp `whatsapp_login` pairing QR uses, so it
///   must work fully offline.
/// - **`http(s):` URLs** — loaded via `AsyncImage` with loading + failure
///   states (browser tier-1 screenshots, #7.2).
///
/// Images are constrained to the content width and preserve their aspect ratio.
/// The upper width cap keeps a QR large enough to scan without ballooning on a
/// wide macOS window.
struct MarkdownInlineImageView: View {
    let alt: String
    let url: String

    /// Cap the rendered width so QR codes stay scannable but don't dominate a
    /// wide window. Filling the (narrower) content width on phones is fine.
    private let maxImageWidth: CGFloat = 320

    var body: some View {
        Group {
            if let decoded = Self.decodeDataURL(url) {
                imageView(decoded)
            } else if let remote = URL(string: url),
                      remote.scheme == "http" || remote.scheme == "https" {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .empty:
                        loadingState
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        failureState
                    @unknown default:
                        failureState
                    }
                }
            } else {
                failureState
            }
        }
        .frame(maxWidth: maxImageWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small, style: .continuous))
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }

    private func imageView(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
        #else
        Color.clear
        #endif
    }

    private var loadingState: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(alt.isEmpty ? "Loading image…" : alt)
                .font(DesignTokens.Typography.chatMeta)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .background(DesignTokens.Color.fillTertiary.opacity(0.5))
    }

    private var failureState: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "photo")
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            Text(alt.isEmpty ? "Image unavailable" : alt)
                .font(DesignTokens.Typography.chatMeta)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.fillTertiary.opacity(0.5))
    }

    #if canImport(UIKit)
    typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    typealias PlatformImage = NSImage
    #endif

    /// Decode a `data:<mime>;base64,<payload>` URL into a platform image with no
    /// network access. Returns `nil` for non-data URLs or undecodable payloads.
    static func decodeDataURL(_ url: String) -> PlatformImage? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data)
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }
}
