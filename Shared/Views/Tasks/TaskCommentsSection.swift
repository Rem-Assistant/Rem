import SwiftUI

/// Gates the task-activity **status chip** ("Proposes: …" / "Applied: …").
///
/// The autonomous **"Applied: <status>" + Undo** treatment is temporarily gated OFF.
/// It surfaced a FALSE applied state — a run rendered "Applied: Blocked" for a status
/// that was never actually applied (founder feedback, #1367). Rather than fix that
/// line now, the applied chip is hidden until the apply signal is trustworthy; the
/// human **"Proposes: <status>" + Accept** path is unaffected. Flip
/// `appliedStatusChipEnabled` to `true` to restore the applied chip once it's improved.
///
/// `nonisolated` so the pure predicate is callable from any context and unit-testable
/// in isolation (mirrors `ChatEmptyStateGate`); it holds no view state.
nonisolated enum TaskActivityStatusChipGate {
    /// Feature flag for the autonomous "Applied + Undo" chip. Gated OFF (#1367) until
    /// the applied-status signal can be trusted. Compile-time constant — the whole
    /// applied branch stays in the view, dark, ready to re-enable.
    static let appliedStatusChipEnabled = false

    /// Whether a comment's proposed/applied status chip should render:
    /// - no status ⇒ never;
    /// - a status the agent applied autonomously (`didApplyStatus`) ⇒ only when the
    ///   feature is enabled (gated off today);
    /// - a human proposal ⇒ always.
    static func showsStatusChip(proposedStatus: String?, didApplyStatus: Bool) -> Bool {
        guard let proposedStatus,
              !proposedStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if didApplyStatus { return appliedStatusChipEnabled }
        return true
    }
}

/// Shared state for the task **Activity** feature. Lets the activity *log* render
/// inline in the task detail while the *composer* docks separately (a bottom card on
/// iOS) — both driven by one model so posting a reply / asking Rem updates the
/// log in place. Canonical store is the backend `task_comments` table (CONTRACT §4).
@MainActor
@Observable
final class TaskCommentsModel {
    var comments: [TaskComment] = []
    var draft: String = ""
    var isLoading = false
    var isPosting = false
    var isRunningAgent = false
    var errorMessage: String?

    // V1 (iOS) is cloud-only — "Ask Rem" always runs the cloud agent, so there is
    // no Cloud/Local target to pick. The runtime distinction is deferred.

    /// The activity item the human is currently replying to. Drives the composer's
    /// "Replying to …" banner (set from a row's Reply button, cleared on send or
    /// cancel). Single source of truth for the reply-target state, shared between the
    /// inline Activity thread and the docked composer (both bind this one model).
    var replyingTo: TaskComment?

    func beginReply(to comment: TaskComment) { replyingTo = comment }
    func cancelReply() { replyingTo = nil }

    /// The single most-recent activity entry. The task detail surfaces only this
    /// one item inline (founder feedback); the full thread is reached via
    /// "View history" / tapping the row → the agent session. `comments` is kept
    /// in chronological order (appended on post/run), so `.last` is the latest.
    var latestComment: TaskComment? { comments.last }

    private(set) var taskId: String = ""
    private var service: (any TaskCommentProviding)?
    private var commitStatus: (String) async -> Void = { _ in }
    /// Called right after a cloud run with the stable session key the backend
    /// stamped on the task (`rem-task-<taskId>`, #971). The host writes it onto the
    /// local task immediately so "Open conversation" resolves to the SAME session the
    /// backend ran against, instead of falling through to the pre-run `task-<slug>`
    /// fallback until the next sync (which splits the conversation across two sessions).
    /// Default no-op for previews / hosts that don't own the task store.
    private var onStampedSessionKey: (_ taskId: String, _ sessionKey: String) -> Void = { _, _ in }
    private var configured = false

