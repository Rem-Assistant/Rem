import SwiftUI

extension Image {
    /// The one place the UIImage/NSImage fork lives for this feature.
    init(browser platformImage: BrowserPlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// A pointer drawn over the live frame so the user can watch the agent (or their own touches)
/// move and click. A soft dot with a ring that pulses on press — enough to read as "the cursor
/// is here / it just clicked" without obscuring the page.
struct RemoteCursor: View {
    let isDown: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Color.brandBlue.opacity(0.9))
                .frame(width: 12, height: 12)
            Circle()
                .stroke(DesignTokens.Color.brandBlue.opacity(0.7), lineWidth: 2)
                .frame(width: isDown ? 34 : 20, height: isDown ? 34 : 20)
                .opacity(isDown ? 0.9 : 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDown)
        .accessibilityHidden(true)
    }
}

// MARK: - The surface

/// The live picture of Rem's browser, and the thing you drive it with.
///
/// A plain SwiftUI `Image` on purpose. An earlier draft rendered the frames onto a `<canvas>`
/// inside a WKWebView, which cost us two things that matter: a canvas is not an accessibility
/// element (invisible to VoiceOver, and untappable by XCUITest — so the single most important
/// interaction in this feature could not be tested at all), and a WKWebView wrapper is UIKit,
/// which would have kept this view off the Mac. This is a real view: testable, and shared.
struct BrowserLiveSurface: View {
    @Bindable var session: BrowserLiveSession

    /// Distinguishes a tap from a pan, and tracks the pan so we can send wheel deltas.
    @State private var isPanning = false
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        if let frame = session.frame {
            // Hug the frame's aspect ratio — full width, proportional height — so there are no
            // black letterbox bars. The gesture rides an overlay that matches the image bounds
            // exactly, so its geometry has no letterbox offset to correct for.
            Image(browser: frame)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    GeometryReader { geo in
                        // The image hugs its frame (no letterbox), so geo.size is the image, and
                        // the normalised cursor maps straight onto it.
                        if let cursor = session.cursor {
                            RemoteCursor(isDown: cursor.isDown)
                                .position(x: cursor.point.x * geo.size.width,
                                          y: cursor.point.y * geo.size.height)
                                .allowsHitTesting(false)
                                .animation(.easeOut(duration: 0.12), value: cursor.point)
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(session.isControlling ? drag(in: geo.size) : nil)
                    }
                }
                .accessibilityLabel(session.hasEnded
                    ? "Last view of Rem's ended browser session"
                    : "Live view of Rem's browser")
                .accessibilityHint(session.hasEnded
                    ? "This browser session has ended."
                    : (session.isControlling
                        ? "You have the controls. Double-tap to tap the page."
                        : "Rem has the controls. Take over to interact."))
        }
    }

    /// One gesture, two meanings — decided by whether the finger moved.
    ///
    /// A short press is a CLICK (press+release at one point, which is exactly what Chromium
    /// needs to synthesise `click`). A drag is a SCROLL, sent as wheel deltas, because on a
    /// phone dragging means scrolling and a login form's button is usually below the fold.
    /// Mapping drag to `mouseMoved` instead — as the first version did — meant the page could
    /// not be scrolled at all, which is the difference between "the transport works" and "you
    /// can log in".
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let travel = hypot(value.translation.width, value.translation.height)
                if !isPanning && travel > Self.panThreshold { isPanning = true }
                guard isPanning else { return }
                // Deltas, not absolutes: wheel events are incremental. Inverted so the content
                // follows the finger, as it does everywhere else on the phone.
                let dx = value.translation.width - lastTranslation.width
                let dy = value.translation.height - lastTranslation.height
                lastTranslation = value.translation
                session.scroll(at: normalise(value.location, in: size), by: CGSize(width: -dx, height: -dy))
            }
            .onEnded { value in
                if !isPanning {
                    session.tap(at: normalise(value.location, in: size))
                }
                isPanning = false
                lastTranslation = .zero
            }
    }

    /// Below this, the finger hasn't moved enough to mean "scroll" — it's a tap. Matches the
    /// slop UIKit uses before it calls a touch a pan.
    private static let panThreshold: CGFloat = 10

    /// The image is aspect-fit inside the view, so the letterboxed margins are NOT part of the
    /// page — mapping the raw view coords would put every tap in the wrong place.
    private func normalise(_ location: CGPoint, in size: CGSize) -> CGPoint {
        let viewport = session.viewport
        guard viewport.width > 0, viewport.height > 0, size.width > 0, size.height > 0 else {
            return .init(x: 0.5, y: 0.5)
        }
        let scale = min(size.width / viewport.width, size.height / viewport.height)
        let drawn = CGSize(width: viewport.width * scale, height: viewport.height * scale)
        let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        return CGPoint(
            x: (location.x - origin.x) / drawn.width,
            y: (location.y - origin.y) / drawn.height
        )
    }
}

