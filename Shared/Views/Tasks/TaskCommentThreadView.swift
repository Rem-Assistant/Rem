import SwiftUI

/// The **task collaboration thread** — the visual hero of the AgentBox demo.
///
/// One scrollable thread of attributed `TaskComment`s (human, GMI AgentBox cloud
/// agent, local Mac/iOS gateway), a header showing the task's assigned runtime
/// with a switch control, and a composer that can post a human comment or ask the
/// cloud agent to act on the task.
///
/// Cross-platform by construction: talks only to `TaskCommentProviding` and
/// `DesignTokens`, no UIKit/AppKit. iOS and Mac inject the concrete service
/// (`TaskCommentService`) or the mock; status-accept and runtime-switch are
/// closures the parent (task store) supplies, since committing a status is a
/// `PATCH /tasks/:id` the store owns (CONTRACT §4).
struct TaskCommentThreadView: View {
    /// Backend task UUID string.
    let taskId: String

    /// The runtime currently assigned to the task (`tasks.assigned_runtime`).
    let assignedRuntime: TaskRuntimeKind

    /// Comment read/write seam. Inject `TaskCommentService()` in the app, or a
    /// `MockTaskCommentService` in previews.
    let service: any TaskCommentProviding

    /// Parent commits an accepted proposed status (a `PATCH /tasks/:id`).
    /// Receives the status string the comment proposed.
    var onAcceptStatus: (String) -> Void = { _ in }

    /// Parent reassigns the task's runtime (`tasks.assigned_runtime`).
    var onSwitchRuntime: (TaskRuntimeKind) -> Void = { _ in }

