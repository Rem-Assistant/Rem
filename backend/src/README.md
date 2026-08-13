# Backend Source (`backend/src/`)

> The cloud server (hosted on Railway) that ties everything together. It handles user sign-in, deploys a personal AI gateway on Fly.io for each new user, stores tasks, enforces usage quotas, and processes Apple subscription receipts. The iOS and Mac apps talk to this to get their gateway credentials.

Node.js/Express backend handling authentication, gateway deployment orchestration, task management, usage tracking, and Apple In-App Purchase processing.

## Directory Structure

```
src/
├── server.ts                    # Express app initialization + migration runner
├── config/
│   ├── env.ts                  # Lazy-loaded environment variable management
│   ├── gateway-defaults.ts     # Gateway config templates & model settings
│   └── plans.ts                # Billing plan definitions & usage limits
├── db/
│   ├── pool.ts                 # PostgreSQL connection pool
│   └── run-migrations.ts       # Idempotent SQL migration runner
├── middleware/
│   └── auth.ts                 # JWT verification middleware (requireJwt)
├── routes/
│   ├── auth.routes.ts          # User auth: login, refresh, delete
│   ├── gateway.routes.ts       # Gateway credentials, pairing, config, pool ops
│   ├── deploy.routes.ts        # Deployment orchestration endpoints
│   ├── tasks.routes.ts         # Task/calendar event CRUD + task comments + agent-run
│   ├── digests.routes.ts       # Proactive cloud digests (list/get/run/delete)
│   ├── usage.routes.ts         # Usage tracking & quota enforcement
│   └── usage.integration.test.ts
├── services/
│   ├── auth.service.ts         # JWT generation, Apple/Google OAuth verification
│   ├── gateway.service.ts      # Gateway credentials, encryption, wake logic
│   ├── managed-talk-configuration.service.ts # Fingerprint-aware managed Voice ownership/recovery
│   ├── gateway-pair.service.ts # WebSocket-based device pairing & config patch
│   ├── usage-tracking.service.ts # Token usage recording & cost calculation
│   ├── task-agent.service.ts    # Cloud task agent (per-task runs) — the OWNER'S gateway, no fallback
│   ├── task-verdict.ts          # The run verdict contract: tool call → envelope → none
│   ├── gateway-agent.service.ts # Runs a cloud agent turn on the user's gateway via chat.send (Move-2)
│   ├── gmi.service.ts           # Shared GMI MaaS (OpenAI-compatible) chat client (digest/brief only)
│   ├── digest.service.ts        # Gather user tasks/events/activity → gateway chat.send → GMI fallback
│   ├── entitlement/
│   │   └── entitlement-provider.ts       # Open-core entitlement boundary (billing impl is private)
│   └── gateway/
│       └── hosted-provisioning.ts        # Open-core hosted-provisioning boundary (host impl is private)
└── scripts/
    ├── patch-default-model-all-gateways.ts # Update model across all gateways
    ├── repair-broken-pairings.ts         # Fix stale pairing state
    ├── run-digests.ts                    # Scheduled batch: generate digests for all active users
    └── run-routines.ts                   # Scheduled batch: run every enabled routine that is due now
```

## Key Subsystems

### Authentication (`auth.service.ts`, `auth.routes.ts`)
- **Two auth methods**: Apple Sign-In (JWKS verification), Google OAuth (`google-auth-library`)
- JWT tokens with 7-day expiry, refresh endpoint accepts expired tokens
- Account deletion cascades: auth_identities → tasks → IAP records → usage_events → Fly app destruction

### Gateway Management (`gateway.service.ts`, `gateway.routes.ts`)
- Gateway token encryption: AES-256-GCM with random IV/tag, stored as `iv:tag:ciphertext` in base64
- `GET /me/credentials` returns only gateway connection material. Organization/provider API keys
  remain backend/gateway owned and are never serialized to app clients.
- Wake logic for Fly.io: polls machine state → starts suspended machines → waits for healthcheck
- Local gateway URL rewriting: detects loopback URLs and rewrites hostname for mobile LAN access
- Device pairing via the supported WebSocket protocol range, currently v3-v4 (`gateway-pair.service.ts`)

### Messaging Channels — REMOVED (`scripts/revoke-native-channels.ts`)
- The native Discord/WhatsApp connector product (`channels.service.ts`, `channels.routes.ts`,
  `/api/v1/channels`) was deleted once Composio covered the same providers (#1228). Messaging
  connectors now live entirely in `composio.service.ts`.
- A native grant lived in the USER'S GATEWAY CONFIG (`channels.<provider>.enabled`, plus a Discord
  bot token or a linked WhatsApp Web session on the Fly volume), not in this database — so removing
  the API alone would have left a running connector with no off switch.
  `npm run revoke:channels` is that off switch: dry-run by default, `--apply` to revoke. It is
  self-contained (it does not import the deleted service) and reports the live-grant count, which
  is also how you confirm nothing was stranded.
- `user_channels` is intentionally NOT dropped. It is the record of what existed; drop it in a
  later migration only after a run reports `live grants: 0`.

### Hosted deploy / provisioning — operated separately (private)

Provisioning per-user gateways on a cloud host (machine create/wake/teardown, the pre-warmed
pool, image rollout) is **not part of this open-core seed**. Product code reaches it only through
two registered interface boundaries, so the seed builds, typechecks, and runs a self-hosted /
local gateway without any hosted implementation present:

- **`services/gateway/hosted-provisioning.ts`** — the `HostedGatewayProvisioning` interface
  (lookup / wake / teardown). Default provider throws `HostedProvisioningNotImplementedError`;
  register a concrete host to enable cloud-managed gateways. See `services/gateway/README.md`.
- **`services/entitlement/entitlement-provider.ts`** — the `EntitlementProvider` interface. Default
  returns `{ isActive: true }` for every account, so managed features are un-gated out of the box;
  register a billing backend to gate them. See `services/entitlement/README.md`.

Managed Voice recovery (`POST /gateway/voice/reconcile`, `managed-talk-configuration.service.ts`)
gates the backend-owned Talk credential on `getCanonicalEntitlement(...).isActive` and inspects its
target through `getHostedGatewayProvisioning()`; self-hosted / local gateways short-circuit to
gateway-owned credential setup before touching either boundary.

Interactive `POST /patch-config` saves require the gateway wrapper to restart and return an
activated config readback before the backend replies; fresh onboarding initializes browser policy
while repair/reconfigure patches omit the user-owned `browser.ssrfPolicy` object.

### Composio Connector Runtime (`composio.routes.ts`, `composio.service.ts`)
- Settings connection status comes from Composio's full paginated connected-account lifecycle;
  unavailable status fails retryably rather than presenting a false disconnected catalog.