    /// Lazy backing resolver, set by `configureLazy`. When the Activity surface is
    /// hosted for a resource that has no backend row yet (a calendar event not opted
    /// into being worked — #872), the FIRST agent action (Run now / reply / open chat)
    /// fires this to create the backing task on demand, so #872's mechanism stays but
    /// runs automatically instead of behind an explicit opt-in card (#875). Returns the
    /// backing task id (already persisted), or nil on failure so the action aborts.
    /// Cleared once a real `taskId` is adopted.
    private var resolveBackingTaskId: (() async -> String?)?

    func configure(
        taskId: String,
        service: (any TaskCommentProviding)? = nil,
        commitStatus: @escaping (String) async -> Void,
        onStampedSessionKey: @escaping (_ taskId: String, _ sessionKey: String) -> Void = { _, _ in }
    ) {
        guard !configured else { return }
        configured = true
        self.taskId = taskId
        self.service = service ?? TaskCommentService()
        self.commitStatus = commitStatus
        self.onStampedSessionKey = onStampedSessionKey
    }

    /// Configure the surface *without* a known `taskId`: the backing task is resolved
    /// (created if needed) on first interaction via `resolveBackingTaskId`. Used by the
    /// calendar event detail so the Activity surface looks and behaves exactly like a
    /// task's, while #872's backing task is created lazily (no "Let Rem work this" card).
    /// Idempotent with `configure` via the shared `configured` flag.
    func configureLazy(
        service: (any TaskCommentProviding)? = nil,
        commitStatus: @escaping (String) async -> Void,
        resolveBackingTaskId: @escaping () async -> String?,
        onStampedSessionKey: @escaping (_ taskId: String, _ sessionKey: String) -> Void = { _, _ in }
    ) {
        guard !configured else { return }
        configured = true
        self.service = service ?? TaskCommentService()
        self.commitStatus = commitStatus
        self.resolveBackingTaskId = resolveBackingTaskId
        self.onStampedSessionKey = onStampedSessionKey
    }

    /// Ensure the model has a backend `taskId` before a network action. A no-op for a
    /// surface already configured with a real id (returns true immediately). For a
    /// lazily-configured surface it fires the resolver once, adopts the returned id,
    /// loads any existing thread, and returns true; returns false if the backing
    /// couldn't be created so the caller aborts (the resolver surfaces its own error).
    private func ensureBackingReady() async -> Bool {
        if !taskId.isEmpty { return true }
        guard let resolveBackingTaskId else { return false }
        guard let id = await resolveBackingTaskId() else { return false }
        taskId = id
        self.resolveBackingTaskId = nil
        await load()
        return true
    }

    /// Resolve the backend `taskId` for a handoff (e.g. opening the task-scoped chat),
    /// creating the backing lazily if needed. Returns nil if it couldn't be resolved so
    /// the host doesn't dead-end into a chat with no task to seed.
    func resolveTaskIdForHandoff() async -> String? {
        guard await ensureBackingReady() else { return nil }
        return taskId.isEmpty ? nil : taskId
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting
    }

    func load() async {
        guard let service else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { comments = try await service.comments(taskId: taskId) }
        catch { errorMessage = error.localizedDescription }
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        // First interaction may need to create #872's backing task (lazy event surface).
        guard await ensureBackingReady() else { return }
        guard let service else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await service.postComment(taskId: taskId, body: body, proposedStatus: nil)
            comments.append(comment)
            draft = ""
            // Reply lifecycle: once the reply posts, drop the reply-target so the
            // composer returns to its default (un-threaded) state. (Backend reply
            // parenting is a follow-up — `task_comments` has no parent_id yet, and
            // the contract is FROZEN; we thread the *interaction*, not yet storage.)
            replyingTo = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func askRem() async {
        // "Run now" on an un-worked event lazily creates #872's backing task first, so
        // the event detail behaves exactly like a task (#875) — no opt-in card.
        guard await ensureBackingReady() else { return }
        guard let service else { return }
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
            // Apply the backend-stamped session key to the local task NOW (#971
            // follow-up), so "Open conversation" opens the SAME gateway session the
            // run used — before the next full sync would otherwise stamp it, which
            // was splitting the conversation across two sessions.
            if let key = result.stampedSessionKey, !key.isEmpty {
                onStampedSessionKey(taskId, key)
            }
        } catch {
            // Recovery (CONTRACT §8): never dead-end — surface a labelled inline error.
            errorMessage = "Rem couldn’t run: \(error.localizedDescription)"
        }
    }

