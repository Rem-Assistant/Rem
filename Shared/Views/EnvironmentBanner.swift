import SwiftUI

/// Which backend a build is pointed at. We unify on a single shared database, so
/// the banner exists to make a *non-production* target unmistakable — "my data is
/// gone" should read as "you're on a test backend," never as data loss. Release
/// builds always resolve to `.production` and show nothing.
///
/// Detection is by backend host so it works on iOS and macOS from the same code;
/// the platform root passes its own `AppConfig.apiBaseURL`.
enum AppBackendEnvironment: Equatable {
    case production
    case staging
    case preview(String)   // ephemeral Railway PR-preview env
    case local
    case unknown

    /// Host substrings that identify the production and staging backends. These are
    /// intentionally placeholders in the open-core repo — set them to the real backend
    /// host slugs in your private build configuration (they are matched against the
    /// `APIBaseURL` baked into the build). The `#if DEBUG` preview samples below match
    /// these same tokens so every banner variant stays visible in Canvas.
    static let productionHostToken = "your-production-host"
    static let stagingHostToken = "your-staging-host"

    static func detect(from urlString: String) -> AppBackendEnvironment {
        let u = urlString.lowercased()
        if u.isEmpty { return .unknown }
        if u.contains(productionHostToken) { return .production }
        if u.contains(stagingHostToken) { return .staging }
        if u.contains("localhost") || u.contains("127.0.0.1")
            || u.range(of: #"://(10|192\.168|172\.(1[6-9]|2\d|3[01]))\."#, options: .regularExpression) != nil {
            return .local
        }
        // Railway PR-preview backends look like backend-pr-<n>... — surface the slug.
        if let r = u.range(of: #"backend[-.]?pr[-.]?\d+"#, options: .regularExpression) {
            return .preview(String(u[r]))
        }
        return .unknown
    }

    /// Production is the only target we treat as "real" — no banner.
    var isProduction: Bool { self == .production }

    /// True when this build is a developer / non-production build — the same
    /// "Developer mode" signal the environment banner surfaces. Used to gate
    /// raw diagnostic detail (wss URLs, transport/protocol errors) that helps
    /// during development but should never reach a normal user.
    ///
    /// Resolves from the backend host baked into the build (`APIBaseURL` in the
    /// Info.plist) so it works identically on iOS and macOS without threading a
    /// runtime URL through shared views. DEBUG builds always qualify. A staging
    /// TestFlight build is release-configuration but non-production, so it also
    /// qualifies and testers keep seeing the raw text.
    ///
    /// Fails CLOSED: in a release build we only return `true` for a *recognized*
    /// non-production environment (staging / local / preview). An empty or
    /// unrecognized host resolves to `.unknown` and is treated as production, so
    /// raw diagnostics (wss URLs, transport errors) never leak to real users if
    /// the baked host string drifts or a new prod host isn't yet in `detect`.
    static var isDeveloperBuild: Bool {
        #if DEBUG
        return true
        #else
        let baked = Bundle.main.infoDictionary?["APIBaseURL"] as? String ?? ""
        switch detect(from: baked) {
        case .staging, .local, .preview:
            return true
        case .production, .unknown:
            return false
        }
        #endif
    }

    var label: String {
        switch self {
        // Dev/staging builds now point at real (prod) data, so "STAGING · test
        // data" is misleading — the banner just flags a developer build.
        case .production: return "PRODUCTION"
        case .staging: return "Developer mode"
        case .preview(let slug): return "PREVIEW · \(slug.uppercased())"
        case .local: return "LOCAL"
        case .unknown: return "NON-PROD"
        }
    }

    /// Accent color for the banner text + glyph against the shared black strip.
    /// Each non-prod target keeps its own identifying hue so they stay
    /// distinguishable at a glance; production is `.clear` (no banner shows).
    var tint: Color {
        switch self {
        case .production: return .clear
        case .staging: return .orange
        case .preview: return .purple
        case .local: return .blue
        case .unknown: return .gray
        }
    }
}

private struct EnvironmentBannerModifier: ViewModifier {
    let backendURL: String

