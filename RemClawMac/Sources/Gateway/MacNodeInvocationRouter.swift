import AppKit
import Foundation
import OpenClawKit
import UserNotifications

/// Routes gateway tool invocations to macOS-specific handlers.
///
/// Implemented:
///   - system.notify (NSUserNotification)
///   - system.which (check for binaries via /usr/bin/which)
///   - system.run (execute shell commands)
///   - clipboard.read / clipboard.write
///   - files.read / files.write / files.list
///   - calendar.events / calendar.add / calendar.update / calendar.delete
///   - browser.proxy (limited: open HTTP(S) URLs in the user's browser)
///
/// Stubbed:
///   - screen.record (needs ScreenCaptureKit — Phase 2)
enum MacNodeInvocationRouter {

    // MARK: - Advertised capabilities (R1 / #810)
    //
    // The Mac advertises only what the `handle(_:)` switch below actually
    // fulfills — notably NO reminders, so the agent is never offered a command
    // this device can't run. Because the router dispatches via a `switch`
    // (not an introspectable dictionary like iOS's `NodeInvocationRouter`),
    // this list is the single source of truth for Mac advertising and must
    // stay in sync with the `switch`. `MacGatewayClient` reads it at connect.

    /// Commands advertised to the gateway/agent at connect time.
    static let advertisedCommands: [String] = [
        "system.notify", "system.which", "system.run",
        "screen.record",
        MacCalendarCommand.events.rawValue,
        MacCalendarCommand.add.rawValue,
        MacCalendarCommand.update.rawValue,
        MacCalendarCommand.delete.rawValue,
        "clipboard.read", "clipboard.write",
        "shell.exec",
        "files.read", "files.write", "files.list",
        "browser.proxy",
    ]

    /// Capability families advertised at connect.
    static let advertisedCaps: [String] = [
        "system", "screen", "calendar", "clipboard", "shell", "files", "browser",
    ]

    @MainActor private static var calendarServiceOverride: MacCalendarGatewayServicing?
    @MainActor private static var liveCalendarService: MacCalendarGatewayServicing?
    @MainActor private static var browserOpenURLOverride: ((URL) -> Bool)?
    @MainActor private static var browserOpenApprovalOverride: ((URL) -> Bool)?

    @MainActor
    static func configureCalendarServiceForTesting(_ service: MacCalendarGatewayServicing) {
        calendarServiceOverride = service
    }

    @MainActor
    static func resetCalendarServiceForTesting() {
        calendarServiceOverride = nil
        liveCalendarService = nil
    }

    @MainActor
    static func configureBrowserOpenForTesting(_ handler: @escaping (URL) -> Bool) {
        browserOpenURLOverride = handler
    }

    @MainActor
    static func configureBrowserOpenApprovalForTesting(_ handler: @escaping (URL) -> Bool) {
        browserOpenApprovalOverride = handler
    }

    @MainActor
    static func resetBrowserOpenForTesting() {
        browserOpenURLOverride = nil
        browserOpenApprovalOverride = nil
    }

    @MainActor
    private static func calendarService() -> MacCalendarGatewayServicing {
        if let calendarServiceOverride {
            return calendarServiceOverride
        }
        if let liveCalendarService {
            return liveCalendarService
        }
        let service = MacCalendarGatewayService()
        liveCalendarService = service
        return service
    }

