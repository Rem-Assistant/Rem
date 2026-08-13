//
//  GuidedFlow.swift
//  RemClaw (Shared)
//
//  A reusable spotlight coach-mark engine: a dimmed scrim with a spotlight
//  cutout over a real UI control, plus a Step X/Y tooltip bubble with Skip/Next.
//  Targets are addressed BY NAME — tag a control with `.guidedAnchor("id")`,
//  then present a `GuidedFlow` over the screen with `.guidedFlow(flow)`. The
//  overlay resolves each target's frame in its own coordinate space via
//  `anchorPreference`, so the spotlight follows the control as it lays out.
//
//  Intended home: guided-onboarding overlays (epic #1373, Screen 4). This file
//  is the ENGINE ONLY — it is deliberately NOT wired into any real onboarding
//  flow yet; wiring copy + trigger points into the actual Screen-4 experience is
//  a separate design task. A `#if DEBUG` fixture at the bottom proves the engine
//  renders (scrim + cutout + Next/Skip bubble) so it can be driven on a sim.
//
//  Lives in `Shared/Views/` so both the iOS (`RemClaw`) and macOS (`RemClawMac`)
//  targets compile it — it is generic UI infrastructure with no platform-specific
//  dependencies. Colors and typography come from `DesignTokens`, never a
//  hardcoded palette.
//
//  ── Attribution ─────────────────────────────────────────────────────────────
//  Ported from the founder's own Munch project (`Munch/GuidedFlow.swift`). Munch
//  ships under the BSD 3-Clause License, which differs from RemClaw's Apache-2.0;
//  BSD 3-Clause condition (1) requires the copyright notice, conditions, and
//  disclaimer to travel with redistributed source, so they are reproduced here:
//
//    BSD 3-Clause License
//    Copyright (c) 2026, Samuel Alake
//    Redistribution and use in source and binary forms, with or without
//    modification, are permitted provided that the following conditions are met:
//    1. Redistributions of source code must retain the above copyright notice,
//       this list of conditions and the following disclaimer.
//    2. Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//    3. Neither the name of the copyright holder nor the names of its
//       contributors may be used to endorse or promote products derived from
//       this software without specific prior written permission.
//    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
//    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//    POSSIBILITY OF SUCH DAMAGE.
//  ────────────────────────────────────────────────────────────────────────────
//

import SwiftUI

// MARK: - Flow model

/// One coach-mark: a spotlight on a target view plus a tooltip bubble.
/// `id` must match the `.guidedAnchor(id)` tag on the view it should point at.
struct GuidedStep: Identifiable {
    let id: String
    let title: String
    let message: String
}

/// A named sequence of coach-marks, shown once per user (keyed by `id`, which is
/// also the persistence key in `GuidedFlowState`). A flow can be a single tip or
/// a multi-step walkthrough of one task.
struct GuidedFlow {
    let id: String
    let steps: [GuidedStep]
}

// MARK: - First-use / debug triggers

/// UserDefaults-backed "shown once" ledger for guided flows, with a DEBUG
/// force-show env var and a debug reset.
enum GuidedFlowState {
    private static let keyPrefix = "guidedFlow.hasSeen."

    /// DEBUG-only capture aid: setting `REM_SHOW_GUIDED` forces every guided flow
    /// to present regardless of the seen-ledger, so a flow can be screenshotted
    /// on a signed-in simulator. Compiled out of Release, harmless when set.
    #if DEBUG
    static let forceShow =
        ProcessInfo.processInfo.environment["REM_SHOW_GUIDED"] != nil
    #else
    static let forceShow = false
    #endif

    /// Has the user already completed or skipped this flow?
    static func hasSeen(_ flow: GuidedFlow) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + flow.id)
    }

    /// Record that the flow has been shown, so it never presents again.
    static func markSeen(_ flow: GuidedFlow) {
        UserDefaults.standard.set(true, forKey: keyPrefix + flow.id)
    }

    /// Should this flow present now? Forced under `REM_SHOW_GUIDED`; otherwise
    /// only the first time it's encountered.
    static func shouldPresent(_ flow: GuidedFlow) -> Bool {
        forceShow || !hasSeen(flow)
    }

    /// Debug reset — clear every seen flag so all guided flows re-present. Wire to
    /// a debug menu, or call from the LLDB console: `expr GuidedFlowState.resetAll()`.
    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Anchor preference

