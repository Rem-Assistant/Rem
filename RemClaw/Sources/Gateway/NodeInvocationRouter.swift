import Foundation
import OpenClawKit
import SwiftData

/// Routes gateway tool invocations (node.invoke.request) to per-domain handlers.
///
/// Uses dictionary dispatch (matching upstream's NodeCapabilityRouter pattern)
/// instead of a monolithic switch statement. Handlers live in separate files
/// under `Handlers/`.
enum NodeInvocationRouter {

    typealias Handler = (BridgeInvokeRequest) async -> BridgeInvokeResponse

    @MainActor private static var isVoiceActiveProvider: (() -> Bool)?

    /// Handler table, built lazily on first access.
    /// Uses a computed `var` with manual caching instead of `static let`
    /// to avoid a Swift compiler crash in DefaultInitializerIsolation
    /// with `@MainActor static let` closures (Xcode 26 beta toolchain bug).
    @MainActor
    private static var _handlers: [String: Handler]?

    /// Commands advertised to the agent as callable tools (R1 / #810).
    /// Derived from the handler registry minus internal dispatch wrappers
    /// (`system.run`) and not-yet-implemented stubs, so the agent is only
    /// ever offered commands this device actually fulfills. Cached alongside
    /// `_handlers`.
    @MainActor
    private static var _advertisedCommands: [String]?

    @MainActor
    private static var handlers: [String: Handler] {
        if let existing = _handlers { return existing }
        buildRegistry()
        return _handlers ?? [:]
    }

    /// The commands advertised to the gateway/agent at connect time
    /// (`GatewayClient`). Single source of truth = this registry, so prose,
    /// allowlist, and the runtime registry can't drift (R1 / #810).
    @MainActor
    static var advertisedCommands: [String] {
        if let existing = _advertisedCommands { return existing }
        buildRegistry()
        return _advertisedCommands ?? []
    }

    /// Capability families advertised at connect — derived from the advertised
    /// command prefixes plus families that carry no directly-invocable command.
    @MainActor
    static var advertisedCaps: [String] {
        let families = Set(advertisedCommands.map { String($0.prefix { $0 != "." }) })
        return families.union(advertisedCapabilityOnlyFamilies).sorted()
    }

    /// Capabilities advertised in addition to those inferred from
    /// `advertisedCommands` — they have no directly-invocable command.
    @MainActor
    static let advertisedCapabilityOnlyFamilies: Set<String> = ["tool-events"]

