import Foundation

/// Pure, value-typed consolidation for a run of consecutive `thinking` strings.
///
/// When the agent loops or struggles it emits the same diagnostic thought over
/// and over ("reminders.add not found"), which used to render as 15–20+ stacked
/// "Thought" rows (one per `parts.thinking[i]`). This helper collapses that run
/// the same way tool results already dedupe via `consolidatedInlineToolResults()`
/// + `ParsedToolResult.consolidationKey` (see `ToolResultParser`/`ToolResultCardView`):
/// identical thoughts (by a normalized `consolidationKey`) fold into a single
/// entry carrying an occurrence count surfaced as an "×N" badge, and the whole
/// run renders behind one collapsed "Thinking · N steps" header.
///
/// Kept pure + `Equatable` so SwiftUI diffing on the grouped result is cheap and
/// the consolidation is unit-testable without spinning up a view.
enum ThinkingBlockGrouping {

    /// A single deduped thought. Identical diagnostics collapse into one entry
    /// whose `occurrences` count drives the "×N" badge.
    struct Entry: Equatable, Identifiable {
        /// Index of first appearance — stable id for cheap SwiftUI diffing.
        let id: Int
        /// Display text, taken verbatim from the first appearance.
        let text: String
        /// N — how many identical thoughts folded into this entry (≥ 1).
        let occurrences: Int
        /// Normalized dedupe key, mirroring `ParsedToolResult.consolidationKey`.
        let consolidationKey: String
    }

    /// Result of consolidating one consecutive run of thoughts.
    struct Group: Equatable {
        /// Deduped thoughts in first-appearance order.
        let entries: [Entry]
        /// Total original thoughts (sum of `occurrences`) — drives "Thinking · N steps".
        let stepCount: Int

        var isEmpty: Bool { entries.isEmpty }

        /// True once there is anything to consolidate — i.e. more than one raw
        /// thought. A single thought keeps the legacy per-thought presentation.
        var needsConsolidation: Bool { stepCount > 1 }

        static let empty = Group(entries: [], stepCount: 0)
    }

    /// Normalize a thought for dedupe. Mirrors `ParsedToolResult.normalized`:
    /// trim surrounding whitespace, lowercase, so cosmetically-different repeats
    /// of the same diagnostic still collapse.
    static func consolidationKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Consolidate an ordered run of thoughts into deduped entries.
    ///
    /// Blank thoughts are dropped. Identical thoughts (by `consolidationKey`) fold
    /// into the first appearance with an occurrence count; order is preserved.
    /// This is the thinking-side twin of `consolidatedInlineToolResults()`.
    static func group(_ thoughts: [String]) -> Group {
        var counts: [String: Int] = [:]
        var total = 0

        for text in thoughts {
            let key = consolidationKey(for: text)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
            total += 1
        }

        var seen = Set<String>()
        var entries: [Entry] = []

        for (index, text) in thoughts.enumerated() {
            let key = consolidationKey(for: text)
            guard !key.isEmpty else { continue }
            guard seen.insert(key).inserted else { continue }
            entries.append(Entry(
                id: index,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                occurrences: counts[key, default: 1],
                consolidationKey: key
            ))
        }

        return Group(entries: entries, stepCount: total)
    }
}