- Grant state and gateway runtime readiness are separate. Connector reads and lifecycle mutations
  observe hosted-MCP reconciliation only within a bounded window far below the clients' 30-second
  request timeout, then return `runtimeReady` plus `runtimeSyncing` while the coalesced backend work
  continues. A committed grant mutation therefore never looks reverted because gateway config was
  slow, and an ACTIVE account is agent-ready only after a later acknowledged scope read.
- Provider work is bounded independently of runtime reconciliation. Catalog logo/account pagination
  uses abortable I/O and a prompt retryable failure (logos retain their CDN fallback). Pause, resume,
  and revoke are serialized per user/toolkit as idempotent desired-state jobs. Catalog refresh waits
  behind any active user mutation lane (or fails retryably) so it cannot publish pre-mutation ACTIVE
  state over an Updating presentation. A slow job returns a bounded retryable `503` with explicit
  `mutationStatus:"unknown"` and no `mutationAccepted` claim; `mutationAccepted:false` is reserved for
  a definitive rejection. It retains its ordering lane through a bounded post-timeout quarantine,
  and abort-aware SDK rejections after that deadline are normalized to the same typed timeout path.
  The newest queued desired state then authoritatively re-lists and reconverges. Later bounded repair
  passes re-read and reapply that latest intent if an older aborted request commits late, and every
  successful repair reconciles gateway scope even when the provider reports an idempotent zero. The
  same quarantine bound prevents a never-settling SDK promise from wedging the toolkit lane forever.
  A newly observed ACTIVE OAuth completion enters that same lane as a newer active generation.
  Each initial mutation captures its provider account IDs; repair batches re-list current status but
  intersect it with that immutable set and also recheck generation before each write. A replacement
  OAuth grant is therefore never eligible for stale pause/revoke work, even if it publishes while an
  older provider list or write is awaiting: original operations also recheck their desired generation
  after listing and before every provider write. A timeout before identity capture remains an explicit failed
  repair rather than being misreported as an authoritative empty-set convergence. Retrying safely
  re-lists only accounts that still need the desired state, including after restart. Connected status
  reads snapshot desired intent before awaiting; a response admitted before pause/revoke cannot publish
  a later ACTIVE intent over that newer mutation, and a status read admitted while pause/revoke is
  already authoritative is likewise ineligible unless the admitted intent was already ACTIVE or the
  polled connection matches a bounded, user/toolkit-scoped Connect session created by this backend
  whose monotonic lane generation, captured before session creation awaited, is still current. The
  lightweight generation and its intent kind outlive the expiring desired-operation cache and are
  retained through every dependent Connect marker, preventing an `absent -> pause/revoke -> absent`
  ABA from restoring ACTIVE. In-flight Connect creation also retains the lane generation until its
  marker can be bound, but route ownership of provider session creation is deadline-bounded so a
  never-settling SDK promise releases its admission token and cannot retain lane state forever. A
  late provider resolution after that deadline cannot create a marker. Once both marker and retained
  generation expire, a bare provider ACTIVE response is status-only—it cannot synthesize a new active
  intent without authority. If an admitted Connect instead completes while a newer retained pause or
  revoke generation still owns the lane, status reasserts that non-active intent with a fresh provider
  list. Concurrent stale completions of the same retained generation dirty the shared convergence
  worker, but every forced pass rechecks that retained generation and operation before enqueueing;
  a newer opposite intent therefore fences the dirty worker before it can queue behind and overwrite
  the replacement. The opposite intent may replace it with a new generation-specific worker. Runtime
  reconciliation follows and awaits that latest worker immediately before syncing; a timed-out or
  rejected worker is never treated as convergence and owns its delayed provider repairs until one
  succeeds, after which the final current worker synchronizes runtime exactly once. This closes the zero-target
  race where the first pause/revoke finished before one or more new OAuth accounts existed; a stale
  ACTIVE snapshot is never returned as enabled or synchronized to runtime.
- The curated hosted-MCP catalog treats Composio's `discord` and `discordbot` as distinct
  toolkits. An ACTIVE account is reduced and scoped by its exact slug, so a Discord user grant
  cannot be mistaken for a Discord Bot grant during status display, auth, or session creation.
- The gateway owns at most one per-user `mcp.servers.composio` endpoint. Its non-secret scope
  generation hashes only retained `ACTIVE`/`INACTIVE` account identity and lifecycle; pending,
  terminal, and unknown rows cannot keep stale agent access alive. Connecting, replacing, pausing,
  or resuming rewrites the complete server entry, explicitly deleting stale managed fields and
  header keys under RFC 7396. Reconciliation uses a separate four-client, fail-fast lane with no
  local waiter queue, while holding the same durable per-user gateway lifecycle advisory lock
  across its account snapshot and one-socket `config.get`/base-hash/`config.patch` write. Destructive
  lifecycle owners retain per-user priority and never share those four permits. Same-process bursts
  collapse to one active pass plus at most one trailing dirty pass; busy admission is surfaced
  retryably. The gateway target and Fly setup metadata are re-read through the same locked client;
  local development falls back only to the canonical configured local URL and persisted token. A
  marked entry (or legacy `mcp.composio.dev` URL) is Rem-owned; an unrelated manually
  configured server named `composio` fails with an ownership conflict instead of being overwritten.
  Revoking the final retained account removes only
  `mcp.servers.composio` with OpenClaw's supported merge-patch `null` deletion. Both paths invoke
  OpenClaw's hot `dispose-mcp-runtimes` action, so the next turn discovers current connector truth
  without restarting the gateway, exposing account ids, or touching user-added MCP servers.
- OAuth completion, Connectors load, enable/disable, disconnect, and gateway wake are independent
  reconciliation triggers. Each is idempotent when the catalog and account generation already
  match; failures never falsify the underlying grant-management response.

### Task Management (`tasks.routes.ts`)
- Dual entity support: tasks (priority, status, repeat_frequency) and calendar events (date_time, duration_minutes)
- Repeating a client-owned task or calendar-event UUID is idempotent for that authenticated user:
  the original row is returned unchanged. Suggestion action UUIDs and offline creates therefore
  converge across devices and retry.
  Client replay must PATCH its immutable queued payload before deleting the intent, because the
  unchanged row may predate edits made after a lost create acknowledgement.
- Full CRUD with pagination, filtering by status/type/since
- Client-provided UUIDs for offline-first creation
- Task and calendar-event create/update validate `list_id` ownership before writing and persist the
  List assignment in the same SQL statement, so a rejected organization reference cannot leave a
  successful unfiled task behind.
