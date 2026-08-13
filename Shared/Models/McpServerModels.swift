import Foundation

// MARK: - MCP Server Models
//
// Upstream config contract (source of truth):
//   openclaw/src/config/types.mcp.ts           — McpServerConfig / McpConfig
//   openclaw/src/config/mcp-config.ts          — CLI list/set/unset helpers
//   openclaw/docs/cli/mcp.md                   — user-facing doc
//
// MCP servers live in the gateway config under `mcp.servers.<name>`. There is NO
// dedicated RPC (`mcp.list`, `mcp.add`, etc) on the gateway — CLI and control
// surfaces both go through `config.get` / `config.patch`. We mirror that.
//
// Auth state: upstream exposes NO per-server auth-state signal. Auth is done
// out-of-band (bearer header in `headers.Authorization`, or the MCP server's
// own OAuth at its URL). We therefore do not synthesize an auth-state flag —
// we show a structured lifecycle state (`configured`, `ready`, `error`) driven
// by the last operation outcome, plus a manual "Authorize" affordance that
// opens the server URL in the user's browser.

/// Transport kinds Rem supports for remote MCP servers on cloud gateways.
///
/// We intentionally do NOT expose stdio here: Fly-deployed gateways can't
/// spawn local child processes reliably, and stdio is a Mac-local concern
/// (future PR). This matches "out of scope: stdio/local MCP servers".
enum McpServerTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case sse
    case streamableHTTP = "streamable-http"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .sse: "SSE"
        case .streamableHTTP: "Streamable HTTP"
        }
    }

    var helpText: String {
        switch self {
        case .sse: "HTTP Server-Sent Events. Default for remote MCP servers."
        case .streamableHTTP: "HTTP streaming transport. Use if the server requires it."
        }
    }
}

/// One MCP server entry as seen by the UI.
///
/// This is the client-side view model: the `name` is the object key under
/// `mcp.servers` (used for both display and identity); `transport`, `url`,
/// and `headers` are the normalized fields from the config record.
///
/// Upstream field mapping (openclaw/src/config/types.mcp.ts):
///   url          -> `url`
///   transport    -> `transport?: "sse" | "streamable-http"` (absent => "sse")
///   headers      -> `headers?: Record<string, string>`
///   command/args -> stdio-only; we ignore these for now (not displayed).
struct McpServerEntry: Identifiable, Sendable, Equatable {
    let name: String
    let url: String?
    let transport: McpServerTransport
    /// Whether `headers.Authorization` is present. We only know redacted boolean,
    /// never the secret value. Used to show an "Authorized (bearer token set)"
    /// badge; NOT used to drive machine decisions.
    let hasAuthHeader: Bool
    /// The raw config record for this server, used to preserve unknown keys
    /// on round-trip. `config.patch` performs a merge patch, so we don't
    /// strictly need this for write — but keeping it lets the detail sheet
    /// show fields we don't model.
    ///
    /// Currently loaded but not written back: reserved for a future edit
    /// sheet that would mutate non-modeled fields (e.g. custom headers,
    /// upstream-only keys). Not dead code — see #341 follow-up notes.
    let rawRecord: [String: JSONValue]

    /// Whether this is a stdio entry (local command). We display these as
    /// "Local" and disable remove/edit from the cloud-gateway UI path.
    var isStdio: Bool {
        rawRecord["command"]?.stringValue != nil
    }

    var id: String { name }
}

/// Structured lifecycle state for an MCP server in the UI.
///
/// Intentionally an enum, not a string — per the "structured signals" rule.
/// We never branch on error text.
///
/// - `configured`: entry exists in `mcp.servers`, no recent operation.
/// - `connecting`: a local add/remove operation is in flight.
/// - `ready`: the most recent write succeeded. We cannot actually probe the
///   server today (no upstream probe RPC), so this is "config write ok",
///   not "round-trip to MCP server verified".
/// - `needsAuth`: reserved for future use if upstream exposes an auth-state
///   signal. Not currently produced by any code path.
/// - `error(message)`: the most recent operation failed; message is the
///   server error verbatim.
enum McpServerLifecycleState: Equatable {
    case configured
    case connecting
    case ready
    case needsAuth
    case error(message: String)
}

