import SwiftUI

/// First-run conversational capture — the first beat of the "orient the human" loop
/// (`docs/product/VISION.md`). After auth + gateway setup, Rem asks a few orienting
/// questions (what to call you, what you're working on, your top priority) and **persists
/// the answers into the user's memory** (`/api/v1/memory`, `source="onboarding"`) so the
/// agent remembers them going forward and they appear under Settings → Memory.
///
/// Deliberate divergence from OpenClaw's gateway-only setup onboarding: upstream stops at
/// "device paired"; Rem keeps going to learn enough to orient the person.
///
/// ## Stateful flow (CLAUDE.md principle 3)
/// - **Source of truth**: the backend `user_memory` table (via `MemoryProviding`). The
///   `rem.hasCompletedConversationalCapture.v1` UserDefaults sentinel is the *local* gate
///   that this one-time step has been shown.
/// - **Transitions**: ask → user answers/skips each question → on finish, every non-empty
///   answer is POSTed as a fact with `source="onboarding"`, then the sentinel flips and the
///   sheet dismisses.
/// - **Recovery**: a failed POST surfaces inline; the user can retry or skip. The sentinel
///   only flips once we reach the end (skipping the whole flow also flips it — it's optional,
///   not mandatory), so a crash mid-flow re-presents it next launch.
/// - **Non-goals**: editing/curating facts here (that's Settings → Memory), and auto-capture
///   from chat (the scheduled extractor, `source="auto"`).
struct ConversationalCaptureView: View {
    /// Injected so previews can pass `MockMemoryService`. Defaults to the live backend service.
    let service: any MemoryProviding
    /// Preferred name from the auth profile, used to greet the user.
    let greetingName: String?
    /// Called when the flow finishes (completed or skipped) — the caller flips the sentinel.
    let onFinish: () -> Void

    init(
        service: (any MemoryProviding)? = nil,
        greetingName: String? = nil,
        onFinish: @escaping () -> Void
    ) {
        // MemoryService() is @MainActor-isolated, so default it in the init body
        // (mirrors SharedMemorySettingsView's injection pattern).
        self.service = service ?? MemoryService()
        self.greetingName = greetingName
        self.onFinish = onFinish
    }

    // MARK: Questions

    /// A single orienting question and how its answer becomes a durable memory fact.
    private struct Question: Identifiable {
        let id: String
        let prompt: String
        let placeholder: String
        /// Turns a trimmed, non-empty answer into the fact stored in memory.
        let makeFact: (String) -> String
    }

    private static let questions: [Question] = [
        Question(
            id: "name",
            prompt: "First, what should I call you?",
            placeholder: "e.g. Sam",
            makeFact: { "Prefers to be called \($0)." }
        ),
        Question(
            id: "working_on",
            prompt: "What are you working on right now?",
            placeholder: "e.g. Launching a new app this summer",
            makeFact: { "Currently working on: \($0)." }
        ),
        Question(
            id: "priority",
            prompt: "And what's your top priority this week?",
            placeholder: "e.g. Ship the beta and line up 5 testers",
            makeFact: { "Top priority right now: \($0)." }
        ),
    ]

    // MARK: State

    /// Index of the question currently being asked.
    @State private var index = 0
    /// The answer the user is typing for the current question.
    @State private var draft = ""
    /// Captured (questionID, fact) pairs, in order, for the running transcript + final save.
    @State private var captured: [(id: String, answer: String, fact: String)] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private var currentQuestion: Question { Self.questions[index] }
    private var isLastQuestion: Bool { index == Self.questions.count - 1 }
    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                        header
                        transcript
                        currentPrompt
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.lg)
                }

                inputBar
            }
            .background(DesignTokens.Color.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { finish(persist: true) }
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .disabled(isSaving)
                        .accessibilityIdentifier("ConversationalCaptureSkipButton")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { inputFocused = true }
        .accessibilityIdentifier("ConversationalCaptureView")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            OnboardingLogoView()
            Text(greeting)
                .font(DesignTokens.Typography.title1Bold)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A couple of quick questions so I can keep what matters to you in mind. You can skip any of these.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var greeting: String {
        if let name = greetingName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "Hi \(name) — I'm Rem."
        }
        return "Hi — I'm Rem."
    }

    /// Already-answered questions + the user's replies, as a lightweight chat transcript.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            ForEach(Array(captured.enumerated()), id: \.element.id) { offset, entry in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    remBubble(Self.questions[offset].prompt)
                    userBubble(entry.answer)
                }
            }
        }
    }

    private var currentPrompt: some View {
        remBubble(currentQuestion.prompt)
            .id("prompt-\(currentQuestion.id)")
    }

    private func remBubble(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.Color.labelPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .fill(DesignTokens.Color.backgroundSecondary)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .fill(DesignTokens.Color.brandBlue)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var inputBar: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.systemRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField(currentQuestion.placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .focused($inputFocused)
                    .submitLabel(.next)
                    .onSubmit { advance() }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                            .fill(DesignTokens.Color.backgroundSecondary)
                    )
                    .disabled(isSaving)
                    .accessibilityIdentifier("ConversationalCaptureInput")

                Button { advance() } label: {
                    Image(systemName: isSaving ? "ellipsis" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolEffect(.pulse, isActive: isSaving)
                        .foregroundStyle(
                            trimmedDraft.isEmpty
                                ? DesignTokens.Color.labelSecondary
                                : DesignTokens.Color.brandBlue
                        )
                }
                .disabled(isSaving)
                .accessibilityLabel(isLastQuestion ? "Finish" : "Next")
                .accessibilityIdentifier("ConversationalCaptureAdvanceButton")
            }

            // Per-question skip — keeps the flow optional question by question.
            Button(isLastQuestion ? "Finish" : "Skip this one") { advance(skip: true) }
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .disabled(isSaving)
                .accessibilityIdentifier("ConversationalCaptureSkipQuestionButton")
        }
        .padding(DesignTokens.Spacing.lg)
        .background(.bar)
    }

    // MARK: Actions

    /// Records the current answer (unless skipping/empty) and advances; on the last
    /// question, persists everything captured and finishes.
    private func advance(skip: Bool = false) {
        guard !isSaving else { return }
        errorMessage = nil

        let answer = trimmedDraft
        if !skip, !answer.isEmpty {
            captured.append((id: currentQuestion.id, answer: answer, fact: currentQuestion.makeFact(answer)))
        }
        draft = ""

        if isLastQuestion {
            finish(persist: true)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                index += 1
            }
            inputFocused = true
        }
    }

    /// Persists captured facts (best effort) and calls `onFinish`. When `persist` is true and
    /// there are facts, each is POSTed with `source="onboarding"`. A failure surfaces inline
    /// and does NOT finish, so the user can retry or skip past it.
    private func finish(persist: Bool) {
        guard !isSaving else { return }

        let facts = captured.map(\.fact)
        guard persist, !facts.isEmpty else {
            onFinish()
            return
        }

        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                for fact in facts {
                    _ = try await service.addMemory(fact: fact, source: "onboarding")
                }
                onFinish()
            } catch {
                errorMessage = "Couldn't save that just now. Tap Finish to retry, or skip."
            }
        }
    }
}

#if DEBUG
#Preview("Capture — Light") {
    ConversationalCaptureView(service: MockMemoryService(), greetingName: "Sam") {}
}

#Preview("Capture — Dark") {
    ConversationalCaptureView(service: MockMemoryService(), greetingName: nil) {}
        .preferredColorScheme(.dark)
}
#endif
