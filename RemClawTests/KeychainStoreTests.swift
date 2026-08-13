import Security
import Testing
@testable import RemClaw

struct KeychainStoreTests {
    @Test func interactionNotAllowedUpdateFailureIsRepairableWhenSavingReplacementValue() {
        #expect(KeychainStore.isRepairableUpdateFailure(errSecInteractionNotAllowed))
    }

    @Test func nonStaleSecurityFailuresAreNotRepairable() {
        #expect(!KeychainStore.isRepairableUpdateFailure(errSecAuthFailed))
        #expect(!KeychainStore.isRepairableUpdateFailure(errSecMissingEntitlement))
    }
}
