import Foundation

/// Read-only access to the agent's workspace — the real bootstrap, identity,
/// memory, and generated files on the gateway's `/data/workspace` volume.
///
/// Unlike ``MemoryProviding`` (the backend `user_memory` "Dreaming" facts list),
/// these files live on the **gateway** and are read through the backend proxy at
/// `/api/v1/gateway/workspace/*`, which in turn calls the gateway wrapper's
/// setup API. They are updated nightly by the agent and survive image patching
/// because they sit on the persistent Fly volume.
///
/// Read-only in Phase 1: there is intentionally no write/delete surface here.
@MainActor
public protocol WorkspaceFilesProviding: AnyObject {
    /// List the workspace files. `available == false` means the gateway can't be
    /// read right now (e.g. no setup password / local gateway) — show an empty state.
    func files() async throws -> WorkspaceFilesResult
    /// Read a single workspace file's text content by its workspace-relative path.
    func file(path: String) async throws -> WorkspaceFileContent
}

// MARK: - Models

/// One file in the agent workspace (workspace-relative path + metadata).
public struct WorkspaceFile: Decodable, Identifiable, Hashable, Sendable {
    public let path: String
    public let size: Int
    public let mtime: String?

    /// Stable identity is the workspace-relative path (unique within a workspace).
    public var id: String { path }

    /// Just the filename (last path component) for display.
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, size: Int, mtime: String? = nil) {
        self.path = path
        self.size = size
        self.mtime = mtime
    }
}

// MARK: - Memory-page classification

/// Legacy full-inventory classification retained for service-level callers and
/// migration tests. The Iteration 1 Settings → Memory surface does not use these
/// categories; it uses ``WorkspaceFile/isVisibleMemoryDefault`` below.
///
/// The gateway's `workspace/list` returns **everything** it finds under
/// `/data/workspace` (the hosted gateway image, operated separately, only skips
/// `.DS_Store`, `.git`, `node_modules`). That includes machine-state files the
/// dreaming/memory runtime writes — `phase-signals.json`, `workspace-state.json`,
/// `memory/.dreams/*`, `.openclaw-wiki/cache/*`, wiki-vault JSON — which are raw
/// machine JSON, not readable memory. We classify **client-side** (per CLAUDE.md:
/// minimum backend change) so callers can distinguish human-readable markdown
/// from machine state without changing or deleting gateway data.
public enum WorkspaceMemoryCategory: Sendable, Equatable {
    /// AI-facing guidance the agent follows (how Rem behaves). e.g. `IDENTITY.md`.
    case remInstructions
    /// Durable facts about the user. e.g. `USER.md`, `MEMORY.md`, `memory/*.md`.
    case yourInfo
    /// Human-readable output of the nightly dreaming pass. e.g. `DREAMS.md`.
    case dreaming
    /// Machine-state / non-markdown files — never shown as readable memory.
    case hidden
}

public extension WorkspaceFile {
    /// Lowercased last path component, for extension/name checks.
    private var lowerName: String { name.lowercased() }

    /// Lowercased full workspace-relative path (forward-slash separators).
    private var lowerPath: String { path.lowercased() }

    /// True for the markdown files we render as prose. Everything else (`.json`,
    /// `.jsonl`, `.log`, binaries, extension-less machine files) is machine state.
    var isReadableMarkdown: Bool {
        lowerName.hasSuffix(".md") || lowerName.hasSuffix(".markdown")
    }

    /// True when any path segment is a hidden/machine directory (leading dot) or a
    /// known machine cache. These hold the dreaming runtime's internal state
    /// (`memory/.dreams/…`) and the wiki cache (`.openclaw-wiki/…`) — raw JSON, not
    /// memory the user should read.
    var isInMachineDirectory: Bool {
        path.split(separator: "/").dropLast().contains { segment in
            segment.hasPrefix(".")
        }
    }

    /// The deliberately small Settings → Memory surface for Iteration 1.
    ///
    /// These are OpenClaw's root bootstrap defaults that describe the agent's
    /// persona, tool guidance, and operating instructions. Everything else stays
    /// on disk but is not presented as user-facing memory until that product model
    /// is decided. Requiring a root-level path prevents a generated file with the
    /// same name inside `memory/` or another directory from leaking into the list.
    var isVisibleMemoryDefault: Bool {
        guard !path.contains("/"), isReadableMarkdown, !isInMachineDirectory else {
            return false
        }
        return ["agents.md", "soul.md", "tools.md"].contains(lowerName)
    }

