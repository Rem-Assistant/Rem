import SwiftUI
#if os(iOS)
import UIKit
import SafariServices
#elseif os(macOS)
import AppKit
#endif

// MARK: - Shared MCP Servers View
//
// Upstream references:
//   openclaw/src/config/types.mcp.ts               — config shape
//   openclaw/src/config/mcp-config.ts              — list/set/unset CLI helpers
//   openclaw/src/cli/mcp-cli.ts                    — CLI command surface
//   openclaw/docs/cli/mcp.md                       — user-facing doc
//   openclaw/src/gateway/server-methods/config.ts  — config.get / config.patch
//
// RPC strategy:
//   There is NO dedicated `mcp.*` RPC on the operator session. Upstream CLI
//   goes through the config file directly; control surfaces must use
//   `config.get` (read) and `config.patch` (merge-patch write) to the
//   `mcp.servers` subtree. We mirror upstream's config shape exactly — if
//   upstream adds a dedicated `mcp.list`/`mcp.set` RPC later, we can swap
//   the transport with no UI change.
//
// Scope note:
//   `config.patch` requires `operator.admin` (openclaw/src/gateway/method-scopes.test.ts
//   line 37). Both platforms already request admin: iOS via
//   `RemClaw/Sources/Gateway/GatewayClient.swift` `reconnectOperator` (line 438),
//   and Mac via `RemClawMac/Sources/Gateway/MacGatewayClient.swift` (line 128,
//   widened in PR #326). Add/remove works symmetrically on both platforms.
//   Any scope-related failure surfaces the gateway's own error verbatim rather
//   than being synthesized.
//
// Product trust model:
//   MCP is an advanced/custom tool substrate, not the normal Connector happy
//   path. Keep add/edit copy aligned with docs/product/SECURITY_MODEL.md and
//   docs/product/CAPABILITIES_IA.md so users understand that adding a server
//   exposes its tools to the assistant on the selected gateway.

