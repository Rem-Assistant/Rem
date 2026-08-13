import Foundation
import OpenClawKit

/// Handles the `canvas.*` node commands (doc 34 stage 2, doc 37).
///
/// ## Why this is not a port of upstream's canvas
///
/// Upstream's canvas makes the PHONE fetch the URL on its own network stack
/// (`openclaw/apps/ios/Sources/Screen/ScreenController.swift:52-73`) into a `.nonPersistent()`
/// cookie jar (`ScreenWebView.swift:95`). Pointing that at a vendor portal would have the user
/// authenticate ON THE PHONE, in an empty session, while the agent's Chromium — whose `/data`
/// profile is the entire point of session persistence — stayed logged out. It would look like
/// it worked and connect nothing.
///
/// Upstream also has no gateway→client pixel path at all (`grep -rin screencast` over openclaw
/// → zero hits), so there is no upstream implementation to mirror here.
///
/// What we mirror instead is upstream's canvas HOST model: the gateway serves a page over the
/// network for the node to fetch (`skills/canvas/SKILL.md`: *"localhost URLs don't work — the
/// node receives the Tailscale hostname"*). Ours is the Fly public hostname, and the page it
/// serves is a live view of the agent's own browser (doc 37).
///
/// So: same command vocabulary, Rem-native presentation (a sheet over chat, not the root view
/// — upstream's `present` ignores placement and `hide` means "go home" only because there the
/// webview IS the app).
///
/// `canvas.a2ui.*` stays stubbed deliberately: A2UI is a web bundle the gateway serves and
/// drives via injected JS, and its host-URL protocol does not exist at our deployed ref
/// (v2026.4.11 speaks `canvasHostUrl`; upstream HEAD replaced it and calls the old path
/// *"intentionally unsupported"* — `openclaw/docs/refactor/canvas.md:56`). Our viewer needs
/// none of it.
enum CanvasCommandHandler {

    @MainActor private static var coordinator: (() -> BrowserViewCoordinator?)?

    @MainActor
    static func configure(coordinator: @escaping @MainActor () -> BrowserViewCoordinator?) {
        Self.coordinator = coordinator
    }

    // MARK: - Commands

    /// Show the live browser. Any `url` the agent passes is deliberately ignored — see
    /// `BrowserViewCoordinator` for why the app resolves its own URL rather than trusting one
    /// from a model that is, at that moment, reading an untrusted web page.
    @MainActor
    static func handlePresent(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let coordinator = coordinator?() else {
            return InvocationHelpers.unavailable(req, "The browser view isn't available on this device.")
        }
        coordinator.present()
        // Returns as soon as the view is up, without waiting for pixels: the gateway may be cold
        // (~128s), and blocking the agent's tool call on a cold start would time it out while the
        // user is already watching the browser wake. The view owns that wait, and shows it.
        return InvocationHelpers.encodeSuccess(req, ["ok": true])
    }

    @MainActor
    static func handleHide(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        coordinator?()?.dismiss()
        return InvocationHelpers.encodeSuccess(req, ["ok": true])
    }

    /// The agent cannot steer this surface anywhere: it shows Rem's browser and nothing else.
    /// To change the page, the agent navigates its OWN browser — which is what the user is
    /// watching — via the `browser` tool.
    @MainActor
    static func handleNavigate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        InvocationHelpers.invalidParams(
            req,
            "canvas.navigate can't point this screen anywhere. It only ever shows Rem's own "
                + "browser. Use `browser navigate` to change the page — the user is watching "
                + "that browser live."
        )
    }

    @MainActor
    static func handleEval(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        InvocationHelpers.unavailable(
            req,
            "canvas.eval isn't available. To run JavaScript in the page you're browsing, use "
                + "the `browser` tool. Do not retry."
        )
    }

    /// `browser screenshot` already captures the same pixels, straight from the source, and
    /// renders inline in chat (#1009). Pointing the agent there avoids a second, worse path.
    @MainActor
    static func handleSnapshot(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        InvocationHelpers.unavailable(
            req,
            "canvas.snapshot isn't available. Use `browser screenshot` to capture the page — "
                + "it renders in chat. Do not retry."
        )
    }
}