    /// The Settings → Memory section this file belongs in (or `.hidden`).
    var memoryCategory: WorkspaceMemoryCategory {
        // 1. Hide machine state: anything not markdown, or inside a dot-directory.
        guard isReadableMarkdown, !isInMachineDirectory else { return .hidden }

        // 2. Dreaming diary — the human-readable dreaming output.
        if lowerName == "dreams.md" { return .dreaming }

        // 3. Rem's instructions — AI-facing guidance the agent follows. These are
        //    OpenClaw's standard every-session/bootstrap instruction files
        //    (`docs/rebuild/32-REMCLAW-MD-SCOPE.md`): IDENTITY.md (name/vibe),
        //    AGENTS.md/REMCLAW.md (rules & how-to-behave), SOUL.md (persona, tone,
        //    boundaries), TOOLS.md (tool conventions — guidance, not availability).
        //    All are guidance the agent follows, not facts about the user.
        let instructionFiles: Set<String> = [
            "identity.md", "agents.md", "remclaw.md", "soul.md", "tools.md",
        ]
        if instructionFiles.contains(lowerName) {
            return .remInstructions
        }

        // 4. Everything else readable = the user's own info (USER.md, MEMORY.md,
        //    memory/*.md daily logs, and any other markdown the agent writes).
        return .yourInfo
    }
}

/// Detects the seeded onboarding scaffold so we don't present an empty template
/// as if it were a real memory. `openclaw onboard` seeds IDENTITY/USER/MEMORY with
/// `writeFileIfMissing` (via the managed onboarding pipeline) — a bare
/// heading plus placeholder/instruction lines and **no real facts**. We treat a
/// file as "not written yet" when, after stripping markdown headings, HTML/`<!--`
/// comments, list-bullet scaffolding, and blank lines, nothing substantive remains.
///
/// Content-based (not a brittle match on exact upstream strings) so it keeps
/// working as the upstream template wording drifts.
public enum WorkspaceMemoryContent {
    /// True when `content` is only the seeded scaffold (headings/comments/blank/
    /// placeholder bullets) with no real user- or agent-authored substance.
    public static func isEmptyOrTemplate(_ content: String) -> Bool {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Markdown heading / thematic break — pure scaffold.
            if line.hasPrefix("#") || line == "---" || line == "***" { continue }
            // HTML comment scaffolding (`<!-- fill this in -->`).
            if line.hasPrefix("<!--") || line.hasPrefix("-->") { continue }
            // An empty bullet or a bullet whose only text is a placeholder hint.
            if let bulletBody = Self.bulletBody(line) {
                if bulletBody.isEmpty || Self.isPlaceholderHint(bulletBody) { continue }
                return false // a bullet with real content
            }
            // Standalone placeholder hint line (e.g. "(nothing yet)", "TODO").
            if Self.isPlaceholderHint(line) { continue }
            // Anything else is real substance.
            return false
        }
        return true
    }

    /// If `line` is a markdown bullet (`- `, `* `, `+ `), return its trimmed body;
    /// otherwise nil.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if line == "-" || line == "*" || line == "+" { return "" }
        return nil
    }

    /// Heuristic: the line's *entire* substantive body is seeded placeholder /
    /// instruction text, not a real fact.
    ///
    /// Matched **whole-body / anchored**, never as a substring — otherwise a genuine
    /// short memory that merely *contains* a hint word ("Fixed the placeholder image
    /// bug in checkout", "todos: buy milk, call mom", "nothing yet to report on the
    /// merger") would be wrongly hidden, which is the opposite of the honest-memory
    /// goal. A line counts as a placeholder only when the whole trimmed body equals a
    /// known hint, or is a fully parenthesized hint like "(nothing yet)".
    static func isPlaceholderHint(_ text: String) -> Bool {
        // Fully parenthesized body — the classic "(nothing yet)" scaffold. Strip the
        // wrapping parens and fall through to the equality check on the inside.
        var body = text.lowercased().trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("(") && body.hasSuffix(")") && body.count >= 2 {
            body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Trailing/leading punctuation shouldn't defeat the match ("TODO:", "TBD.").
        // Note: only strip when the WHOLE body is a hint (equality below), so a real
        // sentence containing a hint word is never touched.
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: ":.!… "))

        let placeholders: Set<String> = [
            "todo", "tbd", "placeholder",
            "nothing here yet", "nothing yet", "no facts yet",
            "to be filled", "to be filled in", "fill this in",
            "add facts", "will be added", "coming soon",
        ]
        return placeholders.contains(body)
    }
}

/// The text content of a single workspace file.
public struct WorkspaceFileContent: Decodable, Sendable {
    public let path: String
    public let content: String
    public let size: Int
    public let truncated: Bool

    public init(path: String, content: String, size: Int, truncated: Bool) {
        self.path = path
        self.content = content
        self.size = size
        self.truncated = truncated
    }
}

