import Foundation

/// Classifies gateway chat sessions the app should hide from the user's chat list.
///
/// Move-2 (backend `gateway-agent.service`) routes cloud work through the user's gateway
/// via `chat.send`, which PERSISTS every run as a real session the app can load. That is
/// intentional for user-initiated runs, but the *background system* passes also persist —
/// and their internal prompts (the "memory keeper" extraction, daily digests, scheduled
/// routines) were leaking into the visible chat history and spamming it.
///
/// Session-key conventions (backend `gateway-agent.service` / `memory-extraction.service`
/// / `brief-authoring.service`, plus upstream memory-core):
///   - `rem-memory-<yyyymmdd>`         — nightly memory-extraction ("Dreaming") pass → HIDE
///   - `rem-digest-<kind>-<date>`      — proactive digest pass                       → HIDE
///   - `rem-routine-<id>`              — scheduled routine run                       → HIDE
///   - `rem-brief-author-<day>-<runId>`— EPHEMERAL daily-brief authoring turn        → HIDE
///                                 (the machine writes the brief prose in a fresh throwaway
///                                  context; `brief-authoring.service.authoringSessionKey`.
///                                  The raw authoring PROMPT was leaking as a visible chat.)
///   - `rem-signal-triage-<uuid>`      — background signal-relevance classification    → HIDE
///                                 (one per ingest tick, holding the user's task titles and the
///                                  batch's senders/subjects. The backend deletes each session
///                                  after its turn; this is the second line for undelivered
///                                  cleanups and for the ones already on live gateways.)
///   - `rem-orchestrator`              — the VISIBLE durable Rem conversation          → KEEP
///                                 (GET /api/v1/brief returns this; day boundaries are UI dividers)
///   - `rem-today-<yyyymmdd>`          — legacy visible per-day brief conversations     → KEEP
///   - `rem-task-<taskId>`             — user-initiated "Run now" on a task            → KEEP
///                                 (must stay reachable from the task → chat link)
///   - `dreaming-narrative-*`           — upstream memory-core narrative pass           → HIDE
///   - managed "Memory Dreaming Promotion" cron session                               → HIDE
///   - everything else                 — a normal user chat                           → KEEP
///
/// The gateway may return either a bare key or its canonical `agent:<agentId>:<key>` form.
/// Classification strips only that structured wrapper before applying exact prefix checks.
enum BackgroundSessionFilter {
    /// Session-key prefixes for background SYSTEM runs that should not appear in the chat list.
    /// `rem-task-`, `rem-orchestrator`, and legacy `rem-today-` are deliberately absent: they are
    /// user-reachable conversations and must stay in the list.
    /// `rem-brief-author-` is the EPHEMERAL brief-authoring turn (raw prompt was leaking as a chat).
    /// `rem-signal-triage-` is the background relevance classifier. The backend deletes each of its
    /// sessions after the turn; this entry is the SECOND line, covering runs where the delete could
    /// not be delivered, plus the ones already on gateways from before that fix. Measured on
    /// remclaw-00000000 before it: 24 openable triage chats, each holding the user's open task
    /// titles and every sender and subject in that tick's batch.
    static let hiddenPrefixes = [
        "rem-memory-",
        "rem-digest-",
        "rem-routine-",
        "rem-brief-author-",
        "rem-signal-triage-",
        "dreaming-narrative-",
    ]

    /// Upstream owns this exact managed-memory job name. Generic `cron:*` sessions remain
    /// visible because user-created automations may intentionally produce reachable chats.
    static let managedBackgroundDisplayNames = ["Cron: Memory Dreaming Promotion"]

    /// True when `sessionKey` is a background system session that should be hidden from the
    /// main chat list. False for user chats and for user-initiated `rem-task-*` runs.
    static func isHidden(_ sessionKey: String, displayName: String? = nil) -> Bool {
        let bareKey = strippingCanonicalAgentPrefix(from: sessionKey)
        if hiddenPrefixes.contains(where: { bareKey.hasPrefix($0) }) {
            return true
        }

        let normalizedDisplayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bareKey.hasPrefix("cron:")
            && (normalizedDisplayName.map(managedBackgroundDisplayNames.contains) ?? false)
    }

    /// `sessions.list` canonicalizes custom aliases to `agent:<agentId>:<alias>`. Strip
    /// exactly the first two structured components; leave bare and malformed keys untouched.
    private static func strippingCanonicalAgentPrefix(from sessionKey: String) -> String {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent", !parts[1].isEmpty else {
            return sessionKey
        }
        let bareKey = parts.dropFirst(2).joined(separator: ":")
        return bareKey.isEmpty ? sessionKey : bareKey
    }
}