/// Collects the frame of every `.guidedAnchor(id)` target, keyed by id, so the
/// overlay can spotlight a specific control BY NAME rather than a passed frame.
struct GuidedAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tag this view as a guided-flow target; the overlay spotlights it by `id`.
    /// Uses `.anchorPreference` so the frame is resolved in the overlay's own
    /// coordinate space, following the view as it lays out.
    func guidedAnchor(_ id: String) -> some View {
        anchorPreference(key: GuidedAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// Optional variant: tag as a guided-flow target only when `id` is non-nil.
    /// Handy when a target is one of several repeated views (e.g. only the first
    /// card in a list should be anchored).
    @ViewBuilder
    func guidedAnchor(ifPresent id: String?) -> some View {
        if let id {
            guidedAnchor(id)
        } else {
            self
        }
    }

    /// Present `flow` as a coach-mark sequence over this view. On first appear (or
    /// always, under `REM_SHOW_GUIDED`) it dims the screen, spotlights the current
    /// step's target, and shows a tooltip. `enabled` gates the whole thing so a
    /// screen can present the flow only in the right context, and — because it is
    /// observed for changes — doubles as an imperative on-demand trigger (flip it
    /// true to present now, false to dismiss).
    func guidedFlow(_ flow: GuidedFlow, enabled: Bool = true, onFinish: (() -> Void)? = nil) -> some View {
        modifier(GuidedFlowModifier(flow: flow, enabled: enabled, onFinish: onFinish))
    }
}

// MARK: - Overlay driver

/// Drives one flow's presentation: reads the collected anchors, tracks the
/// current step, advances/finishes, and records "seen" on completion.
private struct GuidedFlowModifier: ViewModifier {
    let flow: GuidedFlow
    let enabled: Bool
    /// Called when the flow finishes (last step advanced or skipped), so a host
    /// that triggered it on demand can reset its trigger state.
    var onFinish: (() -> Void)? = nil

    /// nil = not presenting; otherwise the index of the visible step.
    @State private var stepIndex: Int?
    /// Guards against re-arming the flow if the view re-appears mid-session.
    @State private var didArm = false

    func body(content: Content) -> some View {
        content
            // Imperative trigger: when `enabled` flips true (e.g. a Getting-started
            // card deep-links into this tab), present the flow regardless of
            // first-use state; flipping false dismisses it.
            .onChange(of: enabled) { _, isEnabled in
                if isEnabled {
                    forcePresent()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { stepIndex = nil }
                }
            }
            .overlayPreferenceValue(GuidedAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let stepIndex, stepIndex < flow.steps.count {
                        let step = flow.steps[stepIndex]
                        GuidedCoachMarkView(
                            step: step,
                            stepNumber: stepIndex + 1,
                            stepCount: flow.steps.count,
                            targetRect: anchors[step.id].map { proxy[$0] },
                            onNext: advance,
                            onSkip: finish
                        )
                        .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
            }
            .onAppear(perform: arm)
    }

    /// First-use trigger. Waits a beat so the target views lay out and register
    /// their anchors before the spotlight is computed, then presents step 0.
    private func arm() {
        guard enabled, !didArm, !flow.steps.isEmpty,
              GuidedFlowState.shouldPresent(flow) else { return }
        didArm = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.25)) { stepIndex = 0 }
        }
    }

    /// On-demand present (host set `enabled` true intentionally), bypassing the
    /// first-use "seen" gate. No-op if a step is already showing.
    private func forcePresent() {
        guard enabled, !flow.steps.isEmpty, stepIndex == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.25)) { stepIndex = 0 }
        }
    }

    private func advance() {
        guard let current = stepIndex else { return }
        let next = current + 1
        if next < flow.steps.count {
            withAnimation(.easeInOut(duration: 0.2)) { stepIndex = next }
        } else {
            finish()
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.2)) { stepIndex = nil }
        GuidedFlowState.markSeen(flow)
        onFinish?()
    }
}

// MARK: - Coach-mark view

/// The visible coach-mark: a dimmed scrim with a spotlight cutout over the
/// target, plus a tooltip bubble with title, body, and Skip / Next-or-Got-it.
private struct GuidedCoachMarkView: View {
    let step: GuidedStep
    let stepNumber: Int
    let stepCount: Int
    /// Target frame in the overlay's coordinate space; nil → center the tooltip
    /// with no spotlight (target hasn't laid out or was removed).
    let targetRect: CGRect?
    let onNext: () -> Void
    let onSkip: () -> Void

    // Structural constants mapped to shared tokens where a clean match exists.
    private let spotlightPadding = DesignTokens.Spacing.sm      // 8
    private let spotlightCorner = DesignTokens.CornerRadius.medium // 12

    private var spotlightRect: CGRect? {
        targetRect?.insetBy(dx: -spotlightPadding, dy: -spotlightPadding)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Dimmed scrim with a cutout over the target. Tapping the scrim
                // advances — natural for a one-tap tip.
                scrim
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNext)