/// Result of listing workspace files. `available == false` → gateway not readable
/// right now (graceful empty state, not an error). `reason` (optional) says why:
/// `"gateway-update-required"` → the gateway runs a wrapper image that predates
/// the workspace endpoints and needs an image update (backend gateway.routes.ts).
public struct WorkspaceFilesResult: Decodable, Sendable {
    public let available: Bool
    public let files: [WorkspaceFile]
    public let reason: String?

    public init(available: Bool, files: [WorkspaceFile], reason: String? = nil) {
        self.available = available
        self.files = files
        self.reason = reason
    }
}

// MARK: - Concrete (backend proxy)

/// Talks to the RemClaw backend's gateway workspace proxy endpoints, reusing the
/// app's existing authenticated HTTP client (base URL + JWT + 401-refresh), with
/// the same `#if os(iOS)` split as ``MemoryService``.
@MainActor
public final class WorkspaceMemoryService: WorkspaceFilesProviding {

    private let decoder = JSONDecoder()

    public init() {}

    public func files() async throws -> WorkspaceFilesResult {
        let (data, http) = try await Self.request(path: "/api/v1/gateway/workspace/files", method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(WorkspaceFilesResult.self, from: data)
    }

    public func file(path: String) async throws -> WorkspaceFileContent {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? path
        let (data, http) = try await Self.request(
            path: "/api/v1/gateway/workspace/file?path=\(encoded)",
            method: "GET"
        )
        try Self.check(http, data: data)
        return try decoder.decode(WorkspaceFileContent.self, from: data)
    }

    // MARK: Transport (platform-split, mirrors MemoryService)

    private static func request(
        path: String,
        method: String
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS)
        return try await AuthenticatedHttpClient.request(path: path, method: method)
        #else
        return try await MacAuthenticatedHttpClient.request(path: path, method: method)
        #endif
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw WorkspaceMemoryError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }
}

public enum WorkspaceMemoryError: LocalizedError {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

private extension CharacterSet {
    /// URL query value allowed set (reserved chars like `/` and `+` percent-encoded).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "/+&=?")
        return set
    }()
}

// MARK: - Mock (previews)

/// In-memory `WorkspaceFilesProviding` seeded with sample identity/memory files.
@MainActor
public final class MockWorkspaceMemoryService: WorkspaceFilesProviding {
    public var available: Bool
    public var store: [String: String]
    public var simulatedDelay: Duration

    public init(available: Bool = true, store: [String: String]? = nil, simulatedDelay: Duration = .milliseconds(250)) {
        self.available = available
        self.store = store ?? MockWorkspaceMemoryService.sample()
        self.simulatedDelay = simulatedDelay
    }

    public func files() async throws -> WorkspaceFilesResult {
        try? await Task.sleep(for: simulatedDelay)
        guard available else { return WorkspaceFilesResult(available: false, files: []) }
        let files = store.keys.sorted().map { path in
            WorkspaceFile(path: path, size: store[path]?.utf8.count ?? 0, mtime: nil)
        }
        return WorkspaceFilesResult(available: true, files: files)
    }

    public func file(path: String) async throws -> WorkspaceFileContent {
        try? await Task.sleep(for: simulatedDelay)
        let content = store[path] ?? ""
        return WorkspaceFileContent(path: path, content: content, size: content.utf8.count, truncated: false)
    }

    public static func sample() -> [String: String] {
        [
            // The three visible defaults.
            "SOUL.md": "# Soul\n\nBe calm, concise, and useful.\n",
            "TOOLS.md": "# Tools\n\nPrefer structured device tools over guesses.\n",
            "AGENTS.md": "# Agents\n\nOwn the full lifecycle and report blockers plainly.\n",
            // Other readable workspace files remain available to prove the surface filters them.
            "IDENTITY.md": "# IDENTITY.md - Agent Identity\n\nName: Rem\nTheme: calm, concise\n",
            "USER.md": "# USER.md - User Profile\n\n- Prefers morning workouts before 8am\n- Has two cats, Mochi and Soba\n",
            "MEMORY.md": "# MEMORY.md\n\n<!-- Long-term notes the agent keeps. -->\n- (nothing yet)\n",
            "memory/2026-07-01.md": "# 2026-07-01\n\n- Shipped the Memory settings screen.\n",
            "DREAMS.md": "# Dreams\n\n## 2026-07-05\nNoticed the user asks about workouts most mornings — likely a routine worth surfacing.\n",
            // Machine state — must be HIDDEN from the page.
            "phase-signals.json": "{\"phase\":\"deep\",\"lastRun\":\"2026-07-05\"}",
            "workspace-state.json": "{\"version\":3}",
            "memory/.dreams/state.json": "{\"candidates\":[]}",
        ]
    }
}
