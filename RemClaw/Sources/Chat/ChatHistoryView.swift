import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// Lists all past chat sessions. Tapping a session navigates to the chat.
struct ChatHistoryView: View {
    private struct SessionDeleteAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(RemGatewaySessionManager.self) private var gateway
    @Bindable var viewModel: OpenClawChatViewModel
    /// Carries the title already painted in the selected row into the pushed destination. The
    /// destination can therefore render an honest first frame while its own history request starts,
    /// instead of briefly falling back to "New conversation".
    var onSelectSession: (String, String) -> Void
    var onNewChat: () -> Void
    var onRetryConnection: (() -> Void)?
    var onReviewConnection: (() -> Void)?

    /// Tracks whether this screen's first authoritative session fetch completed.
    /// Cached rows render immediately; an uncached request renders the real-row skeleton.
    @State private var hasLoadedOnce = false
    @State private var isInitialRequestInFlight = false
    @State private var requestedLimit = SessionListPagination.initialLimit
    @State private var isLoadingMore = false
    @State private var loadMoreFailed = false
    @State private var failedExpansionLimit: Int?
    @State private var searchLoadTask: Task<Void, Never>?
    @State private var searchLoadGeneration = 0
    @State private var isSearchLoading = false
    @State private var searchText: String = ""
    @State private var sessionDeleteAlert: SessionDeleteAlert?
    @State private var confirmedDeletedSessionKeys = Set<String>()

    /// Session key currently being renamed via the alert.
    @State private var renamingSessionKey: String?
    @State private var renameText: String = ""

