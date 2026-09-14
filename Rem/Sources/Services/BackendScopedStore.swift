import Foundation
import SwiftData

/// Namespaces the local SwiftData store by **backend target** in DEBUG builds, so
/// switching staging↔prod SWAPS data instead of wiping it (Fix 3,
/// docs/rebuild/04-FIX-IDENTITY-DATALOSS.md).
///
/// Release builds point at a single prod backend and never switch targets, so
/// they are unaffected and use the default store unchanged.
///
/// Migration-free by design: the FIRST backend target seen inherits the existing
/// default store (so your current data is preserved with zero copying); any
/// *different* target gets its own store file. Switching back restores the
/// original target's data.
enum BackendScopedStore {
    private static let mapKey = "rem.debug.storeFilenameByTarget"

    /// Sentinel meaning "use the default ModelContainer location" (the first
    /// target keeps whatever store already exists).
    static let defaultStoreSentinel = "__default__"

    /// Pure mapping from backend target → store filename, given the current map.
    /// First target → default store; later targets → distinct suffixed stores.
    static func resolveStoreFilename(
        target: String,
        map: [String: String]
    ) -> (filename: String, updatedMap: [String: String]) {
        if let existing = map[target] { return (existing, map) }
        let filename = map.isEmpty ? defaultStoreSentinel : "Rem-\(map.count).store"
        var updated = map
        updated[target] = filename
        return (filename, updated)
    }

    #if DEBUG
    /// A `ModelConfiguration` scoped to the current backend target, or `nil` to
    /// use the default container (no target set, or this target owns the default
    /// store). Persists the target→filename map in UserDefaults.
    @MainActor
    static func debugConfiguration() -> ModelConfiguration? {
        let target = AppConfig.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        let defaults = UserDefaults.standard
        let map = (defaults.dictionary(forKey: mapKey) as? [String: String]) ?? [:]
        let (filename, updated) = resolveStoreFilename(target: target, map: map)
        if updated != map { defaults.set(updated, forKey: mapKey) }

        guard filename != defaultStoreSentinel else { return nil }

        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return ModelConfiguration(url: dir.appending(path: filename))
    }
    #endif
}