// MARK: - Collapsed

/// The affordance in chat: an active session can be watched or taken over until it explicitly ends.
struct BrowserLiveCard: View {
    @Bindable var session: BrowserLiveSession
    /// When the session has ENDED (the user or the agent closed it), the card is a historical
    /// record that reopens onto the frozen last frame without a transport connection. Passed
    /// per-conversation so a global end never mislabels an unrelated chat's active card.
    var ended: Bool = false
    /// Explicit attachment intent renders immediately, before a real browser tool start. Until that
    /// structured event transfers ownership, opening the shared browser could expose another chat's
    /// retained page, so the card remains visible but temporarily non-interactive.
    var isReadyToPresent: Bool = true

    var body: some View {
        Button {
            guard ended || isReadyToPresent else { return }
            ended ? session.presentEnded() : session.present()
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rem's browser session")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                    Text(ended
                         ? "Session ended · tap to review"
                         : (isReadyToPresent ? "Session active · tap to watch or take over" : "Opening browser…"))
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(
                // Solid (opaque) fill so the transcript doesn't read through the card now that it sits
                // directly over the chat with no outer backdrop. `backgroundSecondary` is opaque on
                // BOTH platforms (secondarySystemBackground / controlBackgroundColor) — unlike
                // `pillBackground`, which is translucent on macOS.
                DesignTokens.Color.backgroundSecondary,
                in: .rect(cornerRadius: DesignTokens.CornerRadius.medium)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            ended
                ? "Rem's browser session ended. Tap to review."
                : (isReadyToPresent
                   ? "Rem's browser session is active. Tap to watch or take over."
                   : "Rem is opening a browser.")
        )
    }