// MARK: - Config RPC payloads

/// Shared response shape for `config.get`. Each consumer decodes only its required loose subtree;
/// unrelated config remains ignored. Includes `baseHash` so later `config.patch` calls can pin
/// concurrency (see upstream
/// openclaw/src/gateway/server-methods/config.ts requireConfigBaseHash).
struct ConfigGetResponse: Decodable, Sendable {
    let config: ConfigRoot?
    /// Historical field name; the gateway actually returns the snapshot hash under `hash` (see
    /// upstream `resolveConfigSnapshotHash` → `snapshot.hash`). Prefer `hash`; keep `baseHash` for compat.
    let baseHash: String?
    let hash: String?

    /// The base hash to pin a `config.patch` on — the gateway's own `hash`, falling back to the
    /// legacy `baseHash` key if a build ever emits that instead. Without this the hash was always
    /// nil and every `config.patch` was rejected with "config base hash required".
    var patchBaseHash: String? { hash ?? baseHash }

    struct ConfigRoot: Decodable, Sendable {
        let mcp: McpBlock?
        let browser: BrowserBlock?
        let agents: AgentsBlock?
        let models: ModelsBlock?
    }

    /// Provider declarations from `config.models.providers`. Model Settings reads only the exact
    /// provider/model identity from this loose subtree when an older gateway cannot attest that its
    /// model catalog is complete. Additional provider-owned fields must not break unrelated config
    /// decoding, and display names never authorize a managed model.
    struct ModelsBlock: Decodable, Sendable {
        let providers: [String: JSONValue]?
    }

    struct AgentsBlock: Decodable, Sendable {
        let defaults: AgentDefaults?
    }

    struct AgentDefaults: Decodable, Sendable {
        let userTimezone: String?
        /// OpenClaw accepts either a bare string or an object containing `primary`. Keep the loose
        /// JSON shape so old and current gateways decode without inventing a client-only model.
        let model: JSONValue?
        /// Gateway-backed model visibility/allowlist. Missing or empty means "allow any configured
        /// model" upstream; a non-empty map is the explicit curated set.
        let models: [String: JSONValue]?

        var primaryModelRef: String? {
            if case .string(let value)? = model {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if case .object(let value)? = model,
               case .string(let primary)? = value["primary"] {
                return primary.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }

    struct McpBlock: Decodable, Sendable {
        let servers: [String: JSONValue]?
    }

    /// The cloud browser's SSRF policy. `hostnameAllowlist` is what the "limit to specific sites"
    /// setting drives: empty = every public host reachable (open, the default); non-empty = only
    /// those hosts. Read only to reflect current state; the private/metadata-IP guard is untouched.
    /// See openclaw/src/config/types.browser.ts (BrowserSsrfPolicyConfig).
    struct BrowserBlock: Decodable, Sendable {
        let ssrfPolicy: SsrfPolicy?
    }

    struct SsrfPolicy: Decodable, Sendable {
        let hostnameAllowlist: [String]?
    }
}

/// Request params for `config.patch`. Upstream expects:
///   - `raw`: JSON5 string containing the merge-patch object
///   - `baseHash`: optional; if present must match current config hash
///
/// See openclaw/src/gateway/server-methods/config.ts (config.patch handler).
struct ConfigPatchParams: Encodable, Sendable {
    let raw: String
    let baseHash: String?
}

// MARK: - JSONValue (loose JSON for heterogenous config subtrees)

/// Minimal JSON value enum used to round-trip arbitrary MCP server config
/// records. We only need the structural shape to decide display + write-back;
/// individual fields (`url`, `transport`, `headers.*`) are extracted via
/// accessors rather than modeled as a closed struct, because upstream allows
/// additional keys on `McpServerConfig` (see `[key: string]: unknown` in
/// openclaw/src/config/types.mcp.ts).
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON value"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
