#if os(macOS)
import Foundation
import Testing
@testable import RemClawMac

@MainActor
struct LaunchAgentSecretsMigratorMacTests {

    @Test func plistSurvivesWhenProviderPersistenceFails() async {
        let suiteName = "LaunchAgentSecretsMigratorMacTests.failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app.remclaw.mac.gateway.\(UUID().uuidString).plist")
        var existingFiles: Set<URL> = [plistURL]
        var removedFiles: [URL] = []
        var bootoutCalled = false

        let dependencies = LaunchAgentSecretsMigrator.Dependencies(
            legacyPlistURL: { plistURL },
            fileExists: { existingFiles.contains($0) },
            readData: { _ in Self.leakyPlistData() },
            removeItem: { url in
                existingFiles.remove(url)
                removedFiles.append(url)
            },
            persistProviderKey: { _, _ in false },
            persistGatewayAuthToken: { _ in true },
            bootoutLegacyAgent: { bootoutCalled = true }
        )

        await LaunchAgentSecretsMigrator.runIfNeeded(defaults: defaults, dependencies: dependencies)

        #expect(existingFiles.contains(plistURL))
        #expect(removedFiles.isEmpty)
        #expect(!bootoutCalled)
        #expect(!defaults.bool(forKey: "launchAgentSecretsMigrated.v1"))
    }

    @Test func sentinelDoesNotSuppressScrubWhenPlistReappears() async {
        let suiteName = "LaunchAgentSecretsMigratorMacTests.sentinel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAgentSecretsMigrated.v1")

        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app.remclaw.mac.gateway.\(UUID().uuidString).plist")
        var existingFiles: Set<URL> = [plistURL]
        var removedFiles: [URL] = []
        var bootoutCalled = false

        let dependencies = LaunchAgentSecretsMigrator.Dependencies(
            legacyPlistURL: { plistURL },
            fileExists: { existingFiles.contains($0) },
            readData: { _ in Self.cleanPlistData() },
            removeItem: { url in
                existingFiles.remove(url)
                removedFiles.append(url)
            },
            persistProviderKey: { _, _ in true },
            persistGatewayAuthToken: { _ in true },
            bootoutLegacyAgent: { bootoutCalled = true }
        )

        await LaunchAgentSecretsMigrator.runIfNeeded(defaults: defaults, dependencies: dependencies)

        #expect(!existingFiles.contains(plistURL))
        #expect(removedFiles == [plistURL])
        #expect(bootoutCalled)
        #expect(defaults.bool(forKey: "launchAgentSecretsMigrated.v1"))
    }

    @Test func plistSurvivesWhenReadFails() async {
        let suiteName = "LaunchAgentSecretsMigratorMacTests.readFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app.remclaw.mac.gateway.\(UUID().uuidString).plist")
        var existingFiles: Set<URL> = [plistURL]
        var removedFiles: [URL] = []
        var bootoutCalled = false

        let dependencies = LaunchAgentSecretsMigrator.Dependencies(
            legacyPlistURL: { plistURL },
            fileExists: { existingFiles.contains($0) },
            readData: { _ in nil },
            removeItem: { url in
                existingFiles.remove(url)
                removedFiles.append(url)
            },
            persistProviderKey: { _, _ in true },
            persistGatewayAuthToken: { _ in true },
            bootoutLegacyAgent: { bootoutCalled = true }
        )

        await LaunchAgentSecretsMigrator.runIfNeeded(defaults: defaults, dependencies: dependencies)

        #expect(existingFiles.contains(plistURL))
        #expect(removedFiles.isEmpty)
        #expect(!bootoutCalled)
        #expect(!defaults.bool(forKey: "launchAgentSecretsMigrated.v1"))
    }

    @Test func plistSurvivesWhenMalformed() async {
        let suiteName = "LaunchAgentSecretsMigratorMacTests.malformed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app.remclaw.mac.gateway.\(UUID().uuidString).plist")
        var existingFiles: Set<URL> = [plistURL]
        var removedFiles: [URL] = []
        var bootoutCalled = false

        let dependencies = LaunchAgentSecretsMigrator.Dependencies(
            legacyPlistURL: { plistURL },
            fileExists: { existingFiles.contains($0) },
            readData: { _ in Data("not a plist".utf8) },
            removeItem: { url in
                existingFiles.remove(url)
                removedFiles.append(url)
            },
            persistProviderKey: { _, _ in true },
            persistGatewayAuthToken: { _ in true },
            bootoutLegacyAgent: { bootoutCalled = true }
        )

        await LaunchAgentSecretsMigrator.runIfNeeded(defaults: defaults, dependencies: dependencies)

        #expect(existingFiles.contains(plistURL))
        #expect(removedFiles.isEmpty)
        #expect(!bootoutCalled)
        #expect(!defaults.bool(forKey: "launchAgentSecretsMigrated.v1"))
    }

    private static func leakyPlistData() -> Data {
        let plist: [String: Any] = [
            "Label": "app.remclaw.mac.gateway",
            "EnvironmentVariables": [
                "OPENAI_API_KEY": "sk-proj-fake-openai-test-key",
                "OPENCLAW_AUTH_TOKEN": "fake-gateway-token",
            ],
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }

    private static func cleanPlistData() -> Data {
        let plist: [String: Any] = [
            "Label": "app.remclaw.mac.gateway",
            "ProgramArguments": ["/usr/local/bin/openclaw", "gateway", "run"],
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }
}
#endif
