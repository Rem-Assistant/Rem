import Foundation
import Observation

/// Product-facing projection of the three stored check-in slots into one built-in Daily Brief
/// automation. The backend remains the source of truth for each trigger; this type only derives
/// overview and run-history information that is already present in those records.
enum DailyBriefAutomationPresentation {
    struct Run: Identifiable, Equatable {
        let slot: String
        let processedAt: Date

        var id: String { "\(slot)-\(processedAt.timeIntervalSince1970)" }
    }

    static func isEnabled(_ checkins: [Checkin]) -> Bool {
        checkins.contains(where: \.enabled)
    }

    static func enabledTriggerCount(_ checkins: [Checkin]) -> Int {
        checkins.filter(\.enabled).count
    }

    static func statusDescription(_ checkins: [Checkin]) -> String {
        let count = enabledTriggerCount(checkins)
        switch count {
        case 0: return "Off"
        case 1: return "On · 1 time"
        default: return "On · \(count) times"
        }
    }

    static func recentRuns(_ checkins: [Checkin]) -> [Run] {
        checkins.compactMap { checkin in
            guard let raw = checkin.lastRunAt, let date = parseISO8601(raw) else { return nil }
            return Run(slot: checkin.slot, processedAt: date)
        }
        .sorted { $0.processedAt > $1.processedAt }
    }

    /// OpenClaw timestamps may include fractional seconds. Try both forms rather than choosing a
    /// decoder-wide strategy that would reject the other valid representation.
    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// Shared parent/detail state for the built-in Daily Brief automation. A single coordinator is
/// intentionally owned by the overview route and passed into detail so a refresh started on either
/// screen cannot race a trigger mutation performed on the other.
@MainActor
@Observable
final class DailyBriefAutomationStore {
    private struct Mutation {
        let id: UInt64
        let previous: Checkin
        let optimistic: Checkin
    }

    let service: any CheckinsProviding

    private(set) var checkins: [Checkin]
    private(set) var isLoading: Bool
    private(set) var loadError: Error?
    private(set) var savingSlots: Set<String> = []
    private(set) var detailErrorMessage: String?

    private var refreshGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var mutationsBySlot: [String: Mutation] = [:]

    init(service: any CheckinsProviding, checkins: [Checkin] = []) {
        self.service = service
        self.checkins = checkins
        self.isLoading = checkins.isEmpty
    }

    func load(showSkeleton: Bool) async {
        let generation = beginRefresh()
        if showSkeleton { isLoading = true }
        loadError = nil

        defer {
            if showSkeleton { isLoading = false }
        }

        do {
            let fetched = try await service.checkins()
            guard generation == refreshGeneration else { return }
            applyRefresh(fetched)
        } catch {
            guard generation == refreshGeneration else { return }
            // A background refresh failure must not replace already-renderable authoritative
            // content with an error card. Initial load failures remain actionable.
            if checkins.isEmpty { loadError = error }
        }
    }

    func refreshDetail() async {
        let generation = beginRefresh()
        do {
            let fetched = try await service.checkins()
            guard generation == refreshGeneration else { return }
            applyRefresh(fetched)
            detailErrorMessage = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if checkins.isEmpty {
                detailErrorMessage = "Couldn't refresh Daily Brief. Try again."
            }
        }
    }