/// Generic over `GatewaySessionProviding` so iOS and Mac share one implementation.
/// Structural template: `SharedSkillBrowseView`.
struct SharedMcpServersView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    @State private var entries: [McpServerEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lifecycleByName: [String: McpServerLifecycleState] = [:]
    @State private var showAddSheet = false
    @State private var pendingRemoval: McpServerEntry?
    @State private var banner: Banner?

    /// URL the user asked us to open in their browser for MCP-server-side OAuth.
    /// iOS uses SFSafariViewController via a sheet; Mac uses NSWorkspace directly.
    @State private var authorizeURL: AuthorizeURL?

    struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    struct AuthorizeURL: Identifiable, Equatable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        Group {
            if isLoading && entries.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Loading MCP servers...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = loadError, entries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") { Task { await loadServers() } }
                        .remSettingsCTA(.primary, size: .compact)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                listBody
            }
        }
        .macSettingsCenteredColumn()
        .task { await loadServers() }
        .refreshable { await loadServers() }
        .sheet(isPresented: $showAddSheet) {
            SharedMcpAddServerSheet(
                existingNames: entries.map(\.name),
                onDismiss: { showAddSheet = false },
                onSubmit: { draft in
                    showAddSheet = false
                    Task { await addServer(draft: draft) }
                }
            )
        }
        #if os(iOS)
        .sheet(item: $authorizeURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        #endif
        .confirmationDialog(
            "Remove MCP server?",
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { entry in
            Button("Remove \(entry.name)", role: .destructive) {
                Task { await removeServer(entry: entry) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { entry in
            Text("This removes \(entry.name) from your gateway config. Tools from this server will no longer be available to the assistant.")
        }
        .accessibilityIdentifier("shared-mcp-servers")
    }

    // MARK: - List body

    private var listBody: some View {
        Group {
            #if os(macOS)
            Form { listSections }
                .formStyle(.grouped)
                .macSettingsCenteredColumn()
            #else
            List { listSections }
                .listStyle(.insetGrouped)
            #endif
        }
    }

    @ViewBuilder
    private var listSections: some View {
        if let banner {
            Section {
                bannerView(banner)
            }
        }

        Section {
            if entries.isEmpty {
                emptyState
            } else {
                ForEach(entries) { entry in
                    SharedMcpServerRow(
                        entry: entry,
                        state: lifecycleByName[entry.name] ?? .configured,
                        onRemove: { pendingRemoval = entry },
                        onAuthorize: { openAuthorize(for: entry) }
                    )
                }
            }
        } footer: {
            Text("Custom MCP servers are advanced connectors that expose tools to the assistant. Add the URL of a remote MCP server to make its tools available.")
        }

        Section {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Custom MCP Server", systemImage: "plus")
            }
            .remSettingsCTA(.primary)
            .remSettingsCtaListRow()
            .disabled(!gateway.connectionState.isConnected || !gateway.operatorReady)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No custom MCP servers configured")
                .foregroundStyle(.secondary)
            Text("Add one to give the assistant tools from third-party services.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(banner.kind == .success ? .green : .orange)
            Text(banner.text)
                .font(.footnote)
            Spacer()
            Button {
                self.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Removal binding helper

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    // MARK: - Actions

    private func loadServers() async {
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            loadError = "Not connected to gateway"
            return
        }
        isLoading = true
        loadError = nil
        do {
            let res = try await gateway.skillsRequest(
                method: "config.get",
                paramsJSON: "{}",
                timeoutSeconds: 15
            )
            let decoded = try JSONDecoder().decode(ConfigGetResponse.self, from: res)
            let raw = decoded.config?.mcp?.servers ?? [:]
            entries = raw
                .compactMap { name, value -> McpServerEntry? in
                    guard case .object(let record) = value else { return nil }
                    return parseEntry(name: name, record: record)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // Preserve lifecycle states for known names; drop removed ones.
            let valid = Set(entries.map(\.name))
            lifecycleByName = lifecycleByName.filter { valid.contains($0.key) }
        } catch {
            loadError = "Failed to load MCP servers: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func parseEntry(name: String, record: [String: JSONValue]) -> McpServerEntry {
        let url = record["url"]?.stringValue
        let transportRaw = record["transport"]?.stringValue?.lowercased() ?? "sse"
        let transport = McpServerTransport(rawValue: transportRaw) ?? .sse
        let hasAuthHeader: Bool = {
            guard case .object(let headers)? = record["headers"] else { return false }
            return headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        }()
        return McpServerEntry(
            name: name,
            url: url,
            transport: transport,
            hasAuthHeader: hasAuthHeader,
            rawRecord: record
        )
    }

    private func addServer(draft: McpServerDraft) async {
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            banner = Banner(kind: .error, text: "Not connected to gateway")
            return
        }
        lifecycleByName[draft.name] = .connecting
        banner = nil

        // Build merge-patch: { mcp: { servers: { <name>: { ... } } } }
        //
        // Upstream `applyMergePatch` (openclaw/src/config/merge-patch.ts) is a
        // JSON Merge Patch (RFC 7396) variant: null removes, present object
        // merges. For ADD we send the full object.
        var record: [String: JSONValue] = [:]
        if let url = draft.url, !url.isEmpty {
            record["url"] = .string(url)
        }
        record["transport"] = .string(draft.transport.rawValue)
        if let auth = draft.authorizationHeader, !auth.isEmpty {
            record["headers"] = .object(["Authorization": .string(auth)])
        }

        let patch: [String: JSONValue] = [
            "mcp": .object([
                "servers": .object([
                    draft.name: .object(record)
                ])
            ])
        ]

        do {
            let rawString = try encodeJSON(patch)
            // Re-read the CURRENT config right before writing: the gateway pins the patch on the
            // current hash (a stale one is rejected), and we re-check the name against the CURRENT
            // servers so a same-named server created concurrently — another device / the Control UI,
            // after this sheet opened — isn't silently overwritten by our merge. The load-time
            // duplicate guard can't see a server that appeared after load; this closes that gap.
            let snapshot = try await fetchConfigSnapshot()
            guard !snapshot.serverNames.contains(draft.name) else {
                lifecycleByName[draft.name] = nil
                banner = Banner(kind: .error, text: "A server named \(draft.name) already exists. Pick a different name.")
                return
            }
            let params = ConfigPatchParams(raw: rawString, baseHash: snapshot.hash)
            let paramsData = try JSONEncoder().encode(params)
            let paramsJSON = String(data: paramsData, encoding: .utf8)
            _ = try await gateway.skillsRequest(
                method: "config.patch",
                paramsJSON: paramsJSON,
                timeoutSeconds: 20
            )
            lifecycleByName[draft.name] = .ready
            banner = Banner(kind: .success, text: "Added \(draft.name)")
            await loadServers()
        } catch {
            let message = error.localizedDescription
            lifecycleByName[draft.name] = .error(message: message)
            banner = Banner(kind: .error, text: "Add failed: \(message)")
        }
    }

    private func removeServer(entry: McpServerEntry) async {
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            banner = Banner(kind: .error, text: "Not connected to gateway")
            return
        }
        lifecycleByName[entry.name] = .connecting
        banner = nil

        // JSON Merge Patch semantics (RFC 7396): `null` removes the key.
        // Upstream `applyMergePatch` honors this (see
        // openclaw/src/config/merge-patch.ts).
        let patch: [String: JSONValue] = [
            "mcp": .object([
                "servers": .object([
                    entry.name: .null
                ])
            ])
        ]

        do {
            let rawString = try encodeJSON(patch)
            // Re-read a FRESH hash right before writing — the gateway pins the patch on the CURRENT
            // config hash and rejects a stale load-time one ("config changed since last load").
            let freshHash = try await fetchConfigSnapshot().hash
            let params = ConfigPatchParams(raw: rawString, baseHash: freshHash)
            let paramsData = try JSONEncoder().encode(params)
            let paramsJSON = String(data: paramsData, encoding: .utf8)
            _ = try await gateway.skillsRequest(
                method: "config.patch",
                paramsJSON: paramsJSON,
                timeoutSeconds: 20
            )
            lifecycleByName.removeValue(forKey: entry.name)
            banner = Banner(kind: .success, text: "Removed \(entry.name)")
            await loadServers()
        } catch {
            let message = error.localizedDescription
            lifecycleByName[entry.name] = .error(message: message)
            banner = Banner(kind: .error, text: "Remove failed: \(message)")
        }
    }

    private func openAuthorize(for entry: McpServerEntry) {
        guard let urlString = entry.url, let url = URL(string: urlString) else {
            banner = Banner(kind: .error, text: "This server has no URL to authorize.")
            return
        }
        #if os(iOS)
        authorizeURL = AuthorizeURL(url: url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - Helpers

    /// One fresh `config.get` immediately before a write: the base hash to pin the patch on (the
    /// gateway rejects a stale one — "config changed since last load") AND the CURRENT server names.
    /// A fresh hash alone would let an ADD silently overwrite a same-named server another device / the
    /// Control UI created after the sheet opened (the load-time duplicate guard can't see it), so
    /// addServer re-checks the name against these names before patching.
    private func fetchConfigSnapshot() async throws -> (hash: String?, serverNames: Set<String>) {
        let res = try await gateway.skillsRequest(method: "config.get", paramsJSON: "{}", timeoutSeconds: 15)
        let decoded = try JSONDecoder().decode(ConfigGetResponse.self, from: res)
        return (decoded.patchBaseHash, Set((decoded.config?.mcp?.servers ?? [:]).keys))
    }

    private func encodeJSON(_ value: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SharedMcpServersView",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON patch"]
            )
        }
        return s
    }
}

// MARK: - Row

private struct SharedMcpServerRow: View {
    let entry: McpServerEntry
    let state: McpServerLifecycleState
    let onRemove: () -> Void
    let onAuthorize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout)
                    HStack(spacing: 6) {
                        Text(entry.transport.displayLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if entry.hasAuthHeader {
                            Text("• Bearer token set")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                stateBadge
            }

            if let url = entry.url, !url.isEmpty {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if case .error(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if !entry.isStdio, entry.url != nil {
                    Button("Authorize", action: onAuthorize)
                        .remSettingsCTA(.primary, size: .compact)
                }
                Spacer(minLength: 0)
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.titleOnly)
                }
                .remSettingsCTA(.destructive, size: .compact)
                .disabled(entry.isStdio) // Don't let user nuke stdio entries from this UI.
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("mcp-server-\(entry.name)")
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .configured:
            EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .needsAuth:
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }
}

// MARK: - Add Server Sheet

struct McpServerDraft: Equatable {
    var name: String
    var url: String?
    var transport: McpServerTransport
    var authorizationHeader: String?
}

struct SharedMcpAddServerSheet: View {
    let existingNames: [String]
    let onDismiss: () -> Void
    let onSubmit: (McpServerDraft) -> Void

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var transport: McpServerTransport = .sse
    @State private var bearerToken: String = ""
    @State private var trustAcknowledged = false

    var body: some View {
        #if os(macOS)
        macContainer
            .frame(width: 460, height: 620)
        #else
        NavigationStack {
            form
                .navigationTitle("Add Custom MCP Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onDismiss)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { submit() }
                            .disabled(!isValid)
                    }
                }
        }
        #endif
    }

    #if os(macOS)
    private var macContainer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Custom MCP Server")
                    .font(.title3.bold())
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            form
                .padding()
            Divider()
            HStack {
                Spacer()
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
    }
    #endif

    private var form: some View {
        Form {
            Section {
                Label("Advanced trust grant", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Text("Custom MCP servers are for advanced integrations. Unlike first-party Connectors, Rem cannot verify the provider, permissions, or tool behavior for you before adding the server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("After adding, tools from this server may be available to the assistant through this gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("context7", text: $name)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Name")
            } footer: {
                if !name.isEmpty, existingNames.contains(name) {
                    Text("A server named \(name) already exists. Pick a different name.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Short identifier. Lowercase recommended.")
                }
            }

            Section {
                TextField("https://mcp.example.com", text: $url)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Server URL")
            } footer: {
                if let urlValidationMessage {
                    Text(urlValidationMessage)
                        .foregroundStyle(.orange)
                } else {
                    Text("Use the official HTTPS endpoint from the server's documentation. Local HTTP URLs are accepted only for localhost development.")
                }
            }

            Section {
                Picker("Transport", selection: $transport) {
                    ForEach(McpServerTransport.allCases) { option in
                        Text(option.displayLabel).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(transport.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Bearer token (optional)", text: $bearerToken)
            } header: {
                Text("Authorization")
            } footer: {
                Text("If the server requires a bearer token, paste it here. Adding this server does not connect accounts; OAuth-based servers should be authorized after adding, or exposed later as a first-party Connector.")
            }

            Section {
                Toggle(isOn: $trustAcknowledged) {
                    Text("I trust this server to expose tools to my assistant on this gateway.")
                }
            } footer: {
                Text("This writes to the selected gateway config. It does not install a first-party Connector or grant OS permissions on other devices.")
            }
        }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !existingNames.contains(trimmedName) else { return false }
        guard trustedServerURL(from: trimmedURL) != nil else { return false }
        return trustAcknowledged
    }

    private var urlValidationMessage: String? {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return nil }
        guard let parsed = URL(string: trimmedURL), let scheme = parsed.scheme?.lowercased() else {
            return "Enter a valid server URL."
        }
        guard parsed.host?.isEmpty == false else {
            return "Enter a URL with a server host."
        }
        if scheme == "https" { return nil }
        if scheme == "http", parsed.isLocalhost {
            return nil
        }
        return "Use an HTTPS URL for remote MCP servers. HTTP is allowed only for localhost development."
    }

    private func trustedServerURL(from value: String) -> URL? {
        guard let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased() else {
            return nil
        }
        guard parsed.host?.isEmpty == false else { return nil }
        if scheme == "https" { return parsed }
        if scheme == "http", parsed.isLocalhost { return parsed }
        return nil
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard let trustedURL = trustedServerURL(from: trimmedURL) else { return }
        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespaces)
        let auth: String? = trimmedToken.isEmpty ? nil : "Bearer \(trimmedToken)"
        onSubmit(
            McpServerDraft(
                name: trimmedName,
                url: trustedURL.absoluteString,
                transport: transport,
                authorizationHeader: auth
            )
        )
    }
}

#if DEBUG
struct SharedMcpAddServerFixtureView: View {
    @State private var submittedDraft: McpServerDraft?

    var body: some View {
        VStack(spacing: 0) {
            SharedMcpAddServerSheet(
                existingNames: ["github"],
                onDismiss: {},
                onSubmit: { submittedDraft = $0 }
            )

            if let submittedDraft {
                Text("Submitted \(submittedDraft.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }
}

#Preview("MCP Servers — Gateway Unreachable") {
    NavigationStack {
        SharedMcpServersView(
            gateway: PreviewGatewaySession(scenario: .cloudUnreachable)
        )
        .navigationTitle("Custom MCP Servers")
    }
}

#Preview("MCP Add Server") {
    SharedMcpAddServerFixtureView()
}
#endif

private extension URL {
    var isLocalhost: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

// MARK: - iOS SafariView wrapper

#if os(iOS)
private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif
