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
│   ├── conversations.routes.ts # Rem-owned ordinary conversation CRUD + continuation
│   ├── tasks.routes.ts         # Task/calendar event CRUD + task comments + agent-run
│   ├── digests.routes.ts       # Proactive cloud digests (list/get/run/delete)
│   ├── usage.routes.ts         # Usage tracking & quota enforcement
│   ├── iap.routes.ts           # Apple In-App Purchase endpoints
│   └── usage.integration.test.ts
├── services/
│   ├── auth.service.ts         # JWT generation, Apple/Google OAuth verification
│   ├── gateway.service.ts      # Gateway credentials, encryption, wake logic
│   ├── managed-talk-configuration.service.ts # Fingerprint-aware managed Voice ownership/recovery
│   ├── gateway-pair.service.ts # WebSocket-based device pairing & config patch
│   ├── deploy.service.ts       # Fly.io & Railway deploy pipelines (9 phases)
│   ├── fly.service.ts          # Fly.io Machines API client
│   ├── pool.service.ts         # Pre-warmed gateway pool management
│   ├── usage-tracking.service.ts # Token usage recording & cost calculation
│   ├── task-agent.service.ts    # Task agent — shared Rem runtime, with provenance-gated BYOK compatibility
│   ├── task-verdict.ts          # The run verdict contract: tool call → envelope → none
│   ├── gateway-agent.service.ts # Runs a cloud agent turn on the user's gateway via chat.send (Move-2)
│   ├── gmi.service.ts           # Shared GMI MaaS (OpenAI-compatible) chat client (digest/brief only)
│   ├── digest.service.ts        # Gather user tasks/events/activity → Rem shared runtime → local fallback
│   └── iap/
│       ├── iap-types.ts                  # Type definitions & error classes
│       ├── iap-entitlement.service.ts    # Subscription state management
│       ├── iap-identity.service.ts       # User ↔ subscription mapping
│       ├── apple-server-client.ts        # Apple App Store Server API client
│       ├── iap-notifications.service.ts  # Apple notification webhook processing
│       └── iap-telemetry.service.ts      # PostHog IAP event tracking
└── scripts/
    ├── replenish-pool.ts                 # Maintain pre-warmed gateway pool
    ├── patch-config-all-gateways.ts      # Bulk config patch for all users
    ├── patch-default-model-all-gateways.ts # Update model across all gateways
    ├── repair-broken-pairings.ts         # Fix stale pairing state
    ├── update-gateway-image-all.ts       # Bump gateway Docker image for all users
    ├── prune-rem-agent-runs.ts           # Hard-delete expired shared-runtime output
    ├── run-digests.ts                    # Scheduled batch: generate digests for all active users
    └── run-routines.ts                   # Scheduled batch: run every enabled routine that is due now
