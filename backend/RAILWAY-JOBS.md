# Railway Jobs (crons + gateway rollout)

These jobs **must run inside Railway** — they need the prod DB at `postgres.railway.internal`,
which only resolves on Railway's private network. `railway run` from a laptop injects the env
but runs the process *locally*, so the internal hostname fails with `ENOTFOUND`. That's why these
live as Railway **services**, not local scripts.

Each is a separate service in the **same project + environment (production)** as `backend`,
sharing the same repo/build. Only the **Start Command** and **Cron Schedule** differ.

## 1. Recurring cron service — `rem-cron`

Runs the scheduled loop work. Without it, the sweep / check-ins / routines / memory-extraction
never fire.

| Field | Value |
|-------|-------|
| Root directory | `backend` |
| Start command | `npm run cron:all` |
| Cron schedule | `*/15 * * * *` |
| Restart policy | `never` (cron services exit after each run) |

`cron:all` runs `memories:extract`, `signals:ingest`, `orchestrator:sweep`, `checkins:run`,
`routines:run` — each as an **independent** job (one flaky job no longer blocks the rest),
collecting failures and exiting non-zero only if at least one failed. `orchestrator:sweep` runs
**before** `checkins:run` so a check-in fired the same tick reflects the sweep's actions, and
`signals:ingest` runs before **both** because it is the producer of the `channel_signals` rows
they read. Each script is idempotent and internally time-gated (a check-in only sends in its
window, routines only fire when due, the sweep only picks tasks with `run_status IS NULL` and
stamps a terminal state, signal ingest upserts on `(user, source, source_ref)`), so a 15-min tick
is safe to over-run.

**`orchestrator:sweep` is OFF by default.** The autonomous "brief that ACTS" sweep (#922) runs a
ready task through the user's gateway and applies status — it only executes when
`ORCHESTRATOR_SWEEP_ENABLED` is set truthy (`1`/`true`/`yes`/`on`) in the environment. Without
that flag it no-ops and exits 0, so enabling fleet-wide autonomous execution is a deliberate,
reversible switch. Set/clear `ORCHESTRATOR_SWEEP_ENABLED` on the `rem-cron` service to toggle it.

**`signals:ingest` is OFF by default.** It polls each connected source (Composio) a recently-active
user has authorized and writes the results to `channel_signals`, which is what tier-2 suggestions
("Reply to Ada · Gmail") are derived from. Because it reads user mailboxes fleet-wide on a
schedule, it only runs when `SIGNAL_INGEST_ENABLED` is truthy (`1`/`true`/`yes`/`on`) on the
`rem-cron` service; otherwise it logs a reason code and exits 0. It also self-no-ops when
`COMPOSIO_API_KEY` is unset or no connector descriptors are registered — so a green run is never
evidence that anything was read. Bounds per user per source: 3 connected accounts, 20 items,
3 pages, a 24h window, 2.5s. Reads are idempotent on `(user, source, source_ref)`, so re-running a
tick cannot duplicate a suggestion.

## 2. Gateway image rollout — `rem-rollout` (manual)

Rolls a new gateway image across all fleet gateways. **Not** a cron — trigger by redeploying the
service when you cut a new image. Reads `FLY_GATEWAY_IMAGE` (already set on prod).

| Field | Value |
|-------|-------|
| Root directory | `backend` |
| Start command | `npm run job:rollout` |
| Cron schedule | *(none — manual redeploy)* |
| Restart policy | `never` |

`job:rollout` = `update:image:all --apply && verify:image:rollout`. To roll the current
orient-the-human hook image to the existing ~88 gateways, redeploy this service once. The verify
step reports any machines that didn't take.

## One-time setup (Railway dashboard)

For each service: **New → Empty Service → Connect this repo →** set Root Directory, Start Command,
Cron Schedule (cron one only), Restart Policy. Variables are inherited from the project; confirm
`DATABASE_URL`, `FLY_API_TOKEN`, `FLY_GATEWAY_IMAGE` are present in the production environment.

Railway has no CLI primitive to provision a cron service, so this is a dashboard step. After it
exists, every push to `staging`→prod rebuilds all three services together.
