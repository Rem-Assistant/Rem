import SwiftUI

// MARK: - Rem Face Mark
//
// The branded "Rem face" identity: a scalloped sun/star blob outline with two
// rounded-rect eyes and a smile. Shared across iOS + macOS and both platforms'
// shared views (empty state, thinking indicator). The `CustomFaceShape` outline
// lives here so the voice `RemAnimatedFaceView` (iOS-only, in
// `RemClaw/Sources/Voice/CustomFaceShape.swift`) and every shared surface draw
// the same mark.

// MARK: - Face Outline Shape

/// SVG-derived blob face outline (the scalloped "sun/star" mark). Scales to fill
/// its frame. Trimmable so the thinking indicator can self-draw it 0→1.
struct CustomFaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 204
        let sy = rect.height / 200

        path.move(to: CGPoint(x: 101.813 * sx, y: 0))
        path.addCurve(to: CGPoint(x: 123.171 * sx, y: 8.214 * sy),
                       control1: CGPoint(x: 110.46 * sx, y: 0),
                       control2: CGPoint(x: 117.579 * sx, y: 2.738 * sy))
        path.addCurve(to: CGPoint(x: 137.677 * sx, y: 29.236 * sy),
                       control1: CGPoint(x: 128.694 * sx, y: 13.569 * sy),
                       control2: CGPoint(x: 133.531 * sx, y: 20.575 * sy))
        path.addCurve(to: CGPoint(x: 163.119 * sx, y: 27.324 * sy),
                       control1: CGPoint(x: 147.093 * sx, y: 27.003 * sy),
                       control2: CGPoint(x: 155.574 * sx, y: 26.367 * sy))
        path.addCurve(to: CGPoint(x: 182.920 * sx, y: 39.083 * sy),
                       control1: CGPoint(x: 170.843 * sx, y: 28.304 * sy),
                       control2: CGPoint(x: 177.444 * sx, y: 32.224 * sy))
        path.addCurve(to: CGPoint(x: 189.838 * sx, y: 60.873 * sy),
                       control1: CGPoint(x: 188.281 * sx, y: 45.828 * sy),
                       control2: CGPoint(x: 190.587 * sx, y: 53.091 * sy))
        path.addCurve(to: CGPoint(x: 182.249 * sx, y: 85.308 * sy),
                       control1: CGPoint(x: 189.099 * sx, y: 68.542 * sy),
                       control2: CGPoint(x: 186.570 * sx, y: 76.688 * sy))
        path.addCurve(to: CGPoint(x: 199.522 * sx, y: 103.934 * sy),
                       control1: CGPoint(x: 189.781 * sx, y: 91.162 * sy),
                       control2: CGPoint(x: 195.539 * sx, y: 97.371 * sy))
        path.addCurve(to: CGPoint(x: 202.808 * sx, y: 126.589 * sy),
                       control1: CGPoint(x: 203.615 * sx, y: 110.621 * sy),
                       control2: CGPoint(x: 204.710 * sx, y: 118.173 * sy))
        path.addCurve(to: CGPoint(x: 189.924 * sx, y: 145.698 * sy),
                       control1: CGPoint(x: 200.848 * sx, y: 135.063 * sy),
                       control2: CGPoint(x: 196.553 * sx, y: 141.432 * sy))
        path.addCurve(to: CGPoint(x: 166.496 * sx, y: 154.915 * sy),
                       control1: CGPoint(x: 183.570 * sx, y: 149.767 * sy),
                       control2: CGPoint(x: 175.760 * sx, y: 152.840 * sy))
        path.addCurve(to: CGPoint(x: 162.687 * sx, y: 180.026 * sy),
                       control1: CGPoint(x: 166.542 * sx, y: 164.573 * sy),
                       control2: CGPoint(x: 165.272 * sx, y: 172.944 * sy))
        path.addCurve(to: CGPoint(x: 146.950 * sx, y: 196.628 * sy),
                       control1: CGPoint(x: 160.035 * sx, y: 187.347 * sy),
                       control2: CGPoint(x: 154.789 * sx, y: 192.881 * sy))
        path.addCurve(to: CGPoint(x: 133.115 * sx, y: 200 * sy),
                       control1: CGPoint(x: 142.338 * sx, y: 198.876 * sy),
                       control2: CGPoint(x: 137.726 * sx, y: 200 * sy))
        path.addCurve(to: CGPoint(x: 117.291 * sx, y: 196.022 * sy),
                       control1: CGPoint(x: 127.811 * sx, y: 200 * sy),
                       control2: CGPoint(x: 122.537 * sx, y: 198.674 * sy))
        path.addCurve(to: CGPoint(x: 101.813 * sx, y: 185.774 * sy),
                       control1: CGPoint(x: 112.188 * sx, y: 193.471 * sy),
                       control2: CGPoint(x: 107.028 * sx, y: 190.054 * sy))
        path.addCurve(to: CGPoint(x: 86.249 * sx, y: 196.022 * sy),
                       control1: CGPoint(x: 96.542 * sx, y: 190.055 * sy),
                       control2: CGPoint(x: 91.353 * sx, y: 193.471 * sy))
        path.addCurve(to: CGPoint(x: 70.512 * sx, y: 200 * sy),
                       control1: CGPoint(x: 81.061 * sx, y: 198.674 * sy),
                       control2: CGPoint(x: 75.815 * sx, y: 200 * sy))
        path.addCurve(to: CGPoint(x: 56.764 * sx, y: 196.714 * sy),
                       control1: CGPoint(x: 65.843 * sx, y: 200 * sy),
                       control2: CGPoint(x: 61.260 * sx, y: 198.905 * sy))
        path.addCurve(to: CGPoint(x: 40.940 * sx, y: 180.112 * sy),
                       control1: CGPoint(x: 48.866 * sx, y: 192.967 * sy),
                       control2: CGPoint(x: 43.592 * sx, y: 187.433 * sy))
        path.addCurve(to: CGPoint(x: 37.130 * sx, y: 154.915 * sy),
                       control1: CGPoint(x: 38.354 * sx, y: 172.974 * sy),
                       control2: CGPoint(x: 37.085 * sx, y: 164.575 * sy))
        path.addCurve(to: CGPoint(x: 13.616 * sx, y: 145.612 * sy),
                       control1: CGPoint(x: 27.810 * sx, y: 152.838 * sy),
                       control2: CGPoint(x: 19.971 * sx, y: 149.737 * sy))
        path.addCurve(to: CGPoint(x: 0.905 * sx, y: 126.589 * sy),
                       control1: CGPoint(x: 7.045 * sx, y: 141.346 * sy),
                       control2: CGPoint(x: 2.808 * sx, y: 135.005 * sy))
        path.addCurve(to: CGPoint(x: 4.191 * sx, y: 103.934 * sy),
                       control1: CGPoint(x: -0.997 * sx, y: 118.173 * sy),
                       control2: CGPoint(x: 0.098 * sx, y: 110.621 * sy))
        path.addCurve(to: CGPoint(x: 21.383 * sx, y: 85.308 * sy),
                       control1: CGPoint(x: 8.174 * sx, y: 97.371 * sy),
                       control2: CGPoint(x: 13.906 * sx, y: 91.162 * sy))
        path.addCurve(to: CGPoint(x: 13.789 * sx, y: 60.787 * sy),
                       control1: CGPoint(x: 17.066 * sx, y: 76.680 * sy),
                       control2: CGPoint(x: 14.533 * sx, y: 68.507 * sy))
        path.addCurve(to: CGPoint(x: 20.793 * sx, y: 38.997 * sy),
                       control1: CGPoint(x: 13.040 * sx, y: 53.005 * sy),
                       control2: CGPoint(x: 15.374 * sx, y: 45.742 * sy))
        path.addCurve(to: CGPoint(x: 40.508 * sx, y: 27.324 * sy),
                       control1: CGPoint(x: 26.154 * sx, y: 32.195 * sy),
                       control2: CGPoint(x: 32.726 * sx, y: 28.304 * sy))
        path.addCurve(to: CGPoint(x: 65.995 * sx, y: 29.226 * sy),
                       control1: CGPoint(x: 48.099 * sx, y: 26.312 * sy),
                       control2: CGPoint(x: 56.594 * sx, y: 26.947 * sy))
        path.addCurve(to: CGPoint(x: 80.369 * sx, y: 8.214 * sy),
                       control1: CGPoint(x: 70.130 * sx, y: 20.499 * sy),
                       control2: CGPoint(x: 74.921 * sx, y: 13.494 * sy))
        path.addCurve(to: CGPoint(x: 101.813 * sx, y: 0),
                       control1: CGPoint(x: 86.019 * sx, y: 2.738 * sy),
                       control2: CGPoint(x: 93.167 * sx, y: 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Smile Shape

/// Upward-opening smile arc (a happy mouth). Endpoints are inset from the rect's
/// side edges so the mouth reads narrower than its frame, and a quadratic curve
/// makes a gentle dip (not a full grin). Stroke it with a round line cap to match
/// the Figma reference (dark blob, two vertical eyes, centered smile).
struct RemSmileShape: Shape {
    /// Fraction of the rect width to inset each endpoint inward, narrowing the
    /// visible smile relative to `size` (founder: mouth was too wide).
    private let horizontalInset: CGFloat = 0.14
    /// Fraction of the rect height the arc dips at center — less than 1 keeps the
    /// curve gentle rather than a deep grin (founder: mouth was too curved).
    private let dipFraction: CGFloat = 0.6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * horizontalInset
        let start = CGPoint(x: rect.minX + inset, y: rect.minY)
        let end = CGPoint(x: rect.maxX - inset, y: rect.minY)
        // For a quad curve the lowest point (t=0.5) is 0.5*minY + 0.5*controlY.
        // We want that dip to reach minY + dipFraction*height, so solving for
        // controlY: C = minY + 2*dipFraction*height.
        let dip = rect.height * dipFraction
        let control = CGPoint(x: rect.midX, y: rect.minY + 2 * dip)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

// MARK: - Rem Face Mark View

/// Reusable, animated Rem face mark. Renders the outline + two rounded-rect eyes
/// + a smile, tinted and sized to taste.
///
/// - `.idle` (happy): randomized eye blinks (left / right / both on a gentle
///   2–5s cadence) plus a subtle breathing smile.
/// - `.thinking`: the outline self-draws 0→1 on a loop — the "Rem is thinking"
///   signature that replaces the typing dots.
///
/// Respects Reduce Motion: `.idle` becomes a static happy face; `.thinking`
/// becomes a gentle full-face opacity pulse (no stroke draw).
struct RemFaceMark: View {
    enum Mode {
        /// Happy, living face — occasional blinks + a subtle smile motion.
        case idle
        /// Self-drawing outline loop; the thinking signature.
        case thinking
    }

    var mode: Mode = .idle
    /// Ink color for outline, eyes, and mouth.
    var tint: Color = DesignTokens.Color.labelPrimary
    /// Rendered edge length (square).
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Idle animation state.
    @State private var leftEyeScaleY: CGFloat = 1
    @State private var rightEyeScaleY: CGFloat = 1
    @State private var mouthScale: CGFloat = 1
    @State private var mouthRotation: Double = 0

    // Thinking animation state.
    @State private var trimEnd: CGFloat = 1
    @State private var pulseOpacity: Double = 1

    // MARK: Derived geometry (all proportional to `size`)

    // The outline, eyes, and smile are drawn with the same "pen weight" so they
    // read as one consistent stroke (founder: outline + eyes should look like the
    // same pen). `.thinking` uses a heavier outline so the self-drawing mark still
    // reads with authority at small sizes (~20pt).
    private var penWeight: CGFloat { size * 0.06 }
    private var outlineWidth: CGFloat { mode == .thinking ? size * 0.075 : penWeight }
    // Eyes are short vertical bars; width == pen weight so the filled rounded-rect
    // carries the same visual weight as the outline stroke.
    private var eyeWidth: CGFloat { penWeight }
    // Taller eyes read as more expressive ovals and balance the narrower, flatter
    // smile (founder: eyes weren't tall enough).
    private var eyeHeight: CGFloat { size * 0.19 }
    private var eyeGap: CGFloat { size * 0.15 }
    private var eyeCornerRadius: CGFloat { eyeWidth / 2 }
    private var eyesYOffset: CGFloat { -size * 0.06 }
    private var mouthWidth: CGFloat { size * 0.30 }
    private var mouthHeight: CGFloat { size * 0.11 }
    // Smile sits well below the eyes for clear breathing room.
    private var mouthYOffset: CGFloat { size * 0.20 }
    private var mouthWidthStroke: CGFloat { penWeight }

    /// Outline trim: full circle unless we're actively self-drawing.
    private var effectiveTrim: CGFloat {
        (mode == .thinking && !reduceMotion) ? trimEnd : 1
    }

    /// Eyes + mouth are hidden while the outline is drawing itself (normal
    /// thinking); everything shows in idle and in reduce-motion thinking (where
    /// the whole face pulses).
    private var featuresVisible: Bool {
        !(mode == .thinking && !reduceMotion)
    }

    var body: some View {
        ZStack {
            CustomFaceShape()
                .trim(from: 0, to: effectiveTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: outlineWidth, lineCap: .round, lineJoin: .round))

            if featuresVisible {
                faceFeatures
            }
        }
        .frame(width: size, height: size)
        .opacity((mode == .thinking && reduceMotion) ? pulseOpacity : 1)
        .accessibilityHidden(true)
        // Re-run the animation whenever mode or the Reduce Motion setting flips.
        .task(id: taskKey) { await runAnimation() }
    }

    @ViewBuilder
    private var faceFeatures: some View {
        // Eyes.
        HStack(spacing: eyeGap) {
            RoundedRectangle(cornerRadius: eyeCornerRadius)
                .fill(tint)
                .frame(width: eyeWidth, height: eyeHeight)
                .scaleEffect(y: leftEyeScaleY)
            RoundedRectangle(cornerRadius: eyeCornerRadius)
                .fill(tint)
                .frame(width: eyeWidth, height: eyeHeight)
                .scaleEffect(y: rightEyeScaleY)
        }
        .offset(y: eyesYOffset)

        // Smile.
        RemSmileShape()
            .stroke(tint, style: StrokeStyle(lineWidth: mouthWidthStroke, lineCap: .round))
            .frame(width: mouthWidth, height: mouthHeight)
            .scaleEffect(mouthScale, anchor: .center)
            .rotationEffect(.degrees(mouthRotation))
            .offset(y: mouthYOffset)
    }

    // MARK: - Animation driving

    /// Identity for `.task` so a mode / reduce-motion change restarts the loop.
    private var taskKey: String { "\(mode)-\(reduceMotion)" }

    private func runAnimation() async {
        // Reset to a clean happy resting state before (re)starting.
        resetState()

        guard !reduceMotion else {
            if mode == .thinking { await runReduceMotionPulse() }
            // Idle + Reduce Motion => static happy face, nothing to animate.
            return
        }

        switch mode {
        case .idle:
            startSmileBreathing()
            await runBlinkLoop()
        case .thinking:
            startStrokeDraw()
            // Keep the task alive so it's cancellable on disappear / mode change.
            await sleepForever()
        }
    }

    private func resetState() {
        leftEyeScaleY = 1
        rightEyeScaleY = 1
        mouthScale = 1
        mouthRotation = 0
        trimEnd = (mode == .thinking && !reduceMotion) ? 0 : 1
        pulseOpacity = 1
    }

    /// Gentle continuous "smile breathing" — a few percent of scale + a couple
    /// degrees of rotation, eased in and out. Subtle, never busy.
    private func startSmileBreathing() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            mouthScale = 1.06
            mouthRotation = 2
        }
    }

    /// Randomized blink loop: pick left / right / both, blink quickly, wait 2–5s.
    private func runBlinkLoop() async {
        while !Task.isCancelled {
            let wait = Double.random(in: 2.0...5.0)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { break }
            await blink(Int.random(in: 0..<3))
        }
    }

    /// One blink: scaleY → ~0.1 then back to 1. `choice`: 0 left, 1 right, 2 both.
    @MainActor
    private func blink(_ choice: Int) async {
        let close = 0.09
        withAnimation(.easeInOut(duration: close)) {
            if choice == 0 || choice == 2 { leftEyeScaleY = 0.1 }
            if choice == 1 || choice == 2 { rightEyeScaleY = 0.1 }
        }
        try? await Task.sleep(nanoseconds: UInt64(close * 1_000_000_000))
        if Task.isCancelled { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            leftEyeScaleY = 1
            rightEyeScaleY = 1
        }
    }

    /// Loop the outline drawing itself 0→1 forever.
    private func startStrokeDraw() {
        trimEnd = 0
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
            trimEnd = 1
        }
    }

    /// Reduce Motion thinking: gentle full-face opacity pulse (no stroke draw).
    private func runReduceMotionPulse() async {
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.35
        }
        await sleepForever()
    }

    /// Park the task until cancelled (on disappear / mode change).
    private func sleepForever() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Rem Face Mark") {
    VStack(spacing: 32) {
        HStack(spacing: 40) {
            VStack {
                RemFaceMark(mode: .idle, tint: DesignTokens.Color.brandBlue, size: 96)
                Text("idle · blue").font(.caption)
            }
            VStack {
                RemFaceMark(mode: .idle, tint: DesignTokens.Color.labelPrimary, size: 96)
                Text("idle · neutral").font(.caption)
            }
        }
        HStack(spacing: 40) {
            VStack {
                RemFaceMark(mode: .thinking, tint: DesignTokens.Color.brandBlue, size: 40)
                Text("thinking · blue").font(.caption)
            }
            VStack {
                RemFaceMark(mode: .thinking, tint: DesignTokens.Color.labelPrimary, size: 40)
                Text("thinking · neutral").font(.caption)
            }
        }
    }
    .padding(40)
}
#endif