    func accept(_ status: String) { Task { await commitStatus(status) } }
}

// MARK: - Activity (inline)

/// The inline **Activity** log — primarily Rem's record of what it did/said on the
/// task, plus the human's replies. Attributed `TaskComment`s render in the task
/// detail's scroll; the composer is hosted separately. The human REPLIES to this
/// log (each row has a Reply affordance) rather than treating it as a peer chat.
struct TaskCommentsThread: View {
    let model: TaskCommentsModel

    /// Tap on an activity row drills into the full agent session/chat — the task
    /// is the "workboard", each entry is a doorway into the session that produced
    /// it (mirrors OpenClaw's Workboard → session). Hosts inject the destination.
    /// Default is a no-op; see `TaskActivityRow` for the wiring TODO.
    var onOpenSession: (TaskComment) -> Void = { _ in }

    /// "View history" → open the full activity/comment thread for this task (a
    /// read-focused list of every entry, with its own doorway into the task-scoped
    /// chat). Distinct from `onOpenSession` so View history is a reliable entry for
    /// *every* item — including human comments that have no session to drill into
    /// (the old behavior dead-ended on those). Host owns the destination.
    var onViewHistory: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            // Uppercase section-header treatment (the founder-preferred all-caps
            // style): a quiet, secondary label that names the log as "LAST ACTIVITY"
            // (#1367 — only the single most-recent entry is surfaced inline).
            // Weighted to match the Reply affordance (caption1Bold) — the founder
            // wanted the header more emphasized than the old light caption.
            Text("Last activity")
                .font(DesignTokens.Typography.caption1Bold)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .textCase(.uppercase)

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            if model.isLoading && model.comments.isEmpty {
                loadingRow
            } else if let latest = model.latestComment {
                // Surface only the single most-recent entry inline (founder
                // feedback). The full thread is reached via "View history" or by
                // tapping the row → the agent session that produced it.
                TaskActivityRow(
                    comment: latest,
                    onAcceptStatus: { model.accept($0) },
                    onReply: { model.beginReply(to: latest) },
                    onOpenSession: { onOpenSession(latest) }
                )
            } else {
                Text("No activity yet. Tap Run now, or add a reply.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }

            if model.isRunningAgent {
                agentThinkingRow
            }

            // Run now + View history live in the Activity area (NOT the composer):
            // "Run now" hands the task to Rem; "View history" opens the full thread
            // (shown only once there's history to view).
            if !model.isRunningAgent {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    /// Run now (left) + View history (right). The explicit Run-now button is kept;
    /// View history sits to its right with space between, and only appears once
    /// there's activity to open. Both are understated labels (no filled container —
    /// founder feedback that the contained blue button read too loud).
    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            runNowButton
            Spacer(minLength: DesignTokens.Spacing.md)
            if model.latestComment != nil {
                viewHistoryButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Subtle labelled CTA — runs an agent session on this task ("Run now"). Same
    /// low-key emphasis as the Reply action: plain secondary-colored label.
    private var runNowButton: some View {
        Button {
            Task { await model.askRem() }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                // Play icon (founder: "Run now" is an explicit one-shot *run*, so it
                // reads as a play action — not the sparkle we use for Rem's identity).
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                Text("Run now")
                    .font(DesignTokens.Typography.caption1Bold)
            }
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunningAgent || model.isPosting)
        .accessibilityHint("Runs a cloud session on this task")
    }

    /// Opens the full activity/comment thread for the task. With only the latest
    /// entry shown inline, this is the way into the complete history — a dedicated
    /// list view (which itself offers a doorway into the task-scoped chat), so it
    /// works for *every* item, not just ones with a drill-in session. Rendered in a
    /// quieter **secondary** color (founder feedback) — it's a navigation affordance,
    /// not a primary action, so it sits below Reply/send in emphasis.
    private var viewHistoryButton: some View {
        Button {
            onViewHistory()
        } label: {
            Text("View history")
                .font(DesignTokens.Typography.caption1Bold)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full activity history for this task")
    }

    private var loadingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Loading activity…")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
    }

    private var agentThinkingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Rem is working…")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Color.systemRed)
            Text(message)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Spacer()
            Button("Retry") { Task { await model.load() } }
                .font(DesignTokens.Typography.caption1Bold)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Color.systemRed.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small))
    }
}

