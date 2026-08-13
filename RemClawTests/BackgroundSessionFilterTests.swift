import Foundation
import Testing
@testable import RemClaw

struct BackgroundSessionFilterTests {
    @Test func hidesBackgroundSystemSessions() {
        #expect(BackgroundSessionFilter.isHidden("rem-memory-20260630"))
        #expect(BackgroundSessionFilter.isHidden("rem-digest-morning-20260630"))
        #expect(BackgroundSessionFilter.isHidden("rem-routine-abc123"))
        #expect(BackgroundSessionFilter.isHidden("agent:main:rem-memory-20260630"))
        #expect(BackgroundSessionFilter.isHidden("agent:orchestrator:rem-digest-morning-20260630"))
    }

    @Test func hidesEphemeralBriefAuthoringSessions() {
        // rem-brief-author-<localday>-<runId> is the machine's throwaway authoring turn;
        // the raw authoring prompt was leaking into the visible chat list.
        #expect(BackgroundSessionFilter.isHidden("rem-brief-author-20260724-\(UUID().uuidString)"))
        #expect(BackgroundSessionFilter.isHidden("rem-brief-author-20260724-abc123"))
        #expect(BackgroundSessionFilter.isHidden("agent:main:rem-brief-author-20260724-abc123"))
    }

    @Test func hidesUpstreamMemoryCoreSessionsWithoutHidingGenericCronChats() {
        #expect(BackgroundSessionFilter.isHidden("dreaming-narrative-light-workspace-1"))
        #expect(BackgroundSessionFilter.isHidden("agent:main:dreaming-narrative-deep-workspace-1"))
        #expect(BackgroundSessionFilter.isHidden(
            "agent:main:cron:managed-memory-job",
            displayName: "Cron: Memory Dreaming Promotion"
        ))

        #expect(!BackgroundSessionFilter.isHidden(
            "agent:main:cron:user-automation",
            displayName: "Cron: Send weekly update"
        ))
        #expect(!BackgroundSessionFilter.isHidden(
            "agent:main:user-chat",
            displayName: "Cron: Memory Dreaming Promotion"
        ))
        #expect(!BackgroundSessionFilter.isHidden(
            "agent::cron:managed-memory-job",
            displayName: "Cron: Memory Dreaming Promotion"
        ))
    }

    @Test func keepsUserInitiatedTaskRuns() {
        // rem-task-* is a user "Run now" — must stay reachable from its task.
        #expect(!BackgroundSessionFilter.isHidden("rem-task-abc123"))
        #expect(!BackgroundSessionFilter.isHidden("agent:main:rem-task-abc123"))
    }

    @Test func keepsVisibleDailyBriefConversation() {
        // rem-today-<yyyymmdd> is the visible per-day brief chat the user replies into.
        // It must NOT be hidden (and must not be caught by the rem-brief-author- prefix).
        #expect(!BackgroundSessionFilter.isHidden("rem-today-20260724"))
        #expect(!BackgroundSessionFilter.isHidden("agent:main:rem-today-20260724"))
    }

    @Test func keepsNormalUserChats() {
        #expect(!BackgroundSessionFilter.isHidden("main"))
        #expect(!BackgroundSessionFilter.isHidden("01J8X2K9ABCDEF"))
        #expect(!BackgroundSessionFilter.isHidden(""))
        #expect(!BackgroundSessionFilter.isHidden("agent::rem-memory-20260630"))
        // Not a background prefix even though it contains the substring.
        #expect(!BackgroundSessionFilter.isHidden("my-rem-memory-notes"))
        #expect(!BackgroundSessionFilter.isHidden("agent:main:telegram:group:rem-memory-notes"))
    }

    /// The signal-relevance triage session.
    ///
    /// Measured on remclaw-00000000 before the backend started cleaning these up: `sessions.list`
    /// returned 24 `agent:main:rem-signal-triage-<uuid>` conversations, every one classified
    /// hiddenByApp=NO — openable in the user's chat list, each holding their open task titles plus
    /// every sender and subject in that ingest tick's batch.
    ///
    /// The backend now removes each session after its turn, so this filter is the SECOND line: it
    /// covers runs where the delete could not be delivered, and the sessions already sitting on
    /// live gateways from before that fix. Without these cases the entry could be deleted from
    /// `hiddenPrefixes` and nothing anywhere would go red.
    @Test
    func hidesSignalTriageSessions() {
        #expect(BackgroundSessionFilter.isHidden("rem-signal-triage-1F2E3D4C-5B6A"))
        // The canonical wrapper the gateway actually returns.
        #expect(BackgroundSessionFilter.isHidden("agent:main:rem-signal-triage-1F2E3D4C-5B6A"))
    }

    /// Prefix, not substring — the same trap the memory cases already guard.
    @Test
    func doesNotHideUserChatsMerelyMentioningTriage() {
        #expect(!BackgroundSessionFilter.isHidden("my-rem-signal-triage-notes"))
        #expect(!BackgroundSessionFilter.isHidden("agent:main:telegram:group:rem-signal-triage-x"))
        // A user-reachable conversation must never be swept up by this.
        #expect(!BackgroundSessionFilter.isHidden("rem-orchestrator"))
    }
}
