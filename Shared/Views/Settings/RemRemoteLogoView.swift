import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
private typealias RemPlatformImage = UIImage
#elseif canImport(AppKit)
private typealias RemPlatformImage = NSImage
#endif

/// Remote brand-logo view that renders **raster (PNG/JPEG) *and* SVG** sources, falling back to a
/// caller-supplied placeholder for a nil URL, a network error, or undecodable bytes — never an
/// empty slot.
///
/// ## Why this exists (#1069 icon root cause)
/// SwiftUI's `AsyncImage` is backed by `UIImage` / `NSImage`, neither of which can decode SVG.
/// Composio's toolkit logos — served from `logos.composio.dev` and most `meta.logo` URLs — come
/// back as `image/svg+xml` (verified: `curl -I https://logos.composio.dev/api/gmail` →
/// `content-type: image/svg+xml`). So the previous `AsyncImage` path failed its image phase on
/// *every* Connectors row and fell through to the SF Symbol, which read as "no real logos ever
/// render". Composio's CDN ignores `?format=png` / `.png`, so there is no raster variant to request
/// instead — the client has to render the SVG.
///
/// This view fetches the bytes once (cached in-process by URL), decodes raster through the platform
/// image loader, and renders SVG through a transparent `WKWebView` (a system framework — no
/// third-party SVG dependency). Works on both iOS and macOS.
struct RemRemoteLogoView<Fallback: View>: View {
    let url: URL?
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 6
    @ViewBuilder var fallback: () -> Fallback

    @State private var payload: RemLogoPayload?
    @State private var didFail = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let payload {
            switch payload {
            case .raster(let image):
                #if canImport(UIKit)
                Image(uiImage: image).resizable().scaledToFit()
                #elseif canImport(AppKit)
                Image(nsImage: image).resizable().scaledToFit()
                #endif
            case .svg(let markup):
                #if canImport(WebKit)
                RemSVGImageView(markup: markup)
                #else
                fallback()
                #endif
            }
        } else if didFail {
            // Genuine failure (nil URL, network error, undecodable bytes): the caller's SF-Symbol
            // fallback — the row is never left with an empty icon slot, and never shimmers forever.
            fallback()
        } else {
            // Still loading (payload not yet resolved, no failure yet): a shimmering placeholder
            // fills the icon slot so slow remote SVGs read as "loading" rather than flashing the
            // SF-Symbol fallback and then swapping to the real logo.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DesignTokens.Color.fillTertiary)
                .shimmering()
                .accessibilityHidden(true)
        }
    }

    private func load() async {
        payload = nil
        didFail = false
        guard let url else { didFail = true; return }

        if let cached = RemLogoCache.shared.value(for: url) {
            payload = cached
            return
        }

        guard let fetched = await RemLogoCache.shared.fetch(url) else {
            didFail = true
            return
        }
        payload = fetched
    }
}

/// Decoded logo bytes — either a platform-decodable raster image or raw SVG markup for the
/// WebKit-backed renderer.
private enum RemLogoPayload {
    case raster(RemPlatformImage)
    case svg(String)
}

/// Process-wide, main-actor logo cache. Toolkit logos are static per URL, so a scroll or a re-render
/// must never refetch. Keyed by the absolute URL string.
@MainActor
private final class RemLogoCache {
    static let shared = RemLogoCache()
    private var store: [String: RemLogoPayload] = [:]
    /// De-dupes concurrent fetches for the same URL (all 11 rows can request at once on first load).
    private var inFlight: [String: Task<RemLogoPayload?, Never>] = [:]

    func value(for url: URL) -> RemLogoPayload? { store[url.absoluteString] }

    func fetch(_ url: URL) async -> RemLogoPayload? {
        let key = url.absoluteString
        if let cached = store[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<RemLogoPayload?, Never> { [weak self] in
            let payload = await Self.download(url)
            if let payload, let self { self.store[key] = payload }
            self?.inFlight[key] = nil
            return payload
        }
        inFlight[key] = task
        return await task.value
    }

    /// Fetches and classifies the bytes off the main actor. Raster wins when the platform image
    /// loader can decode it; otherwise SVG is detected by sniffing for an `<svg` root (covers the
    /// `image/svg+xml` and mislabeled-`text/html` cases Composio's CDN returns).
    nonisolated private static func download(_ url: URL) async -> RemLogoPayload? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !data.isEmpty else { return nil }

            if let image = RemPlatformImage(data: data) {
                return .raster(image)
            }
            // Sniff the leading bytes for an SVG root before committing to the WebKit renderer.
            let prefix = data.prefix(1024)
            if let text = String(data: prefix, encoding: .utf8), text.lowercased().contains("<svg"),
               let full = String(data: data, encoding: .utf8) {
                return .svg(full)
            }
            return nil
        } catch {
            return nil
        }
    }
}

#if canImport(WebKit)
/// Renders raw SVG markup inside a transparent, non-interactive `WKWebView`. The SVG is inlined via
/// `loadHTMLString` (no extra network hop, no CORS surprises) and scaled to fill the row's icon
/// frame. Transparent so it reads correctly in both light and dark mode.
///
/// Hardened defense-in-depth even though the bytes come from Composio's CDN (low risk): JavaScript
/// is disabled, a restrictive CSP `<meta>` blocks any external resource load, and a nav delegate
/// cancels every navigation except the initial in-memory document — so a malicious SVG can't script,
/// beacon out, or navigate away. Reloads only when the markup actually changes (avoids churn/flicker).
private struct RemSVGImageView {
    let markup: String

    private var html: String {
        """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          html,body{margin:0;padding:0;height:100%;width:100%;background:transparent;overflow:hidden;}
          body{display:flex;align-items:center;justify-content:center;}
          svg,img{max-width:100%;max-height:100%;width:auto;height:auto;display:block;}
        </style></head><body>\(markup)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Nav delegate + last-loaded-markup guard. Allows only the in-memory document load
    /// (`about:blank` / no network scheme); cancels link taps and any http(s)/file navigation.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedMarkup: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == nil || scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    private func makeConfiguredWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(html, baseURL: nil)
        coordinator.loadedMarkup = markup
        return webView
    }
}

#if canImport(UIKit)
extension RemSVGImageView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let webView = makeConfiguredWebView(context.coordinator)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedMarkup != markup else { return }
        context.coordinator.loadedMarkup = markup
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#elseif canImport(AppKit)
extension RemSVGImageView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = makeConfiguredWebView(context.coordinator)
        // No public transparent-background API on macOS WKWebView; KVC `drawsBackground` is the
        // long-standing, App-Store-safe way to make it clear.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedMarkup != markup else { return }
        context.coordinator.loadedMarkup = markup
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif
#endif

#if DEBUG
#Preview("Remote logo — raster + fallback") {
    HStack(spacing: 16) {
        RemRemoteLogoView(url: URL(string: "https://logos.composio.dev/api/gmail")) {
            SettingsIcon(icon: "envelope.fill", color: .blue)
        }
        RemRemoteLogoView(url: nil) {
            SettingsIcon(icon: "link", color: .blue)
        }
    }
    .padding()
}
#endif