    /// Builds (and caches) the handler table plus the advertised-command list.
    /// `advertisedCommands` excludes internal dispatch wrappers (`system.run`)
    /// and "coming soon" / not-applicable stubs, which would only ever return
    /// a terminal UNAVAILABLE — the agent should never be offered them.
    @MainActor
    private static func buildRegistry() {
        var h: [String: Handler] = [:]
        var nonAdvertised: Set<String> = []

        /// Registers a stub handler and excludes it from the advertised set.
        func addStub(_ key: String, _ message: String) {
            h[key] = stub(message)
            nonAdvertised.insert(key)
        }

        /// Registers a real handler that is dispatched but NOT advertised — atomically, so a
        /// new entry can't be registered-here-advertised-there and silently leak into the tool
        /// list (the drift `_advertisedCommands` as single source of truth exists to prevent).
        func addUnadvertised(_ key: String, _ handler: @escaping Handler) {
            h[key] = handler
            nonAdvertised.insert(key)
        }

        // System
        h[OpenClawSystemCommand.notify.rawValue] = SystemCommandHandler.handleNotify
        // Closure wrapper needed: handleWhich is sync but Handler typealias is async
        h[OpenClawSystemCommand.which.rawValue] = { req in SystemCommandHandler.handleWhich(req) }
        // Internal dispatch wrapper (gateway v2026.4.9+) — not a tool itself.
        h[OpenClawSystemCommand.run.rawValue] = handleSystemRun
        nonAdvertised.insert(OpenClawSystemCommand.run.rawValue)
        addStub(OpenClawSystemCommand.execApprovalsGet.rawValue, "Exec approvals are not applicable on iOS")
        addStub(OpenClawSystemCommand.execApprovalsSet.rawValue, "Exec approvals are not applicable on iOS")

        // Calendar
        h[RemCalendarCommand.events.rawValue] = CalendarCommandHandler.handleEvents
        h[RemCalendarCommand.add.rawValue] = CalendarCommandHandler.handleAdd
        h[RemCalendarCommand.update.rawValue] = CalendarCommandHandler.handleUpdate
        h[RemCalendarCommand.delete.rawValue] = CalendarCommandHandler.handleDelete

        // Reminders
        h[RemRemindersCommand.list.rawValue] = RemindersCommandHandler.handleList
        h[RemRemindersCommand.add.rawValue] = RemindersCommandHandler.handleAdd
        h[RemRemindersCommand.update.rawValue] = RemindersCommandHandler.handleUpdate
        h[RemRemindersCommand.delete.rawValue] = RemindersCommandHandler.handleDelete

        // Device
        h[RemDeviceCommand.status.rawValue] = DeviceCommandHandler.handleStatus
        h[RemDeviceCommand.info.rawValue] = DeviceCommandHandler.handleInfo

        // Tasks
        h[RemTasksCommand.list.rawValue] = TasksCommandHandler.handleList
        h[RemTasksCommand.get.rawValue] = TasksCommandHandler.handleGet
        h[RemTasksCommand.search.rawValue] = TasksCommandHandler.handleSearch
        h[RemTasksCommand.create.rawValue] = TasksCommandHandler.handleCreate
        h[RemTasksCommand.update.rawValue] = TasksCommandHandler.handleUpdate
        h[RemTasksCommand.delete.rawValue] = TasksCommandHandler.handleDelete

        // Lists (task organization — Sorted-style)
        h[RemListsCommand.list.rawValue] = ListsCommandHandler.handleList
        h[RemListsCommand.create.rawValue] = ListsCommandHandler.handleCreate

        // Folders (top-level task organization)
        h[RemFoldersCommand.list.rawValue] = FoldersCommandHandler.handleList
        h[RemFoldersCommand.create.rawValue] = FoldersCommandHandler.handleCreate

        // Stubs (Phase 3) — registered for dispatch, never advertised.
        for cmd in [OpenClawCameraCommand.list, .snap, .clip] {
            addStub(cmd.rawValue, "Camera is not yet implemented in Rem. Coming soon.")
        }
        addStub(OpenClawScreenCommand.record.rawValue, "Screen recording is not yet implemented in Rem. Coming soon.")
        // A2UI stays stubbed: it's a web bundle the gateway serves and drives via injected JS,
        // and its host-URL protocol doesn't exist at our deployed ref (v2026.4.11 speaks
        // `canvasHostUrl`; upstream HEAD replaced it and calls the old path "intentionally
        // unsupported" — openclaw/docs/refactor/canvas.md:56). Our viewer needs none of it.
        for cmd in [OpenClawCanvasA2UICommand.push, .pushJSONL, .reset] {
            addStub(cmd.rawValue, "Canvas A2UI is not applicable in Rem")
        }

        // Canvas — the live view of Rem's cloud browser (doc 37).
        // `present`/`hide` are advertised; the rest are registered so the agent gets a useful,
        // terminal redirect ("use the `browser` tool") instead of an unknown-command error,
        // but are not advertised as tools it should reach for.
        h[OpenClawCanvasCommand.present.rawValue] = CanvasCommandHandler.handlePresent
        h[OpenClawCanvasCommand.hide.rawValue] = CanvasCommandHandler.handleHide
        addUnadvertised(OpenClawCanvasCommand.navigate.rawValue, CanvasCommandHandler.handleNavigate)
        addUnadvertised(OpenClawCanvasCommand.evalJS.rawValue, CanvasCommandHandler.handleEval)
        addUnadvertised(OpenClawCanvasCommand.snapshot.rawValue, CanvasCommandHandler.handleSnapshot)

        _handlers = h
        _advertisedCommands = h.keys.filter { !nonAdvertised.contains($0) }.sorted()
    }

    // MARK: - Configuration

    @MainActor
    static func configureTaskAccess(
        modelContext: @escaping @MainActor () -> ModelContext?,
        taskSyncService: @escaping @MainActor () -> TaskSyncServiceProtocol?,
        taskApiService: @escaping @MainActor () -> TaskApiServiceProtocol?,
        organizationApiService: @escaping @MainActor () -> OrganizationApiService? = { nil }
    ) {
        TasksCommandHandler.configure(
            modelContext: modelContext,
            taskSyncService: taskSyncService,
            taskApiService: taskApiService,
            organizationApiService: organizationApiService
        )
        ListsCommandHandler.configure(
            modelContext: modelContext,
            organizationApiService: organizationApiService
        )
        FoldersCommandHandler.configure(
            modelContext: modelContext,
            organizationApiService: organizationApiService
        )
    }

    @MainActor
    static func configureVoiceStateProvider(_ provider: @escaping @MainActor () -> Bool) {
        isVoiceActiveProvider = provider
    }

    // MARK: - Dispatch

    static func handle(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let command = req.command
        let startTime = CFAbsoluteTimeGetCurrent()

        let response = await dispatch(command: command, req: req)

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        await trackInvocation(command: command, response: response, durationMs: durationMs)

        return response
    }

    /// Dispatch on MainActor to preserve isolation for handlers that touch
    /// EventKit/SwiftData. Non-isolated handlers are safe to call here too.
    @MainActor
    private static func dispatch(command: String, req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let handler = handlers[command] else {
            // Terminal: the command isn't in this device's registry, so a
            // retry will never succeed (R2-A / #811).
            return InvocationHelpers.unknownCommand(req, command)
        }
        return await handler(req)
    }

    // MARK: - Telemetry

    @MainActor
    private static var currentSource: String {
        (isVoiceActiveProvider?() ?? false) ? "voice" : "chat"
    }

