import Foundation
import Testing

struct AppBundleBrandingTests {
    @Test func iOSBundleUsesRemForBothUserVisibleNames() throws {
        let root = projectRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("RemClaw/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["CFBundleName"] as? String == "Rem")
        #expect(plist["CFBundleDisplayName"] as? String == "Rem")
    }

    @Test func debugAndReleaseKeepInternalArtifactsAndUseRemPermissionCopy() throws {
        let project = try String(
            contentsOf: projectRoot().appendingPathComponent("RemClaw.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        for configurationID in ["7778127B2F374DFC0003116E", "7778127C2F374DFC0003116E"] {
            let configuration = try configurationBlock(id: configurationID, in: project)
            #expect(configuration.contains("INFOPLIST_FILE = RemClaw/Info.plist;"))
            #expect(configuration.contains("INFOPLIST_KEY_CFBundleName = Rem;"))
            #expect(configuration.contains("INFOPLIST_KEY_CFBundleDisplayName = Rem;"))
            #expect(configuration.contains("PRODUCT_NAME = Rem;"))
            #expect(configuration.contains("EXECUTABLE_NAME = \"$(TARGET_NAME)\";"))
            #expect(configuration.contains("PRODUCT_MODULE_NAME = \"$(TARGET_NAME)\";"))
            #expect(configuration.contains("WRAPPER_NAME = \"$(TARGET_NAME).app\";"))
            #expect(configuration.contains("INFOPLIST_KEY_NSCalendarsUsageDescription = \"Rem needs calendar access"))
            #expect(configuration.contains("INFOPLIST_KEY_NSMicrophoneUsageDescription = \"Rem needs microphone access"))
            #expect(configuration.contains("INFOPLIST_KEY_NSRemindersUsageDescription = \"Rem needs reminders access"))
            #expect(!configuration.contains("RemClaw needs"))
        }
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func configurationBlock(id: String, in project: String) throws -> Substring {
        let marker = "\(id) /*"
        guard let start = project.range(of: marker)?.lowerBound,
              let end = project[start...].range(of: "\n\t\t};")?.upperBound else {
            throw BrandingTestFailure("Missing build configuration \(id)")
        }
        return project[start..<end]
    }
}

private struct BrandingTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
