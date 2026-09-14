import SwiftUI

// MARK: - Animated Face View (adapted from ArcVoiceView)
//
// The `CustomFaceShape` outline this view strokes now lives in the shared
// `Shared/Views/RemFaceMark.swift` (compiled into both the iOS and Mac targets)
// so the branded mark is reused across the empty state and thinking indicator.
// This voice-driven view stays iOS-only because it binds to `RemTalkModeManager`.

/// Blob face with animated eyes. State-driven from RemTalkModeManager.
struct RemAnimatedFaceView: View {
    let talkMode: RemTalkModeManager
    var bubbleHeight: CGFloat = 0

    @State private var leftEyeScaleY: CGFloat = 1.0
    @State private var rightEyeScaleY: CGFloat = 1.0
    @State private var faceScale: CGFloat = 1.0

    private var faceSize: CGFloat {
        let base: CGFloat = 120
        let min: CGFloat = 80
        let normalizedHeight = Swift.min(bubbleHeight / 300, 1.0)
        return Swift.max(base - normalizedHeight * (base - min), min)
    }

    private var eyeScale: CGFloat {
        Swift.max(faceSize / 120, 80.0 / 120)
    }

    var body: some View {
        ZStack {
            CustomFaceShape()
                .stroke(Color.primary, lineWidth: 10)
                .frame(width: faceSize, height: faceSize)
                .scaleEffect(faceScale)

            HStack(spacing: 20 * eyeScale) {
                RoundedRectangle(cornerRadius: 6 * eyeScale)
                    .fill(Color.primary)
                    .frame(width: 10 * eyeScale, height: 32 * eyeScale)
                    .scaleEffect(y: leftEyeScaleY)
                RoundedRectangle(cornerRadius: 6 * eyeScale)
                    .fill(Color.primary)
                    .frame(width: 10 * eyeScale, height: 32 * eyeScale)
                    .scaleEffect(y: rightEyeScaleY)
            }
        }
        .onChange(of: talkMode.isSpeaking) { _, _ in animateForState() }
        .onChange(of: talkMode.isListening) { _, _ in animateForState() }
        .onAppear { animateForState() }
    }

    private func animateForState() {
        if talkMode.isSpeaking || talkMode.statusText == "Thinking..." {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.1)) {
                leftEyeScaleY = 0.96
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.3)) {
                rightEyeScaleY = 0.94
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                faceScale = 1.02
            }
        } else if talkMode.isListening {
            leftEyeScaleY = 1.0
            rightEyeScaleY = 1.0
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                faceScale = 1.05
            }
        } else {
            withAnimation(.easeOut(duration: 0.5)) {
                leftEyeScaleY = 1.0
                rightEyeScaleY = 1.0
                faceScale = 1.0
            }
        }
    }
}