// MARK: - Activity Row

/// One entry in the **Activity** log. The agent is attributed simply as **"Rem"**
/// (no "AgentBox" suffix, no cloud badge — V1 iOS is cloud-only, the runtime
/// distinction is deferred). Layout, top-to-bottom: author · body (capped at 3
/// lines) · then a footer row with the relative **timestamp** (muted secondary)
/// and a **Reply** action beside it (blue — the tappable affordance). Tapping
/// Reply threads the next composer message against this item; tapping the row
/// body opens the full session (see `onOpenSession`).
struct TaskActivityRow: View {
    let comment: TaskComment
    /// Commit a status to the task. Used both for **Accept** (legacy human proposal →
    /// commit `proposedStatus`) and **Undo** (agent already applied a status → commit the
    /// recorded `previousStatus` to revert). Same backend `PATCH /tasks/:id` path.
    var onAcceptStatus: (String) -> Void = { _ in }
    var onReply: () -> Void = {}
    /// Tapping the row drills into the full agent session/chat that produced this
    /// entry (the task is the "workboard"; each row is a doorway into its session).
    /// The session handle now travels on the comment as `TaskComment.sessionId`
    /// (backend `task_comments.session_id`, migration 022); `TaskCommentsThread`
    /// passes the whole comment up via its own `onOpenSession`, and the host
    /// (`RemMainTabView` → `RemChatView`/`SharedRemChatView`) resolves the session.
    /// A comment with no `sessionId` (human comments, pre-022 rows) falls back
    /// gracefully in the host rather than crashing.
    var onOpenSession: () -> Void = {}

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var avatarIconSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            avatar

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Author is a label, not an action — keep it neutral. Blue is
                // reserved for tappable affordances (Reply / send), so the name
                // must not read as clickable. The avatar carries the brand tint.
                Text(displayAuthor)
                    .font(DesignTokens.Typography.caption1Bold)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .lineLimit(1)

                // Truncate long agent messages so the row stays compact and the
                // Notes section below remains visible/accessible.
                Text(comment.body)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let proposed = comment.proposedStatus,
                   TaskActivityStatusChipGate.showsStatusChip(
                       proposedStatus: proposed,
                       didApplyStatus: comment.didApplyStatus
                   ) {
                    proposedStatusChip(proposed)
                        .padding(.top, DesignTokens.Spacing.xs)
                }