- Every user-initiated mutation also clears the brief's staleness counter (migration 116): `PATCH
  /tasks/:id` folds `brief_surface_count = 0, stale_at = NULL` into its own UPDATE, `POST
  /tasks/:id/comments` calls `resetTaskStaleness`, and `POST /tasks/:id/agent-run` folds the reset
  into its dispatch stamp. Machine writes (`orchestrator-sweep`) must NOT reset — see
  `task-staleness.service.ts` for the exhaustive list and the reasoning.
- **`description` is CO-AUTHORED** (migration 120, `task-description.ts` +
  `task-description.service.ts`). It is the "what I know NOW" surface from
  `docs/product/DECISIONS.md`, as opposed to `task_comments` ("what happened each run") and
  chat ("the conversation"). One column holds both authors, separated by an agent-managed
  block delimiter, and each side may write only its own half:
  `PATCH /tasks/:id` with `description` replaces the USER's text and preserves Rem's block;
  an agent run replaces Rem's block and preserves the user's text. Both take the same
  `SELECT ... FOR UPDATE` row lock, so a concurrent edit and run cannot lose a half. Never
  write the column with a bare `UPDATE tasks SET description = $1` — that is the clobber the
  design exists to prevent. `formatTask` emits `description` (the whole column),
  `description_user`, and `description_agent`, so no client re-implements the delimiter parser.
- Both run paths WRITE the description: `POST /tasks/:id/agent-run` and the autonomous
  `orchestrator-sweep` (which folds the write into the same transaction as the status apply
  and the comment). The run returns its state on a `task_context:` marker line, and both
  prompts read the description back, which is what stops a run starting from zero.

### Task runs: one runtime, one verdict (`task-agent.service.ts`, `task-verdict.ts`)
- **Every task run happens on the OWNER'S gateway.** `POST /tasks/:id/agent-run`, routines
  (`routine-runner.service.ts`) and the autonomous `orchestrator-sweep` all pass `userId` into
  `runAgentOnTask`, which runs one `chat.send` turn on that user's gateway. There is **no
  fallback runtime**. The retired AgentBox/GMI path (`GMI_AGENTBOX_URL`, `GMI_API_KEY`) spent one
  shared org key for every user: it rate-limited, and it billed the operator for work that metered
  to nobody. A user with no gateway now gets an actionable comment and `run_status='blocked'`
  instead of a silent charge to someone else. `gmi.service.ts` now survives for exactly ONE caller:
  the brief's connector-enrichment producer (see below).
- **A blocked run says WHY, in a machine field.** `AgentRunResult.runBlock` is `{ code, mode }` from
  `run-block.ts`, persisted on `tasks` AND `task_comments` (migration 121) and returned live. The
  backend never ships the sentence: the client picks copy and call-to-action from the pair, because
  "out of quota" (upgrade) and "your key was refused" (fix the key) are the same failure with
  different owners. Written unconditionally, so a successful run CLEARS a previous block.
- **`task-verdict.ts` is the run's machine decision, and the only place one is read.** A run
  produces prose (what happened — the `task_comments` row the user reads) and a `TaskVerdict`
  (what it DECIDED — the status the route applies, the `previous_status` it stamps for Undo, the
  terminal `run_status`). Two carriers, one normalizer, strict precedence:
  1. `tool_call` — the agent invokes a `rem_task_report` tool and the gateway streams us its
     schema-validated arguments as an `agent`/`stream:"tool"` event. **Not live yet**: no such tool
     exists on the deployed fleet, and adding one is a fleet operation (see below). The reader
     ships so landing the tool is a config change, not a code change.
  2. `envelope` — one versioned machine line, `rem.task_verdict.v1 {json}`, stripped from the
     prose before it is persisted. This is what carries the verdict today.
  3. `none` — no verdict. The comment lands, **no status is applied**, `run_status='review'`.
- **Fail-closed, and countable.** Every reader returns `undefined` rather than guessing, so the
  failure mode is "Rem proposed nothing", never "Rem moved your task to the wrong status".
  `AgentRunResult.verdictSource` records which carrier won, so a verdict that stops arriving is
  visible instead of looking identical to an agent that chose not to propose one.
- **No prose regex.** `parseProposedStatusFromText` is deleted. It matched `status:` followed by a
  keyword anywhere in free prose — so a sentence merely discussing a status was a status decision,
  including on the autonomous sweep, which then applied it.
- **`opts.model` is ignored** (#808). `ChatSendParamsSchema` has no `model` field, so a turn uses
  the model that user's gateway is configured with.
- Backend gateway sockets advertise `caps: ['tool-events']` (`gateway-pair.service.ts`), mirroring
  `GatewayClient.swift:49`. Without it `chat.send` never registers the connection as a tool-event
  recipient and no tool call is delivered — see that constant's docblock for the upstream citation.

### Proactive Cloud Digests (`digests.routes.ts`, `digest.service.ts`, `scripts/run-digests.ts`)
- Twice-daily briefs the GMI cloud agent writes **unprompted**: `morning_brief` (today's events + open/overdue tasks) and `evening_recap` (completed today, new comments, what's still open).
- `digest.service.ts` gathers from the backend's own tables (tasks, calendar events, task_comments), then asks the user's **gateway** to write the brief via `chat.send` (`gateway-agent.service.ts`, Move-2). **There is no second runtime.** The GMI-MaaS fallback was removed: a user whose gateway is their own ran on their key on the happy path and on the operator's org key on any wake failure, which is the per-feature hybrid `run-block.ts` exists to forbid.
- **Never hard-fails**: nothing to report → stored as `source='empty'` with no model call; the gateway could not take the turn → deterministic local summary (`source='fallback'`).
- Scheduled by an external cron hitting `npm run digests:run` (`DIGEST_KIND=morning_brief|evening_recap`); on-demand via `POST /digests/run`. See [docs/agentbox/DIGESTS.md](../../docs/agentbox/DIGESTS.md).

### Agenda Daily Brief Conversation (`brief.routes.ts`, `brief-authoring.service.ts`)
- `BRIEF_AI_AUTHORING_ENABLED` controls future scheduled authoring and connector collection; it
  does not revoke a current-day artifact that was already durably delivered. `GET /brief` always
  performs the exact artifact/revision/delivery read and advertises `brief_session_key` only for
  that proven delivery. Turning check-in triggers off stops future runs without hiding today's brief.
- Agenda's optional AI prose is authored by the user's own gateway in fresh
  `rem-brief-author-*` contexts. An expiring authoring lease makes one canonical artifact per
  user/local-day/slot, so overlapping cron/check-in workers cannot produce different card/chat prose.
- Rollout is backend-first: `GET /api/v1/brief` negotiates legacy `rem-today-*` unless the client
  sends `X-Rem-Conversation-Continuity: durable-orchestrator-v1`, but advertises that key only after
  the exact transcript has a delivered visible artifact. Each canonical artifact is temporarily
  dual-delivered so both routes stay populated while old clients remain installed. Remove the
  legacy response/delivery only after the compatible client floor is enforced.
- Each delivery has an expiring, token-owned lease. Immediately before `chat.inject`, the worker
  persists that artifact's current exact-prose occurrence count and renews/revalidates ownership.
  Upstream `chat.inject.label` is visible message text, so no marker or preamble is sent. After an
  ambiguous response or worker crash, reconciliation succeeds only when history contains a new
  occurrence beyond that persisted baseline; identical prose from an older artifact does not count.
- Connector reads are split three ways. `connector-signals.registry.ts` holds one descriptor per
  readable source — Composio action, pinned action version, time-window query and raw→
  `NormalizedSignal` mapping, and nothing else; `listDescriptors()` is the single authority for
  "which sources can Rem actually read?", so any derived UI state cannot drift from the code that
  does the reading. `connector-signals.runner.ts` owns every rule that must hold for EVERY source
  (`CONNECTOR_SIGNAL_BOUNDS`: 3 accounts / 20 items / 3 pages / 24h / 2500ms, plus dedupe, the
  post-fetch timestamp re-check and the structured `unavailableReason`); a descriptor has no field
  with which to widen a bound, `buildQuery` receives CLONED window bounds it cannot mutate, and
  runner-owned fetch keys are stripped from whatever it returns. `mapItem` is called per item
  inside a guard, so one malformed item is dropped and counted (`malformedItems`) rather than
  failing the whole collection. Descriptors are deep-frozen, so the pinned `actionVersion` cannot
  be reassigned at runtime. Gmail is the first descriptor.
- **There is exactly ONE descriptor registry.** `connector-signals.registry.ts` is it.
  `listDescriptors()` is read by the Daily Brief collector, by `signals:ingest`, and by
  `GET /automations/:kind/inputs` — a connector the Inputs screen can name is exactly a connector
  some code path can actually read, and the only way to add one is to add a descriptor. Two earlier
  lane-local registries (`connector-signals.ts`, whose `listSignalDescriptors()` returned `[]`, and
  `automation-input-descriptors.ts`, a hand-typed `[{source:'gmail'}]`) are deleted. The stub is
  why `channel_signals` had zero rows: the cron gate saw `descriptorCount=0` and declined every
  tick while the suite stayed green. `signal-ingest.service.db.test.ts` now proves a row reaches
  `channel_signals` from `listDescriptors()`, so a disconnected registry fails a test.
- **A signal is not yet a suggestion.** `signal-relevance.service.ts` sits between ingest and the
  deriver and decides whether a row deserves to interrupt the user. Judgment happens AT INGEST
  (`ingestSignalsForUser` calls `runRelevancePassForUser` right after that user's writes), so the
  cost is one batched turn per cron tick over only the unjudged rows, not a model call on every
  user-facing agenda GET. The usual objection to ingest-time judgment — policy cannot change without
  a backfill — is answered by `SIGNAL_RELEVANCE_POLICY`: a row whose stored policy differs from the
  code's counts as unjudged and is re-judged next tick.
- The judge's context is the user's OWN OPEN TASKS plus their folder/list filing, not memory. All
  three memory sources are dead (`user_memory` is retired behind `MEMORY_KEEPER_ENABLED`; OpenClaw
  dreaming is stale; there is no notes table). Tasks are live, user-maintained and directly
  predictive — an open "File visa paperwork" is why an immigration email matters and a deploy alert
  does not. A user with no tasks still gets `UNIVERSAL_PRIORS`/`UNIVERSAL_NEGATIVES`, which stay in
  force either way. **`CONTEXT_PRECEDENCE` is load-bearing and was measured, not assumed:** without
  that paragraph a live run returned identical verdicts with and without the task list. With it, the
  same run separates a `rem-canary` alert (ACT, named in an open task) from a `rem-cron` alert (DROP,
  same sender, named nowhere).
- **The judge names WHEN as well as WHAT, and a task's `start_date` IS its timeblock.** There is no
  separate calendar-block entity and nothing here creates one. `relevance_start_at` (migration 122)
  holds the judge's recommended start; `deriveSuggestions` puts it on `action.startDate`, which the
  accepting client already applies — so one tap on Add creates the task already scheduled. The card
  shows it by PREFIXING the server-authored `subtitle` ("Thursday 4:00 PM · …"), which is why this
  shipped with no new SwiftUI. `suggested-time.ts` owns the whole contract: the strict reader
  (`parseConnectorInstant` — never `new Date(string)`), the plausibility rule, the label, and the
  prompt fragment. One rule, enforced on BOTH write and read, because two of its four clauses are
  relative to the reading instant.
- **"Implausible" is defined, and it degrades rather than clamps.** A recommendation is used only if
  it resolves to an absolute instant (an ISO value MUST carry an explicit offset — a bare wall clock
  is refused; an epoch-number *string* is accepted, because epoch is inherently UTC and has no zone
  to be missing), is strictly in the future, is inside the 14-day horizon, and falls between 06:00
  and 22:00 in the USER'S zone. Anything else yields no time, and the suggestion keeps its
  pre-existing `laterToday` start with no label — so the failure mode of the whole feature is "the
  task lands where it used to", never "the task lands at 3am" and never "the suggestion disappears".
  The time is cleared alongside the other `relevance_*` columns when a re-delivery changes the
  content: a time decided about different text is not about this one.
- **The card's day band is counted in CALENDAR days, never in elapsed milliseconds.**
  `formatSuggestedTimeLabel` uses `localDayDelta` over two `YYYY-MM-DD` stamps. The first version
  compared `date - now < 7 * DAY_MS`, and whenever the recommended time-of-day was earlier than the
  current time-of-day a target seven calendar days out came in under 7×24h and printed TODAY'S
  weekday — "Wednesday 10:00 AM" for next Wednesday, which reads as a time already past. Weekday
  names cover days 2–6 only; day 7 is the same weekday as today, so it becomes a date.
- **A recommendation can be 14 days out, and the agenda shows a single day.** Accepting one creates
  a task that appears nowhere today (`TaskEvent.shouldAppear(on:)` filters by day) while the card is
  optimistically removed — so the suggestion vanishes with no confirmation of where it went. Before
  this change every suggestion was `laterToday` and Add always landed somewhere visible. Whether
  that wants a toast, an undo, or nothing is a product call; recorded here so it is not rediscovered
  as a bug.
- **The judge is shown the next 14 days of the user's schedule, from its own query.** Reusing
  `loadTaskContext` would not have worked, and the reason is worth knowing: it has no `type` filter,
  so synced calendar events (`tasks` rows of `type = 'calendar_event'`) are ALREADY in the relevance
  prompt — but it orders `start_date ASC` and nobody ever completes a calendar event, so the forty
  oldest dated rows are ancient events and next week never appears. `loadScheduleContext` is the
  same never-throws discipline over the opposite window.
- **No structured time survives ingestion today, so there is nothing for a model guess to lose to.**
  `GmailBriefRawItem` is six fields (`composio.service.ts`); an ICS attachment or a `DTSTART` never
  enters the process, and `channel_signals` has no column for one. A time named IN a message reaches
  the judge only as English inside `summary` — which is why the prompt tells it to prefer that time
  when it sees one. Wiring a genuinely structured time would be a change at the transport, the
  descriptor and the schema; do not claim an invite's own time "wins" until all three exist.
- **Fail-open is the invariant.** `relevance_decision` is nullable and the deriver filters on
  `IS DISTINCT FROM 'drop'`, never `= 'act'`. An unreachable gateway, a timeout, an unparseable
  batch, an `act` the model could not title, or a policy bump all leave the row NULL, and NULL
  SURFACES — unjudged, with the old `Reply to <sender>` title. Losing a real signal is worse than
  showing a mediocre one, and a `= 'act'` predicate would let one bad classifier day silently empty
  the user's suggestions while looking like a quiet inbox. Relevance counters are reported on the
  ingest summary line but deliberately excluded from `failed`/`signalIngestExitCode`: ingestion
  succeeded even when judgment did not.
- The judge runs on the USER'S OWN GATEWAY (`runAgentTurnOnGateway`), which is what billing meters.
  ⚠️ That crosses the boundary drawn at `brief-authoring.service.ts:1310` ("raw connector text must
  never enter gateway chat.send, whose agent runtime has tools"). Prompt-breakout is mitigated by
  the fencing in `buildRelevancePrompt`; TOOLS ARE NOT — see the header of
  `signal-relevance.service.ts` before changing the provider or widening `summary` from the subject
  line to body text.
- Persistence is mitigated by DELETING the session after each turn, NOT by the per-run key. This
  line used to say "throwaway per-run session key" and call persistence mitigated; both were wrong.
  `chat.send` persists, so a fresh key per run left one openable
  `agent:main:rem-signal-triage-<uuid>` chat per tick — 24 of them measured on one gateway, each
  holding the user's open task titles and every sender and subject in that batch. Contained by
  `deleteSessionOnGateway` in a `finally`, with `BackgroundSessionFilter.hiddenPrefixes` as the
  second line. Note that upstream's `sessions.delete` ARCHIVES rather than erases — the transcript
  is renamed and stays on the volume, so this removes the session from the list and is not a
  data-erasure guarantee.
- Toolkit authority is threaded, not assumed: `ActiveConnectorAccountSource.listActiveAccountIds`
  takes `(userId, toolkitSlug, timeoutMs)` and the runner passes `descriptor.toolkitSlug`. There is
  no Gmail-specific account wrapper — `composioActiveAccountSource` is the single binding.
- `brief-input.service.ts` projects that collection into the Daily Brief's input snapshot: only an
  enabled, due check-in may enumerate ACTIVE Gmail grants and execute pinned read-only
  `GMAIL_FETCH_EMAILS` `20260721_00`. It retains only sender,
  subject/preview, provider IDs and timestamp in-memory, and persists only backend producer,
  capture time, source manifest, stable IDs and fingerprints with the artifact. Connector-fed
  prose uses the backend's plain GMI chat-completions seam, which declares no tools; raw email data
  never enters gateway `chat.send` or its authoring JSONL. Only final prose is injected. If that
  tool-less model fails, task-bearing briefs fall back to a task-only gateway prompt and
  connector-only briefs fail closed. Collection failures remain unavailable rather than empty.

### Daily Brief artifacts (`brief.routes.ts`, `brief.service.ts`, `brief-authoring.service.ts`)

- Clients negotiating `X-Rem-Suggestion-Contract: atomic-v1` receive suggestions in the same
  `/brief` response with an immutable `brief_revision` and exact `suggestion_snapshot_id`.
  All bucket, authored-revision, dismissal, signal, and proposal reads use one read-only
  repeatable-read transaction, so concurrent task writes cannot splice two database states into it.
  Every proposal carries a backend-issued UUID `actionId`; create-task clients reuse it as the
  task UUID, so schedule movement across refresh cannot duplicate an accepted action.
  Timezone/local-day authority is resolved through the same checked-out client after `BEGIN`.
  Proposed "today" schedules are suppressed during the final local minute, when no future instant
  remains inside that day; they never silently spill into tomorrow.
  Connected-source-only responses remain revision-bound even when no task brief prose exists.
  `brief-atomic.integration.test.ts` drives the actual HTTP route with two real PostgreSQL
  connections to prove the snapshot across concurrent timezone/day, task, artifact, dismissal,
  and signal commits. CI provisions PostgreSQL and runs this contract explicitly.
- `gatherBrief` is the deterministic source for live Agenda buckets and the all-clear fallback.
- **Task staleness (`task-staleness.service.ts`, migration 116)** — the brief stops repeating itself.
  Each committed brief artifact advances `tasks.brief_surface_count` for the open tasks it raised
  (blocked / overdue / on-deck, `type='task'` only); at `BRIEF_STALE_THRESHOLD` (3, one per authoring
  slot ⇒ at least a full day of silence) the task is stamped `tasks.stale_at` and
  `briefWithoutStaleTasks` drops it from the context the authoring turn is given. Counting happens
  only where `completeBriefArtifact` succeeded, which the authoring lease already fences to once per
  user/local-day/slot — reads of `GET /brief` never count, or staleness would track how often the
  user opens the app. **Staleness is a separate column, never a `tasks.status` value**: `status` is a
  filter in `gatherBrief`, `suggestions.service`, `digest.service`, `orchestrator-sweep`, and
  `GET /tasks?status=`, so a `'stale'` value would make the task vanish from the app and overwrite
  the user's real status. Stale tasks stay in `GET /tasks` and in `/brief`'s buckets. **Both
  surfaces report staleness on the wire**: `/brief` items carry the derived boolean `is_stale`, and
  every task shape from `formatTask` (`GET /tasks`, `GET /tasks/:id`, and the create/update/backing
  responses) carries the raw `stale_at` timestamp beside `status`, never instead of it — so a task
  that is `blocked` AND stale reports both, and the client can de-emphasise the row and label it.
  A `null` is as load-bearing as a timestamp: it is how the client learns a task was un-staled.
  Any USER action clears the counter — `PATCH /tasks/:id` (folded into that route's own
  UPDATE), a user comment, or an `agent-run` dispatch — while autonomous `orchestrator-sweep` writes
  deliberately do not, so Rem cannot revive its own nagging. Nothing is ever deleted or
  auto-completed. `task-staleness.db.test.ts` drives the real authoring path against PGlite.
- When AI authoring is enabled, every eligible non-empty time slot owns one canonical persisted artifact and uses a fresh gateway authoring turn. Empty backend task snapshots remain deterministic Agenda state only: they do not append synthetic assistant prose to Today, because gateway/connector-owned work can make an injected “all clear” contradict the user's actual AI-authored update.
- Historical deterministic artifacts remain identifiable as `fallback`, but new empty snapshots do not author or deliver them. A later real gateway artifact may supersede a historical fallback after its artifact-row delivery fence expires. Every successful replacement rotates an immutable revision carried through delivery claim, preparation, reconciliation, and completion so a stale worker cannot inject or mark a newer artifact delivered.
- The same exact artifact is delivered to the durable `rem-orchestrator` transcript and the legacy per-day transcript during rollout. `/brief` keeps buckets/counts live but takes prose + session identity from the canonical `daily_briefs` pointer only when both it and its exact current artifact revision are `source=gateway` and proven delivered to the negotiated transcript. Legacy `source=fallback` artifacts are never prose authority.
- A delivered artifact's Agenda summary is normalized or derived from that same canonical markdown.
  If no useful lead can be derived, `/brief` clears the summary instead of retaining
  `gatherBrief`'s deterministic fallback beside canonical markdown/session authority.
- `npm run brief:repair -- --user-id UUID --local-day YYYY-MM-DD --digest SHA256 [--message-id ID]` is a staging-only, dry-run-by-default recovery seam. It requires both the immutable Railway staging environment ID and a pinned fingerprint read from the connected Postgres cluster before commit. It reads history with the target staging user's already-stored gateway mapping and requires an exact, unique transcript identity; even dry-run verification may wake a sleeping Fly gateway. `--commit` refuses active authoring/delivery leases, then invalidates only that user/day's historical fallback rows and adopts the verified message inside one transaction. It never infers first/latest prose or prints prose/credentials.
- Enabled Daily Brief triggers use an artifact-first notification lifecycle: a check-in authors (or
  recovers) its exact local-day/slot artifact, proves the current revision is delivered to
  `rem-orchestrator`, then sends one collapsible APNs alert and stamps the trigger. Authoring or
  transcript-delivery failure sends no notification and leaves the trigger retryable **within a
  bounded per-local-day attempt budget** (`CHECKIN_MAX_DELIVERY_ATTEMPTS`, currently 5). Each
  attempt increments `user_checkins.attempt_count`; the counter is bucketed by
  `attempt_day` (the user's LOCAL day, so an outage spanning midnight does not spend the new
  day's budget) and is cleared by `stampCheckinRun`. Once the budget is exhausted the slot is
  consumed for that local day rather than re-attempted on every tick. Unbounded retryability
  was the defect in #1279 — a failing slot re-authored and re-delivered a brief every 15
  minutes, to real devices — so "retryable" here is deliberately finite. Notification
  prose comes from that canonical artifact; tapping always fetches and reads the newest Today
  artifact rather than trusting stale payload text. See `docs/product/DAILY_BRIEF_LIFECYCLE.md`.
- The standalone `brief:author` cron is delivery-recovery-only. It selects recent canonical gateway
  artifacts missing an exact-revision rollout transcript delivery and retries those side effects;
  it does not select task/check-in rows, gather work, claim a slot, author prose, or send APNs.
  Fresh scheduled authoring belongs exclusively to enabled check-ins that are due.
- Multiple overdue check-in slots are processed in local-day chronology, and the `daily_briefs`
  upsert rejects backward slot movement. This database fence also prevents an older overlapping
  worker from replacing the newer canonical Today pointer or its collapsed notification. The final
  pre-`chat.inject` preparation durably commits the reconciliation baseline and proves that the
  exact artifact revision still backs that pointer. A second revalidation transaction holds the
  canonical, artifact, and delivery row locks through `chat.inject`, so a newer slot's upsert waits
  across backend processes until the older irreversible side effect and delivery state settle;
  there is no preparation-to-injection interleave window or crash-induced loss of the baseline.
- APNs delivery has a separate durable `daily_brief_notification_fences` row per account, carrying
  the latest local day and slot.
  Its transaction is held through the external send, so overlapping workers cannot let an older
  slot arrive after a newer collapse-id alert; retryable all-destination failures do not advance it.
- APNs destinations are single-owner across accounts. Registration transfers ownership using a
  per-install generation and atomically retires every earlier token for that installation. Sign-out
  physically removes every installation sibling and leaves a generation tombstone in the independent
  `push_installation_fences` table even when a rotated token row has not inserted yet. Delivery ranks
  all account owners together and requires the strongest destination to match that live fence.
  Migration repair adopts enabled pre-fence rows under the same per-user `legacy:<user-id>` authority
  used by the compatibility route, preserving delivery for shipped clients whose success cache skips
  a launch POST. It deletes disabled unfenced rows and makes `installation_id` mandatory: an old
  replica may refresh an already-authorized row without changing its authority, but a new legacy
  NULL-installation insert fails closed. The compatibility trigger row-locks the authority it copies,
  so current rotation/logout either retires the old write afterward or makes its re-read fail closed;
  there is no copy-then-resurrect window. A cold upgraded client whose legacy-cache upgrade has not
  completed asks unregister to delete that exact legacy account/token atomically with its new-install
  tombstone, without removing other legacy devices. Physical retirement also keeps old senders that
  ignore `enabled` from seeing stale rows during a rolling deploy. Brief payloads carry the owner
  while keeping lock-screen copy neutral; the app rejects a tap unless live auth matches that owner.
  Generation-0 legacy clients may switch accounts only after their user-scoped unregister wins: a
  conflicting registration returns retryable 409 rather than falsely returning the other owner's
  row as 201. Retrying after the delayed unregister succeeds installs the new owner, while an old
  unregister arriving after a current-client transfer cannot remove that transferred row.

### Routines (`routine-schedule.service.ts`, `routine-runner.service.ts`, `scripts/run-routines.ts`)
- A routine is an existing task that does work on a cadence (`routine_schedules`, migration 017). CRUD lives in `routine-schedule.service.ts`; the per-run execution + governance gate (model-gate → deny-list → shared agent → attributed task_comment → RunReport → `stampLastRun`) lives in `routine-runner.service.ts`.
- **Backend-scheduled** (NOT gateway cron): an external Railway cron runs `npm run routines:run` every 15 minutes; `scripts/run-routines.ts` selects routines due now (`isDailyRoutineDue` + cadence, per-user timezone) and calls `runRoutine` in-process. The `routine_schedules` row is the sole source of truth; CRUD does no gateway sync. (Replaces the deleted `routine-cron.service.ts` gateway-cron trigger.)
- Wake-on-demand: if a run's agent issues a device command, the user's Fly gateway auto-wakes via `auto_start_machines` on the request — no explicit wake step in the scheduler.
- `internal-routines.routes.ts` (`POST /internal/routines/:id/run`, shared-secret auth) is retained as a manual/programmatic trigger seam, but is **no longer** the scheduled path.

### Usage Tracking (`usage.routes.ts`, `usage-tracking.service.ts`)
- Plan-based limits: free (50/day, 500/month) vs pro (1000/day, 20000/month)
- Dual tables: `usage_events` (detailed) + `usage_counters` (aggregates with `ON CONFLICT` upsert)
- Per-model cost calculation (stored in cents)
- **Quota windows are the USER's local calendar day/month, not UTC** (#1289). `quotaWindowStart`
  is the single boundary; `getUserQuotaUsage` is the single read, so `/usage/summary` (display)
  and `/usage/authorize` (enforcement) cannot land on different days and produce a false "limit
  reached". `/usage/consume` applies the same boundary inside its transaction. The timezone
  comes from the shared `resolveUserTimezone` chain (`users.timezone` → `user_checkins.timezone`
  → UTC) — the same one the brief, digests and check-in scheduler use. A user with no stored
  timezone resolves to UTC, which is exactly the pre-#1289 behaviour; the apps write
  `users.timezone` on launch/foreground/login (migration 101), so it self-heals.
- `usage_counters.day` / `minute_bucket` moved to that same local-day bucket **going forward
  only — no backfill**. The table is write-only in the product (nothing reads it for quota or
  display), and `usage_events.created_at` remains the `timestamptz` record of truth from which
  any rollup can be re-derived for any timezone. Consequence: aggregate by summing rows, never
  assume one row per user per day.

#### Debugging a user's counter: three expected behaviours that look like bugs

Check these first — all three are intended.

1. **A counter that jumped UP on the day #1289 shipped.** For a negative-offset user the window
   *widens* at deploy. Someone who spent 40 turns before 17:00 local and 15 after previously saw
   `15/50` (a fresh UTC day had started under them); afterwards they correctly see `55/50` and
   are held until their own midnight. Positive-offset users see the mirror — the window narrows
   and the number drops. This is the true count for their local day, it affects the deploy day
   only, and it self-corrects at their next local midnight. There is deliberately no
   grandfathering: one correct boundary beats two. Also stated on `quotaWindowStart`.
2. **A counter that did not reset at UTC midnight.** Correct — it resets at the user's local
   midnight. `/usage/summary` returns the resolved `timezone` precisely so you can tell which
   calendar the numbers describe instead of guessing.
3. **A 25-hour day, twice a year, in `America/Havana` or `Atlantic/Azores`.** Those two zones end
   DST *at* local midnight, so local midnight happens twice. The window starts at the **first**
   one, which makes that local day 25 hours long and keeps usage recorded during the repeated
   hour inside the window. Anchoring on the second instant instead moved the window mid-day (the
   counter appeared to reset) and, when the 1st of the month fell on that Sunday, pushed the
   month `start` past `now` so every event was filtered out and the monthly limit stopped
   enforcing entirely. See `localWallClockToUtc` in `digest.service.ts`.

- `POST /usage/consume` locks the authenticated user's row and performs the quota read plus request-event insert on one PostgreSQL transaction. Concurrent consumes for that user therefore cannot both claim the final slot once every backend replica runs this implementation.
- Every successful `/usage/consume` call reserves exactly one slot. Caller-supplied `Idempotency-Key` headers and `event_id` body fields are not replay authority because the current client-to-gateway flow has no end-to-end binding from a reservation to the downstream `chat.send`; reusing either value cannot suppress consumption or bypass a limit. Gateway `/usage/record` retains its separate event-idempotency contract for token-report spool retries.

### In-App Purchases (`iap/`)
- StoreKit 2 signed transaction verification via Apple App Store Server API
- Subscription chain ownership tracking (prevents cross-user transfer)
- App Store Server Notifications V2 webhook with signature verification
- Reconciliation pass for stale subscriptions
- Family sharing detection and rejection

### Whose key pays: BYOK is a global mode (`run-block.ts`)
- **BYOK is a per-user MODE, not a per-feature choice.** A user is on their own model provider or on
  Rem-managed, for everything. Any path that picks a provider credential independently of that mode
  is a bug — including a "fallback" that only triggers on a transient.
- `resolveModelRuntimeMode(userId)` is the single seam. It derives the mode from whether *Rem*
  provisioned the credentials that runtime authenticates with: `users.hosting_provider = 'fly'` →
  `rem_managed` (the org `ANTHROPIC_API_KEY` and `GMI_API_KEY` are injected at deploy time);
  `railway`/`local`/`manual` → `byok`; no gateway at all → `unknown` (the column DEFAULTs to
  `'railway'`, so it means nothing without one).
- **Sound in one direction only.** `byok` is proven; `rem_managed` is not. A managed-Fly user who
  brought their own key would be invisible here — safe today only because bringing a key to a
  managed gateway is unimplemented (`SharedBYOKSettingsView` writes the device Keychain and is
  deliberately unlinked; see `docs/architecture/2026-08-09-cloud-gateway-byok-contract.md`). When
  Phase 1 of that contract ships, the credential-install mutation must record the mode and this
  resolver must read that record instead of `hosting_provider`.
- `mayChargeRemManagedKey(mode)` is the gate, and it **fails closed on `unknown`**: a failed mode
  lookup is not permission to bill the operator.
- **The only remaining backend call on the org `GMI_API_KEY`** is the brief's connector-enrichment
  producer (`brief-authoring.service.ts`). It is a PRIMARY, not a fallback: raw connector text must
  never enter the tool-capable, persisted gateway turn, so it cannot be rerouted the way task runs
  were. It is gated on `mayChargeRemManagedKey` instead. What a blocked user loses depends on the
  day: one with tasks still authors from task data (enrichment lost, brief kept); a
  **connector-only day produces no brief at all** (`reason = 'connector_model_not_owned'`), because
  connector text may not fall through to the tool-capable gateway. That is the deliberate trade.
  **No user takes this branch today** — see the mode note above.

## Patterns & Conventions

- **Service layer**: Routes call services, never DB directly. Services import pool/env directly.
- **Parameterized queries**: All SQL uses `$1, $2` parameters — no string concatenation.
- **Transaction safety**: `BEGIN/COMMIT/ROLLBACK` with `try/finally` cleanup. Row locking via `FOR UPDATE` / `FOR UPDATE SKIP LOCKED`.
- **Lazy-loaded config**: Environment variables accessed only when used (prevents startup failures for unused vars).
- **Logging**: Bracket prefix convention: `[AUTH]`, `[deploy]`, `[pool]`, `[billing]`.
- **Error responses**: `{ error: string, code?: string, reason?: string }` with appropriate HTTP status codes.
- **Service token auth**: Backend-to-gateway communication uses `BACKEND_SERVICE_TOKEN` (not user JWTs).
- **Advisory locks**: `pg_try_advisory_lock` prevents concurrent pool replenishment.
- **Database capacity**: The shared pool uses `connectionTimeoutMillis`; keep lifecycle checkout
  bounds aligned so an unreachable PostgreSQL handshake cannot outlive its caller indefinitely.

## API Routes

All routes mounted at `/api/v1`:

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/auth/login` | None | Apple/Google sign-in |
| POST | `/auth/refresh` | Expired JWT OK | Token refresh |
| DELETE | `/auth/me` | JWT | Account deletion |
| GET | `/me` | JWT | User profile and gateway metadata |
| PATCH | `/me/gateway` | JWT | Update gateway URL + credentials |
| GET | `/me/credentials` | JWT | Gateway URL + token (shortcut used by apps) |
| POST | `/approve-device` | JWT | Auto-approve pending pairings |
| POST | `/patch-config` | JWT | Patch gateway config |
| POST | `/gateway/voice/reconcile` | JWT | Reconcile managed Voice config or return the required setup path |
| POST | `/deploy/start` | JWT | Begin gateway deployment |
| GET | `/deploy/status` | JWT | Check deploy progress |
| GET/POST/PATCH/DELETE | `/tasks/*` | JWT | Task CRUD |
| GET/POST | `/tasks/:id/comments` | JWT | Task comment thread (user + cloud_agent + local_runtime) |
| POST | `/tasks/:id/agent-run` | JWT | Run the GMI AgentBox cloud agent on a task |
| GET | `/digests` | JWT | List the user's proactive digests |
| GET | `/digests/:id` | JWT | Fetch a single digest |
| POST | `/digests/run` | JWT | Generate a digest now (`{ kind? }`) |
| DELETE | `/digests/:id` | JWT | Dismiss/delete a digest |
| GET | `/usage/summary` | JWT | Usage stats |
| POST | `/usage/consume` | JWT | Atomically authorize and reserve one AI request slot |
| POST | `/iap/transaction-sync` | JWT | Sync Apple transaction |
| POST | `/iap/apple/notifications` | None (Apple signature) | App Store webhook |
| GET | `/automations/:kind/inputs` | JWT | What an automation actually reads, derived (`kind`: `daily-brief`) |
| GET | `/automations/:kind/outputs` | JWT | What an automation actually produces, derived (`kind`: `daily-brief`) |