    @State private var comments: [TaskComment] = []
    @State private var draft: String = ""
    @State private var isLoading = false
    @State private var isPosting = false
    @State private var isRunningAgent = false
    @State private var errorMessage: String?

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            thread
            Divider()
            composer
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Runtime")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                TaskRuntimeBadge(runtime: assignedRuntime)
            }

            Spacer()

            Menu {
                ForEach(TaskRuntimeKind.assignableCases, id: \.self) { runtime in
                    Button {
                        onSwitchRuntime(runtime)
                    } label: {
                        if runtime == assignedRuntime {
                            Label(runtime.displayName, systemImage: "checkmark")
                        } else {
                            Text(runtime.displayName)
                        }
                    }
                }
            } label: {
                Label("Switch", systemImage: "arrow.triangle.2.circlepath")
                    .font(DesignTokens.Typography.footnote)
            }
            .accessibilityLabel("Switch runtime")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Thread

    @ViewBuilder
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    if isLoading && comments.isEmpty {
                        loadingPlaceholder
                    } else if comments.isEmpty {
                        emptyState
                    } else {
                        ForEach(comments) { comment in
                            TaskCommentRow(comment: comment, onAcceptStatus: onAcceptStatus)
                                .id(comment.id)
                        }
                    }

                    if isRunningAgent {
                        agentThinkingRow
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
            .onChange(of: comments.count) { _, _ in
                guard let last = comments.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var loadingPlaceholder: some View {
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .fill(DesignTokens.Color.pillBackground)
                .frame(height: 56)
                .shimmering()
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .accessibilityHidden(true)
            Text("No comments yet")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Text("Add a note, or ask Rem to take a first pass.")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
                .multilineTextAlignment(.center)

            Button {
                Task { await askCloud() }
            } label: {
                Label("Ask Rem", systemImage: "sparkles")
                    .font(DesignTokens.Typography.caption1Bold)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.brandBlue)
            .controlSize(.small)
            .padding(.top, DesignTokens.Spacing.xs)
            .disabled(isRunningAgent || isPosting)
            .accessibilityHint("Runs Rem on this task")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    private var agentThinkingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TaskRuntimeBadge(runtime: .agentbox, compact: true)
            ProgressView()
                .controlSize(.small)
            Text("Rem is working…")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Spacer()
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Color.systemRed)
            Text(message)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Spacer()
            Button("Retry") { Task { await load() } }
                .font(DesignTokens.Typography.caption1Bold)
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Color.systemRed.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelTertiary)
                .disabled(!canSend)
                .accessibilityLabel("Send comment")
            }

            HStack {
                Button {
                    Task { await askCloud() }
                } label: {
                    Label("Ask Rem", systemImage: "sparkles")
                        .font(DesignTokens.Typography.footnote)
                }
                .buttonStyle(.borderless)
                .disabled(isRunningAgent || isPosting)
                .accessibilityHint("Runs Rem on this task")

                Spacer()

                if isPosting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            comments = try await service.comments(taskId: taskId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await service.postComment(taskId: taskId, body: body, proposedStatus: nil)
            comments.append(comment)
            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func askCloud() async {
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isRunningAgent = true
        errorMessage = nil
        defer { isRunningAgent = false }
        do {
            let result = try await service.runCloudAgent(
                taskId: taskId,
                instruction: instruction.isEmpty ? nil : instruction
            )
            comments.append(result.comment)
            draft = ""
        } catch {
            // Recovery (CONTRACT §8): never dead-end. Surface a labelled inline error.
            errorMessage = "Rem couldn’t run: \(error.localizedDescription)"
        }
    }
}

// MARK: - Comment Row

/// One attributed comment, **flat** (Notion-style, no card elevation). Distinguishes
/// author kind by a tinted avatar + runtime badge; shows relative time, and surfaces
/// a proposed-status chip with an Accept action.
///
/// Accessibility: the prose + attribution are merged into a single VoiceOver element
/// (`.contain` at the row, an explicit label on the text column), while the Accept
/// button stays an independently focusable, actionable control — `.combine` would
/// have swallowed it.
struct TaskCommentRow: View {
    let comment: TaskComment
    var onAcceptStatus: (String) -> Void = { _ in }
    /// When `false`, the proposed-status chip renders without its Accept action —
    /// used in the read-only history list, where committing a status lives on the
    /// inline activity card instead (which owns the `PATCH /tasks/:id` wiring).
    var showsAccept: Bool = true
    /// Tapping the row opens the task-scoped chat (the continuation chat). Wired by
    /// the View-history host to the same open-chat path the main Activity surface
    /// uses; defaults to a no-op for the old thread/preview hosts. Mirrors
    /// `TaskActivityRow.onOpenSession`.
    var onOpenComment: () -> Void = {}

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var avatarIconSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            avatar

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                attribution
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(attributionAccessibilityLabel)

                if let proposed = comment.proposedStatus,
                   TaskActivityStatusChipGate.showsStatusChip(
                       proposedStatus: proposed,
                       didApplyStatus: comment.didApplyStatus
                   ) {
                    proposedStatusChip(proposed)
                        .padding(.top, DesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: 0)
        }
        // Whole row is tappable → opens the task chat (matches the Activity surface).
        // Inner buttons (Accept) keep their own hit areas and take priority.
        .contentShape(Rectangle())
        .onTapGesture { onOpenComment() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the chat for this task")
    }

    // MARK: Attribution (avatar + author line + body)

    private var attribution: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            authorLine
            Text(comment.body)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.15))
            if comment.authorKind == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: avatarIconSize, weight: .semibold))
                    .foregroundStyle(accent)
            } else {
                // Rem's identity is the branded face mark — the same face used in the
                // Rem starter-chat null state — not a sparkle (#1367). Matches
                // `TaskActivityRow` so the log reads identically inline and in history.
                RemFaceMark(tint: accent, size: avatarSize * 0.6)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .accessibilityHidden(true)
    }

    private var authorLine: some View {
        // Wraps to the next line at large Dynamic Type sizes rather than truncating.
        // Matches the Activity surface (`TaskActivityRow`): the agent is attributed
        // simply as "Rem" (no runtime badge), in a neutral primary label — blue is
        // reserved for tappable affordances.
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(displayAuthor)
                .font(DesignTokens.Typography.caption1Bold)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .lineLimit(1)

            if let time = relativeTime {
                Text(time)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
        }
    }

    /// Agent is simply **"Rem"**; the human keeps their backend label ("You").
    /// Mirrors `TaskActivityRow.displayAuthor` so View history reads identically.
    private var displayAuthor: String {
        comment.authorKind == .user ? comment.authorLabel : "Rem"
    }

    private var attributionAccessibilityLabel: String {
        var parts = ["\(displayAuthor) said: \(comment.body)"]
        if let time = relativeTime { parts.append(time) }
        return parts.joined(separator: ", ")
    }

    private func proposedStatusChip(_ status: String) -> some View {
        // Wraps the chip + action onto two lines at large sizes via a flexible layout.
        // Mirrors `TaskActivityRow`: an APPLIED status (agent acted) reads "Applied: …"
        // with Undo; a human proposal reads "Proposes: …" with Accept.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                statusLabel(status)
                if showsAccept { statusAction(status) }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                statusLabel(status)
                if showsAccept { statusAction(status) }
            }
        }
    }

    /// A status is a *status*, not an action — so it renders monochrome (no orange),
    /// matching the Activity surface. "Blocked" gets the heavier primary label. The verb
    /// reflects whether Rem applied it ("Applied") or merely proposed it ("Proposes").
    private func statusLabel(_ status: String) -> some View {
        let isBlocked = status.lowercased().contains("block")
        let tint = isBlocked
            ? DesignTokens.Color.labelPrimary
            : DesignTokens.Color.labelSecondary
        let verb = comment.didApplyStatus ? "Applied" : "Proposes"
        let icon = comment.didApplyStatus ? "checkmark.seal.fill" : "flag.fill"
        return HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text("\(verb): \(prettyStatus(status))")
                .font(DesignTokens.Typography.caption1Bold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.Color.fillTertiary, in: Capsule())
        .accessibilityLabel("\(verb) status: \(prettyStatus(status))")
    }

    /// Undo (revert to the recorded `previousStatus`) when the agent applied a status;
    /// otherwise Accept (commit the human's proposal). Both route through `onAcceptStatus`.
    @ViewBuilder
    private func statusAction(_ status: String) -> some View {
        if comment.didApplyStatus {
            if let previous = comment.previousStatus, !previous.isEmpty {
                Button("Undo") { onAcceptStatus(previous) }
                    .font(DesignTokens.Typography.caption1Bold)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Reverts the task to its previous status")
            }
        } else {
            Button("Accept") { onAcceptStatus(status) }
                .font(DesignTokens.Typography.caption1Bold)
                .buttonStyle(.borderless)
                .accessibilityHint("Commits the proposed status to the task")
        }
    }

    // MARK: Attribution styling

    private var accent: Color {
        switch comment.authorKind {
        case .user: DesignTokens.Color.labelPrimary
        case .cloudAgent: DesignTokens.Color.brandBlue
        case .localRuntime: DesignTokens.Color.systemGreen
        }
    }

    private var relativeTime: String? {
        guard let date = comment.createdAtDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func prettyStatus(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Previews

#Preview("Thread — Light") {
    TaskCommentThreadView(
        taskId: "task-preview",
        assignedRuntime: .agentbox,
        service: MockTaskCommentService()
    )
    .frame(width: 420, height: 640)
}

#Preview("Thread — Dark") {
    TaskCommentThreadView(
        taskId: "task-preview",
        assignedRuntime: .localMac,
        service: MockTaskCommentService()
    )
    .frame(width: 420, height: 640)
    .preferredColorScheme(.dark)
}

#Preview("Thread — Empty") {
    TaskCommentThreadView(
        taskId: "task-empty",
        assignedRuntime: .localiOS,
        service: MockTaskCommentService(thread: [], simulatedDelay: .zero)
    )
    .frame(width: 420, height: 640)
}

#Preview("Comment Rows") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
        ForEach(MockTaskCommentService.sampleThread()) { comment in
            TaskCommentRow(comment: comment)
        }
    }
    .padding()
}