                footer
            }

            Spacer(minLength: 0)
        }
        // Whole row is tappable → opens the session. Inner buttons (Reply, Accept)
        // keep their own hit areas and take priority over this gesture.
        .contentShape(Rectangle())
        .onTapGesture { onOpenSession() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full session for this activity")
    }

    // MARK: Footer (timestamp + Reply)

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if let time = relativeTime {
                Text(time)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }

            // Reply is a genuine action — blue is the tappable-colored affordance.
            Button("Reply", action: onReply)
                .font(DesignTokens.Typography.caption1Bold)
                .foregroundStyle(DesignTokens.Color.brandBlue)
                .buttonStyle(.plain)
                .accessibilityHint("Reply to this activity")
        }
        .padding(.top, DesignTokens.Spacing.xs)
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
                // Rem starter-chat null state — not a sparkle (#1367).
                RemFaceMark(tint: accent, size: avatarSize * 0.6)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .accessibilityHidden(true)
    }

    /// Agent is simply **"Rem"** — the human keeps their backend label ("You").
    private var displayAuthor: String {
        comment.authorKind == .user ? comment.authorLabel : "Rem"
    }

    private func proposedStatusChip(_ status: String) -> some View {
        // AI autonomy: when the agent already APPLIED the status (`didApplyStatus`), the
        // chip reads "Applied: …" with an **Undo** that reverts to `previousStatus`. A
        // human proposal (no apply) keeps the legacy "Proposes: …" + **Accept**.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                statusLabel(status)
                statusAction(status)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                statusLabel(status)
                statusAction(status)
            }
        }
    }

    /// A status is a *status*, not an action — so it renders monochrome (no orange, no
    /// blue). "Blocked" gets the heavier primary label to stand apart. The verb reflects
    /// whether Rem applied it ("Applied") or merely proposed it ("Proposes").
    private func statusLabel(_ status: String) -> some View {
        let isBlocked = status.lowercased().contains("block")
        let tint = isBlocked
            ? DesignTokens.Color.labelPrimary
            : DesignTokens.Color.labelSecondary
        let verb = comment.didApplyStatus ? "Applied" : "Proposes"
        // Applied = Rem already did it (a checkmark badge); Proposes = awaiting the human.
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

    /// Undo (when the agent applied the status) or Accept (legacy human proposal). Both
    /// commit a status via `onAcceptStatus`; Undo reverts to the recorded
    /// `previousStatus`. Rendered **blue** (the tappable-affordance color, matching
    /// Reply/send). Undo is omitted if there's no recorded previous status to revert to.
    @ViewBuilder
    private func statusAction(_ status: String) -> some View {
        if comment.didApplyStatus {
            if let previous = comment.previousStatus, !previous.isEmpty {
                Button("Undo") { onAcceptStatus(previous) }
                    .font(DesignTokens.Typography.caption1Bold)
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.Color.brandBlue)
                    .accessibilityHint("Reverts the task to its previous status")
            }
        } else {
            Button("Accept") { onAcceptStatus(status) }
                .font(DesignTokens.Typography.caption1Bold)
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Color.brandBlue)
                .accessibilityHint("Commits the proposed status to the task")
        }
    }

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

// MARK: - Composer

/// The Activity **reply composer** — reuses the chat input shell (`RemComposerBar`)
/// so the task page and the chat view share one component. The chat composer's
/// logic is bound to `OpenClawChatViewModel` (send/abort/quota) and can't be
/// reused wholesale, so the shared piece is the *presentation* shell.
///
/// V1 (iOS) is cloud-only, so the old Cloud/Local segmented control + helper copy
/// are gone, and "Ask Rem to work on this" moved up into the Activity area. What's
/// left here is intentionally simple: a text field that posts a reply, with a
/// **"Replying to …" banner** docked at the top of the pill when the user taps
/// Reply on an activity item.
struct TaskCommentComposer: View {
    @Bindable var model: TaskCommentsModel
    @FocusState private var isFocused: Bool

    /// When set, the composer's primary action **opens the task-scoped chat**
    /// (carrying whatever the user typed) instead of posting an inline reply. This
    /// is the founder's model for the iOS task detail: the composer is the doorway
    /// into the connected chat — "the composer should open whatever link we already
    /// have" — so unblocking a task continues in a real, context-seeded conversation
    /// rather than a one-line comment. Inline hosts (Mac combined section) leave this
    /// `nil`, preserving the post-a-comment behavior.
    var onOpenChat: ((String) -> Void)? = nil

