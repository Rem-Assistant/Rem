# RemClaw Backend

Minimal Express server for auth, gateway metadata, billing, and gateway lifecycle support.

## Quick Start (1 Command)

For a fresh clone, run:

```bash
npm run dev:local
```

This command:
- creates `backend/.env.local` from `backend/.env.local.example` if missing
- generates local secrets if placeholders are still present
- starts a local Postgres container on `localhost:54329`
- runs the backend in dev mode (with auto migrations)

## Env

- `DATABASE_URL` — PostgreSQL connection string (required)
- `JWT_SECRET` — Signing secret for JWT (required)
- `GATEWAY_ENCRYPTION_KEY` — AES key for encrypting gateway tokens in DB (required). Use 32-byte key as hex (64 chars) or any string (derived with scrypt).

## Migrations

Gateway fields live in `src/db/migrations/005_add_gateway_fields.sql`. They are applied automatically on server startup. To run migrations only (e.g. from CI):

```bash
DATABASE_URL=postgres://... npm run migrate
```

Migrations are idempotent (safe to run multiple times).

### Schema in integration tests — apply the migrations, never restate them

Tests that need a real PostgreSQL schema must build it from `src/db/migrations`, not from a
hand-written `CREATE TABLE` block. Use `createMigratedDatabase()`
(`src/db/test-support/migrated-database.ts`): it creates a throwaway database, applies every
migration in the production runner's sorted-filename order, and hands back a pool.

```ts
const database = await createMigratedDatabase({
  adminConnectionString: process.env.TEST_DATABASE_URL!,
  label: 'my_suite',
});
// ... database.pool ...
await database.drop();
```

A hand-written stub is a second, silent definition of the schema. It rots: every new column has to
be hand-copied into it, and a miss surfaces as an unrelated assertion (`expected 500 to be 200`)
because routes swallow query errors, so the next reader debugs the wrong feature. Stubs also drift
into being simply *wrong* — the one removed from `brief-atomic.integration.test.ts` gave
`daily_brief_artifact_deliveries` an `id` primary key it does not have and typed `revision` as TEXT
when it is UUID.

Seed rows with **named columns** (`INSERT INTO t (a, b) VALUES ...`). Positional inserts only stay
valid while new columns land at the end of a table.

A throwaway *database* rather than a `CREATE SCHEMA` + `search_path` is deliberate: migrations may
schema-qualify their DDL, and `100_user_channels_connecting_status.sql` already does. Its
`to_regclass('public.user_channels')` guard returns NULL under a temp schema, so the migration
silently no-ops — a skipped migration being the same class of bug as a missing column. This needs a
`TEST_DATABASE_URL` role that may create databases; CI's `postgres:16` service role can.

## API (Epic 1)

- `GET /api/v1/me` — Returns user profile and gateway metadata (`gateway.url`, `gateway.hostingProvider`, `gateway.isConnected`). Requires `Authorization: Bearer <jwt>`.
- `PATCH /api/v1/me/gateway` — Body: `{ gatewayUrl, gatewayToken [, hostingProvider ] }`. Encrypts token, persists, returns updated gateway metadata. Requires JWT.

Token is never returned in API responses; it is stored encrypted.

## Task Sync Deletions

Task list pages are not deletion snapshots: clients may read them while rows are changing.
`DELETE /api/v1/tasks/:id` therefore records a user-scoped tombstone in the same transaction
as the delete (migration 103), and `GET /api/v1/tasks/deletions` returns those explicit
tombstones for cross-device reconciliation. Clients must not infer deletion from list absence.
Tombstones begin at migration 103; tasks deleted before that cutover cannot be reconstructed
as historical tombstones and may remain as stale local rows on a long-dormant device. This is
a deliberate no-data-loss rollout tradeoff: users can delete such a row again to create a
durable tombstone, while the client never guesses from a mutable/possibly stale list response.

## Gateway Timezone Context

The app's device timezone is stored in `users.timezone`, then reconciled into each configured
gateway as `agents.defaults.userTimezone` after the timezone write, after gateway credentials are
first saved (including dedicated and pooled deployment), and again after every successful wake.
OpenClaw uses that setting for agent-only timestamp context while keeping chat transcript text raw.

## Managed Fly Gateways

Managed cloud gateways are per-user Fly Machines. The gateway app has a persistent
`/data` volume mounted into the machine; OpenClaw state, paired device records,
workspace files, and gateway config live under that volume rather than inside the
Docker image.