    var body: some View {
        Group {
            if !gateway.connectionState.isConnected, hasLoadedOnce, allSessions.isEmpty {
                connectingView
            } else if !hasLoadedOnce && allSessions.isEmpty {
                let initialState = SessionsListViewStateResolver.resolve(
                    operatorReady: gateway.operatorReady,
                    isLoading: isInitialRequestInFlight,
                    hasLoadedOnce: hasLoadedOnce,
                    hasVisibleSessions: false,
                    hasLoadError: viewModel.sessionsLoadError != nil)
                if initialState.usesLoadingSkeleton {
                    SessionListLoadingSkeleton()
                } else {
                    connectingView
                }
            } else if allSessions.isEmpty, isSearchLoading {
                SessionListLoadingSkeleton()
            } else if allSessions.isEmpty, let loadError = viewModel.sessionsLoadError {
                sessionsLoadErrorView(loadError)
            } else if allSessions.isEmpty {
                sessionsEmptyView(isSearching: !searchQuery.isEmpty)
            } else {
                List {
                    if !gateway.connectionState.isConnected {
                        ChatConnectionRecoveryCard(
                            connectionState: gateway.connectionState,
                            onRetry: onRetryConnection,
                            onReviewConnection: onReviewConnection
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(allSessions) { session in
                        Button {
                            onSelectSession(session.key, sessionDisplayName(session))
                        } label: {
                            sessionRow(session)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteSession(session)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if !BriefContext.isBriefSession(session.key) {
                                Button {
                                    renameText = sessionDisplayName(session)
                                    renamingSessionKey = session.key
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                            }
                            Button(role: .destructive) {
                                deleteSession(session)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .onAppear {
                            loadMoreIfNeeded(after: session)
                        }
                    }

                    if loadMoreFailed {
                        Button("Try loading more") {
                            retryLoadMore()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                    }

                    // The app-wide bottom toolbar floats above tab content. Keep a real
                    // trailing list row (rather than only a scroll-content margin): List
                    // includes this height in its scroll range, so a near-screenful list
                    // can always lift its final conversation completely above the toolbar.
                    Color.clear
                        .frame(height: DesignTokens.Spacing.xxl + DesignTokens.Spacing.xl)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityHidden(true)
                }
                .listStyle(.plain)
                .refreshable {
                    if await viewModel.reloadSessions(limit: requestedLimit) {
                        await loadUntilVisibleOrComplete()
                    }
                    hasLoadedOnce = true
                }
            }
        }
        .navigationTitle("Chat Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search conversations")
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingSessionKey != nil },
            set: { if !$0 { renamingSessionKey = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let key = renamingSessionKey {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        SessionDisplayNames.setName(trimmed, for: key)
                    }
                }
                renamingSessionKey = nil
            }
            Button("Cancel", role: .cancel) {
                renamingSessionKey = nil
            }
        }
        .alert(item: $sessionDeleteAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("OK")))
        }
        .task {
            if !gateway.operatorReady {
                for _ in 0..<60 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    if gateway.operatorReady { break }
                }
                guard gateway.operatorReady else {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await loadInitialSessionsIfNeeded()
        }
        .onChange(of: gateway.operatorReady) { _, ready in
            guard ready else { return }
            Task {
                if hasLoadedOnce {
                    if await viewModel.reloadSessions(limit: requestedLimit) {
                        await loadUntilVisibleOrComplete()
                    }
                } else {
                    await loadInitialSessionsIfNeeded()
                }
            }
        }
        .onChange(of: viewModel.sessionsLimitApplied) { _, appliedLimit in
            guard let appliedLimit else { return }
            requestedLimit = max(requestedLimit, appliedLimit)
        }
        .onChange(of: acceptedSessionMetadataVersion, initial: true) { _, _ in
            reconcileAcceptedSessionMetadata()
        }
        .onChange(of: searchText) { _, newValue in
            searchLoadTask?.cancel()
            searchLoadGeneration += 1
            let generation = searchLoadGeneration
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isSearchLoading = false
                return
            }
            isSearchLoading = true
            searchLoadTask = Task {
                await loadRemainingSessionsForSearch()
                guard !Task.isCancelled, generation == searchLoadGeneration else { return }
                isSearchLoading = false
            }
        }
        .onDisappear {
            searchLoadTask?.cancel()
            searchLoadGeneration += 1
            isSearchLoading = false
        }
    }

    // MARK: - Session List

    @ViewBuilder
    private func sessionsEmptyView(isSearching: Bool) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: isSearching ? "magnifyingglass" : "message.badge.waveform.fill")
                .font(.system(size: 40))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            Text(isSearching ? "No results" : "No conversations yet")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            if !isSearching {
                Button("Start a chat") { onNewChat() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Color.systemBlue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// All sessions sorted by most recent activity, using the full sessions list
    /// instead of sessionChoices (which applies a 24-hour cutoff).
    /// Filters out empty sessions that never had a message sent.
    private var allSessions: [OpenClawChatSessionEntry] {
        let deduped = dedupedSessions(viewModel.sessions)
        let presentationSessions = IOSBriefSessionListPresentation
            .removingCurrentArtifactOnlyBridgeDuplicates(
                from: deduped,
                sessionKey: \.key,
                totalTokens: \.totalTokens,
                normalizedLastMessagePreview: \.lastMessagePreview
            )
        // Only hide sessions that are truly empty local placeholders —
        // sessions with ANY server metadata or local data should be shown.
        // This is critical for cross-device visibility: a new device has no
        // UserDefaults data, so sessions must survive on server fields alone.
        let nonEmpty = presentationSessions.filter { session in
            if confirmedDeletedSessionKeys.contains(session.key) { return false }
            // Hide internal background system sessions (nightly memory extraction,
            // digests, scheduled routines). Move-2 persists these gateway runs as real
            // sessions with tokens + previews, so this check must come FIRST — otherwise
            // they'd pass the "has content" tests below and spam the chat list. User-run
            // `rem-task-*` sessions are intentionally NOT hidden (reachable from the task).
            if BackgroundSessionFilter.isHidden(
                session.key,
                displayName: session.displayName
            ) { return false }
            // Hide sessions that never had a message exchanged.
            // totalTokens == 0 (or nil) means the session was opened but
            // no message was sent — these are empty placeholders.
            // Local data (preview/timestamp/name) overrides: if the user
            // sent a message this session, show it even if the server
            // hasn't updated totalTokens yet.
            if SessionLastMessagePreviews.preview(for: session.key) != nil { return true }
            if SessionLastMessageTimes.timestamp(for: session.key) != nil { return true }
            if SessionDisplayNames.name(for: session.key) != nil { return true }
            // Server transcript-derived last message (from sessions.list
            // `lastMessagePreview`) is only cached when a real message exists,
            // so it's a safe "has content" signal for sessions whose first
            // message was sent on another device.
            if SessionServerLastMessagePreviews.preview(for: session.key) != nil { return true }
            if MessageCleaner.cleanSessionListDisplayText(session.lastMessagePreview) != nil { return true }
            if MessageCleaner.isUsableSessionTitle(session.displayName) {
                return true
            }
            // NOTE: do NOT keep a session solely because `updatedAt != nil`.
            // Merely opening a fresh chat patches session defaults
            // (verboseLevel/execNode), which materializes an empty session on
            // the gateway with an `updatedAt` set but zero tokens and no
            // transcript. Trusting `updatedAt` here is what let abandoned
            // empty chats pile up as "Untitled" rows. A genuine one-message
            // session is already retained above (local/server preview or a
            // pinned name) or below (totalTokens > 0), so dropping the bare
            // `updatedAt` check does not hide real conversations.
            if let tokens = session.totalTokens, tokens > 0 { return true }
            return false
        }
        let sorted = nonEmpty.sorted { lhs, rhs in
            sessionTimestamp(lhs) > sessionTimestamp(rhs)
        }
        guard !searchQuery.isEmpty else { return sorted }
        return sorted.filter { session in
            sessionDisplayName(session).lowercased().contains(searchQuery)
            || (SessionLastMessagePreviews.preview(for: session.key)?.lowercased().contains(searchQuery) ?? false)
            || (SessionServerLastMessagePreviews.preview(for: session.key)?.lowercased().contains(searchQuery) ?? false)
            || (session.lastMessagePreview?.lowercased().contains(searchQuery) ?? false)
        }
    }

    /// SwiftUI observes only the accepted view-model snapshot. This keeps
    /// metadata side effects behind the view model's request-order watermark:
    /// a slower rejected response can never pin an older title locally.
    private var acceptedSessionMetadataVersion: Int {
        var hasher = Hasher()
        for session in viewModel.sessions {
            hasher.combine(session.key)
            hasher.combine(session.derivedTitle)
            hasher.combine(session.displayName)
            hasher.combine(session.lastMessagePreview != nil)
            hasher.combine(session.totalTokens)
        }
        return hasher.finalize()
    }

    private func reconcileAcceptedSessionMetadata() {
        let acceptedKeys = Set(viewModel.sessions.map(\.key))
        confirmedDeletedSessionKeys.formIntersection(acceptedKeys)

        var acceptedTitles: [String: String] = [:]
        for session in viewModel.sessions {
            if let stableTitle = MessageCleaner.acceptedSessionTitle(
                derivedTitle: session.derivedTitle,
                displayName: session.displayName,
                lastMessagePreview: session.lastMessagePreview,
                totalTokens: session.totalTokens)
            {
                acceptedTitles[session.key] = stableTitle
            }
        }
        SessionDisplayNames.setNamesIfAbsent(acceptedTitles)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Deduplicate sessions by key, keeping the most recently updated entry.
    private func dedupedSessions(_ sessions: [OpenClawChatSessionEntry]) -> [OpenClawChatSessionEntry] {
        var seen = Set<String>()
        var result: [OpenClawChatSessionEntry] = []
        let sorted = sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        for entry in sorted {
            guard !seen.contains(entry.key) else { continue }
            seen.insert(entry.key)
            result.append(entry)
        }
        return result
    }

    // MARK: - Session Row

    @ViewBuilder
    private func sessionRow(_ session: OpenClawChatSessionEntry) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(sessionDisplayName(session))
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(relativeTimestamp(for: session))
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }

                if let subtitle = sessionSubtitle(for: session) {
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    /// Returns the last-message timestamp if tracked locally, otherwise falls back to updatedAt.
    private func sessionTimestamp(_ session: OpenClawChatSessionEntry) -> Date {
        if let local = SessionLastMessageTimes.timestamp(for: session.key) {
            return local
        }
        if let ms = session.updatedAt {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return .distantPast
    }

    /// Relative timestamp string: "Just now", "5m", "2h", "Yesterday", "Mon", or "Feb 1".
    private func relativeTimestamp(for session: OpenClawChatSessionEntry) -> String {
        let date = sessionTimestamp(session)
        guard date != .distantPast else { return "" }
        let now = Date()
        let seconds = now.timeIntervalSince(date)

        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }

        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        // Within the last week — show day name
        if seconds < 7 * 86400 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }

        // Older — show abbreviated date
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Resolves a display name for a session, filtering out generic client and
    /// device names so a row is never titled "iPhone 17 Pro".
    private func sessionDisplayName(_ session: OpenClawChatSessionEntry) -> String {
        if let dailyTitle = BriefContext.displayTitle(
            for: session.key,
            accountID: gateway.authenticatedAccountIDForRecovery
        ) {
            return dailyTitle
        }
        // Clean + validate each candidate via the shared helper: a pinned/derived
        // title that captured an "untrusted metadata" / fenced-json envelope
        // (channel/inbound message) renders as real text, and a device-name
        // title (the gateway labels sessions with the connecting device's name)
        // is rejected so we fall through to the message-derived name. Display-time
        // only — the stored name is untouched.
        if let local = MessageCleaner.usableSessionTitle(SessionDisplayNames.name(for: session.key)) {
            return local
        }
        if let derived = MessageCleaner.usableSessionTitle(session.derivedTitle) {
            return derived
        }
        if let server = MessageCleaner.usableSessionTitle(session.displayName) {
            return server
        }
        return "Untitled chat"
    }

    /// Resolves the one-line subtitle under a session row. Prefers the last
    /// message exchanged on this device, then the request-scoped gateway
    /// `lastMessagePreview` (with the older persisted server-preview store as a
    /// compatibility fallback), and only then a generic placeholder.
    private func sessionSubtitle(for session: OpenClawChatSessionEntry) -> String? {
        SessionRowSubtitleResolver.resolve(
            localPreview: MessageCleaner.cleanSessionListDisplayText(
                SessionLastMessagePreviews.preview(for: session.key)),
            serverPreview: MessageCleaner.cleanSessionListDisplayText(
                session.lastMessagePreview
                    ?? SessionServerLastMessagePreviews.preview(for: session.key)),
            totalTokens: session.totalTokens,
            hasUpdatedAt: session.updatedAt != nil
        )
    }

    // MARK: - Actions

    private func deleteSession(_ session: OpenClawChatSessionEntry) {
        Task {
            struct DeleteParams: Codable { let key: String }
            do {
                let data = try JSONEncoder().encode(DeleteParams(key: session.key))
                guard let params = String(data: data, encoding: .utf8) else { return }
                let chatSession = await gateway.client.chatSession
                _ = try await chatSession.request(
                    method: "sessions.delete",
                    paramsJSON: params,
                    timeoutSeconds: 10)

                SessionDisplayNames.removeName(for: session.key)
                SessionLastMessageTimes.remove(session.key)
                SessionLastMessagePreviews.remove(session.key)
                SessionServerLastMessagePreviews.remove(session.key)
                confirmedDeletedSessionKeys.insert(session.key)
                let refreshLimit = max(
                    requestedLimit,
                    viewModel.sessionsLimitApplied ?? viewModel.sessions.count)
                requestedLimit = refreshLimit
                if !(await viewModel.reloadSessions(limit: refreshLimit)) {
                    sessionDeleteAlert = SessionDeleteAlert(
                        title: "Conversation Deleted",
                        message: "The conversation was deleted, but the list could not refresh. Pull to refresh and try again.")
                } else {
                    await loadUntilVisibleOrComplete()
                }
            } catch {
                sessionDeleteAlert = SessionDeleteAlert(
                    title: "Couldn’t Delete Conversation",
                    message: "The conversation was not deleted and is still available. Try again.")
            }
        }
    }

    private func loadMoreIfNeeded(after session: OpenClawChatSessionEntry) {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.key == allSessions.last?.key,
              !isLoadingMore,
              let nextLimit = SessionListPagination.nextLimit(
                currentLimit: requestedLimit,
                receivedCount: viewModel.sessions.count,
                hasMore: viewModel.sessionsHasMore)
        else { return }

        isLoadingMore = true
        loadMoreFailed = false
        Task {
            let previousVisibleTail = allSessions.last?.key
            let succeeded = await viewModel.reloadSessions(limit: nextLimit)
            guard !Task.isCancelled else {
                isLoadingMore = false
                return
            }
            if succeeded {
                requestedLimit = nextLimit
                failedExpansionLimit = nil
                await loadUntilVisibleTailAdvances(from: previousVisibleTail)
            } else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
            }
            isLoadingMore = false
        }
    }

    @ViewBuilder
    private var connectingView: some View {
        ChatConnectionRecoveryCard(
            connectionState: gateway.connectionState,
            onRetry: onRetryConnection,
            onReviewConnection: onReviewConnection
        )
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionsLoadErrorView(_ details: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Conversations", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The agent is connected, but its conversations could not be loaded.")
        } actions: {
            Button("Try Again") {
                hasLoadedOnce = false
                Task { await retrySessionsLoad() }
            }
            .buttonStyle(.borderedProminent)

            DisclosureGroup("Technical details") {
                Text(details)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    private func loadInitialSessionsIfNeeded() async {
        guard !isInitialRequestInFlight else { return }
        requestedLimit = SessionListPagination.restoredLimit(
            currentLimit: requestedLimit,
            appliedLimit: viewModel.sessionsLimitApplied,
            cachedCount: viewModel.sessions.count)
        isInitialRequestInFlight = true
        let succeeded = await viewModel.reloadSessions(limit: requestedLimit)
        if succeeded {
            loadMoreFailed = false
            failedExpansionLimit = nil
            await loadUntilVisibleOrComplete()
        }
        isInitialRequestInFlight = false
        hasLoadedOnce = true
    }

    private func retrySessionsLoad() async {
        guard !isInitialRequestInFlight else { return }
        isInitialRequestInFlight = true
        let retryLimit = failedExpansionLimit ?? requestedLimit
        let succeeded = await viewModel.reloadSessions(limit: retryLimit)
        isInitialRequestInFlight = false
        hasLoadedOnce = true
        guard succeeded else {
            failedExpansionLimit = retryLimit
            loadMoreFailed = true
            return
        }
        requestedLimit = max(requestedLimit, retryLimit)
        failedExpansionLimit = nil
        loadMoreFailed = false
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await loadUntilVisibleOrComplete()
        } else {
            await loadRemainingSessionsForSearch()
        }
    }

    private func retryLoadMore() {
        guard !isLoadingMore else { return }
        let nextLimit = failedExpansionLimit ?? SessionListPagination.nextLimit(
                currentLimit: requestedLimit,
                receivedCount: viewModel.sessions.count,
                hasMore: viewModel.sessionsHasMore)
        guard let nextLimit else { return }
        isLoadingMore = true
        loadMoreFailed = false
        Task {
            let previousVisibleTail = allSessions.last?.key
            let succeeded = await viewModel.reloadSessions(limit: nextLimit)
            guard !Task.isCancelled else {
                isLoadingMore = false
                return
            }
            if succeeded {
                requestedLimit = nextLimit
                failedExpansionLimit = nil
                await loadUntilVisibleTailAdvances(from: previousVisibleTail)
            } else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
            }
            isLoadingMore = false
        }
    }

    private func loadRemainingSessionsForSearch() async {
        while isLoadingMore, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        while !Task.isCancelled {
            let nextLimit: Int?
            if let total = viewModel.sessionsTotalCount, total > requestedLimit {
                nextLimit = total
            } else {
                nextLimit = SessionListPagination.nextLimit(
                    currentLimit: requestedLimit,
                    receivedCount: viewModel.sessions.count,
                    hasMore: viewModel.sessionsHasMore)
            }
            guard let nextLimit else { return }
            let succeeded = await viewModel.reloadSessions(limit: nextLimit)
            guard !Task.isCancelled else { return }
            guard succeeded else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
                return
            }
            requestedLimit = nextLimit
            failedExpansionLimit = nil
            if viewModel.sessionsHasMore == false { return }
        }
    }

    /// A server page can consist entirely of internal/background sessions that are intentionally
    /// filtered from this surface. Keep paging until at least one real conversation is visible or
    /// the authoritative list is exhausted, rather than presenting a false empty state.
    private func loadUntilVisibleOrComplete() async {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        while allSessions.isEmpty, !Task.isCancelled {
            guard let nextLimit = SessionListPagination.nextLimit(
                currentLimit: requestedLimit,
                receivedCount: viewModel.sessions.count,
                hasMore: viewModel.sessionsHasMore)
            else { return }
            let succeeded = await viewModel.reloadSessions(limit: nextLimit)
            guard !Task.isCancelled else { return }
            guard succeeded else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
                return
            }
            requestedLimit = nextLimit
            failedExpansionLimit = nil
        }
    }

    /// Continue through hidden-only windows after a visible row triggered
    /// pagination. Stop as soon as the visible tail changes or the gateway says
    /// the authoritative list is complete.
    private func loadUntilVisibleTailAdvances(from previousVisibleTail: String?) async {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        while !Task.isCancelled {
            guard let nextLimit = SessionListPagination.nextLimitPastFilteredWindow(
                previousVisibleTail: previousVisibleTail,
                currentVisibleTail: allSessions.last?.key,
                currentLimit: requestedLimit,
                receivedCount: viewModel.sessions.count,
                hasMore: viewModel.sessionsHasMore)
            else { return }
            let succeeded = await viewModel.reloadSessions(limit: nextLimit)
            guard !Task.isCancelled else { return }
            guard succeeded else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
                return
            }
            requestedLimit = nextLimit
            failedExpansionLimit = nil
        }
    }
}

enum IOSBriefSessionListPresentation {
    static func removingCurrentArtifactOnlyBridgeDuplicates<Entry>(
        from entries: [Entry],
        now: Date = Date(),
        calendar: Calendar = .current,
        sessionKey: (Entry) -> String,
        totalTokens: (Entry) -> Int?,
        normalizedLastMessagePreview: (Entry) -> String?
    ) -> [Entry] {
        BriefSessionListDeduplicator.removingCurrentArtifactOnlyBridgeDuplicates(
            from: entries,
            now: now,
            calendar: calendar,
            sessionKey: sessionKey,
            totalTokens: totalTokens,
            hasLocalUserInteraction: { entry in
                let key = sessionKey(entry)
                return SessionLastMessagePreviews.preview(for: key) != nil
                    || SessionLastMessageTimes.timestamp(for: key) != nil
            },
            normalizedLastMessagePreview: {
                MessageCleaner.cleanSessionListDisplayText(normalizedLastMessagePreview($0))
            }
        )
    }
}