    func body(content: Content) -> some View {
        let env = AppBackendEnvironment.detect(from: backendURL)
        // Production shows nothing — return the content untouched so we don't
        // change layout for the shipping target.
        if env.isProduction {
            content
        } else {
            // A *dedicated* top strip rather than a floating overlay. Stacking
            // the strip above `content` in a VStack means the banner occupies
            // real layout height at the very top and pushes the rest of the app
            // (its navigation bar, back chevron, "..." menu, titles) down
            // beneath it — so nothing overlaps the nav controls. Mirrors the
            // in-app `GatewayDisconnectedBanner`, which sits above the
            // `NavigationStack` in the same way (RemMainTabView).
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(env.label)
                }
                .font(.system(size: 11, weight: .bold))
                // Accent-colored label + glyph on a rounded black pill. The accent
                // (env.tint) carries the environment identity.
                .foregroundStyle(env.tint)
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                // Inset + rounded so it reads as a contained callout that matches the
                // composer's shape, rather than a full-bleed top strip. It still occupies
                // its own layout height at the top (VStack above `content`), so it never
                // overlaps the nav bar.
                .background(Color.black, in: .capsule)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connected to \(env.label) backend")

                content
            }
        }
    }
}

extension View {
    /// Adds a dedicated top strip (its own layout height, not an overlay) when
    /// the build points at a non-production backend, insetting the app's content
    /// beneath it so the banner never overlaps the navigation bar. Pass the
    /// platform's resolved backend URL (e.g. `AppConfig.apiBaseURL`).
    func environmentBanner(backendURL: String) -> some View {
        modifier(EnvironmentBannerModifier(backendURL: backendURL))
    }
}

#if DEBUG
/// Sample backend URLs — one per branch of `AppBackendEnvironment.detect` — so
/// every banner variant is visible in Canvas. Keeping these in lockstep with the
/// host substrings in `detect(from:)` is what makes the previews real: each URL
/// must actually resolve to its labelled variant.
private enum BannerPreviewSamples {
    static let cases: [(env: AppBackendEnvironment, url: String)] = [
        (.production, "https://YOUR-PRODUCTION-HOST.example"),
        (.staging, "https://YOUR-STAGING-HOST.example"),
        (.preview("backend-pr-123"), "https://backend-pr-123.example"),
        (.local, "http://localhost:8080"),
        (.unknown, "https://some-other-host.example.com"),
    ]
}

/// One labelled cell: the env's name + sample URL, with the real banner applied
/// on top of a stand-in content block so its actual styling (strip, tint, glyph)
/// renders exactly as it does in-app. Production resolves to no strip — the cell
/// makes that "renders nothing" outcome explicit rather than looking broken.
private struct BannerPreviewCell: View {
    let env: AppBackendEnvironment
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(env.isProduction ? "production · renders nothing" : env.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            // Stand-in for app content, with the banner modifier applied so the
            // top strip (or, for production, its absence) is shown as shipped.
            Color(white: 0.95)
                .frame(height: 44)
                .overlay(Text(url).font(.caption2).foregroundStyle(.secondary))
                .environmentBanner(backendURL: url)
        }
    }
}

/// Combined preview: all five variants stacked so every banner branch is visible
/// in Canvas at once (production included, to show it produces no strip).
#Preview("Environment Banner — all variants") {
    VStack(spacing: 16) {
        ForEach(Array(BannerPreviewSamples.cases.enumerated()), id: \.offset) { _, sample in
            BannerPreviewCell(env: sample.env, url: sample.url)
        }
    }
    .padding(.vertical)
}

// One preview per variant so each can be inspected in isolation in Canvas.
#Preview("Banner — production (no strip)") {
    BannerPreviewCell(env: .production, url: BannerPreviewSamples.cases[0].url)
}

#Preview("Banner — staging") {
    BannerPreviewCell(env: .staging, url: BannerPreviewSamples.cases[1].url)
}

#Preview("Banner — preview") {
    BannerPreviewCell(env: .preview("backend-pr-123"), url: BannerPreviewSamples.cases[2].url)
}

#Preview("Banner — local") {
    BannerPreviewCell(env: .local, url: BannerPreviewSamples.cases[3].url)
}

#Preview("Banner — unknown") {
    BannerPreviewCell(env: .unknown, url: BannerPreviewSamples.cases[4].url)
}
#endif
