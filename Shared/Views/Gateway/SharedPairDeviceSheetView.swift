import SwiftUI
import CoreImage.CIFilterBuiltins

/// Displays a gateway's connection credentials in three forms so another
/// device can pair without the user touching a terminal:
///
///   1. **QR code** — scannable from any iPhone camera; decodes to the
///      base64url setup-code string.
///   2. **Setup code** — copy-paste string (matches `GatewaySetupCode.encode()`
///      format).
///   3. **Raw URL + token** — collapsed "Advanced" view for users who want
///      to type fields manually into another app.
///
/// The view is read-only and purely presentational — the caller is
/// responsible for supplying a current `GatewaySetupCode` (URL, token,
/// display name). Placed in Shared/ so iOS can reuse it later if we ever
/// want iPhone→iPad or Watch pairing; currently called only from Mac.
struct SharedPairDeviceSheetView: View {

    /// The credentials to display. The view re-derives the encoded string
    /// every render so callers can update by passing a new code.
    let code: GatewaySetupCode

    /// True when the gateway is bound to a LAN-accepting interface. When
    /// false, the sheet shows a prominent warning — the setup code will
    /// decode cleanly on the other device, but the TCP connection will
    /// fail because nothing is listening on the LAN IP. Callers on macOS
    /// pass `LocalGatewayManager.isLANReachable()`; iOS callers (future)
    /// can pass `true` since the iOS gateway story is different.
    var isLANReachable: Bool = true

    /// Called when the user taps Done. Caller dismisses the sheet.
    var onClose: () -> Void

    @State private var copied = false
    @State private var advancedExpanded = false

    private var encodedString: String { code.encode() }

    var body: some View {
        VStack(spacing: 20) {
            header

            if !isLANReachable {
                loopbackWarning
            }

            qrCodeView

            codeSection

            DisclosureGroup("Advanced — URL and token", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldRow(label: "URL", value: code.url)
                    fieldRow(label: "Token", value: code.token, isSecret: true)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            Spacer(minLength: 0)

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 420, height: 560)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            Text("Pair a Device")
                .font(.title3)
                .fontWeight(.semibold)
            if let displayName = code.displayName {
                Text("Scan or paste to connect to \(displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Scan with your iPhone camera, or paste the code on another device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var loopbackWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gateway is loopback-bound")
                    .font(.caption.weight(.semibold))
                Text("The gateway is only accepting connections from this Mac. Pairing will fail from another device until you rebind it to LAN. Run `openclaw config set gateway.bind lan` and restart the gateway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var qrCodeView: some View {
        if let qr = Self.qrCodeImage(for: encodedString) {
            qr
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 200, height: 200)
                .overlay(
                    Text("Couldn't render QR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        }
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup Code")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Text(encodedString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copyToClipboard(encodedString)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func fieldRow(label: String, value: String, isSecret: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(isSecret ? String(repeating: "•", count: min(value.count, 24)) : value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copyToClipboard(value)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if isSecret {
                Text("Copy copies the real token, not the dots.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 58)
            }
        }
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Renders `string` as a QR code using CoreImage. Medium correction level
    /// (`M`) keeps the density moderate for short base64url payloads — if the
    /// token ever grows past a few hundred bytes we can drop to `L`.
    static func qrCodeImage(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // Scale up so the QR renders crisply at display size. The raw
        // filter output is ~25x25 pixels; 10x scale → 250x250 before
        // SwiftUI resizes.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(cgImage, scale: 1.0, label: Text("Setup code QR"))
    }
}

#if DEBUG
#Preview("Pair Device Sheet — Reachable") {
    SharedPairDeviceSheetView(
        code: GatewaySetupCode(
            url: PreviewGatewayConfigs.localMac.url,
            token: "preview-token",
            tls: false,
            displayName: "Mac Gateway",
            stableID: "preview-local-mac"
        ),
        isLANReachable: true,
        onClose: {}
    )
}

#Preview("Pair Device Sheet — Loopback Warning") {
    SharedPairDeviceSheetView(
        code: GatewaySetupCode(
            url: "http://127.0.0.1:18790",
            token: "preview-token",
            tls: false,
            displayName: "Mac Gateway",
            stableID: "preview-local-mac"
        ),
        isLANReachable: false,
        onClose: {}
    )
}
#endif