    static func handle(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let command = req.command

        switch command {

        // MARK: - System

        case "system.notify":
            return await handleNotify(req)

        case "system.which":
            return await handleWhich(req)

        case "system.run", "shell.exec":
            return await handleShellExec(req)

        // MARK: - Clipboard

        case "clipboard.read":
            return handleClipboardRead(req)

        case "clipboard.write":
            return handleClipboardWrite(req)

        // MARK: - Files

        case "files.read":
            return await handleFilesRead(req)

        case "files.write":
            return await handleFilesWrite(req)

        case "files.list":
            return await handleFilesList(req)

        // MARK: - Browser

        case "browser.proxy":
            return await handleBrowserProxy(req)

        // MARK: - Calendar

        case MacCalendarCommand.events.rawValue:
            return await handleCalendarEvents(req)

        case MacCalendarCommand.add.rawValue:
            return await handleCalendarAdd(req)

        case MacCalendarCommand.update.rawValue:
            return await handleCalendarUpdate(req)

        case MacCalendarCommand.delete.rawValue:
            return await handleCalendarDelete(req)

        // MARK: - Screen (Phase 2)

        case "screen.record":
            return unavailable(req, "Screen recording is not yet implemented. Coming soon.")

        // MARK: - Unknown

        default:
            // Terminal: this command is not in the Mac handler registry, so
            // retrying will never succeed (R2-A / #811).
            return BridgeInvokeResponse(
                id: req.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .invalidRequest,
                    message: "UNKNOWN_COMMAND: '\(command)' does not exist on the connected device. Do not retry.",
                    retryable: false))
        }
    }

    // MARK: - Calendar

    @MainActor
    private static func handleCalendarEvents(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let params: MacCalendarEventsParams = decodeParams(req) ?? MacCalendarEventsParams()

        do {
            let events = try await calendarService().fetchEvents(params: params)
            return encodeSuccess(req, CalendarEventsResponse(events: events))
        } catch {
            return calendarErrorResponse(req, error)
        }
    }

    @MainActor
    private static func handleCalendarAdd(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: MacCalendarAddParams = decodeParams(req) else {
            return invalidParams(req, "calendar.add requires title and startDate")
        }

        do {
            let response = try await calendarService().addEvent(params: params)
            return encodeSuccess(req, response)
        } catch {
            return calendarErrorResponse(req, error)
        }
    }

    @MainActor
    private static func handleCalendarUpdate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: MacCalendarUpdateParams = decodeParams(req) else {
            return invalidParams(req, "calendar.update requires eventId")
        }

        do {
            let response = try await calendarService().updateEvent(params: params)
            return encodeSuccess(req, response)
        } catch {
            return calendarErrorResponse(req, error)
        }
    }

    @MainActor
    private static func handleCalendarDelete(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: MacCalendarDeleteParams = decodeParams(req) else {
            return invalidParams(req, "calendar.delete requires eventId")
        }

        do {
            let response = try await calendarService().deleteEvent(params: params)
            return encodeSuccess(req, response)
        } catch {
            return calendarErrorResponse(req, error)
        }
    }

    // MARK: - system.notify

    private static func handleNotify(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: SystemNotifyParams = decodeParams(req) else {
            return invalidParams(req, "missing notify params")
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let content = UNMutableNotificationContent()
        content.title = params.title
        content.body = params.body
        if params.sound != nil { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))

        do {
            try await center.add(request)
            return BridgeInvokeResponse(id: req.id, ok: true)
        } catch {
            return errorResponse(req, "NOTIFY_FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - system.which

    private static func handleWhich(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        // Report which common binaries are available
        let binaries = ["git", "node", "python3", "brew", "docker", "ffmpeg", "curl", "jq"]
        var results: [String: String] = [:]

        for bin in binaries {
            let (output, code) = await shell("/usr/bin/which", [bin])
            if code == 0, let path = output.split(separator: "\n").first {
                results[bin] = String(path)
            }
        }

        guard let data = try? JSONEncoder().encode(["bins": results]),
              let json = String(data: data, encoding: .utf8)
        else {
            return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: "{\"bins\":{}}")
        }
        return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: json)
    }

    // MARK: - shell.exec / system.run

    private static func handleShellExec(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: ShellExecParams = decodeParams(req) else {
            return invalidParams(req, "shell.exec requires command")
        }

        let timeoutSeconds = params.timeoutMs.map { Double($0) / 1000.0 } ?? 30.0
        let (output, exitCode) = await shell("/bin/zsh", ["-c", params.command], timeout: timeoutSeconds)

        let payload = ShellExecResponse(exitCode: exitCode, output: output)
        return encodeSuccess(req, payload)
    }

    // MARK: - clipboard.read

    private static func handleClipboardRead(_ req: BridgeInvokeRequest) -> BridgeInvokeResponse {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string) ?? ""
        let payload = ClipboardPayload(text: text)
        return encodeSuccess(req, payload)
    }

    // MARK: - clipboard.write

    private static func handleClipboardWrite(_ req: BridgeInvokeRequest) -> BridgeInvokeResponse {
        guard let params: ClipboardPayload = decodeParams(req) else {
            return invalidParams(req, "clipboard.write requires text")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(params.text, forType: .string)
        return BridgeInvokeResponse(id: req.id, ok: true)
    }

    // MARK: - files.read

    private static func handleFilesRead(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: FilesReadParams = decodeParams(req) else {
            return invalidParams(req, "files.read requires path")
        }

        let path = (params.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return errorResponse(req, "File not found: \(params.path)")
        }

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return encodeSuccess(req, FilesReadResponse(content: content, path: path))
        } catch {
            return errorResponse(req, "Failed to read file: \(error.localizedDescription)")
        }
    }

    // MARK: - files.write

    private static func handleFilesWrite(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: FilesWriteParams = decodeParams(req) else {
            return invalidParams(req, "files.write requires path and content")
        }

        let path = (params.path as NSString).expandingTildeInPath
        do {
            try params.content.write(toFile: path, atomically: true, encoding: .utf8)
            return BridgeInvokeResponse(id: req.id, ok: true)
        } catch {
            return errorResponse(req, "Failed to write file: \(error.localizedDescription)")
        }
    }

    // MARK: - files.list

    private static func handleFilesList(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: FilesListParams = decodeParams(req) else {
            return invalidParams(req, "files.list requires path")
        }

        let path = (params.path as NSString).expandingTildeInPath
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            let limit = params.limit ?? 100
            let items: [FilesListItem] = Array(entries.prefix(limit)).map { name in
                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                return FilesListItem(name: name, isDirectory: isDir.boolValue)
            }
            return encodeSuccess(req, FilesListResponse(entries: items, path: path))
        } catch {
            return errorResponse(req, "Failed to list directory: \(error.localizedDescription)")
        }
    }

    // MARK: - browser.proxy

    @MainActor
    private static func handleBrowserProxy(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: BrowserProxyParams = decodeParams(req) else {
            return invalidParams(req, "browser.proxy requires method and path")
        }

        let method = (params.method ?? "GET").uppercased()
        let path = params.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard method == "POST", path == "/tabs/open" else {
            return unavailable(req, "Only opening browser tabs is supported on Rem for Mac today.")
        }

        guard let urlString = params.body?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else {
            return invalidParams(req, "browser.proxy /tabs/open requires url")
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              BrowserOpenApproval.isPublicWebURL(url) else {
            return invalidParams(req, "Rem can only open public http or https links after approval.")
        }

        let approved: Bool
        if let browserOpenApprovalOverride {
            approved = browserOpenApprovalOverride(url)
        } else {
            approved = BrowserOpenApproval.confirm(url: url)
        }

        guard approved else {
            return unavailable(req, "Opening this link was cancelled.")
        }

        let didOpen: Bool
        if let browserOpenURLOverride {
            didOpen = browserOpenURLOverride(url)
        } else {
            didOpen = NSWorkspace.shared.open(url)
        }

        guard didOpen else {
            return unavailable(req, "macOS did not open the URL")
        }

        let tab = BrowserProxyTab(
            targetId: "mac-open-\(UUID().uuidString)",
            tabId: nil,
            label: params.body?.label,
            title: nil,
            url: url.absoluteString,
            type: "page"
        )
        return encodeSuccess(req, BrowserProxyResponse(result: tab))
    }

    // MARK: - Shell helper

    private static func shell(_ launchPath: String, _ arguments: [String], timeout: Double = 10.0) async -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ("spawn error: \(error.localizedDescription)", 127)
        }

        // Timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    // MARK: - Helpers

    private static func unavailable(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        // Terminal: an unavailable / not-implemented capability won't appear on
        // retry (R2-A / #811).
        BridgeInvokeResponse(
            id: req.id, ok: false,
            error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: \(message)", retryable: false))
    }

    private static func invalidParams(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(
            id: req.id, ok: false,
            error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: \(message)"))
    }

    private static func errorResponse(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(
            id: req.id, ok: false,
            error: OpenClawNodeError(code: .invalidRequest, message: "ERROR: \(message)"))
    }

    private static func calendarErrorResponse(_ req: BridgeInvokeRequest, _ error: Error) -> BridgeInvokeResponse {
        if let calendarError = error as? MacCalendarGatewayError {
            return BridgeInvokeResponse(
                id: req.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "CALENDAR_UNAVAILABLE: \(calendarError.userMessage)"
                )
            )
        }

        return BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(
                code: .unavailable,
                message: "CALENDAR_UNAVAILABLE: \(error.localizedDescription)"
            )
        )
    }

    private static func decodeParams<T: Decodable>(_ req: BridgeInvokeRequest) -> T? {
        guard let json = req.paramsJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encodeSuccess<T: Encodable>(_ req: BridgeInvokeRequest, _ payload: T) -> BridgeInvokeResponse {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return errorResponse(req, "failed to encode response")
        }
        return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: json)
    }
}

