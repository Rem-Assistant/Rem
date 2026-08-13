import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Pasteable setup-code entry. The user pastes a single base64url string
/// emitted by the backend deploy response (or a local Mac gateway on
/// startup), we decode it, and they confirm to add the gateway.
///
/// Falls back to the legacy URL + token form via a Manual segment for power
/// users with a gateway that doesn't yet emit setup codes.
///
/// When a `prefilledDiscovery` is supplied, the view shows a context
/// banner identifying the Bonjour-discovered gateway and pre-fills the
/// Manual URL + display-name fields — the user only needs to provide
/// a token (via setup code or Manual entry) to complete pairing. This
/// is the tap-target from `SharedNearbyGatewaysView` (see #276).
struct SharedSetupCodeEntryView: View {

    /// Optional context from a Bonjour-discovered gateway. When non-nil,
    /// the view reflects that it's finishing a specific pairing rather
    /// than standing up a fresh one.
    var prefilledDiscovery: DiscoveredGateway? = nil

    /// Called when the user confirms a decoded setup code. Caller persists
    /// the resulting `GatewayConfig` and dismisses.
    var onConnect: (GatewayConfig) -> Void

    /// Called when the user submits the Manual segment's legacy URL + token
    /// legacy form. Caller persists and dismisses.
    var onConnectManual: ((GatewayConfig) -> Void)? = nil

    @State private var codeText: String = ""
    @State private var decoded: GatewaySetupCode?
    @State private var decodeError: String?
    @State private var entryMode: SetupCodeEntryMode = .setupCode
    @State private var showScanner: Bool = false

    @State private var manualName: String = ""
    @State private var manualURL: String = ""
    @State private var manualToken: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Connection Method", selection: $entryMode) {
                    ForEach(SetupCodeEntryMode.availableModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("setup-code-entry-mode-picker")
            }

            if let prefilledDiscovery {
                Section {
                    discoveryContext(prefilledDiscovery)
                } header: {
                    Text("Discovered Gateway")
                } footer: {
                    Text("Bonjour found this gateway on your network. Paste its setup code below, or finish pairing with the prefilled manual fields.")
                }
            }