### Derived automation inputs

`GET /automations/:kind/inputs` answers "what does this automation actually read?" — and every
`state` on it is **computed, never stored or hand-written**. It replaces the hand-typed rows in
`Shared/Automations/AutomationContract.swift`, which hardcoded `.planned` for connectors and was
wrong in both directions (it stayed `.planned` after the Gmail collector shipped, and would have
stayed `.active` if the collector were removed). A capability claim a human types cannot
self-correct.

State is derived from three observed facts, in `automation-inputs.service.ts`:

| Fact | Source of truth |
|------|-----------------|
| Which connectors have a descriptor | the connector signal registry (code that actually runs) |
| Whether the caller has >= 1 **ACTIVE** Composio account | `listActiveToolkitSlugs` (paused/`INACTIVE` does not count) |
| The newest per-source collect outcome | `daily_brief_artifacts.input_manifest` (migration 114) |

Yielding exactly four states: `included`, `not_connected`, `unavailable`, `coming_soon`.

Notes for anyone changing this:

- **`input_manifest` holds JSON `null`, not just SQL NULL** — the authoring INSERT stringifies
  `null` when no snapshot was collected. `input_manifest IS NOT NULL` lets that through and
  `jsonb_array_elements` then raises `cannot extract elements from a scalar`. The read is guarded
  with `jsonb_typeof(...) = 'object'` / `= 'array'`; verified against a live PostgreSQL 16.
