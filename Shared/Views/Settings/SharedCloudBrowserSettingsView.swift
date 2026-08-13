import SwiftUI

// MARK: - Shared Cloud Browser Settings — "Limit to specific sites"
//
// Rem's cloud browser (headless Chromium on the user's gateway) is OPEN by default: it can reach any
// PUBLIC host (private/metadata IPs stay blocked regardless). This screen is the opt-in INVERSE —
// "Limit to specific sites" (off by default). When on, Rem's browser may only visit the hosts the
// user lists; everything else is blocked.
//
// Mechanism: the browser resolves its SSRF policy ONLY at gateway STARTUP, so a plain operator
// `config.patch` writes the file but the live gateway ignores it. We therefore route the write
// through the backend (`patchGatewayConfigViaBackendAndRestart`), which patches server-side AND
// restarts the gateway so the new policy loads. The restart drops the WS for ~1–2 min, so we batch
// all edits behind one explicit "Save & restart" instead of writing per keystroke.
//
// Config shape (openclaw/src/config/types.browser.ts, BrowserSsrfPolicyConfig):
//   - Open (default):   browser.ssrfPolicy.hostnameAllowlist = []   (empty = every public host)
//   - Limited:          browser.ssrfPolicy.hostnameAllowlist = [hosts]   (non-empty = only these)
// Arrays REPLACE under RFC 7386 merge, so each write sends the whole array — no `null` is ever sent
// (a bare null in a gateway config patch bricks old-wrapper gateways). `dangerouslyAllowPrivateNetwork`
// is never touched, so internal/metadata IPs stay blocked in both modes.