    /// Whether the composer opens the chat (`true`) or posts an inline reply.
    private var opensChat: Bool { onOpenChat != nil }

    /// The primary affordance: open the connected chat (doorway mode) or post the
    /// reply (inline mode). In doorway mode the button is always live — the chat is
    /// always there to open — even with an empty field.
    private func primaryAction() {
        if let onOpenChat {
            onOpenChat(model.draft)
        } else {
            Task { await model.send() }
        }
    }

    private var isPrimaryEnabled: Bool {
        opensChat ? !model.isPosting : model.canSend
    }

    var body: some View {
        RemComposerBar(
            text: $model.draft,
            placeholder: composerPlaceholder,
            lineLimit: 1...4,
            font: DesignTokens.Typography.body,
            focus: $isFocused,
            onSubmit: { primaryAction() },
            // Top-of-composer accessory slot — hosts the reply-target banner.
            attachments: { replyingBanner },
            leading: { EmptyView() },
            trailing: { EmptyView() },
            send: { sendButton }
        )
        // Tapping Reply on a row sets `replyingTo`; focus the field so the user
        // can type immediately. Clearing it (send / cancel) leaves focus alone.
        .onChange(of: model.replyingTo) { _, target in
            if target != nil { isFocused = true }
        }
    }

    /// Placeholder copy reflects the composer's job: in doorway mode it opens the
    /// connected chat ("Continue in chat…"); in inline mode it posts a reply.
    private var composerPlaceholder: String {
        if model.replyingTo != nil { return "Write your reply…" }
        return opensChat ? "Continue in chat…" : "Add a reply…"
    }

    /// "Replying to …" banner — docked at the top of the composer pill while
    /// replying. Layout: a leading icon beside a vertical stack that puts the
    /// **subject** ("Replying to Rem") above the **content** (the quoted text),
    /// with a trailing X to cancel. (Not subject + content on one line.)
    @ViewBuilder
    private var replyingBanner: some View {
        if let target = model.replyingTo {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Replying to \(replyAuthor(target))")
                        .font(DesignTokens.Typography.caption1Bold)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)

                    if let quote = replyQuote(target) {
                        Text(quote)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(DesignTokens.Color.labelTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    model.cancelReply()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel reply")
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                DesignTokens.Color.fillTertiary,
                in: .rect(cornerRadius: DesignTokens.CornerRadius.small)
            )
        }
    }

    private func replyAuthor(_ comment: TaskComment) -> String {
        comment.authorKind == .user ? comment.authorLabel : "Rem"
    }