- **A failed Composio lookup is not "no connection."** Collapsing the two tells a connected user
  to connect. The lookup returns a discriminated result and falls back to our own recorded
  provenance before ever claiming coverage.
- **Wire names are a cross-layer contract.** `automation-inputs.contract.test.ts` asserts the exact
  key set and JSON types of the serialized response, because a rename (`source` → `provider`) is
  invisible to tests that only assert values — that is exactly what broke a previous multi-lane run.

### Derived automation outputs

`GET /automations/:kind/outputs` is the other half, and it exists because the client kept a
hand-typed `.planned` on "Suggested tasks" after Inputs moved server-side. That literal was already
false: `deriveSuggestions` produces tier-1 (overdue / calendar) and tier-2 connected-source
suggestions, and `GET /brief` serves them. A unit test asserted the literal said `.planned` and
passed the whole time — a literal compared against a literal can only agree.

State is derived from two observed facts, in `automation-outputs.service.ts`:

| Fact | Source of truth |
|------|-----------------|
| Whether a producer is registered for the output | `PRODUCERS` — an entry is allowed only if an observer watches the real producer |
| What that producer actually produced for the caller | `daily_brief_artifacts` (authored row), `gatherBrief` counts, `deriveSuggestions` length |

Yielding three states: `included`, `idle`, `coming_soon`.

Notes for anyone changing this:

- **Observe the producer, never re-implement it.** `countAttentionItems` calls `gatherBrief` and
  reads `counts.blocked + counts.overdue`; `countTaskSuggestions` calls `deriveSuggestions` and
  takes `.length`. Re-deriving "what counts as overdue" here would be a second copy of the rule and
  the same drift the connector registry exists to prevent.
- **An unobservable producer degrades to `idle`, never `included`.** Each observation is settled
  independently, so one slow or throwing producer cannot fail the route — and cannot be reported as
  delivering.
- **A real zero is not `null`.** `lastItemCount: 0` means the producer ran and had nothing;
  `null` means the producer has no meaningful count (one authored brief is not a count). Collapsing
  them makes "Included" unfalsifiable, which is the failure this lane exists to end.
- **`source = 'fallback'` is deliberately NOT read as failure.** Per migration 109 it marks the
  deterministic all-clear composer — the empty-day path, not a degraded one. Treating it as failure
  would be exactly the kind of plausible-looking derivation that put `.planned` in the client.
- **`coming_soon` is derived from ABSENCE from `PRODUCERS`.** `PLANNED_OUTPUTS` is empty today, and
  that emptiness is the finding: every output this surface names is one the runner actually emits.
