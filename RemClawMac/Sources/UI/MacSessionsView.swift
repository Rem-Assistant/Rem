import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// Lists all past chat sessions, matching the iOS ChatHistoryView.
/// Tapping a session navigates to the Chat tab with that session active.
struct MacSessionsView: View {
    private struct SessionDeleteAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum SessionsViewState {
        case disconnected
        case waitingForRequest
        case loading
        case empty(isSearching: Bool)
        case loaded
        case error(SessionsLoadError)
    }

    private struct SessionsLoadError {
        let message: String
        let details: String
    }

    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(MacRouter.self) private var router

    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var hasLoadedOnce = false
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var lastLoadError: SessionsLoadError?
    @State private var requestedLimit = SessionListPagination.initialLimit
    @State private var sessionsHasMore: Bool?
    @State private var sessionsTotalCount: Int?
    @State private var isLoadingMore = false
    @State private var loadMoreFailed = false
    @State private var failedExpansionLimit: Int?
    @State private var isInitialLoadInFlight = false
    @State private var isSearchLoading = false
    @State private var searchLoadGeneration = 0
    @State private var searchLoadTask: Task<Void, Never>?
    @State private var sessionDeleteAlert: SessionDeleteAlert?
    @State private var confirmedDeletedSessionKeys = Set<String>()

    /// Session key currently being renamed via the alert.
    @State private var renamingSessionKey: String?
    @State private var renameText = ""

