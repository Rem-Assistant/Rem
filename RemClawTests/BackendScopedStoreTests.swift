import Foundation
import Testing
@testable import RemClaw

/// Pins Fix 3's store-namespacing: switching backend target (DEBUG) must SWAP
/// the local store, not wipe it. The first target keeps the existing default
/// store (migration-free); other targets get distinct stores; switching back is
/// stable. See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
struct BackendScopedStoreTests {
    typealias Store = BackendScopedStore

    @Test func firstTargetInheritsDefaultStore() {
        let (filename, map) = Store.resolveStoreFilename(target: "https://prod", map: [:])
        #expect(filename == Store.defaultStoreSentinel)
        #expect(map["https://prod"] == Store.defaultStoreSentinel)
    }

    @Test func secondTargetGetsDistinctStore() {
        let start = ["https://prod": Store.defaultStoreSentinel]
        let (filename, map) = Store.resolveStoreFilename(target: "https://staging", map: start)
        #expect(filename == "Rem-1.store")
        #expect(map["https://staging"] == "Rem-1.store")
        // prod's mapping is untouched.
        #expect(map["https://prod"] == Store.defaultStoreSentinel)
    }

    @Test func knownTargetIsStableAndDoesNotMutateMap() {
        let start = ["https://prod": Store.defaultStoreSentinel, "https://staging": "Rem-1.store"]
        let (filename, map) = Store.resolveStoreFilename(target: "https://staging", map: start)
        #expect(filename == "Rem-1.store")
        #expect(map == start) // no churn for a known target
    }

    @Test func switchingBackAndForthPreservesEachStore() {
        var map: [String: String] = [:]
        (_, map) = Store.resolveStoreFilename(target: "prod", map: map)      // default
        (_, map) = Store.resolveStoreFilename(target: "staging", map: map)   // Rem-1
        let (prodAgain, _) = Store.resolveStoreFilename(target: "prod", map: map)
        let (stagingAgain, _) = Store.resolveStoreFilename(target: "staging", map: map)
        #expect(prodAgain == Store.defaultStoreSentinel)
        #expect(stagingAgain == "Rem-1.store")
    }
}