    private func replyQuote(_ comment: TaskComment) -> String? {
        let trimmed = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Primary button — same circular send button as the chat composer. In doorway
    /// mode it opens the connected chat (arrow-up-right "go"); in inline mode it
    /// posts the reply (arrow-up "send").
    @ViewBuilder
    private var sendButton: some View {
        Button {
            primaryAction()
        } label: {
            Image(systemName: opensChat ? "arrow.up.right" : "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    isPrimaryEnabled ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelTertiary,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!isPrimaryEnabled)
        .accessibilityLabel(opensChat ? "Open chat for this task" : "Send reply")
    }
}

// MARK: - Combined section (Mac / inline hosts)

/// Thread + composer stacked, for hosts that render comments inline (e.g. the Mac
/// task detail Form). iOS splits these so only the composer docks to the bottom.
struct TaskCommentsSection: View {
    let taskId: String
    let service: (any TaskCommentProviding)?
    var commitStatus: (String) async -> Void
    /// Forwarded to the thread so "View history" / row taps can open the full
    /// session. Defaults to a no-op for hosts that don't yet wire navigation.
    var onOpenSession: (TaskComment) -> Void
    /// Forwarded to the model: called after a cloud run with the backend-stamped
    /// `rem-task-<taskId>` session key so the host can apply it to the local task
    /// immediately (#971 follow-up). Default no-op for hosts without a task store.
    var onStampedSessionKey: (_ taskId: String, _ sessionKey: String) -> Void

    @State private var model = TaskCommentsModel()

    init(
        taskId: String,
        service: (any TaskCommentProviding)? = nil,
        commitStatus: @escaping (String) async -> Void = { _ in },
        onOpenSession: @escaping (TaskComment) -> Void = { _ in },
        onStampedSessionKey: @escaping (_ taskId: String, _ sessionKey: String) -> Void = { _, _ in }
    ) {
        self.taskId = taskId
        self.service = service
        self.commitStatus = commitStatus
        self.onOpenSession = onOpenSession
        self.onStampedSessionKey = onStampedSessionKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            TaskCommentsThread(
                model: model,
                onOpenSession: onOpenSession,
                // Inline hosts (Mac) have no separate history destination wired, so
                // View history keeps its prior behavior here: drill into the latest
                // entry's session. iOS overrides this with a dedicated history view.
                onViewHistory: { if let latest = model.latestComment { onOpenSession(latest) } }
            )
            // Inline-post composer (no `onOpenChat`) — Mac posts comments in place.
            TaskCommentComposer(model: model)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }
        .task {
            model.configure(
                taskId: taskId,
                service: service,
                commitStatus: commitStatus,
                onStampedSessionKey: onStampedSessionKey
            )
            await model.load()
        }
    }
}

// MARK: - Activity history (full thread)

/// The full activity/comment thread for a task — the destination behind **"View
/// history"**. Lists every attributed `TaskComment` (Rem's runs + the human's
/// replies) read-only. Tapping any row opens the **task-scoped chat** (the founder's
/// "unblock" surface), so it's both the complete record and a valid entry point into
/// the connected chat — works for every item, including human comments that have no
/// session to drill into. (The standalone "Continue in chat" button was removed per
/// #1367; the row tap is the entry point.)
struct TaskActivityHistoryView: View {
    let taskId: String
    let service: (any TaskCommentProviding)?

    /// Opens the task-scoped continuation chat, seeded with the latest activity so
    /// the AI continues the unblock conversation. The host resolves the destination;
    /// the latest comment travels up so the seed carries Rem's most recent update.
    var onContinueInChat: (TaskComment?) -> Void

    @State private var model = TaskCommentsModel()

    init(
        taskId: String,
        service: (any TaskCommentProviding)? = nil,
        onContinueInChat: @escaping (TaskComment?) -> Void = { _ in }
    ) {
        self.taskId = taskId
        self.service = service
        self.onContinueInChat = onContinueInChat
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                if let errorMessage = model.errorMessage {
                    historyError(errorMessage)
                } else if model.isLoading && model.comments.isEmpty {
                    loadingRow
                } else if model.comments.isEmpty {
                    emptyState
                } else {
                    ForEach(model.comments) { comment in
                        // Read-only in history: Accept lives on the inline activity
                        // card (where status commits are wired), not the log. Tapping a
                        // row opens the task chat (continuation chat) — the same
                        // open-chat path the main Activity surface uses — seeded with
                        // this entry (reuses `onContinueInChat`, which the host routes
                        // through `openTaskChat`).
                        TaskCommentRow(
                            comment: comment,
                            showsAccept: false,
                            onOpenComment: { onContinueInChat(comment) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Read-only: no commit needed (Accept is hidden), so pass a no-op.
            model.configure(taskId: taskId, service: service, commitStatus: { _ in })
            await model.load()
        }
    }

    private var loadingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Loading activity…")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No activity yet")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Text("Continue in chat to start working on this task with Rem.")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    private func historyError(_ message: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Color.systemRed)
            Text(message)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Spacer()
            Button("Retry") { Task { await model.load() } }
                .font(DesignTokens.Typography.caption1Bold)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Color.systemRed.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small))
    }
}

#Preview("Activity — Mock") {
    ScrollView {
        TaskCommentsSection(
            taskId: "task-preview",
            service: MockTaskCommentService()
        )
    }
}
