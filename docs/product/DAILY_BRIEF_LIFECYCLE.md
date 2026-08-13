# Daily Brief lifecycle and source of truth

This is the short operational contract for future agents. It supersedes older design notes where
they disagree about conversation identity, notification ordering, or fallback prose.

## User outcome

Agenda Summary, the Today chat, spoken playback, and a Daily Brief notification must describe the
same assistant-authored artifact. A notification is a doorway into that conversation, not a second
copy of the brief.

## Sources of truth

- Trigger selection and latest processing evidence: `user_checkins` through
  `checkin.service.ts`. All triggers off means no scheduled brief and no scheduled notification.
- Live task/calendar buckets: `brief.service.ts` over backend task data in the user's timezone.
- User-visible prose: the current `daily_briefs` pointer plus its matching
  `daily_brief_artifacts` revision.
- Visible delivery proof: `daily_brief_artifact_deliveries` for `rem-orchestrator`. A cache row
  without this exact-revision proof is not a brief the app may announce or narrate.
- Agenda may promote `/brief` prose into durable transcript/read state only when the response also
  advertises the delivered `rem-orchestrator` authority. Same-day equality with nil/legacy authority
  is still deterministic fallback, not delivery proof.
- Conversation: one durable `rem-orchestrator` transcript. Message timestamps create day dividers.
- Playback/read state: the account/day/session/prose fingerprint used by the iOS explicit playback
  controller. Notification payload text is never playback authority.

## Scheduled transition

1. An enabled local-time trigger becomes due.
2. Gather live backend task/calendar buckets.
3. Author or recover one canonical artifact for that local-day/slot.
4. Prove that exact current revision is visibly delivered to `rem-orchestrator`.
5. Send one APNs alert using collapse/thread id `rem-daily-brief`.
6. Stamp the trigger as processed.

If steps 3 or 4 fail, send no notification and do not stamp; the next scheduler tick retries. If
authoring is intentionally feature-disabled, stamp without sending so the worker does not churn.
APNs configuration/token absence happens after artifact proof and does not re-author the brief.

The standalone `brief:author` job is not a second scheduling authority. It only retries rollout
transcript delivery for an already-authored canonical gateway artifact. It never selects users merely
because they have tasks or an enabled-but-not-due trigger, never authors a new artifact, and never
sends APNs. Therefore all triggers disabled means no new scheduled artifact or notification, while an
artifact authored before disablement may still finish its interrupted transcript delivery.

## Notification transition

- The alert body is intentionally neutral because the lock screen is not authenticated. Tapping it
  resolves the account-bound canonical artifact; private task prose never travels in the alert.
- APNs destination ownership is exclusive per token/environment. Current clients send a globally
  ordered millisecond generation (monotonic within the install), so delayed requests cannot reclaim
  the destination. Sign-out leaves a disabled generation tombstone until a newer account registers,
  including cold-process logout via the persisted last registered token. Generation-0 legacy
  account switches fail with retryable 409 while the prior owner still exists, then succeed after
  that account's delayed user-scoped unregister; the backend never disguises another owner's row as
  a successful registration. Migration adopts enabled pre-fence destinations under the same
  per-user legacy authority so shipped clients whose local success cache suppresses a launch POST
  keep receiving pushes; disabled pre-fence destinations are physically removed. Authority copying
  row-locks the destination through conflict handling so concurrent rotation/logout cannot be
  followed by stale resurrection. If an upgraded client logs out before its legacy cache is upgraded,
  one transaction tombstones the new installation and retires that exact legacy account/token while
  preserving the account's other legacy devices.
- Backend migrations complete before HTTP traffic is accepted; registration never races the schema
  that enforces exclusive destination ownership.
- The server uses one APNs collapse id and Notification Center thread so a newer brief replaces or
  groups older delivery. A durable per-account notification fence carries the latest local day and
  slot and is row-locked through the APNs call, so overlapping workers cannot deliver an older
  brief after a newer one, including across midnight.
- Foreground delivery removes older alerts in that thread.
- Account-bound notifications resolve to `remclaw://brief/listen?accountId=…`. Ownerless legacy
  check-in alerts intentionally only open the app: after an account switch there is no trustworthy
  way to prove which account authored them, so they must not start playback in the current account.
- The app then runs the ordinary explicit playback flow: fetch `/brief`, open `rem-orchestrator`,
  match the exact delivered assistant message, scroll to it, and start Voice Chat narration. Because
  `/brief` already proves the current account-local-day delivery, explicit Read ignores the matched
  message's projected timestamp and the device calendar entirely. Without that backend authority,
  discovery still requires a timestamp on the device's current day and cannot authorize historical
  equality alone.
- A stale tap resolves forward to the newest delivered artifact; it never speaks stale payload text.
- A newer notification Read command cancels and invalidates an older in-flight read before starting
  its own fetch. If the older read is already audible, supersession stops its continuation-backed
  player synchronously; a failed replacement cannot leave stale prose or phantom playback state.
  A claimed command remains pending unless the replacement request actually starts.
- Immediately before either rollout transcript injection, delivery preparation requires the exact
  artifact revision to still back the canonical `daily_briefs` pointer. An older slot that loses the
  pointer while paused performs no gateway side effect. Preparation commits the reconciliation
  baseline before the side effect; a second exact-state PostgreSQL transaction then keeps the
  canonical, artifact, and delivery rows locked through `chat.inject`. A newer-slot pointer advance
  waits cross-process until that gateway side effect and delivery state finish, while a crash still
  leaves the baseline available to reconcile an ambiguous injection.

## Current input boundary

The scheduled gather step is backed by Rem's server-side task/calendar tables plus a backend-owned,
read-only Gmail snapshot collected only for an enabled check-in that is due. Gmail requires ACTIVE
Composio grants; paused grants are excluded. Every active account is addressed by its exact ID up to
a small cap, and collection is bounded by a pinned action/version, wall time, pages, items, and an
exact rolling time window. Only sender, subject/preview, provider message/thread ID and timestamp
enter an in-memory backend model prompt. Artifact storage retains producer/capture/source/stable-ID/fingerprint
provenance, not mailbox text. Connector failure is `unavailable`, never a trustworthy empty result,
and task-only authoring continues. Client-writable suggestion signals are not evidence of collection.

Connector text is explicitly delimited as untrusted quoted data and sent only through the backend's
plain GMI chat-completions seam, which provides no tool definitions. Raw email data never enters
gateway `chat.send`, gateway authoring JSONL, Postgres, or application logs; only final model prose
is injected into Today. A tool-less-model failure falls back to task-only gateway authoring when
tasks exist, while a connector-only brief fails closed.
The Automation UI remains Planned because the backend has no safe public source-status contract yet.
Exact follow-up: expose authenticated last-capture availability, capture time, bounded source name,
and unavailable reason from trusted artifact provenance, then promote Gmail without exposing content
or account IDs. Cloud Browser remains Planned.

## Recovery and deletion

- A failed authoring/delivery lease is released and safely retried.
- The staging-only brief repair command may adopt an exact, uniquely verified transcript message;
  it never guesses by first/latest position.
- Trigger disablement stops future scheduled creation and notifications; it does not delete Today
  history.
- Newer artifacts supersede older notification content. Historical chat messages remain as the
  user's durable record.