New assignments default to canonical per-user Fly apps (`remclaw-{user}`). Pre-warmed
`remclaw-pool-*` claims are disabled unless `GATEWAY_POOL_ASSIGNMENT_ENABLED=true`; do not enable
that gate until claim-time transfer preserves the gateway volume while moving it into the user's
canonical app identity. Existing pool-assigned users require an explicit volume-preserving
migration and must not be silently redeployed or reset merely to change the displayed name.
Pool images never contain the managed Talk credential while unclaimed. Both direct onboarding and
pool assignment read the claimant's canonical entitlement before the first managed Talk write, and
inactive pool assignment also scrubs the credential slot for legacy pre-warmed rows before the
gateway pointer commits. Pool claim and assignment use the same durable per-user PostgreSQL fence as
IAP entitlement mutations: assignment first transfers the Fly Machine's `REMCLAW_USER_ID` and
`BACKEND_URL`, then writes Talk, commits the pointer, and revalidates entitlement before releasing
the fence. A replica that finds an existing durable claim fails closed instead of relaunching its
assignment. Failed pre-pointer writes retain their claim for cleanup; compensation releases and
reacquires the lifecycle fence, then scrubs only after a fresh read still proves the claim is
unconsumed and no canonical gateway pointer exists.

Managed Talk rotation also requires `ELEVENLABS_API_KEY_GENERATION` (positive integer, default `1`).
Increment it whenever `ELEVENLABS_API_KEY` changes. The database accepts only a higher generation;
draining replicas may confirm a newer converged key but cannot write their older key back.
Credential removal and generation greater than 1 are phase-two mutations because the legacy wake
writer can restore its environment key. Keep `MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE=false`
through the mixed-version rollout. Only set it to `true` after rollout telemetry confirms every
live writer advertises the lifecycle/generation fence and all legacy replicas have drained. Until
then, inactive-key scrub and rotation remain durably pending and the installed key is left intact,
which makes both old and new wake writers converge without oscillation.

Gateway image rollout (canary → batch → fleet) is driven by the managed cloud
infrastructure, which is operated separately and is not part of this repo (see
the Open-Core Boundary in the top-level `README.md`).

### Managed voice configuration

`src/config/gateway-defaults.ts` is the source of truth for the managed Talk provider
configuration applied during new deploys and explicit ownership-aware Talk reconciliation.
Broad Repair Cloud Gateway and bulk config patches omit Talk entirely so they cannot replace a
user-owned provider, credential, or voice. OpenClaw's strict schema requires the selected provider at
`talk.provider` and its settings under the matching `talk.providers.<id>` entry. Never
restore the rejected legacy flat `talk.apiKey`, `talk.voiceId`, or `talk.modelId` keys.
Fresh onboarding supplies the initial managed voice/model defaults. Managed redeploy saves the
canonical Fly pointer first, then runs the same fingerprint-aware reconciliation as gateway wake;
only a credential matching Rem's stored ownership fingerprint may rotate. `/gateway/wake` reads the effective Talk config and
adds only the managed credential when an existing ElevenLabs branch already owns provider/voice/model
selections, and applies the full canonical Talk branch only when managed Talk is wholly absent; healthy
gateways are left untouched so a cold app launch does not cause a no-op config restart.
Whenever provisioning or reconfiguration actually installs the managed credential, the deploy
pipeline stores its SHA-256 ownership fingerprint atomically with the Fly machine pointer. If an
old image cannot accept the config patch, the existing fingerprint is preserved rather than
claiming a credential the backend did not install.

Important compatibility note: app clients can connect to gateways that were
deployed before the current OpenClaw server image. Do not rely on a fleet upgrade
as the only fix for protocol/auth compatibility issues. For example, the 2026-05
Approval Pending incident came from Swift clients signing the newer v3
device-auth payload against older gateways that still verified the v2 canonical
payload only. The app-side fix kept Swift signing compatible with v2 while
managed Fly gateways can still be upgraded separately.

Pairing approval follows the same compatibility rule. Current wrapper images
advertise the upstream v3-v4 protocol range for internal `approve-all` and
status calls. The backend detects the exact protocol-mismatch response from
older fixed-v3 wrappers and falls back to its ranged direct WebSocket client,
so approval recovery does not depend on an immediate fleet image rollout. The
direct client correlates each approval response and counts only `ok: true`
acknowledgements; sending an approval request alone is never reported as success.