@MainActor
private enum BrowserOpenApproval {
    static func confirm(url: URL) -> Bool {
        let host = url.host(percentEncoded: false) ?? "this site"
        let alert = NSAlert()
        alert.messageText = "Open \(host) in your default browser?"
        alert.informativeText = url.absoluteString
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func isPublicWebURL(_ url: URL) -> Bool {
        guard let rawHost = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        let host = canonicalHost(rawHost)
        guard !host.isEmpty else {
            return false
        }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }

        if isObfuscatedIPAddressHost(host) || isPrivateIPv4Host(host) || isPrivateIPv6Host(host) {
            return false
        }

        return true
    }

    private static func canonicalHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isObfuscatedIPAddressHost(_ host: String) -> Bool {
        if host.allSatisfy(\.isNumber) {
            return true
        }

        let labels = host.split(separator: ".")
        guard !labels.isEmpty else { return false }

        if labels.contains(where: { $0.lowercased().hasPrefix("0x") }) {
            return true
        }

        let numericLabels = labels.filter { $0.allSatisfy(\.isNumber) }
        guard numericLabels.count == labels.count else { return false }

        if labels.count != 4 {
            return true
        }

        return labels.contains { label in
            guard let value = Int(label) else { return true }
            if !(0...255).contains(value) { return true }
            return label.count > 1 && label.first == "0"
        }
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              parts.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else {
            return false
        }

        return first == 0
            || first == 10
            || first == 127
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    private static func isPrivateIPv6Host(_ host: String) -> Bool {
        if host == "::1"
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || host.hasPrefix("fe80:") {
            return true
        }

        if host.contains(":ffff:") {
            return true
        }

        return false
    }
}

// MARK: - Command types

struct SystemNotifyParams: Codable, Sendable {
    var title: String
    var body: String
    var sound: String?
}

struct ShellExecParams: Codable, Sendable {
    var command: String
    var timeoutMs: Int?
    var cwd: String?
}

struct ShellExecResponse: Codable, Sendable {
    var exitCode: Int32
    var output: String
}

struct ClipboardPayload: Codable, Sendable {
    var text: String
}

struct FilesReadParams: Codable, Sendable {
    var path: String
}

struct FilesReadResponse: Codable, Sendable {
    var content: String
    var path: String
}

struct FilesWriteParams: Codable, Sendable {
    var path: String
    var content: String
}

struct FilesListParams: Codable, Sendable {
    var path: String
    var limit: Int?
}

struct FilesListItem: Codable, Sendable {
    var name: String
    var isDirectory: Bool
}

struct FilesListResponse: Codable, Sendable {
    var entries: [FilesListItem]
    var path: String
}

struct BrowserProxyParams: Codable, Sendable {
    var method: String?
    var path: String
    var body: BrowserProxyBody?
}

struct BrowserProxyBody: Codable, Sendable {
    var url: String?
    var label: String?
}

struct BrowserProxyResponse: Codable, Sendable {
    var result: BrowserProxyTab
}

struct BrowserProxyTab: Codable, Sendable {
    var targetId: String
    var tabId: String?
    var label: String?
    var title: String?
    var url: String
    var type: String
}