    var body: some View {
        Group {
            switch viewState {
            case .disconnected:
                disconnectedView
            case .waitingForRequest:
                // The gateway is ready and the uncached request is scheduled. Keep the real-row
                // skeleton stable across this first frame and the in-flight request that follows.
                loadingView
            case .loading:
                loadingView
            case .empty(let isSearching):
                emptyView(isSearching: isSearching)
            case .loaded:
                sessionsList
            case .error(let loadError):
                errorView(loadError)
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $searchText, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Chat")
                .disabled(!session.operatorReady)
            }

        }
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingSessionKey != nil },
            set: { if !$0 { renamingSessionKey = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let key = renamingSessionKey {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        MacSessionDisplayNames.setName(trimmed, for: key)
                        // Also patch on the gateway so the name persists across devices
                        patchSessionLabel(key: key, label: trimmed)
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
            await loadOnAppear()
        }
        .onChange(of: session.operatorReady) { _, ready in
            guard ready else { return }
            Task {
                if hasLoadedOnce {
                    if await fetchSessions(limit: requestedLimit) {
                        await loadUntilVisibleOrComplete()
                    }
                } else {
                    await loadOnAppear()
                }
            }
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

    // MARK: - Placeholder Views

    private var disconnectedView: some View {
        ContentUnavailableView {
            Label("Gateway Disconnected", systemImage: "bolt.slash")
        } description: {
            Text(disconnectedMessage)
        } actions: {
            Button("Connect") {
                session.connectIfConfigured()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.brandBlue)
            .disabled(!session.isConfigured)

            if !session.isConfigured {
                Button("Open Settings") {
                    router.selectedScreen = .settings
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        // Shimmering placeholder rows while the first sessions.list is in flight
        // and nothing is cached yet — mirrors the iOS ChatHistoryView loading state.
        SessionListLoadingSkeleton()
    }

    private var connectingView: some View {
        ContentUnavailableView {
            Label("Connecting to your agent", systemImage: "bolt.horizontal")
        } description: {
            Text("Conversations will load when the connection is ready.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(isSearching: Bool) -> some View {
        VStack(spacing: 12) {
            if !isSearching {
                Image(systemName: "message.badge.waveform.fill")
                    .font(DesignTokens.Typography.largeTitle)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                Text("No conversations yet")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Button("Start a chat") {
                    router.startNewChat()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.brandBlue)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(DesignTokens.Typography.largeTitle)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                Text("No results")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ loadError: SessionsLoadError) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Conversations", systemImage: "exclamationmark.triangle")
        } description: {
            Text(loadError.message)
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Retry") {
                        Task { await retrySessionsLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Color.brandBlue)
                    .disabled(isLoading || !session.operatorReady)

                    Button("Connect") {
                        session.connectIfConfigured()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.isConfigured)
                }

                DisclosureGroup("Technical details") {
                    Text(loadError.details)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        List {
            ForEach(filteredSessions) { entry in
                sessionRow(entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        router.openSession(entry.key)
                    }
                    .contextMenu {
                        if !BriefContext.isBriefSession(entry.key) {
                            Button {
                                renameText = sessionDisplayName(entry)
                                renamingSessionKey = entry.key
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                        Button(role: .destructive) {
                            deleteSession(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .onAppear {
                        loadMoreIfNeeded(after: entry)
                    }
            }

            if loadMoreFailed {
                Button("Try loading more") {
                    retryLoadMore()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Session Row

    @ViewBuilder
    private func sessionRow(_ entry: OpenClawChatSessionEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(sessionDisplayName(entry))
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(relativeTimestamp(for: entry))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                }

                if let preview = SessionRowSubtitleResolver.resolve(
                    localPreview: MessageCleaner.cleanSessionListDisplayText(
                        MacSessionLastMessagePreviews.preview(for: entry.key)),
                    serverPreview: MessageCleaner.cleanSessionListDisplayText(
                        entry.lastMessagePreview
                            ?? SessionServerLastMessagePreviews.preview(for: entry.key)),
                    totalTokens: entry.totalTokens,
                    hasUpdatedAt: entry.updatedAt != nil) {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Data

    private var filteredSessions: [OpenClawChatSessionEntry] {
        let deduped = dedupedSessions(sessions)
        let presentationSessions = MacBriefSessionListPresentation
            .removingCurrentArtifactOnlyBridgeDuplicates(
                from: deduped,
                sessionKey: \.key,
                totalTokens: \.totalTokens,
                normalizedLastMessagePreview: \.lastMessagePreview
            )
        let nonEmpty = presentationSessions.filter { entry in
            if confirmedDeletedSessionKeys.contains(entry.key) { return false }
            // Hide internal background system sessions (memory extraction, digests,
            // scheduled routines) — Move-2 persists these gateway runs with tokens +
            // previews, so this must come FIRST or they'd pass the checks below. User-run
            // `rem-task-*` sessions stay visible (reachable from their task).
            if BackgroundSessionFilter.isHidden(
                entry.key,
                displayName: entry.displayName
            ) { return false }
            // Show sessions that have local data or server-side token usage
            if MacSessionLastMessagePreviews.preview(for: entry.key) != nil { return true }
            if SessionServerLastMessagePreviews.preview(for: entry.key) != nil { return true }
            if MessageCleaner.cleanSessionListDisplayText(entry.lastMessagePreview) != nil { return true }
            if MacSessionLastMessageTimes.timestamp(for: entry.key) != nil { return true }
            if MacSessionDisplayNames.name(for: entry.key) != nil { return true }
            if MessageCleaner.isUsableSessionTitle(entry.displayName) { return true }
            if let tokens = entry.totalTokens, tokens > 0 { return true }
            return false
        }
        let sorted = nonEmpty.sorted { lhs, rhs in
            sessionTimestamp(lhs) > sessionTimestamp(rhs)
        }
        guard !searchQuery.isEmpty else { return sorted }
        return sorted.filter { entry in
            sessionDisplayName(entry).lowercased().contains(searchQuery)
            || (MacSessionLastMessagePreviews.preview(for: entry.key)?.lowercased().contains(searchQuery) ?? false)
            || (SessionServerLastMessagePreviews.preview(for: entry.key)?.lowercased().contains(searchQuery) ?? false)
            || (entry.lastMessagePreview?.lowercased().contains(searchQuery) ?? false)
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var viewState: SessionsViewState {
        if isSearchLoading && filteredSessions.isEmpty {
            return .loading
        }
        let baseState = SessionsListViewStateResolver.resolve(
            operatorReady: session.operatorReady,
            isLoading: isInitialLoadInFlight,
            hasLoadedOnce: hasLoadedOnce,
            hasVisibleSessions: !filteredSessions.isEmpty,
            hasLoadError: lastLoadError != nil
        )

        switch baseState {
        case .disconnected:
            return .disconnected
        case .waitingForRequest:
            return .waitingForRequest
        case .loading:
            return .loading
        case .empty:
            return .empty(isSearching: !searchQuery.isEmpty)
        case .loaded:
            return .loaded
        case .error:
            if let loadError = lastLoadError {
                return .error(loadError)
            }
            return .empty(isSearching: !searchQuery.isEmpty)
        }
    }

    private var disconnectedMessage: String {
        switch session.connectionState {
        case .pairingRequired:
            return "Approval is pending for this Mac. Approve the request, then reconnect to view sessions."
        case .unauthorized:
            return "Your gateway token is no longer valid. Reconnect to continue."
        case .unreachable(let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Can’t reach the gateway. \(detail)"
            }
            return "Can’t reach the gateway. Connect to your gateway to view sessions."
        case .connecting:
            return "Connecting to your gateway…"
        case .disconnected, .connected:
            return "Connect to your gateway to view sessions."
        }
    }

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

    private func loadOnAppear() async {
        guard session.operatorReady else { return }
        guard !isInitialLoadInFlight else { return }
        isInitialLoadInFlight = true
        defer {
            isInitialLoadInFlight = false
            hasLoadedOnce = true
        }
        if await fetchSessions() {
            await loadUntilVisibleOrComplete()
        }
    }

    @discardableResult
    private func fetchSessions(limit: Int? = nil) async -> Bool {
        guard !isLoading else { return false }
        guard session.operatorReady else { return false }
        isLoading = true
        defer { isLoading = false }
        lastLoadError = nil

        do {
            let transport = await session.makeChatTransport()
            let response = try await transport.listSessions(limit: limit ?? requestedLimit)
            await MainActor.run {
                sessions = response.sessions
                reconcileAcceptedSessionMetadata(response.sessions)
                sessionsHasMore = response.hasMore
                sessionsTotalCount = response.totalCount
                requestedLimit = max(
                    requestedLimit,
                    response.limitApplied ?? limit ?? requestedLimit)
            }
            return true
        } catch {
            let nsError = error as NSError
            lastLoadError = SessionsLoadError(
                message: "The gateway is online, but we couldn’t fetch conversations.",
                details: "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
            #if DEBUG
            print("[MacSessionsView] fetchSessions failed: \(error)")
            #endif
            return false
        }
    }

    /// Reconcile only the response accepted by this view. This both prevents a
    /// cross-device follow-up from being mistaken for a first message and lets
    /// deletion tombstones expire once an authoritative refresh omits the key.
    private func reconcileAcceptedSessionMetadata(_ acceptedSessions: [OpenClawChatSessionEntry]) {
        let acceptedKeys = Set(acceptedSessions.map(\.key))
        confirmedDeletedSessionKeys.formIntersection(acceptedKeys)

        var acceptedTitles: [String: String] = [:]
        for entry in acceptedSessions {
            if let stableTitle = MessageCleaner.acceptedSessionTitle(
                derivedTitle: entry.derivedTitle,
                displayName: entry.displayName,
                lastMessagePreview: entry.lastMessagePreview,
                totalTokens: entry.totalTokens)
            {
                acceptedTitles[entry.key] = stableTitle
            }
        }
        MacSessionDisplayNames.setNamesIfAbsent(acceptedTitles)
    }

    private func retrySessionsLoad() async {
        guard !isInitialLoadInFlight else { return }
        isInitialLoadInFlight = true
        defer {
            isInitialLoadInFlight = false
            hasLoadedOnce = true
        }
        let retryLimit = failedExpansionLimit ?? requestedLimit
        guard await fetchSessions(limit: retryLimit) else {
            failedExpansionLimit = retryLimit
            loadMoreFailed = true
            return
        }
        requestedLimit = max(requestedLimit, retryLimit)
        failedExpansionLimit = nil
        loadMoreFailed = false
        if searchQuery.isEmpty {
            await loadUntilVisibleOrComplete()
        } else {
            await loadRemainingSessionsForSearch()
        }
    }

    private func loadMoreIfNeeded(after entry: OpenClawChatSessionEntry) {
        guard searchQuery.isEmpty,
              entry.key == filteredSessions.last?.key,
              !isLoading,
              !isLoadingMore,
              let nextLimit = SessionListPagination.nextLimit(
                currentLimit: requestedLimit,
                receivedCount: sessions.count,
                hasMore: sessionsHasMore)
        else { return }

        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            loadMoreFailed = false
            let previousVisibleTail = filteredSessions.last?.key
            if await fetchSessions(limit: nextLimit) {
                guard !Task.isCancelled else { return }
                requestedLimit = nextLimit
                failedExpansionLimit = nil
                await loadUntilVisibleTailAdvances(from: previousVisibleTail)
            } else {
                guard !Task.isCancelled else { return }
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
            }
        }
    }

    private func retryLoadMore() {
        guard !isLoadingMore else { return }
        let nextLimit = failedExpansionLimit ?? SessionListPagination.nextLimit(
            currentLimit: requestedLimit,
            receivedCount: sessions.count,
            hasMore: sessionsHasMore)
        guard let nextLimit else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            loadMoreFailed = false
            let previousVisibleTail = filteredSessions.last?.key
            if await fetchSessions(limit: nextLimit) {
                guard !Task.isCancelled else { return }
                requestedLimit = nextLimit
                failedExpansionLimit = nil
                await loadUntilVisibleTailAdvances(from: previousVisibleTail)
            } else {
                guard !Task.isCancelled else { return }
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
            }
        }
    }

    private func loadRemainingSessionsForSearch() async {
        while (isLoading || isLoadingMore), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        while !Task.isCancelled {
            let nextLimit: Int?
            if let total = sessionsTotalCount, total > requestedLimit {
                nextLimit = total
            } else {
                nextLimit = SessionListPagination.nextLimit(
                    currentLimit: requestedLimit,
                    receivedCount: sessions.count,
                    hasMore: sessionsHasMore)
            }
            guard let nextLimit else { return }
            let succeeded = await fetchSessions(limit: nextLimit)
            guard !Task.isCancelled else { return }
            guard succeeded else {
                failedExpansionLimit = nextLimit
                loadMoreFailed = true
                return
            }
            requestedLimit = nextLimit
            failedExpansionLimit = nil
            if sessionsHasMore == false { return }
        }
    }

    private func loadUntilVisibleOrComplete() async {
        guard searchQuery.isEmpty else { return }
        while filteredSessions.isEmpty, !Task.isCancelled {
            guard let nextLimit = SessionListPagination.nextLimit(
                currentLimit: requestedLimit,
                receivedCount: sessions.count,
                hasMore: sessionsHasMore)
            else { return }
            let succeeded = await fetchSessions(limit: nextLimit)
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

    private func loadUntilVisibleTailAdvances(from previousVisibleTail: String?) async {
        guard searchQuery.isEmpty else { return }
        while !Task.isCancelled {
            guard let nextLimit = SessionListPagination.nextLimitPastFilteredWindow(
                previousVisibleTail: previousVisibleTail,
                currentVisibleTail: filteredSessions.last?.key,
                currentLimit: requestedLimit,
                receivedCount: sessions.count,
                hasMore: sessionsHasMore)
            else { return }
            let succeeded = await fetchSessions(limit: nextLimit)
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

    // MARK: - Helpers

    private func sessionDisplayName(_ entry: OpenClawChatSessionEntry) -> String {
        if let dailyTitle = BriefContext.displayTitle(
            for: entry.key,
            accountID: session.authenticatedAccountIDForRecovery
        ) {
            return dailyTitle
        }
        // Clean + validate each candidate via the shared helper: an
        // "untrusted metadata" / fenced-json envelope renders as real text, and
        // a device-name title (the gateway labels sessions with the connecting
        // device's name, e.g. "Sam's MacBook Pro") is rejected so we fall
        // through to the message-derived name. Display-time only.
        if let local = MessageCleaner.usableSessionTitle(MacSessionDisplayNames.name(for: entry.key)) {
            return local
        }
        if let derived = MessageCleaner.usableSessionTitle(entry.derivedTitle) {
            return derived
        }
        if let server = MessageCleaner.usableSessionTitle(entry.displayName) {
            return server
        }
        return "Untitled chat"
    }

    private func sessionTimestamp(_ entry: OpenClawChatSessionEntry) -> Date {
        if let local = MacSessionLastMessageTimes.timestamp(for: entry.key) {
            return local
        }
        if let ms = entry.updatedAt {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return .distantPast
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private func relativeTimestamp(for entry: OpenClawChatSessionEntry) -> String {
        let date = sessionTimestamp(entry)
        guard date != .distantPast else { return "" }
        let now = Date()
        let seconds = now.timeIntervalSince(date)

        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }

        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        if seconds < 7 * 86400 {
            return Self.weekdayFormatter.string(from: date)
        }

        let formatter = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? Self.monthDayFormatter
            : Self.monthDayYearFormatter
        return formatter.string(from: date)
    }

    // MARK: - Actions

    private func deleteSession(_ entry: OpenClawChatSessionEntry) {
        Task {
            struct DeleteParams: Codable { var key: String }
            do {
                let data = try JSONEncoder().encode(DeleteParams(key: entry.key))
                guard let json = String(data: data, encoding: .utf8) else { return }
                let gatewaySession = await session.client.chatSession
                _ = try await gatewaySession.request(
                    method: "sessions.delete",
                    paramsJSON: json,
                    timeoutSeconds: 10)

                MacSessionDisplayNames.removeName(for: entry.key)
                MacSessionLastMessageTimes.remove(entry.key)
                MacSessionLastMessagePreviews.remove(entry.key)
                SessionServerLastMessagePreviews.remove(entry.key)
                confirmedDeletedSessionKeys.insert(entry.key)
                sessions.removeAll { $0.key == entry.key }
                if !(await fetchSessions(limit: requestedLimit)) {
                    sessionDeleteAlert = SessionDeleteAlert(
                        title: "Conversation Deleted",
                        message: "The conversation was deleted, but the list could not refresh. Try again from Sessions.")
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

    private func patchSessionLabel(key: String, label: String) {
        Task {
            struct PatchParams: Codable {
                var key: String
                var label: String
            }
            let params = PatchParams(key: key, label: label)
            if let data = try? JSONEncoder().encode(params),
               let json = String(data: data, encoding: .utf8) {
                let gatewaySession = await session.client.chatSession
                _ = try? await gatewaySession.request(
                    method: "sessions.patch",
                    paramsJSON: json,
                    timeoutSeconds: 10)
            }
        }
    }
}

enum MacBriefSessionListPresentation {
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
                return MacSessionLastMessagePreviews.preview(for: key) != nil
                    || MacSessionLastMessageTimes.timestamp(for: key) != nil
            },
            normalizedLastMessagePreview: {
                MessageCleaner.cleanSessionListDisplayText(normalizedLastMessagePreview($0))
            }
        )
    }
}