Historical pooled gateways are migrated with `npm run pool:migrate` (dry-run by default). Apply
mode holds a per-user PostgreSQL advisory lock shared with `/gateway/wake`, existing-gateway Fly
repair deploys, and account deletion. First-time provisioning writes a
`gateway_fly_app_ownership.state = 'provisioning'` row under that fence before Fly app creation,
releases the database session during multi-minute machine work, then reacquires the fence and proves
the provisional row still belongs to the live user before any organization Talk key is installed.
The row also stores the deployment attempt ID: a rolling replica that arrives after reservation
receives an in-progress outcome and cannot refresh the lease, onboard with different tokens,
finalize the pointer, or compensate/destroy the owning attempt's app.
The pointer, Fly metadata, and canonical ownership transition commit atomically; pre-pointer failure
transitions the same row to retryable deletion. Migration rejects
stale pre-lock plans by re-reading the authoritative user and claimed source ownership under the
lifecycle lock before checkpoint creation or Fly mutation. Authenticated manual gateway ownership
updates acquire that same lock and write on its PostgreSQL session. Migration also rejects
any topology with mounts beyond the single validated `/data`
volume and writes a durable `gateway_pool_migrations` checkpoint before fencing the source. After
a process restart, that AES-256-GCM encrypted checkpoint restores the exact source config/state and
deletes only the checkpoint-owned partial target before retrying. Dedicated-gateway wakes reserve
only a bounded share of the shared PostgreSQL pool. Destructive owners wait fairly for a bounded
dedicated connection and then enter PostgreSQL's native blocking advisory-lock queue, so they remain
visible to old and new replicas during a rolling deploy without retaining an application-pool
checkout. Wake traffic uses the same lock key with a non-blocking attempt and therefore fails closed
behind any active or database-queued owner. Successful cutover retains the stopped source as
a `gateway_pool.status = 'migrated'` rollback record. The shared PostgreSQL pool uses a native
2-second connection timeout so stalled socket handshakes are destroyed by `pg` rather than
silently consuming pool capacity after a lifecycle caller has timed out.

The every-15-minute cron runs `pool:cleanup`, which is intentionally limited to orphaned direct
provisioning/deletion apps, migration targets, retained rollback apps, and unconsumed claims whose
owning user was deleted. It never
replenishes the disabled pool and never age-sweeps claims that still belong to a live user. Account
deletion first adopts canonical and provisional direct apps into durable `delete_pending` ownership;
account deletion and scheduled cleanup remove durable metadata only after
Fly confirms app deletion (or an idempotent 404), so transient Fly failures remain retryable.
The service-token replenishment cleanup also takes the claimed user's lifecycle fence, then
atomically retires an age-stale claim to ownerless durable cleanup state before destroying its app.
That row transition makes a draining pre-lock replica's guarded claim consumption fail and roll
back any invisible pointer write, while a replica that already consumed the claim wins before the
destructive call.

## Billing Source Of Truth

Apple subscription entitlement is server-authoritative. The backend resolves
entitlement from App Store Server API transaction/status data and writes
`users.billing_plan` + `users.billing_status`. Client receipt blobs are not
accepted by backend APIs.

## IAP Notifications + Reconciliation

- `POST /api/v1/iap/apple/notifications` — App Store Server Notifications V2 webhook (`signedPayload`).
- `POST /api/v1/iap/reconcile` — service-token protected reconciliation pass for existing subscription chains.

Additional env vars for notifications:
- `APPLE_IAP_ROOT_CA_PATHS` — comma-separated certificate paths for Apple root CAs.
- `APPLE_IAP_ENABLE_ONLINE_CHECKS` — `true|false` revocation/expiry checks in signature verification.

## Daily Brief Authoring

The BRIEF owns its title. Gateway-authored prose must open with a `## ` headline line; the
authoring lease holder extracts it once (`extractBriefHeadline`) and stores it in
`daily_brief_artifacts.headline` (migration 119) beside `summary`. `GET /api/v1/brief` returns it
as `headline`, and every client surface that names the brief renders that one string — the iOS
Agenda summary card header and the orchestrator chat title. Nothing re-derives a title at render
time; that split is exactly what made the card say “Good morning” while the chat said “The Day”.

A `null` headline (pre-migration artifacts whose prose opened without a heading, or no delivered
artifact yet) means each surface keeps its previous fallback: the clock-derived time-of-day
greeting on the Agenda card, “Rem” in chat. Migration 119 backfills existing rows whose markdown
already began with a heading.

Brief prose after the headline must still begin with a substantive description of the day, and the
backend strips a legacy generic greeting prefix before storing the card summary. The brief response advertises a
conversation key only after authored prose is visibly delivered to that exact gateway transcript;
with authoring disabled or delivery pending, Summary remains a card/detail interaction instead of
opening an empty chat.

Due check-in authoring may add a bounded backend-owned Gmail snapshot. The collector uses only
ACTIVE Composio accounts and pinned read-only `GMAIL_FETCH_EMAILS` `20260721_00`; provider text is
held in-memory and sent only to a plain backend chat-completions call with no tool definitions; raw
email data never enters gateway `chat.send` or its JSONL. Artifacts persist provenance only. A timeout,
schema/transport error, paused connection, or over-cap account set records Gmail unavailable and
continues task-only authoring. No deploy is implied by this contract.