```

## Key Subsystems

### Agent Runtime Boundary (`runtime/`)
- Task-agent execution depends on the Rem-owned `AgentRuntime` contract rather than selecting a
  gateway transport directly. Rem-managed manual task runs, signal relevance, and digest generation
  execute on the shared implementation; authenticated task-chat continuations and the backend
  memory extractor do too. Task continuations serialize by task, replay by client dispatch UUID,
  and commit both visible turns atomically.
- Migration 134 and `conversations.routes.ts` provide the backend-owned ordinary conversation
  lifecycle: tenant-scoped create/list/read/rename/delete, bounded paginated history and tool-free continuation on
  `rem_shared`, exact client-dispatch replay, and deletion that retains only a tombstone while
  purging transcript and runtime output. Native chat routing and legacy transcript import remain a
  separate cutover, so this API foundation is not yet a claim that the shipped app bypasses gateways.
- Manual task runs and their continuations stay on the shared runtime; they never fall back to the
  transitional BYOK gateway adapter. Migration 129 and `RemCapabilityEffectLedger` now provide the
  tenant-scoped capability-grant, live run-owner and exact act-policy authorization, idempotent
  effect claim, redacted token-free audit/replay views, revocation, and uncertain recovery substrate
  for tool-bearing work. Immutable admitted-run and proposal-run identity survive runtime-row pruning.
  Expired effects
  await adapter-specific reconciliation and are never silently re-executed; a leased internal-service
  reconciler may settle an uncertain row after executor-token loss but cannot authorize dispatch.
  L0-L2 plan-only routines run on the tenant-scoped shared observe runtime. Their durable
  `routine_run_occurrences` claim fences concurrent workers, rotates a fresh model attempt after a
  typed transient Rem-managed runtime failure, and atomically commits the attributed task comment
  with `last_run_at`. Quota, credential, unknown-payer, and other stable blocks surface once as a
  needs-attention comment instead of retrying forever. One canonical occurrence key is derived from
  the prior durable completion rather than mutable cadence/hour/timezone fields, so stale schedule
  snapshots cannot each publish an outcome. Terminal block code and payer mode persist on the comment;
  an explicit Run Now carries its own distinct key. A missing-model warning parks that same
  occurrence in `waiting_model` without stamping `last_run_at`; scheduler retries stay quiet until
  model selection atomically makes the occurrence reclaimable, preserving one-shot eligibility.
  Migration 133 also binds new schedules to a task owned by the same tenant; the runner and
  settlement path independently fail closed on any pre-migration ownership mismatch before even a
  transitional L3+ wildcard run.
  L3+ acting routines remain on their existing runtime path until their concrete tool adapters
  claim and settle the effect fence and pass lifecycle tests.
- Autonomous sweeps use a `trusted_automation` Rem observe turn in the canonical
  `rem-task-<UUID>` conversation. The model may only emit `rem_task_report`; a separate act-only
  run verifies that durable proposal, receives one internal-service automation-policy grant, and
  commits `tasks.update`, terminal run state, task context, Activity/Undo, replayable transcript,
  and effect settlement together. It shares the task-chat lock, refreshes/fences the task revision
  and both conversation tails, and only admits first-party user instructions to unattended policy.
  The sweep remains off by default until Rem-owned read-only connector/browser parity is available.
- `OpenClawAgentRuntime` is the transitional production adapter; the shared multi-tenant Rem
  runtime will replace it at the composition point.
- The existing PostgreSQL task, conversation, routine, brief, memory, billing, and connector
  records remain canonical. Do not introduce a parallel runtime-owned product database.

### Authentication (`auth.service.ts`, `auth.routes.ts`)
- **Two auth methods**: Apple Sign-In (JWKS verification), Google OAuth (`google-auth-library`)
- JWT tokens with 7-day expiry, refresh endpoint accepts expired tokens
- Account deletion cascades: auth identities, conversations, tasks, IAP records, and usage events;
  transitional Fly app destruction still runs while gateway accounts exist.

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

### Deployment (`deploy.service.ts`, `fly.service.ts`, `pool.service.ts`)
- **Fly.io pipeline** (9 phases): creating_project → setting_variables → deploying → waiting_for_healthy → running_onboarding → saving_credentials → complete
- **Pre-warmed pool**: Maintains 2 ready-to-assign gateways for <30s first deploy. Atomic claim via `FOR UPDATE SKIP LOCKED`. Falls back to full pipeline (~100s) if pool is empty.
- **Railway pipeline**: GraphQL API for project → service → environment → volume → domain creation
- Config patching: fresh onboarding initializes browser policy; repair/reconfigure/bulk patches
  omit the user-owned `browser.ssrfPolicy` object. Interactive `POST /patch-config` saves require
  the gateway wrapper to restart and return an activated config readback before the backend replies;
  if setup access is unavailable, the backend rejects before attempting the legacy WebSocket patch.
  The wrapper stops the gateway before its file mutation, restores the prior bytes after a failed
  activation when no newer write won. Its one-time browser migration opens only the exact historic
  Rem-generated hostname postures; user-authored Limited hostname restrictions remain unchanged.
- Interactive Voice recovery uses `POST /gateway/voice/reconcile`: managed Fly gateways receive
  the backend-owned canonical Talk configuration only while their canonical entitlement is active,
  and only after the stored URL host, Fly app/machine metadata, machine `REMCLAW_USER_ID`, and
  `BACKEND_URL` prove one ownership chain. Reconciliation runs inside the per-user gateway
  lifecycle lock and reads exact Talk secrets only over the backend's admin-scoped gateway session.
  The interactive route uses the dedicated owner's fail-fast lane before wake and again before
  mutation, returning `409` instead of waiting behind a migration/deletion or starving the shared
  database pool; background reconciliation retains FIFO lifecycle admission. After lock admission,
  dedicated lifecycle sessions install a 5-second PostgreSQL `statement_timeout`, and Voice routes
  keep target, canonical-entitlement, and fingerprint queries on that bounded session. This database
  budget sits inside the shared clients' 600-second recovery deadline rather than extending it.
  Broad managed redeploy/reconfigure patches omit Talk, then invoke this ownership-aware service
  after the canonical Fly pointer is durable. `users.managed_talk_credential_fingerprint` records ownership without storing another secret:
  rotations update only a matching Rem-managed key, expired entitlements remove only that matching
  key, and a user-owned replacement is preserved while Rem relinquishes the marker. A missing managed
  key is repaired without resending an existing ElevenLabs provider/voice/model selection. The endpoint
  returns only non-secret outcomes.
  Local/manual gateways and unavailable managed provider configuration are explicitly routed to
  gateway-owned credential setup. Client-entered gateway saves clear stale Fly metadata and cannot
  label themselves managed without that external ownership proof.
  Entitlement transactions acquire the same cross-replica advisory fence before their users row
  lock, set a durable `managed_talk_reconcile_required` bit, and schedule a compensating reconcile
  after commit. Fresh direct onboarding and pre-warmed assignment consult canonical entitlement
  before any organization Talk key is written. Assignment has one durable claim per user, transfers
  Machine ownership env before writing the key, commits only into an empty user pointer, and performs
  a second in-lock reconcile after the pointer is durable. An ambiguous pre-pointer Talk response
  triggers compensation only after releasing/reacquiring the lifecycle fence and rereading the
  claim plus canonical pointer; another replica's durable claim is never resumed. If scrub or later
  work still fails, the claim remains durable. Account deletion captures unconsumed claims before
  their owner foreign key clears, and scheduled cleanup destroys orphaned claimed apps before
  removing metadata. Age-based replenishment cleanup holds that same user fence and atomically
  retires a stale claim to ownerless durable cleanup state before Fly deletion. That row transition
  also fences draining pre-lock replicas: their guarded claim consumption fails and rolls back any
  still-uncommitted user pointer instead of committing a destroyed app.
  `managed_talk_credential_generation` plus the desired fingerprint make key rotation monotonic
  across rolling replicas. Operators must increment `ELEVENLABS_API_KEY_GENERATION` with every key
  change; equal-generation fingerprint disagreement fails closed. Destructive scrub and generation
  greater than 1 remain pending while `MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE=false`; enable
  phase two only after every live writer advertises the lifecycle/generation fence and legacy
  replicas have drained.
  Fresh direct Fly provisioning creates durable provisional app ownership under the user lifecycle
  fence before the remote app request. It reacquires the fence and proves the user/ownership row
  before installing the organization Talk key, then commits the user pointer, Fly metadata, and
  canonical ownership in one transaction. Each provisional row is exclusive to one durable
  deployment attempt ID; concurrent replicas report the existing work as in progress and cannot
  finalize or compensate another attempt. Account deletion converts both canonical and in-flight
  ownership to `delete_pending` before deleting the user, and scheduled cleanup retries non-404 Fly
  failures without losing the app name.

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
- `task-update.service.ts` is the canonical transaction-owned task update writer shared by the
  authenticated PATCH route and Rem's hosted `tasks.update` adapter. The runtime adapter has no
  device/OpenClaw hop and commits the tenant-scoped task mutation with its audited effect outcome;
  only authenticated user action resets staleness. A validated shared-runtime `rem_task_report`
  proposal now reaches this adapter through an act-only execution run and exact one-use approval
  grant; the model itself never receives acting authority. Interactive and trusted-automation paths
  share the adapter, which commits task status, terminal run state, agent-owned context, the
  Undo-bearing activity row, and successful effect settlement together.
  `runtime:effects:reconcile` resolves expired claims without redispatch.
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
  `orchestrator-sweep` (whose audited adapter folds the write into the same transaction as status,
  comment, and effect settlement). The run returns its state through `rem_task_report`, and both
  prompts read the description back, which is what stops a run starting from zero.

### Task runs: one runtime, one verdict (`task-agent.service.ts`, `task-verdict.ts`)
- **Rem-managed manual task runs use Rem's shared runtime, without a personal gateway.**
  `POST /tasks/:id/agent-run` passes authenticated tenant authority plus a stable per-dispatch
  idempotency key into one `rem_shared` observe turn. The runtime offers only the side-effect-free
  `rem_task_report` function, validates and durably replays its arguments, and cannot itself execute
  task writes. Tool-only output that does not validate becomes a charged terminal error, never a
  durable empty success. The authenticated `Run Now` action approves the exact normalized report:
  a deterministic act-only executor first verifies the successful tenant/session observe run and
  its exact final stored call, then admits only `tasks.update`, replays one tenant-scoped one-use
  grant on retry, and delegates the mutation to the audited adapter. If that effect is blocked,
  failed, or pending, the route leaves the status unapplied and records a reviewable proposal rather
  than bypassing the ledger. Transitional envelope/BYOK verdicts retain their route-owned direct
  apply path but receive no Rem tool authority. The autonomous `orchestrator-sweep` uses the same
  proposal verifier and adapter under trusted automation policy; L3+ scheduled routines remain a
  separate transitional gateway seam. Proven BYOK accounts retain
  a narrow manual-run fallback to their credential-owning gateway until Rem owns encrypted BYOK
  credential transport; unknown payer state never triggers that fallback.
- **A blocked run says WHY, in a machine field.** `AgentRunResult.runBlock` is `{ code, mode }` from
  `run-block.ts`, persisted on `tasks` AND `task_comments` (migration 121) and returned live. The
  backend never ships the sentence: the client picks copy and call-to-action from the pair, because
  "out of quota" (upgrade) and "your key was refused" (fix the key) are the same failure with
  different owners. Written unconditionally, so a successful run CLEARS a previous block.
- **`task-verdict.ts` is the run's machine decision, and the only place one is read.** A run
  produces prose (what happened — the `task_comments` row the user reads) and a `TaskVerdict`
  (what it DECIDED — the status the route applies, the `previous_status` it stamps for Undo, the
  terminal `run_status`). Two carriers, one normalizer, strict precedence:
  1. `tool_call` — the shared runtime's primary carrier. `rem_task_report` is registered as
     structured output, not an acting capability; its normalized call is stored with the run.
  2. `envelope` — one versioned machine line, `rem.task_verdict.v1 {json}`, stripped from the
     prose before it is persisted. Retained while provider/model tool support is monitored and for
     transitional runtimes.
  3. `none` — no verdict. The comment lands, **no status is applied**, `run_status='review'`.
- **Deletion removes the private runtime copy.** `DELETE /tasks/:id` takes the same advisory lock as
  task chat/manual runs, then purges every tenant-scoped `rem-task-<id>` runtime row in the task and
  tombstone transaction. A concurrent turn cannot recreate task context after deletion commits.
- **Fail-closed, and countable.** Every reader returns `undefined` rather than guessing, so the
  failure mode is "Rem proposed nothing", never "Rem moved your task to the wrong status".
  `AgentRunResult.verdictSource` records which carrier won, so a verdict that stops arriving is
  visible instead of looking identical to an agent that chose not to propose one.
- **No prose regex.** `parseProposedStatusFromText` is deleted. It matched `status:` followed by a
  keyword anywhere in free prose — so a sentence merely discussing a status was a status decision,
  including on the autonomous sweep, which then applied it.
- **`opts.model` is honored** by the Rem runtime and included in the durable request fingerprint.
- Backend gateway sockets advertise `caps: ['tool-events']` (`gateway-pair.service.ts`), mirroring
  `GatewayClient.swift:49`. Without it `chat.send` never registers the connection as a tool-event
  recipient and no tool call is delivered — see that constant's docblock for the upstream citation.

### Proactive Cloud Digests (`digests.routes.ts`, `digest.service.ts`, `scripts/run-digests.ts`)
- Twice-daily briefs Rem writes **unprompted**: `morning_brief` (today's events + open/overdue tasks) and `evening_recap` (completed today, new comments, what's still open).
- `digest.service.ts` gathers from backend-owned tables, then asks the Rem shared tool-free runtime to write the brief. It does not discover or wake a personal gateway.
- **Never hard-fails**: nothing to report → stored as `source='empty'` with no model call; runtime unavailable → deterministic local summary (`source='fallback'`).
- Scheduled by an external cron hitting `npm run digests:run` (`DIGEST_KIND=morning_brief|evening_recap`); on-demand via `POST /digests/run`. See [docs/agentbox/DIGESTS.md](../../docs/agentbox/DIGESTS.md).

### Agenda Daily Brief Conversation (`brief.routes.ts`, `brief-authoring.service.ts`)
- `BRIEF_AI_AUTHORING_ENABLED` controls future scheduled authoring and connector collection; it
  does not revoke a current-day artifact already authored. `GET /brief` returns the exact canonical
  artifact independently of gateway delivery, marks it `is_authored`, and advertises
  `brief_session_key` only for proven conversation delivery. Turning check-in triggers off stops
  future runs without hiding today's brief.
- Agenda's optional AI prose for Rem-managed users is authored by the shared Rem runtime in fresh
  `rem-brief-author-*` contexts. A durable semantic attempt identity survives lease recovery and
  prevents duplicate model work; an expiring authoring lease makes one canonical artifact per
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
  `loadTaskContext` would not have worked, and the reason is worth knowing: it orders
  `start_date ASC` and nobody ever completes a calendar event, so the forty oldest dated rows would
  be ancient events and next week would never appear. `loadScheduleContext` is the same never-throws
  discipline over the opposite window.
- **`loadTaskContext` filters to `type = 'task'`, so calendar events are NOT aggregation parents.**
  Synced calendar events (`tasks` rows of `type = 'calendar_event'`, migration 024) sit as `pending`
  forever ("nobody closes a birthday"). Without the filter they surfaced as `[P#]` parent
  candidates, and a `complete` echo-matched to one stored `decision='complete'` (suppressing the
  signal) while the write no-opped — the writers in `task-description.service.ts` refuse any
  `type <> 'task'` parent. The candidate list the model sees is now exactly the set those writers
  will accept.
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
  prose uses the Rem-owned shared runtime in observe-only mode with no allowed tools; raw email data
  never enters gateway `chat.send` or its authoring JSONL. Only final prose is injected. If enriched
  authoring fails, managed task-bearing briefs make a distinct task-only shared-runtime dispatch;
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
- When AI authoring is enabled, every eligible non-empty time slot owns one canonical persisted artifact. Rem-managed users author through the shared tool-free runtime with a durable semantic attempt identity; BYOK task-only remains on the transitional gateway until credential transport exists. Empty backend task snapshots remain deterministic Agenda state only: they do not append synthetic assistant prose to Today, because connector-owned work can make an injected “all clear” contradict the user's actual update.
- Historical deterministic artifacts remain identifiable as `fallback`, but new empty snapshots do not author or deliver them. A later real gateway artifact may supersede a historical fallback after its artifact-row delivery fence expires. Every successful replacement rotates an immutable revision carried through delivery claim, preparation, reconciliation, and completion so a stale worker cannot inject or mark a newer artifact delivered.
- The same exact artifact is offered to the durable `rem-orchestrator` transcript and the legacy per-day transcript during rollout. `/brief` keeps buckets/counts live and takes prose from the canonical `daily_briefs` pointer immediately; `is_authored` authorizes the card/read-aloud surface independently, while `brief_session_key` remains withheld until the exact revision is proven delivered to the negotiated transcript. Legacy `source=fallback` artifacts are never prose authority.
- A delivered artifact's Agenda summary is normalized or derived from that same canonical markdown.
  If no useful lead can be derived, `/brief` clears the summary instead of retaining
  `gatherBrief`'s deterministic fallback beside canonical markdown/session authority.
- `npm run brief:repair -- --user-id UUID --local-day YYYY-MM-DD --digest SHA256 [--message-id ID]` is a staging-only, dry-run-by-default recovery seam. It requires both the immutable Railway staging environment ID and a pinned fingerprint read from the connected Postgres cluster before commit. It reads history with the target staging user's already-stored gateway mapping and requires an exact, unique transcript identity; even dry-run verification may wake a sleeping Fly gateway. `--commit` refuses active authoring/delivery leases, then invalidates only that user/day's historical fallback rows and adopts the verified message inside one transaction. It never infers first/latest prose or prints prose/credentials.
- Enabled Daily Brief triggers use an artifact-first notification lifecycle: a check-in authors (or
  recovers) its exact local-day/slot artifact, revalidates that canonical pointer under the
  notification fence, then sends one collapsible APNs alert and stamps the trigger. During the
  mixed-client rollout, APNs remains gated on exact transcript delivery because older clients need
  `brief_session_key`; updated clients may still fetch and read canonical gateway-free artifacts
  directly from `/brief`. Version-capable artifact-only push fanout is a separate migration. Authoring
  failure sends no notification and leaves the trigger retryable **within a
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
- A routine is an existing, same-tenant task that does work on a cadence (`routine_schedules`, migrations 017 and 133). CRUD lives in `routine-schedule.service.ts`; the per-run execution + governance gate lives in `routine-runner.service.ts`. `routine-policy-lock.service.ts` uses its own bounded database pool to serialize the authoritative enabled/autonomy/prompt/model read and complete dispatch with update, pause, and delete, so those mutations have a defined order relative to an L3 acting turn without starving ordinary queries. Every L0-L2 outcome plus scheduled model/policy terminal outcomes claims a durable occurrence before any model call or comment; successful plans and denied outcomes settle the comment plus `last_run_at` in one statement. Model-selection warnings instead park the occurrence without stamping a run, remain deduplicated while configuration is unchanged, and become reclaimable when a model is selected so one-shot routines are not consumed. Public JWT Run Now carries an explicit manual identity and may intentionally run a paused routine; the retained shared-secret gateway webhook remains scheduled/fail-closed because legacy cron jobs can still invoke it. L3+ acting runs retain their transitional writer until concrete adapters exist.
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
- `resolveModelRuntimeMode(userId)` is the single seam. It reads durable payer ownership from
  `users.model_runtime_mode` (migration 126), independent of gateway URL, hosting provider, or
  deployment state. Existing and new accounts default to `rem_managed`; missing, invalid, or
  unavailable state resolves to `unknown`.
- No current product mutation stores `byok`. A future BYOK migration must make a credential
  available to the assigned Rem runtime and change `model_runtime_mode` in the same lifecycle;
  device Keychain presence alone is not backend runtime authority.
- `mayChargeRemManagedKey(mode)` is the gate, and it **fails closed on `unknown`**: a failed mode
  lookup is not permission to bill the operator.
- `runAgentTurnOnSharedRuntime` enforces that gate centrally before loading the provider runtime,
  so digest, memory, relevance, and future callers cannot bypass payer ownership by omission.
- Daily Brief authoring for Rem-managed accounts runs through the observe-only shared runtime with
  no tools. Connector text never enters legacy gateway `chat.send`. A future BYOK account keeps
  task-only authoring on its own gateway until Rem owns a consented credential transport; a
  connector-only BYOK day fails closed with `connector_model_not_owned`.

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
| POST | `/tasks/:id/agent-run` | JWT | Run Rem's task agent and persist its verdict/transcript |
| GET/POST | `/conversations` | JWT | List or create Rem-owned ordinary conversations |
| GET/PATCH/DELETE | `/conversations/:id` | JWT | Read, rename, or delete one owned conversation |
| POST | `/conversations/:id/chat` | JWT | Continue a conversation with exact dispatch replay |
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