            switch entryMode {
            #if os(iOS)
            case .scan:
                Section {
                    scanQRCodeButton
                } footer: {
                    Text("Scan the QR code shown by Rem on your Mac or gateway dashboard.")
                }
            #endif

            case .setupCode:
                Section {
                    #if os(iOS)
                    TextField("Paste setup code", text: $codeText, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: codeText) { _, newValue in
                            evaluate(newValue)
                        }
                    #else
                    TextField("Paste setup code", text: $codeText, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .onChange(of: codeText) { _, newValue in
                            evaluate(newValue)
                        }
                    #endif

                    if let decoded {
                        decodedSummary(decoded)
                    } else if let decodeError, !codeText.isEmpty {
                        Text(decodeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    #if os(iOS)
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            codeText = pasted
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    #endif
                } header: {
                    Text("Setup Code")
                } footer: {
                    Text(setupCodeFooterText)
                }

            case .manual:
                Section {
                    Text("Use this only when you have a gateway URL and token but no setup code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    manualFields
                } header: {
                    Text("Manual Connection")
                } footer: {
                    Text("Manual URL entry is for custom or older gateways that cannot emit setup codes.")
                }
            }
        }
        .navigationTitle(prefilledDiscovery == nil ? "Add Gateway" : "Finish Pairing")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    if entryMode == .manual {
                        submitManual()
                    } else if let decoded {
                        onConnect(decoded.toGatewayConfig())
                    }
                }
                .disabled(!canConnect)
            }
        }
        .onAppear {
            applyPrefillIfNeeded()
        }
        // Note: do NOT auto-read the clipboard on appear. iOS shows a
        // banner ("Rem pasted from …") on every UIPasteboard.string read,
        // which would fire each time the user opens this view. Keep the
        // explicit Paste button (iOS) as the single trigger.
        #if os(iOS)
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScan: { payload in
                    codeText = payload
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
        }
        #endif
    }

    // MARK: - Prefill

    /// Seeds the Manual form with the discovered gateway's URL + name so the
    /// selected nearby-gateway path has an obvious token entry point. Setup-code
    /// paste still works as-is and will overwrite these values when the user
    /// confirms via setup code.
    private func applyPrefillIfNeeded() {
        guard let gateway = prefilledDiscovery, manualURL.isEmpty else { return }
        manualURL = gateway.url
        manualName = gateway.name
        entryMode = .manual
    }

    @ViewBuilder
    private func discoveryContext(_ gateway: DiscoveredGateway) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.name)
                    .font(.callout.weight(.semibold))
                Text("\(gateway.host):\(String(gateway.port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    #if os(iOS)
    private var scanQRCodeButton: some View {
        Button {
            showScanner = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan QR Code")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Fastest way to connect to your Mac or cloud gateway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    private var setupCodeFooterText: String {
        #if os(iOS)
        "Paste the setup code if you cannot scan the QR code."
        #else
        "Paste the setup code shown by Rem on your Mac or gateway dashboard."
        #endif
    }

    @ViewBuilder
    private var manualFields: some View {
        #if os(iOS)
        TextField("Display name", text: $manualName)
            .textInputAutocapitalization(.words)
        TextField("Gateway URL", text: $manualURL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Token", text: $manualToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField("Display name", text: $manualName)
        TextField("Gateway URL", text: $manualURL)
            .autocorrectionDisabled()
        SecureField("Token", text: $manualToken)
            .autocorrectionDisabled()
        #endif
    }

    // MARK: - Decoded summary

    @ViewBuilder
    private func decodedSummary(_ code: GatewaySetupCode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Decoded — ready to connect")
                    .font(.caption.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let displayName = code.displayName {
                Text(displayName)
                    .font(.callout.weight(.semibold))
            }
            Text(code.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if prefillMismatch(for: code) {
                Label {
                    Text("This code points to a different host than the nearby gateway you tapped. Connect will use the code's address.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    /// True when a setup code was pasted for a discovery context but points
    /// at a different host:port — we still let the user connect (the code
    /// is authoritative), we just flag the divergence so they don't assume
    /// they're pairing the Mac they tapped.
    private func prefillMismatch(for code: GatewaySetupCode) -> Bool {
        guard let discovered = prefilledDiscovery,
              let codeURL = URL(string: code.url),
              let codeHost = codeURL.host?.lowercased()
        else { return false }
        let discoveredHost = discovered.host.lowercased()
        let codePort = codeURL.port ?? 0
        return codeHost != discoveredHost || codePort != Int(discovered.port)
    }

    // MARK: - Decode evaluation

    private func evaluate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            decoded = nil
            decodeError = nil
            return
        }
        if let parsed = GatewaySetupCode.decode(trimmed) {
            decoded = parsed
            decodeError = nil
        } else {
            decoded = nil
            decodeError = "Couldn't decode this as a setup code. Check the value, or use Manual entry."
        }
    }

    // MARK: - Manual fallback

    private var manualFormValid: Bool {
        !manualURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !manualToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canConnect: Bool {
        switch entryMode {
        case .manual:
            manualFormValid
        case .setupCode:
            decoded != nil
        #if os(iOS)
        case .scan:
            false
        #endif
        }
    }

    private func submitManual() {
        guard manualFormValid else { return }
        let trimmedName = manualName.trimmingCharacters(in: .whitespaces)

        // Reuse GatewaySetupCode.toGatewayConfig so the .fly.dev host
        // sniff and provider/displayName inference live in exactly one
        // place across the codebase.
        let synthesized = GatewaySetupCode(
            url: manualURL.trimmingCharacters(in: .whitespaces),
            token: manualToken.trimmingCharacters(in: .whitespaces),
            tls: nil,
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            stableID: nil
        )
        let config = synthesized.toGatewayConfig()
        (onConnectManual ?? onConnect)(config)
    }
}

private enum SetupCodeEntryMode: String, CaseIterable, Identifiable {
    #if os(iOS)
    case scan
    #endif
    case setupCode
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        #if os(iOS)
        case .scan: "Scan"
        #endif
        case .setupCode: "Code"
        case .manual: "Manual"
        }
    }

    static var availableModes: [SetupCodeEntryMode] {
        #if os(iOS)
        [.scan, .setupCode, .manual]
        #else
        [.setupCode, .manual]
        #endif
    }
}

#if DEBUG
#Preview("Setup Code — Code") {
    NavigationStack {
        SharedSetupCodeEntryView(onConnect: { _ in })
    }
}

#Preview("Setup Code — Nearby Gateway") {
    NavigationStack {
        SharedSetupCodeEntryView(
            prefilledDiscovery: PreviewGatewayDiscovery.nearbyMac,
            onConnect: { _ in }
        )
    }
}
#endif