/// Generic over `GatewaySessionProviding` so iOS and Mac share one implementation.
struct SharedCloudBrowserSettingsView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    /// The allowlist currently APPLIED on the gateway (loopback filtered out for display). Empty =
    /// open. This is the source of truth we diff the draft against to know if there's a change.
    @State private var appliedSites: [String] = []
    /// The user's in-progress edits. Written (and the gateway restarted) only on "Save & restart".
    @State private var draftSites: [String] = []
    /// Toggle state. On = "limit to specific sites". Seeded from `!appliedSites.isEmpty`.
    @State private var limitEnabled = false
    @State private var newSite: String = ""

    @State private var isLoading = true
    @State private var hasLoadedPolicy = false
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var banner: Banner?
    @State private var cookieClearState: CookieClearState = .idle
    @State private var showCookieClearConfirmation = false
    @State private var toast: RemToastItem?

    struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    // MARK: - Derived

    /// The allowlist the draft would write: the sites when limiting, or [] (open) when the toggle is
    /// off. Empty while the toggle is on just means "not restricting yet" (still open) — the footer
    /// says so, and Save is blocked until at least one site is added.
    private var draftAllowlist: [String] {
        limitEnabled ? draftSites : []
    }

    private var hasUnsavedChange: Bool {
        draftAllowlist != appliedSites
    }

    /// Save is offered only when there's a real change to write, and never for the incoherent
    /// "limit on, zero sites" state (which is just "open" and would be a no-op restart).
    private var canSave: Bool {
        guard !isSaving, !isLoading, !cookieClearState.isClearing, hasUnsavedChange else { return false }
        if limitEnabled && draftSites.isEmpty { return false }
        return true
    }

    private var cookieClearIsUnavailable: Bool {
        isLoading || isSaving || cookieClearState.isClearing
    }

    private var loadPresentation: CloudBrowserSettingsLoadPresentation {
        .resolve(
            isLoading: isLoading,
            hasLoadedPolicy: hasLoadedPolicy,
            hasError: loadError != nil
        )
    }

    // MARK: - Body

    var body: some View {
        List {
            switch loadPresentation {
            case .skeleton:
                CloudBrowserSettingsSkeleton()
            case .failure:
                policyLoadFailure
                browserDataSection
            case .content:
                settingsContent
            }
        }
        .navigationTitle("Cloud browser")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .bottom) {
            if let banner {
                bannerView(banner).padding(DesignTokens.Spacing.md)
            }
        }
        .animation(.default, value: limitEnabled)
        .animation(.default, value: draftSites)
        .task { await loadPolicy() }
        .confirmationDialog(
            "Clear all cloud browser cookies?",
            isPresented: $showCookieClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Cookies", role: .destructive) {
                Task { await clearAllCookies() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs Rem out of websites in its cloud browser. It won’t disconnect Connectors or clear Safari or app data.")
        }
        .remToast(item: $toast)
    }

    @ViewBuilder
    private var settingsContent: some View {
        Section {
            Toggle(isOn: Binding(
                get: { limitEnabled },
                set: { limitEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limit to specific sites")
                    Text("Only let Rem's browser visit sites you approve.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
            }
            .disabled(isLoading || isSaving)
        } footer: {
            Text("Rem's browser can open any public website by default. Turn this on to restrict it to a list you choose — useful if you want Rem to only touch a few trusted sites. Internal and private network addresses stay blocked either way.")
        }

        if limitEnabled {
            allowedSitesSection
        }

        if let loadError {
            Section {
                Text(loadError)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.systemRed)
            }
        }

        if canSave || isSaving {
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(isSaving ? "Restarting Rem's browser…" : "Save & restart")
                    }
                }
                .disabled(!canSave)
            } footer: {
                Text("Saving restarts Rem's cloud browser so the change takes effect — the connection drops for a minute or two, then reconnects.")
            }
        }

        browserDataSection
    }

    @ViewBuilder
    private var policyLoadFailure: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(loadError ?? "Couldn't read the current setting.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Button("Try Again") { Task { await loadPolicy() } }
                    .remSettingsCTA(.primary, size: .compact)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        } header: {
            Text("Cloud browser policy")
        }
    }

    // MARK: - Allowed sites editor

    @ViewBuilder
    private var allowedSitesSection: some View {
        Section {
            if draftSites.isEmpty {
                Text("No sites yet. Add one below — until then, Rem's browser can still open any site.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            } else {
                ForEach(draftSites, id: \.self) { site in
                    HStack {
                        Text(site).foregroundStyle(DesignTokens.Color.labelPrimary)
                        Spacer()
                        Button {
                            draftSites.removeAll { $0 == site }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(DesignTokens.Color.systemRed)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(site)")
                    }
                }
            }

            HStack {
                TextField("Add a site (e.g. notion.so)", text: $newSite)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { addSite() }
                Button("Add") { addSite() }
                    .disabled(normalizedNewSite == nil)
            }
        } header: {
            Text("Allowed sites")
        }
    }

    // MARK: - Browser data

    @ViewBuilder
    private var browserDataSection: some View {
        Section {
            Button(role: .destructive) {
                showCookieClearConfirmation = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if cookieClearState.isClearing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(cookieClearState.isClearing ? "Clearing cookies…" : "Clear all cookies")
                    Spacer()
                }
            }
            .disabled(cookieClearIsUnavailable)
            .accessibilityIdentifier("cloud-browser-clear-cookies")

            if case .failed(let message) = cookieClearState {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(message)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.systemRed)

                    Button("Try Again") {
                        Task { await clearAllCookies() }
                    }
                    .disabled(cookieClearIsUnavailable)
                    .accessibilityIdentifier("cloud-browser-clear-cookies-retry")
                }
            }
        } header: {
            Text("Browser data")
        } footer: {
            Text("Rem keeps website sign-ins in its private cloud browser so it can return later. Clearing cookies signs Rem out of those websites, but does not disconnect Connectors or clear Safari or app data.")
        }
    }

    // MARK: - Site parsing

    /// Normalize a typed entry to a bare hostname: strip scheme/path, lowercase, trim. Returns nil if
    /// it isn't a plausible host (empty, has spaces, or has no dot and isn't a wildcard).
    private var normalizedNewSite: String? {
        Self.normalizeHost(newSite)
    }

    static func normalizeHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        // Reduce to a bare hostname: drop scheme, then userinfo, then anything after the host
        // (path, query, fragment, port) — otherwise entries like "https://notion.so:443/x?y" would
        // be stored verbatim and silently never match upstream's exact-hostname allowlist check.
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        for sep: Character in ["/", "?", "#", ":"] {
            if let i = s.firstIndex(of: sep) { s = String(s[..<i]) }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        // Require a dot (rules out typos like "notion") unless it's an explicit wildcard.
        guard s.contains("."), s != "." else { return nil }
        // Reject loopback: it's blocked by the private-network guard regardless, and an entry like
        // "127.0.0.1" would restrict the browser to loopback-only (blocking all public nav) while the
        // UI filters it out on read — a confusing "shows open but isn't" desync.
        guard !Self.isLoopback(s) else { return nil }
        return s
    }

    private func addSite() {
        guard let host = normalizedNewSite else { return }
        if !draftSites.contains(host) { draftSites.append(host) }
        newSite = ""
    }

    // MARK: - Load / save

    @MainActor
    private func loadPolicy() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let res = try await gateway.skillsRequest(method: "config.get", paramsJSON: "{}", timeoutSeconds: 15)
            let decoded = try JSONDecoder().decode(ConfigGetResponse.self, from: res)
            let current = decoded.config?.browser?.ssrfPolicy?.hostnameAllowlist ?? []
            let sites = current.filter { !Self.isLoopback($0) }
            appliedSites = sites
            draftSites = sites
            limitEnabled = !sites.isEmpty
            hasLoadedPolicy = true
        } catch {
            loadError = "Couldn't read the current setting. Check the connection and try again."
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        banner = nil
        defer { isSaving = false }

        let allowlist = draftAllowlist
        // JSON-encode the array so hostnames are escaped correctly; arrays REPLACE under merge-patch.
        guard let arrayData = try? JSONEncoder().encode(allowlist),
              let arrayJSON = String(data: arrayData, encoding: .utf8) else {
            banner = Banner(kind: .error, text: "Couldn't prepare the change. Try again.")
            return
        }
        let patch = "{\"browser\":{\"ssrfPolicy\":{\"hostnameAllowlist\":\(arrayJSON)}}}"

        do {
            try await gateway.patchGatewayConfigViaBackendAndRestart(configPatchJSON: patch)
            appliedSites = allowlist.filter { !Self.isLoopback($0) }
            banner = Banner(
                kind: .success,
                text: allowlist.isEmpty
                    ? "Rem's browser can now open any site."
                    : "Saved. Rem's browser is limited to your \(allowlist.count) site\(allowlist.count == 1 ? "" : "s")."
            )
        } catch {
            banner = Banner(kind: .error, text: (error as? LocalizedError)?.errorDescription ?? "Couldn't save the change. Try again.")
        }
    }

    @MainActor
    private func clearAllCookies() async {
        guard !cookieClearIsUnavailable else { return }
        toast = nil
        cookieClearState = .clearing

        do {
            _ = try await gateway.skillsRequest(
                method: "browser.request",
                paramsJSON: try CloudBrowserCookieClearRequest.encodedParameters(),
                timeoutSeconds: 20
            )
            cookieClearState = .idle
            toast = .success("Cloud browser cookies cleared")
        } catch {
            if let detail = (error as? LocalizedError)?.errorDescription, !detail.isEmpty {
                cookieClearState = .failed("Couldn’t clear cookies: \(detail)")
            } else {
                cookieClearState = .failed("Couldn’t clear cloud browser cookies. Check the connection and try again.")
            }
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    // MARK: - Banner

    @ViewBuilder
    private func bannerView(_ banner: Banner) -> some View {
        Text(banner.text)
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                (banner.kind == .success ? DesignTokens.Color.brandBlue : DesignTokens.Color.systemRed),
                in: Capsule()
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner) {
                try? await Task.sleep(for: .seconds(4))
                if self.banner == banner { self.banner = nil }
            }
    }
}

enum CloudBrowserSettingsLoadPresentation: Equatable {
    case skeleton
    case failure
    case content

    static func resolve(
        isLoading: Bool,
        hasLoadedPolicy: Bool,
        hasError: Bool
    ) -> Self {
        if isLoading && !hasLoadedPolicy { return .skeleton }
        if hasError && !hasLoadedPolicy { return .failure }
        return .content
    }
}

private struct CloudBrowserSettingsSkeleton: View {
    var body: some View {
        Group {
            Section {
                HStack(spacing: DesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: 7) {
                        placeholder(width: 150, height: 14)
                        placeholder(width: 240, height: 11)
                    }
                    Spacer()
                    Capsule()
                        .fill(DesignTokens.Color.fillTertiary)
                        .frame(width: 48, height: 28)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    placeholder(width: 280, height: 9)
                    placeholder(width: 220, height: 9)
                }
            }

            Section {
                HStack {
                    placeholder(width: 122, height: 14)
                    Spacer()
                }
            } header: {
                placeholder(width: 92, height: 10)
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    placeholder(width: 270, height: 9)
                    placeholder(width: 205, height: 9)
                }
            }
        }
        .redacted(reason: .placeholder)
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading cloud browser settings")
    }

    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(height / 2, 4), style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: height)
    }
}

// MARK: - Cookie lifecycle contract

/// Exact upstream `browser.request` envelope for clearing every cookie in Rem's managed browser
/// profile. No target or website is supplied: the managed gateway has one persistent `openclaw`
/// Chromium profile, and upstream's `/cookies/clear` clears that profile's entire browser context.
/// It deliberately does not clear local storage, downloads, Connectors, or device browser data.
struct CloudBrowserCookieClearRequest: Encodable, Sendable, Equatable {
    struct EmptyBody: Encodable, Sendable, Equatable {}

    let method = "POST"
    let path = "/cookies/clear"
    let body = EmptyBody()

    static func encodedParameters() throws -> String {
        let request = Self()
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                request,
                .init(codingPath: [], debugDescription: "Could not encode browser cookie-clear request as UTF-8")
            )
        }
        return json
    }
}

private enum CookieClearState: Equatable {
    case idle
    case clearing
    case failed(String)

    var isClearing: Bool {
        self == .clearing
    }
}
