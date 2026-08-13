import Foundation
import OpenClawProtocol

/// Chronological pairwise merge for the durable homes that make up a task execution chat:
/// backend `task_chat_messages` (cloud runs), legacy `task-<12>` gateway history, and
/// canonical `rem-task-<UUID>` gateway continuation. Compatibility history is merged
/// first, then the backend transcript is merged into that union.
enum TaskChatHistoryMerge {
    private struct Entry {
        let message: AnyCodable
        let timestampMilliseconds: Double?
        let fallbackRank: Double
        let stableIndex: Int
    }

    static func merged(
        taskTranscript: [AnyCodable],
        gatewayHistory: [AnyCodable]
    ) -> [AnyCodable] {
        let taskEntries = rankedEntries(
            taskTranscript,
            allMissingRank: -.greatestFiniteMagnitude,
            stableIndexOffset: 0
        )
        let gatewayEntries = rankedEntries(
            gatewayHistory,
            allMissingRank: .greatestFiniteMagnitude,
            stableIndexOffset: taskTranscript.count
        )

        return (taskEntries + gatewayEntries)
            .sorted { lhs, rhs in
                let lhsRank = lhs.timestampMilliseconds ?? lhs.fallbackRank
                let rhsRank = rhs.timestampMilliseconds ?? rhs.fallbackRank
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.stableIndex < rhs.stableIndex
            }
            .map(\.message)
    }

    /// Named compatibility entry point so the legacy/canonical union remains a pure,
    /// directly tested contract rather than transport-only orchestration.
    static func mergedGatewayCompatibility(
        legacyHistory: [AnyCodable],
        canonicalHistory: [AnyCodable]
    ) -> [AnyCodable] {
        merged(taskTranscript: legacyHistory, gatewayHistory: canonicalHistory)
    }

    /// Scrub malformed legacy metadata even when a directly opened history row has no
    /// compatibility alias or task transcript to merge. Returning the gateway payload
    /// untouched in that case lets one invalid timestamp drop an otherwise valid turn.
    static func normalizedGatewayHistory(_ history: [AnyCodable]) -> [AnyCodable] {
        merged(taskTranscript: [], gatewayHistory: history)
    }

    /// Gives untimestamped lifecycle/tool messages a bounded rank between their
    /// timestamped neighbours. This keeps each source's durable turn order intact
    /// while still allowing the two sources to interleave chronologically.
    private static func rankedEntries(
        _ messages: [AnyCodable],
        allMissingRank: Double,
        stableIndexOffset: Int
    ) -> [Entry] {
        let observed = messages.map(timestampMilliseconds)
        var ranks = observed

        for index in ranks.indices where ranks[index] == nil {
            let previousIndex = (0..<index).last(where: { observed[$0] != nil })
            let nextIndex = ((index + 1)..<observed.count).first(where: { observed[$0] != nil })

            switch (previousIndex, nextIndex) {
            case let (.some(previousIndex), .some(nextIndex)):
                let previous = observed[previousIndex]!
                let next = observed[nextIndex]!
                let fraction = Double(index - previousIndex) / Double(nextIndex - previousIndex)
                ranks[index] = next >= previous
                    ? previous + ((next - previous) * fraction)
                    : previous
            case let (.some(previousIndex), .none):
                ranks[index] = observed[previousIndex]! + (Double(index - previousIndex) * 0.001)
            case let (.none, .some(nextIndex)):
                ranks[index] = observed[nextIndex]! - (Double(nextIndex - index) * 0.001)
            case (.none, .none):
                ranks[index] = allMissingRank
            }
        }

        // Malformed/non-monotonic source timestamps must never reorder that source.
        for index in ranks.indices.dropFirst() {
            if let previous = ranks[index - 1], let current = ranks[index], current < previous {
                ranks[index] = previous
            }
        }

        return messages.enumerated().map { index, message in
            Entry(
                message: normalizedTimestampMessage(message),
                timestampMilliseconds: ranks[index],
                fallbackRank: allMissingRank,
                stableIndex: stableIndexOffset + index
            )
        }
    }

    /// `OpenClawChatMessage` and shared presentation code interpret timestamps as epoch
    /// milliseconds. Rewrite older epoch-second values into that canonical unit; a malformed
    /// string/Boolean timestamp would otherwise make `decodeMessages` drop the entire turn, so
    /// preserve the turn and discard only unusable metadata.
    private static func normalizedTimestampMessage(_ message: AnyCodable) -> AnyCodable {
        guard let data = try? JSONEncoder().encode(message),
              var dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dictionary["timestamp"]
        else { return message }

        if !(raw is Bool), let number = raw as? NSNumber {
            let value = number.doubleValue
            if value.isFinite {
                let milliseconds = value < 100_000_000_000 ? value * 1000 : value
                guard milliseconds != value else { return message }
                dictionary["timestamp"] = milliseconds
                return AnyCodable(dictionary)
            }
        }

        dictionary.removeValue(forKey: "timestamp")
        return AnyCodable(dictionary)
    }

    private static func timestampMilliseconds(_ message: AnyCodable) -> Double? {
        guard let data = try? JSONEncoder().encode(message),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dictionary["timestamp"],
              !(raw is Bool),
              let number = raw as? NSNumber
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        // Be tolerant of task turns produced by older clients that used epoch seconds.
        return value < 100_000_000_000 ? value * 1000 : value
    }
}