                // A brand ring around the highlighted element (non-interactive so
                // it never eats the tap meant for the real control underneath).
                if let rect = spotlightRect {
                    RoundedRectangle(cornerRadius: spotlightCorner, style: .continuous)
                        .stroke(DesignTokens.Color.brandBlue, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                tooltip
                    .frame(maxWidth: 340)
                    .position(tooltipPosition(in: proxy.size))
            }
        }
    }

    // Neutral dimming scrim. Black-at-55% is a universal overlay dim, not a brand
    // color, so it stays a literal rather than a palette token.
    private let scrimDim = Color.black.opacity(0.55)

    @ViewBuilder
    private var scrim: some View {
        if let rect = spotlightRect {
            Rectangle()
                .fill(scrimDim)
                .reverseMask {
                    RoundedRectangle(cornerRadius: spotlightCorner, style: .continuous)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
        } else {
            Rectangle().fill(scrimDim)
        }
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm + 2) {
            if stepCount > 1 {
                Text("Step \(stepNumber) of \(stepCount)")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.brandBlue)
            }
            Text(step.title)
                // 17pt semibold == the system `.headline` role the source used.
                .font(DesignTokens.Typography.body.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Text(step.message)
                .font(DesignTokens.Typography.subheadline)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip", action: onSkip)
                    .font(DesignTokens.Typography.subheadline)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Spacer()
                Button(action: onNext) {
                    Text(stepNumber == stepCount ? "Got it" : "Next")
                        .font(DesignTokens.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .background(DesignTokens.Color.brandBlue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        // SOLID/opaque bubble: a translucent material lets the surface behind bleed
        // through and kills contrast. Use the primary background so nothing shows
        // through, keeping the rounded shape + shadow.
        .background(
            DesignTokens.Color.backgroundPrimary,
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge, style: .continuous)
                .stroke(DesignTokens.Color.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(.horizontal, 20)
    }

    /// Place the tooltip above the target when there's room, else below, else
    /// center. A height estimate is fine for the proof; a production version
    /// would measure the bubble.
    private func tooltipPosition(in screen: CGSize) -> CGPoint {
        guard let rect = targetRect else {
            return CGPoint(x: screen.width / 2, y: screen.height / 2)
        }
        let estimatedHeight: CGFloat = 180
        let margin: CGFloat = 16
        let x = screen.width / 2

        let aboveCenter = rect.minY - margin - estimatedHeight / 2
        if aboveCenter - estimatedHeight / 2 > margin {
            return CGPoint(x: x, y: aboveCenter)
        }
        let belowCenter = rect.maxY + margin + estimatedHeight / 2
        return CGPoint(x: x, y: min(belowCenter, screen.height - estimatedHeight / 2 - margin))
    }
}

// MARK: - Reverse mask helper

private extension View {
    /// Punch the `mask` shape OUT of this view (the spotlight cutout), rather than
    /// keeping only what the mask covers.
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

// MARK: - DEBUG demo / fixture

#if DEBUG
/// Standalone demo that proves the engine renders end to end: a dimmed scrim, a
/// spotlight cutout around one anchored control, and a Step X/Y tooltip bubble
/// with Skip/Next. This is a FIXTURE, not real onboarding — reached via the
/// `--rem-guided-flow-fixture` launch arg (see `RemClaw/RemClawApp.swift`) so it
/// can be driven on a simulator past the auth gate. Presenting the flow through
/// the `enabled` flip (rather than the seen-ledger) makes it re-show on every
/// launch regardless of persisted state.
struct GuidedFlowFixtureView: View {
    private static let demoFlow = GuidedFlow(
        id: "guidedFlowDemo",
        steps: [
            GuidedStep(
                id: "demoPrimary",
                title: "Connect a source",
                message: "The scrim dims the screen and spotlights the real control. Tap Next to advance the coach-mark."
            ),
            GuidedStep(
                id: "demoSecondary",
                title: "Turn on notifications",
                message: "The cutout follows to the next anchored control. Tap Got it to finish, or Skip to dismiss."
            ),
        ]
    )

    @State private var enabled = false
    @State private var finished = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Guided Flow demo")
                    .font(DesignTokens.Typography.title3Bold)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                Text(finished
                     ? "Flow finished. Relaunch the fixture to see it again."
                     : "A DEBUG fixture for the coach-mark engine (#1373).")
                    .font(DesignTokens.Typography.subheadline)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // The two anchored controls the demo flow spotlights, in order.
            VStack(spacing: DesignTokens.Spacing.md) {
                Button {
                } label: {
                    Label("Connect a source", systemImage: "link")
                        .font(DesignTokens.Typography.body.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.md)
                        .background(DesignTokens.Color.brandBlue,
                                    in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .guidedAnchor("demoPrimary")

                Button {
                } label: {
                    Label("Turn on notifications", systemImage: "bell.badge")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.md)
                        .background(DesignTokens.Color.backgroundSecondary,
                                    in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .guidedAnchor("demoSecondary")
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.xxl)
        }
        .padding(.top, DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary)
        .guidedFlow(Self.demoFlow, enabled: enabled) {
            finished = true
        }
        // Present on appear via the imperative `enabled` trigger so the fixture
        // re-shows every launch, independent of the seen-ledger.
        .onAppear { enabled = true }
    }
}

#Preview("Guided Flow") {
    GuidedFlowFixtureView()
}
#endif
