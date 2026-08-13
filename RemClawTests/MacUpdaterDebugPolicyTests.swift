import Foundation
import Testing

struct MacUpdaterDebugPolicyTests {
    @Test func debugBuildsDoNotStartSparkleAutomatically() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let macAppModel = try read("RemClawMac/Sources/App/MacAppModel.swift", from: projectRoot)
        #expect(macAppModel.contains("startingUpdater: isSparkleEnabled"))
        let sparklePolicy = try excerpt(
            named: "MacRuntimeConfig.isSparkleEnabled",
            in: macAppModel,
            from: "static var isSparkleEnabled: Bool",
            through: "#endif"
        )
        #expect(sparklePolicy.contains("#if DEBUG"))
        #expect(sparklePolicy.contains("false"))
        #expect(sparklePolicy.contains("#else"))
        #expect(sparklePolicy.contains("true"))

        let readme = try read("RemClawMac/README.md", from: projectRoot)
        #expect(readme.contains("Sparkle is enabled only for non-Debug macOS builds."))
        #expect(readme.contains("Local Debug builds do not start the updater at launch."))
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func excerpt(
        named name: String,
        in source: String,
        from startMarker: String,
        through endMarker: String
    ) throws -> Substring {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source[start...].range(of: endMarker)?.upperBound else {
            throw TestFailure("Missing \(name) policy block")
        }
        return source[start..<end]
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