    /// A rectangular still of the live frame — the same pixels, just small.
    private var preview: some View {
        ZStack {
            DesignTokens.Color.pillBackground
            if isReadyToPresent, let frame = session.frame {
                Image(browser: frame).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .frame(width: 56, height: 40)
        .clipShape(.rect(cornerRadius: DesignTokens.CornerRadius.small))
        .accessibilityHidden(true)
    }
}

// MARK: - Expanded

/// Full-screen: watch, and take over.
///
/// No scrubber and no "jump to live": this is a live stream, not a recording — we keep no frame
/// history, so those controls would be lying. It is always live, and says so.
struct SharedBrowserLiveSheet: View {
    @Bindable var session: BrowserLiveSession
    var onClose: () -> Void

    /// Mirrors the focused remote field. Edited natively (delete/cursor/paste), pushed back on
    /// every change. Never logged, never sent to the model — it rides the already-authenticated
    /// wrapper socket straight to CDP, and passwords are redacted on that wire.
    @State private var editorText = ""

    /// Drives the iOS keyboard for the editor. Tapping a remote field focuses it there; this
    /// makes the LOCAL editor focus at the same moment, so one tap both activates the remote
    /// field and raises the keyboard — the two cursors come alive together.
    @FocusState private var editorFocused: Bool

    /// Guards the "End" action — ending stops what the agent is doing, so it confirms first.
    @State private var showEndConfirm = false

    var body: some View {
        GeometryReader { geo in
            NavigationStack {
                Group {
                    if session.hasEnded {
                        // Review-only: keep the last locally observed frame and never reconnect an
                        // ended card merely to manufacture a preview.
                        frozen(title: "This browser session has ended",
                               detail: session.frame == nil
                                   ? "No preview was retained."
                                   : "This is the last thing it was showing.",
                               showRetry: false)
                    } else {
                        switch session.phase {
                        case .live:
                            // No Spacer, no maxHeight fill — the content hugs its own height so the
                            // sheet (sized to that height below) has no blank space under it.
                            VStack(spacing: 0) {
                                addressBar
                                BrowserLiveSurface(session: session)
                                controlBar
                            }
                            .frame(maxWidth: .infinity)
                        case .waking, .idle:
                            waking.frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .failed(let message):
                            // A drop AFTER pixels: keep the last frame and offer a retry, same size
                            // as live, instead of a blank error card. Only fall back to the plain
                            // error when there is no frame to freeze on.
                            if session.frame != nil {
                                frozen(title: "Rem's browser disconnected", detail: message, showRetry: true)
                            } else {
                                failure(message).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .navigationTitle("Rem's browser")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                    // "Done" hides the sheet but leaves Rem's browser running; "End" (top-right,
                    // where the Live badge is deliberately NOT — a toolbar item on iOS 26 gets its
                    // own glass capsule) stops what the agent is doing and closes. Only while live.
                    ToolbarItem(placement: .primaryAction) {
                        if session.phase == .live {
                            Button("End", role: .destructive) { showEndConfirm = true }
                        }
                    }
                }
                .confirmationDialog("End Rem's browser session?",
                                    isPresented: $showEndConfirm, titleVisibility: .visible) {
                    Button("End session", role: .destructive) {
                        session.endByUser() // pause the agent (chat.abort); onClose tears down the stream
                        onClose()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This stops what Rem is doing in the browser and closes this view.")
                }
            }
            // A solid sheet, not the default translucent material: on recent iOS the material let
            // the chat glass through in the bottom safe area. Match the control bar so the sheet
            // reads as one opaque surface from the address row down through the home indicator.
            .presentationBackground(DesignTokens.Color.backgroundSecondary)
            #if os(iOS)
            // Size the sheet to its content — a short sheet that hugs the frame — rather than a
            // full-height sheet with blank space below. `.large` stays available so the user can
            // pull it up. Recomputed as the frame's shape, control state, or keyboard changes.
            // The frozen ended/disconnected states keep the same hugging size, not a tall blank.
            .presentationDetents(showsSizedSheet ? [.height(sheetHeight(width: geo.size.width)), .large] : [.large])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    #if os(iOS)
    /// Whether the sheet sizes itself to its content (a short hugging sheet) rather than defaulting
    /// to `.large`. True while live, and for the frozen ended/disconnected stills so they don't
    /// jump to a tall blank.
    private var showsSizedSheet: Bool {
        if session.hasEnded { return true }
        if session.phase == .live { return true }
        if case .failed = session.phase { return session.frame != nil }
        return false
    }

    /// Content height ≈ nav bar + address bar + the frame drawn at this width + the control bar
    /// (taller while editing a field). Sized off the frame's own aspect ratio, so a landscape
    /// page yields a short sheet and a portrait one a taller sheet — responsive to what's shown.
    private func sheetHeight(width: CGFloat) -> CGFloat {
        let aspect = session.viewport.width > 0 ? session.viewport.height / session.viewport.width : 0.62
        let image = width * aspect
        // caption + full-width CTA (~96); while controlling, add the 52pt input area + divider
        // above it (constant height whether it shows a placeholder or an active field). The frozen
        // states show a shorter status bar (a line or two, plus a retry button when offered).
        let controls: CGFloat
        if session.isControlling { controls = 178 }
        else if session.hasEnded { controls = 84 }
        else if case .failed = session.phase { controls = 108 }
        else { controls = 96 }
        let chrome: CGFloat = 52 /* nav */ + 40 /* address */ + controls + 24 /* padding */
        return min(image + chrome, geoHeightCap)
    }

    /// Never let the computed sheet exceed a near-full screen, whatever the frame reports.
    private var geoHeightCap: CGFloat { 900 }
    #endif

    /// Where the remote browser actually is, reported by Chromium.
    ///
    /// Read-only: this is evidence, not navigation. The host is emphasised and the rest is
    /// dimmed, because the host is the part that answers "am I really on Discord?" — a long
    /// URL with a convincing path is the oldest trick there is.
    private var addressBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // The URL sits in its own filled pill — a distinct gray on top of the sheet's
            // `backgroundSecondary` — so it reads as an address field rather than blending into
            // the surrounding chrome. The "Live" badge stays OUTSIDE the pill, to its right.
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: session.currentURL?.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(session.currentURL?.scheme == "https"
                        ? DesignTokens.Color.labelSecondary
                        : DesignTokens.Color.systemOrange)
                Group {
                    if let url = session.currentURL, let host = url.host() {
                        // The host never truncates and the path does. A long path that pushes the
                        // host off the end is exactly how a lookalike would hide, so the part that
                        // answers "where am I really?" is the part that always survives.
                        HStack(spacing: 0) {
                            Text(host)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                                .fixedSize(horizontal: true, vertical: false)
                            Text(url.path())
                                .foregroundStyle(DesignTokens.Color.labelTertiary)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text("about:blank").foregroundStyle(DesignTokens.Color.labelTertiary)
                    }
                }
                .font(DesignTokens.Typography.caption1)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.Color.fillTertiary, in: .rect(cornerRadius: DesignTokens.CornerRadius.small))

            // Only when actually streaming — a frozen/ended still is not "Live".
            if session.phase == .live { liveBadge }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Color.backgroundSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.currentURL.map {
            "Page address: \($0.host() ?? $0.absoluteString), \(session.hasEnded ? "ended" : "live")"
        } ?? "No page loaded, \(session.hasEnded ? "ended" : "live")")
    }

    /// Takeover is explicit in both directions, so it is always unambiguous who has the mouse.
    ///
    /// While you hold the controls this also carries the keyboard. The page is a picture, so the
    /// system keyboard has nothing to focus. Instead: tap a field in the image (that focuses it
    /// remotely), and its contents mirror into the native editor below — where delete, cursor,
    /// selection and paste all work, and every edit is pushed back to the remote field. That is
    /// what makes editing and deleting easy, versus poking a remote cursor with append+backspace.
    @ViewBuilder
    private var controlBar: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            // Input FIRST: while you hold the controls this area mirrors whatever field you tap in
            // the page (placeholder until you pick one). It sits above the CTA because you reach
            // for the field before you decide to hand control back — inputs before buttons reads
            // more naturally. A divider sets it apart from the takeover row. Hidden while Rem
            // drives; there is nothing to edit until you take over.
            if session.isControlling {
                fieldEditor
                Divider()
            }

            // Takeover: a caption over the app's standard full-width CTA, so passing the mouse
            // back and forth reads like every other primary action in the app instead of a
            // one-off inline button crammed next to a label.
            VStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                Text(session.isHandBackPending
                    ? "Checking your plan…"
                    : (session.isControlling ? "You have the controls" : "Rem is driving"))
                    .font(DesignTokens.Typography.subheadline)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button(session.isHandBackPending
                    ? "Checking…"
                    : (session.isControlling ? "Give control back to Rem" : "Take control")) {
                    if session.isControlling { session.handBack() } else { session.takeControl() }
                }
                .remPrimaryActionButton()
                .disabled(session.isHandBackPending)
                .accessibilityLabel(session.isHandBackPending
                    ? "Giving control back to Rem"
                    : (session.isControlling ? "Give control back to Rem" : "Take control"))
                .accessibilityHint(session.isHandBackPending
                    ? "Rem is reserving and accepting the continuation turn."
                    : (session.handBackErrorText == nil
                        ? ""
                        : "The handoff did not finish. Activate to try again."))

                if let handBackErrorText = session.handBackErrorText {
                    Text(handBackErrorText)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.systemRed)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Color.backgroundSecondary)
        // Seed the editor when a NEW field is tapped; clear it when focus goes away. This assigns
        // `editorText` DIRECTLY (not via `fieldText`), so seeding never echoes back onto the remote
        // field. Also raise the keyboard the instant a field is focused, so tapping it activates
        // the editor too — otherwise the remote cursor blinks while yours stays asleep.
        .onChange(of: session.focusedField) { _, field in
            editorText = field?.value ?? ""
            // Raise the keyboard for a text field, but not for a <select> (it uses a menu, not
            // the keyboard).
            editorFocused = field != nil && field?.options == nil
        }
    }

    /// Binding that pushes to the remote field ONLY on a user edit. The programmatic seed (when a
    /// new field is tapped) assigns `editorText` directly — bypassing this setter — so it can't
    /// echo the seeded value straight back onto the field the tap just moved focus to.
    private var fieldText: Binding<String> {
        Binding(
            get: { editorText },
            set: { newValue in
                guard newValue != editorText else { return }
                editorText = newValue
                session.setFocusedValue(newValue)
            }
        )
    }

    /// One field-height so the input feels as substantial as the CTA beneath it, rather than a
    /// thin control dwarfed by the button.
    private let fieldHeight: CGFloat = 52

    @ViewBuilder
    private var fieldEditor: some View {
        if let field = session.focusedField, let options = field.options {
            // A <select>: offer a native menu of its options (the OS dropdown popup would be
            // invisible in the screencast). Picking one sets it in the remote page.
            Menu {
                ForEach(options) { option in
                    Button(option.label) { session.selectOption(option.value) }
                }
            } label: {
                HStack {
                    Text(options.first(where: { $0.value == field.value })?.label ?? "Choose…")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, minHeight: fieldHeight, alignment: .leading)
                .background(DesignTokens.Color.fillTertiary, in: .rect(cornerRadius: DesignTokens.CornerRadius.medium))
            }
            .accessibilityLabel("Choose an option for the dropdown")
        } else if let field = session.focusedField {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Group {
                    if field.isSecure {
                        SecureField("Password", text: fieldText)
                    } else {
                        TextField("Edit this field", text: fieldText)
                    }
                }
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused($editorFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.go)
                .onSubmit { session.pressKey("Enter") }
                .accessibilityLabel(field.isSecure ? "Edit the password field" : "Edit the focused field")

                Button { session.pressKey("Enter") } label: {
                    Image(systemName: "return")
                }
                .font(DesignTokens.Typography.body)
                .accessibilityLabel("Press Return in the page")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(minHeight: fieldHeight)
            .background(DesignTokens.Color.fillTertiary, in: .rect(cornerRadius: DesignTokens.CornerRadius.medium))
        } else {
            // The "before" state: plain helper text, NOT a filled pill — only a real field gets the
            // container, so the placeholder can't be mistaken for an empty input. Kept at the field
            // height so the area doesn't resize under the divider when a field is picked.
            Text("Tap a field on the page to edit it here")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .frame(maxWidth: .infinity, minHeight: fieldHeight, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.md)
        }
    }

    /// A tight pill, not a loose dot-and-word floating in the toolbar: a red dot + "Live" on a
    /// faint red capsule with compact padding, so it reads as one intentional badge and matches
    /// the snug padding of the buttons rather than sprawling across the nav bar.
    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(DesignTokens.Color.systemRed).frame(width: 6, height: 6)
            Text("Live")
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 3)
        .background(DesignTokens.Color.systemRed.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live")
    }

    private var waking: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text("Waking Rem's browser…")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            // Honest about the cold start rather than a spinner that implies something's wrong.
            Text("This can take a minute if Rem hasn't been busy.")
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
    }

    /// A frozen still of the last frame with a status bar where the controls would be. Same shape
    /// and size as the live sheet, so ending or dropping doesn't collapse it to a blank error —
    /// used for "session ended" (agent closed it) and "disconnected" (offer a retry).
    private func frozen(title: String, detail: String, showRetry: Bool) -> some View {
        VStack(spacing: 0) {
            addressBar
            BrowserLiveSurface(session: session)
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(DesignTokens.Typography.subheadline)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Text(detail)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .multilineTextAlignment(.center)
                if showRetry {
                    Button("Try again") { session.start() }
                        .font(DesignTokens.Typography.footnote)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.md)
            .background(DesignTokens.Color.backgroundSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Rem's browser", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { session.start() }
        }
    }
}
