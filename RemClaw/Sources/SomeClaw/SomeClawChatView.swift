import SwiftUI

#if DEBUG

/// Debug-only chat surface for the SomeClaw relay (#94). Intentionally
/// minimalist: bubbles, thinking dots, and a one-line composer. Reuses
/// the standard system fonts/colors instead of `DesignTokens` so we can
/// drop the screen later without ripping anything out of production code.
struct SomeClawChatView: View {

    @Bindable var viewModel: SomeClawChatViewModel

    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .navigationTitle("SomeClaw")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Session") {
                        Task { await viewModel.startNewSession() }
                    }
                    Button("Clear (local only)") {
                        viewModel.clearLocally()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if viewModel.isThinking {
                        ThinkingIndicator()
                            .id("thinking")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isThinking) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if viewModel.isThinking {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
        } else if let last = viewModel.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Message SomeClaw…", text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .focused($composerFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .submitLabel(.send)
                .onSubmit { sendDraft() }

            Button {
                sendDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.client.connectionState == .connected
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await viewModel.send(text) }
    }
}

private struct MessageBubble: View {
    let message: SomeClawChatViewModel.Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            content
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var content: some View {
        Text(message.text.isEmpty && message.isStreaming ? " " : message.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(textColor)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: alignment)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var background: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return Color(.secondarySystemBackground)
        case .errorEvent: return Color.red.opacity(0.15)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return Color(.label)
        case .errorEvent: return Color.red
        }
    }
}

private struct ThinkingIndicator: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .opacity(opacity(for: index))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { animate() }
    }

    private func opacity(for index: Int) -> Double {
        let cycle = phase + Double(index) * 0.33
        let value = sin(cycle * .pi * 2)
        return 0.3 + (value + 1) / 2 * 0.7
    }

    private func animate() {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

#endif
