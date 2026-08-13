import SwiftUI

/// The Rem "Grok-style" composer **shell** — a vertically-growing text field
/// inside a rounded `.ultraThinMaterial` pill, with a bottom control row
/// (leading affordance · spacer · trailing affordance · send button) and an
/// optional attachments strip on top.
///
/// Extracted from `SharedRemChatView.composerBar` so the chat input and the task
/// **comment** input render the same component (DRY rule; Decision Principle 1 —
/// reuse an existing pattern). The chat composer's *logic* was too coupled to
/// `OpenClawChatViewModel` (send / abort / quota / attachments / sessions /
/// thinking) to reuse directly, so only the **presentation** is shared here:
/// every interactive affordance is injected by the host via a `@ViewBuilder`
/// slot.
///
/// - chat host     → leading: Think + Speak (sibling pills) · send: chat send/abort
/// - activity host → attachments: "Replying to …" banner · send: post reply
///   (the activity composer keeps the leading/trailing slots empty — its
///   "Ask Rem to work on this" CTA lives up in the Activity log, not the pill)
struct RemComposerBar<Attachments: View, Leading: View, Trailing: View, Send: View>: View {
    @Binding var text: String
    var placeholder: String
    var lineLimit: ClosedRange<Int> = 1...5
    var font: Font = DesignTokens.Typography.chatMessage

    /// Optional focus binding. When supplied, the field binds to it and (on iOS)
    /// a downward drag inside the composer resigns focus to dismiss the keyboard.
    var focus: FocusState<Bool>.Binding?

    var onSubmit: () -> Void

    var attachments: () -> Attachments
    var leading: () -> Leading
    var trailing: () -> Trailing
    var send: () -> Send

    /// Explicit init so the four view slots get `@ViewBuilder` — the synthesized
    /// memberwise initializer does NOT propagate the builder attribute, which
    /// would reject multi-statement / `if` closures (e.g. the chat attachments
    /// strip and Speak pill).
    init(
        text: Binding<String>,
        placeholder: String,
        lineLimit: ClosedRange<Int> = 1...5,
        font: Font = DesignTokens.Typography.chatMessage,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: @escaping () -> Void,
        @ViewBuilder attachments: @escaping () -> Attachments,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder send: @escaping () -> Send
    ) {
        self._text = text
        self.placeholder = placeholder
        self.lineLimit = lineLimit
        self.font = font
        self.focus = focus
        self.onSubmit = onSubmit
        self.attachments = attachments
        self.leading = leading
        self.trailing = trailing
        self.send = send
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            // Bleed the attachments strip out of the composer's `md` content
            // inset so thumbnails align to the pill edge instead of sitting
            // doubly-indented inside the text field's padded column. The host's
            // strip re-adds a small leading inset of its own.
            attachments()
                .padding(.horizontal, -DesignTokens.Spacing.md)

            editorField

            HStack(spacing: DesignTokens.Spacing.sm) {
                leading()
                Spacer()
                trailing()
                send()
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 30))
        #if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onChanged { value in
                    if value.translation.height > 12 {
                        focus?.wrappedValue = false
                    }
                }
        )
        #endif
    }

    /// Height of one line of `font`, measured from a hidden probe so the fade gate is
    /// Dynamic-Type-safe rather than assuming a fixed point size.
    @State private var lineHeight: CGFloat = 0
    /// Current rendered height of the growing field.
    @State private var fieldHeight: CGFloat = 0

    /// True once the field has grown to (near) its max line count and is therefore scrolling
    /// internally — only then do we fade the top/bottom edges. Below that a fade would clip the
    /// single/few visible lines.
    private var isScrollable: Bool {
        lineHeight > 0 && fieldHeight >= lineHeight * (CGFloat(lineLimit.upperBound) - 0.5)
    }

    @ViewBuilder
    private var editorField: some View {
        let field = TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(lineLimit)
            .font(font)
            .padding(.top, 4)
            .textFieldStyle(.plain)
            .onSubmit(onSubmit)

        let focused: some View = {
            if let focus {
                return AnyView(field.focused(focus))
            } else {
                return AnyView(field)
            }
        }()

        focused
            // Measure one line (hidden probe) and the field's current height.
            .overlay(alignment: .topLeading) {
                Text("Ag")
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ComposerLineHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ComposerFieldHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ComposerLineHeightKey.self) { lineHeight = $0 }
            .onPreferenceChange(ComposerFieldHeightKey.self) { fieldHeight = $0 }
            // Gradient-clip the top/bottom edges once the field scrolls, mirroring the chat's
            // vertical fades. `inset == 0` when not scrolling makes the mask fully opaque (no clip).
            .mask(verticalEdgeMask)
    }

    private var verticalEdgeMask: some View {
        let inset: CGFloat = isScrollable ? 12 : 0
        return VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: inset)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: inset)
        }
    }
}

private struct ComposerLineHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct ComposerFieldHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