    @MainActor
    private static func trackInvocation(command: String, response: BridgeInvokeResponse, durationMs: Int) {
        let source = currentSource

        if response.ok {
            TelemetryService.shared.track(eventName: TelemetryEvent.aiToolInvoked, properties: [
                "command": command,
                "success": true,
                "duration_ms": durationMs,
                "source": source,
            ])
        } else {
            let errorMessage = response.error?.message ?? "unknown"
            TelemetryService.shared.track(eventName: TelemetryEvent.aiToolError, properties: [
                "command": command,
                "success": false,
                "error_message": errorMessage,
                "duration_ms": durationMs,
                "source": source,
            ])
        }

        trackDomainEvent(command: command, ok: response.ok, source: source)
    }

    @MainActor
    private static func trackDomainEvent(command: String, ok: Bool, source: String) {
        guard ok else { return }

        switch command {
        case RemTasksCommand.create.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.taskCreated, properties: ["source": source, "type": "task"])
        case RemCalendarCommand.add.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.eventCreated, properties: ["source": source, "type": "event"])
        case RemCalendarCommand.update.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.eventUpdated, properties: ["source": source])
        case RemCalendarCommand.delete.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.eventDeleted, properties: ["source": source])
        case RemTasksCommand.delete.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.taskDeleted, properties: ["source": source])
        case RemRemindersCommand.add.rawValue:
            TelemetryService.shared.track(eventName: TelemetryEvent.reminderCreated, properties: ["source": source])
        default:
            break
        }
    }

    // MARK: - system.run command router

    /// Gateway v2026.4.9+ dispatches commands via exec/system.run.
    /// On Mac, this runs shell commands. On iOS, we parse the command string
    /// and route to the appropriate native handler.
    @MainActor
    private static func handleSystemRun(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        // Parse params: { "command": "calendar.events startDate=\"...\" endDate=\"...\"" }
        guard let paramsJSON = req.paramsJSON,
              let paramsData = paramsJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode(SystemRunParams.self, from: paramsData) else {
            return BridgeInvokeResponse(
                id: req.id, ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "system.run requires command"))
        }

        let (subcommand, args) = parseShellCommand(params.command)

        // Route to existing handler via dispatch
        let routedReq = BridgeInvokeRequest(
            id: req.id,
            command: subcommand,
            paramsJSON: args
        )

        guard let handler = handlers[subcommand] else {
            // Terminal: no native handler for this subcommand (R2-A / #811).
            return InvocationHelpers.unknownCommand(req, subcommand)
        }

        let response = await handler(routedReq)

        // Track telemetry under the actual subcommand, not "system.run"
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - CFAbsoluteTimeGetCurrent()) * 1000)
        trackDomainEvent(command: subcommand, ok: response.ok, source: currentSource)

        // Wrap the result in system.run format (exitCode + output)
        if response.ok {
            let outputJSON = response.payloadJSON ?? "null"
            let wrapped = "{\"exitCode\":0,\"output\":\(outputJSON)}"
            return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: wrapped)
        } else {
            let errorMsg: String
            if let err = response.error {
                // Use JSONSerialization for safe escaping
                if let data = try? JSONSerialization.data(withJSONObject: ["output": err.message]),
                   let json = String(data: data, encoding: .utf8) {
                    errorMsg = "{\"exitCode\":1,\(json.dropFirst().dropLast())}"
                } else {
                    errorMsg = "{\"exitCode\":1,\"output\":\"error\"}"
                }
            } else {
                errorMsg = "{\"exitCode\":1,\"output\":\"unknown error\"}"
            }
            return BridgeInvokeResponse(id: req.id, ok: false, payloadJSON: errorMsg, error: response.error)
        }
    }

    /// Parse a shell-style command string into (command, argsJSON).
    /// Input:  `calendar.events startDate="2026-04-14T00:00:00" endDate="2026-04-14T23:59:59"`
    /// Output: `("calendar.events", "{\"startDate\":\"2026-04-14T00:00:00\",\"endDate\":\"2026-04-14T23:59:59\"}")`
    private static func parseShellCommand(_ raw: String) -> (String, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let firstSpace = trimmed.firstIndex(of: " ") else {
            return (trimmed, nil)
        }

        let command = String(trimmed[..<firstSpace])
        let argsString = String(trimmed[trimmed.index(after: firstSpace)...])

        // Parse key=value or key="value" pairs into a JSON dictionary
        var dict: [String: String] = [:]
        let pattern = #/(\w+)=(?:"([^"]*)"|([\S]+))/#
        for match in argsString.matches(of: pattern) {
            let key = String(match.output.1)
            let value = String(match.output.2 ?? match.output.3 ?? "")
            dict[key] = value
        }

        if dict.isEmpty {
            // If no key=value pairs, pass the raw args as a "command" field
            if let data = try? JSONSerialization.data(withJSONObject: ["command": argsString]),
               let json = String(data: data, encoding: .utf8) {
                return (command, json)
            }
            return (command, nil)
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            return (command, json)
        }
        return (command, nil)
    }

    private struct SystemRunParams: Codable {
        var command: String
        var timeoutMs: Int?
        var cwd: String?
    }

    // MARK: - Helpers

    private static func stub(_ message: String) -> Handler {
        { req in InvocationHelpers.unavailable(req, message) }
    }
}