    func persist(
        slot: String,
        enabled: Bool,
        deliveryHour: Int,
        deliveryMinute: Int
    ) async {
        guard let previous = checkins.first(where: { $0.slot == slot }) else { return }

        detailErrorMessage = nil
        mutationGeneration &+= 1
        let mutationID = mutationGeneration
        let optimistic = Checkin(
            slot: previous.slot,
            enabled: enabled,
            deliveryHour: deliveryHour,
            deliveryMinute: deliveryMinute,
            timezone: previous.timezone,
            lastRunAt: previous.lastRunAt)

        // Invalidate every GET that began before this mutation. A later refresh may still run;
        // applyRefresh merges its run evidence while retaining the optimistic control fields.
        refreshGeneration &+= 1
        mutationsBySlot[slot] = Mutation(
            id: mutationID,
            previous: previous,
            optimistic: optimistic)
        savingSlots.insert(slot)
        replace(optimistic)

        do {
            let updated = try await service.update(
                slot: slot,
                enabled: enabled,
                deliveryHour: deliveryHour,
                deliveryMinute: deliveryMinute)
            guard let mutation = mutationsBySlot[slot], mutation.id == mutationID else { return }

            let current = checkins.first(where: { $0.slot == slot })
            replace(mergingNewestRunEvidence(updated, current))
            // A refresh that began while the PUT was active captured a pre-confirmation
            // snapshot. Invalidate it before releasing mutation ownership; otherwise its delayed
            // response would no longer see the optimistic fence and could revert this success.
            refreshGeneration &+= 1
            mutationsBySlot[slot] = nil
            savingSlots.remove(slot)
        } catch {
            guard let mutation = mutationsBySlot[slot], mutation.id == mutationID else { return }

            // Roll back only if this mutation still owns the optimistic control values. A newer
            // mutation or authoritative state replacement must never be overwritten. Preserve
            // run evidence learned by a refresh while the failed PUT was in flight.
            if let current = checkins.first(where: { $0.slot == slot }),
               sameControls(current, mutation.optimistic) {
                let rollback = Checkin(
                    slot: mutation.previous.slot,
                    enabled: mutation.previous.enabled,
                    deliveryHour: mutation.previous.deliveryHour,
                    deliveryMinute: mutation.previous.deliveryMinute,
                    timezone: mutation.previous.timezone,
                    lastRunAt: newestRunEvidence(
                        mutation.previous.lastRunAt,
                        current.lastRunAt))
                replace(rollback)
            }
            // A refresh launched under the failed mutation's optimistic fence is also stale once
            // rollback completes. A new refresh can begin from the settled state.
            refreshGeneration &+= 1
            mutationsBySlot[slot] = nil
            savingSlots.remove(slot)
            detailErrorMessage = "Couldn't save Daily Brief. Try again."
        }
    }

    private func beginRefresh() -> UInt64 {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    private func applyRefresh(_ fetched: [Checkin]) {
        checkins = fetched.map { remote in
            guard let mutation = mutationsBySlot[remote.slot],
                  let current = checkins.first(where: { $0.slot == remote.slot }),
                  sameControls(current, mutation.optimistic)
            else { return remote }

            return Checkin(
                slot: current.slot,
                enabled: current.enabled,
                deliveryHour: current.deliveryHour,
                deliveryMinute: current.deliveryMinute,
                timezone: current.timezone,
                lastRunAt: newestRunEvidence(current.lastRunAt, remote.lastRunAt))
        }
    }

    private func replace(_ checkin: Checkin) {
        guard let index = checkins.firstIndex(where: { $0.slot == checkin.slot }) else { return }
        checkins[index] = checkin
    }

    private func mergingNewestRunEvidence(_ updated: Checkin, _ current: Checkin?) -> Checkin {
        Checkin(
            slot: updated.slot,
            enabled: updated.enabled,
            deliveryHour: updated.deliveryHour,
            deliveryMinute: updated.deliveryMinute,
            timezone: updated.timezone,
            lastRunAt: newestRunEvidence(updated.lastRunAt, current?.lastRunAt))
    }

    private func sameControls(_ lhs: Checkin, _ rhs: Checkin) -> Bool {
        lhs.slot == rhs.slot &&
            lhs.enabled == rhs.enabled &&
            lhs.deliveryHour == rhs.deliveryHour &&
            lhs.deliveryMinute == rhs.deliveryMinute &&
            lhs.timezone == rhs.timezone
    }

    private func newestRunEvidence(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return value
        case let (left?, right?):
            guard let leftDate = DailyBriefAutomationPresentation.parseISO8601(left),
                  let rightDate = DailyBriefAutomationPresentation.parseISO8601(right)
            else {
                // A valid non-nil current value is still more informative than deleting it.
                return rhs ?? lhs
            }
            return leftDate >= rightDate ? left : right
        }
    }
}
