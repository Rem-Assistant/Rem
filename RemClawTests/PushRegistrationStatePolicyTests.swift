import Testing
@testable import RemClaw

struct PushRegistrationStatePolicyTests {
    @Test func coldProcessLogoutUsesThePersistedRegisteredToken() {
        #expect(PushRegistrationStatePolicy.tokensForUnregister(
            latest: nil,
            persisted: "persisted-token"
        ) == ["persisted-token"])
    }

    @Test func rotationUnregistersPersistedSuccessAndFreshInFlightToken() {
        #expect(PushRegistrationStatePolicy.tokensForUnregister(
            latest: "fresh-token",
            persisted: "persisted-token"
        ) == ["persisted-token", "fresh-token"])
    }

    @Test func blankValuesDoNotAttemptAnUnregister() {
        #expect(PushRegistrationStatePolicy.tokensForUnregister(latest: " ", persisted: nil).isEmpty)
    }

    @Test func identicalLatestAndPersistedTokenIsUnregisteredOnce() {
        #expect(PushRegistrationStatePolicy.tokensForUnregister(
            latest: "same-token",
            persisted: "same-token"
        ) == ["same-token"])
    }

    @Test func legacySuccessCacheCannotSkipInstallationAuthorityUpgrade() {
        #expect(!PushRegistrationStatePolicy.registrationMatchesAuthority(
            token: "same-token",
            environment: "production",
            userId: "account-a",
            installationId: "install-a",
            ownershipGeneration: 42,
            persistedToken: "same-token",
            persistedEnvironment: "production",
            persistedUserId: "account-a",
            persistedInstallationId: nil,
            persistedOwnershipGeneration: nil
        ))
    }

    @Test func completeInstallationAuthorityCanSkipRedundantRegistration() {
        #expect(PushRegistrationStatePolicy.registrationMatchesAuthority(
            token: "same-token",
            environment: "production",
            userId: "account-a",
            installationId: "install-a",
            ownershipGeneration: 42,
            persistedToken: "same-token",
            persistedEnvironment: "production",
            persistedUserId: "account-a",
            persistedInstallationId: "install-a",
            persistedOwnershipGeneration: 42
        ))
        #expect(!PushRegistrationStatePolicy.registrationMatchesAuthority(
            token: "same-token",
            environment: "production",
            userId: "account-a",
            installationId: "install-a",
            ownershipGeneration: 43,
            persistedToken: "same-token",
            persistedEnvironment: "production",
            persistedUserId: "account-a",
            persistedInstallationId: "install-a",
            persistedOwnershipGeneration: 42
        ))
    }

    @Test func coldUpgradeLogoutRetiresMigratedLegacyAuthority() {
        #expect(PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: "migrated-token",
            persistedUserId: "account-a",
            persistedInstallationId: nil,
            persistedOwnershipGeneration: nil,
            currentUserId: "account-a"
        ))
        #expect(PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: "migrated-token",
            persistedUserId: "account-a",
            persistedInstallationId: "install-a",
            persistedOwnershipGeneration: nil,
            currentUserId: "account-a"
        ))
    }

    @Test func completedUpgradeAndUnrelatedCachesDoNotRetireLegacyAuthority() {
        #expect(!PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: "current-token",
            persistedUserId: "account-a",
            persistedInstallationId: "install-a",
            persistedOwnershipGeneration: 42,
            currentUserId: "account-a"
        ))
        #expect(!PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: "migrated-token",
            persistedUserId: "account-a",
            persistedInstallationId: nil,
            persistedOwnershipGeneration: nil,
            currentUserId: "account-b"
        ))
        #expect(!PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: " ",
            persistedUserId: "account-a",
            persistedInstallationId: nil,
            persistedOwnershipGeneration: nil,
            currentUserId: "account-a"
        ))
    }
}
