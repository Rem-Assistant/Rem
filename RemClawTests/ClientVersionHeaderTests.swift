import Foundation
import Testing

struct ClientVersionHeaderTests {
    @Test func sharedClientVersionDeclaresVersionAndPlatformHeaders() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let clientVersion = try read("Shared/Services/ClientVersion.swift", from: projectRoot)
        #expect(clientVersion.contains("static let headerName: String = \"X-Client-Version\""))
        #expect(clientVersion.contains("static let platformHeaderName: String = \"X-Client-Platform\""))
        #expect(clientVersion.contains("static let platformValue: String"))
        #expect(clientVersion.contains("request.setValue(headerValue, forHTTPHeaderField: headerName)"))
        #expect(clientVersion.contains("request.setValue(platformValue, forHTTPHeaderField: platformHeaderName)"))
    }

    @Test func backendRequestCallSitesUseSharedClientVersionHeaders() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let callSitePaths = [
            "RemClaw/Sources/Services/Auth/AuthenticatedHttpClient.swift",
            "RemClaw/Sources/Services/Auth/RemAuthService.swift",
            "RemClawMac/Sources/Gateway/MacAuthenticatedHttpClient.swift",
            "RemClawMac/Sources/Gateway/MacGatewaySessionManager.swift",
            "Shared/Views/Settings/SharedDeleteAccountSheet.swift",
        ]

        for path in callSitePaths {
            let source = try read(path, from: projectRoot)
            #expect(source.contains("ClientVersion.setHeaders(on: &request)"))
            #expect(!source.contains("ClientVersion.headerValue, forHTTPHeaderField: ClientVersion.headerName"))
        }
    }

    @Test func backendLogsClientVersionAndPlatform() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let server = try read("backend/src/server.ts", from: projectRoot)
        #expect(server.contains("extractClientInfo(req)"))
        #expect(server.contains("clientVersion=${client.version}"))
        #expect(server.contains("clientPlatform=${client.platform}"))

        let middleware = try read("backend/src/middleware/client-info.ts", from: projectRoot)
        #expect(middleware.contains("'x-client-version'"))
        #expect(middleware.contains("'x-client-platform'"))
    }
}

private func read(_ path: String, from root: URL) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
