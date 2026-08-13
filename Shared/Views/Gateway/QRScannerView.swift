#if os(iOS)
import SwiftUI
import AVFoundation

/// iOS QR scanner sheet. Captures a single QR payload, hands the decoded
/// string to `onScan`, and dismisses. The caller is responsible for
/// validating the payload (e.g. via `GatewaySetupCode.decode`).
///
/// Used by `SharedSetupCodeEntryView` as the camera entry point for
/// pasting a Mac-generated pairing QR (see #279 + #283).
///
/// Permission: iOS prompts for camera access on first use. If denied,
/// the view shows an inline message with a "Open Settings" button.
struct QRScannerView: View {
    /// Called with the decoded QR payload. The view dismisses itself on
    /// the first successful scan; callers don't need to.
    var onScan: (String) -> Void
    var onCancel: () -> Void

    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    scannerContent
                case .notDetermined:
                    requestView
                case .denied, .restricted:
                    deniedView
                @unknown default:
                    deniedView
                }
            }
            .navigationTitle("Scan Setup Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    // MARK: - Authorized: live camera preview

    private var scannerContent: some View {
        ZStack {
            QRScannerRepresentable { payload in
                // Haptic + dismiss-via-callback. Caller handles validation.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onScan(payload)
            }
            .ignoresSafeArea(edges: .bottom)

            // Reticle overlay — 260x260 rounded-rect, gives the user a target.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 3)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

            VStack {
                Spacer()
                Text("Point your camera at the QR code on your Mac")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .background(Color.black)
    }

    // MARK: - Not determined: explicit permission prompt

    private var requestView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("Camera Access Needed")
                .font(.title3.weight(.semibold))
            Text("Rem uses the camera to scan setup-code QR codes shown on your Mac. No images are saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Allow Camera") {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    Task { @MainActor in
                        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Denied: fallback with settings deep-link

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Camera Access Denied")
                .font(.title3.weight(.semibold))
            Text("Enable camera access in Settings, or close this and paste the setup code manually instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
private struct QRScannerPreviewSurface: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 260, height: 260)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

                VStack {
                    Spacer()
                    Text("Point your camera at the QR code on your Mac")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("Scan Setup Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
        }
    }
}

#Preview("QR Scanner — Camera Surface") {
    QRScannerPreviewSurface()
}

#Preview("QR Scanner — Permission Prompt") {
    QRScannerView(onScan: { _ in }, onCancel: {})
}
#endif

// MARK: - AVFoundation UIViewRepresentable

private struct QRScannerRepresentable: UIViewRepresentable {
    let onScan: (String) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.onScan = onScan
        return view
    }

    func updateUIView(_ uiView: ScannerView, context: Context) {}

    final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasScanned = false
        var onScan: ((String) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureSession()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureSession()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // Capture the session reference on MainActor (where UIView
                // lives) before hopping off for the blocking startRunning
                // call. AVCaptureSession itself is thread-safe.
                let session = self.session
                Task.detached(priority: .userInitiated) {
                    session.startRunning()
                }
            } else {
                session.stopRunning()
            }
        }

        private func configureSession() {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            self.previewLayer = layer
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasScanned,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let payload = object.stringValue,
                  !payload.isEmpty
            else { return }
            hasScanned = true
            session.stopRunning()
            onScan?(payload)
        }
    }
}

#endif
