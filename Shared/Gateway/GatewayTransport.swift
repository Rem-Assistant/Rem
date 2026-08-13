import Foundation

// MARK: - Gateway Transport (#317 Remote Mac gateway access epic)

/// How the client reaches a gateway — the **transport / remote-access** axis,
/// orthogonal to `GatewayProvider` (which tracks **deployment** location:
/// Fly cloud vs local Mac vs manual URL).
///
/// Two axes, one `GatewayConfig`:
/// - `GatewayProvider` — *where does this gateway live?* (Fly / local Mac / manual)
/// - `GatewayTransport` — *how does this device reach it?* (LAN Bonjour / Tailscale /
///   SSH tunnel / manual URL)
///
/// A single gateway can mix them — e.g. `{provider: .local, transport: .tailscale}`
/// is a user's Mac gateway reached over their tailnet.
///
/// **Upstream pattern.** Mirrors the remote-access methods documented in
/// `openclaw/docs/gateway/remote.md:69-84` (SSH tunnel) and
/// `openclaw/docs/gateway/tailscale.md:1-130` (Tailscale Serve). Bonjour is
/// the default LAN path (`_openclaw-gw._tcp`) that already works today.
/// Manual is the paste-a-URL escape hatch we've always had.
///
/// **Introduced by PR 1 of #317 (Remote Mac gateway access epic).** Pure
/// data model. No behavior depends on this field yet — PR 2 wires the Mac
/// Tailscale toggle to write `.tailscale`; PR 3 adds the iOS remote-gateway
/// setup flow that writes `.tailscale` or `.ssh` based on how the user
/// obtained the URL; PR 4 branches the connection router on this field.
///
/// **Backward compat.** `GatewayConfig.transport` is `Optional`. Existing
/// persisted configs decode with `transport == nil`, which means "infer from
/// URL host and provider at connect time" — see
/// `GatewayTransport.inferred(fromURL:provider:)`.
/// New configs written after PR 2/3 always set the field explicitly; the
/// inference path exists only so pre-#317 stored configs continue to work.
enum GatewayTransport: String, Codable, Sendable, CaseIterable {
    /// LAN discovery via mDNS / Bonjour (`_openclaw-gw._tcp`). Hostnames
    /// resolve as `<name>.local`. The existing LAN path — no behavior change.
    case bonjour = "bonjour"

    /// Tailscale Serve fronts the gateway's loopback bind. Client connects
    /// directly to the Mac's `<machine>.ts.net` URL from any tailnet device.
    /// Requires the same tailnet on both ends (per locked decision 2 —
    /// reject cross-tailnet access; matches upstream's security model).
    /// See `openclaw/docs/gateway/tailscale.md:1-130`.
    case tailscale = "tailscale"

    /// The user's Mac runs an `ssh -L` tunnel to a jump host; the iPhone
    /// connects to the **resulting public URL** (not raw SSH — iPhone never
    /// opens an SSH connection per locked decision 1). The Mac app just
    /// shows the user a copyable `ssh -L` command; the app doesn't manage
    /// the tunnel lifecycle. See `openclaw/docs/gateway/remote.md:69-84`.
    case ssh = "ssh"

    /// A URL the user pasted or scanned that doesn't fit the other cases.
    /// No provider-specific routing at connect time; the URL is trusted
    /// as-is.
    case manual = "manual"

    /// Human-readable label for settings surfaces.
    var displayName: String {
        switch self {
        case .bonjour: "Local Network"
        case .tailscale: "Tailscale"
        case .ssh: "SSH Tunnel"
        case .manual: "Manual"
        }
    }

    /// SF Symbol for settings surfaces.
    var icon: String {
        switch self {
        case .bonjour: "wifi"
        case .tailscale: "network"
        case .ssh: "lock.shield"
        case .manual: "link"
        }
    }

    /// Infer a transport from a gateway URL when the stored config predates
    /// #317 and has `transport == nil`. Used only as a private helper for the
    /// provider-aware read-time fallback; new configs always set `transport`
    /// explicitly.
    ///
    /// Rules (checked in order):
    /// - Host ends in `.ts.net` → `.tailscale` (Tailscale MagicDNS)
    /// - Host is `127.0.0.1` / `localhost` → `.ssh` (loopback implies the
    ///   Mac owns an SSH tunnel; if it's actually a local gateway on this
    ///   same device, the caller knows because `provider == .local` —
    ///   see `inferred(fromURL:provider:)` for the combined rule)
    /// - Host ends in `.local` → `.bonjour` (mDNS)
    /// - Anything else → `.manual` (pasted/cloud URL)
    ///
    /// This is best-effort inference for back-compat; URL-only callers cannot
    /// distinguish local loopback from an SSH tunnel, so keep this private and
    /// route real call sites through `inferred(fromURL:provider:)`.
    private static func inferred(fromURL urlString: String) -> GatewayTransport {
        guard let host = URL(string: urlString)?.host?.lowercased(),
              !host.isEmpty else {
            return .manual
        }
        if host.hasSuffix(".ts.net") { return .tailscale }
        if host == "127.0.0.1" || host == "localhost" { return .ssh }
        if host.hasSuffix(".local") { return .bonjour }
        return .manual
    }

    /// Deployment-aware variant of `inferred(fromURL:)`. When the caller
    /// knows the gateway's provider, a loopback URL on a `.local` deployment
    /// resolves to `.bonjour` (the gateway is *on this machine*, not behind
    /// an SSH tunnel). All other cases defer to the URL-only path.
    static func inferred(fromURL urlString: String, provider: GatewayProvider) -> GatewayTransport {
        guard let host = URL(string: urlString)?.host?.lowercased(),
              !host.isEmpty else {
            return .manual
        }
        // A local-deployment gateway reached via loopback is the "Mac
        // hosting Rem also hosts its gateway" case — that's Bonjour-
        // equivalent (same machine, no remote transport), not SSH.
        if provider == .local, host == "127.0.0.1" || host == "localhost" {
            return .bonjour
        }
        return inferred(fromURL: urlString)
    }
}
