# Scripts (`backend/src/scripts/`)

> Admin scripts for managing all users' AI gateways in bulk. Useful when rolling out a config change, updating the AI model, fixing a widespread pairing bug, or keeping the pre-warmed deployment pool stocked. These are run manually by the developer — not triggered by the app.

Operational and maintenance scripts for bulk gateway management. All scripts support `--dry-run` and iterate per-user with individual error handling.

## Key Files

| Script | Purpose |
|--------|---------|
| `patch-config-all-gateways.ts` | Patches managed non-Talk config (allowCommands, model, hooks) for all users, then runs fingerprint-aware Talk reconciliation so provider/credential/voice choices are never overwritten by the broad patch. Supports `--apply` to restart gateways after patching. |
| `patch-default-model-all-gateways.ts` | Targeted script that only patches the primary model setting. Defaults to `anthropic/claude-sonnet-4-5`. |
| `update-gateway-image-all.ts` | Updates Docker image for all Fly gateway machines. Resolves image from `--image` flag or `FLY_GATEWAY_IMAGE` env. Skips machines already on target image. 120s timeout per machine. |
| `verify-gateway-image-rollout.ts` | Read-only rollout verifier for backend-referenced active Fly gateways. Includes legacy rows where the app name is only recoverable from `gateway_url`; reports old image, missing machine, Fly API failures, and unreachable health checks without printing secret values. |
| `repair-broken-pairings.ts` | Repairs broken pairing records with `operator.admin` scope. Implements full WebSocket protocol v3 (challenge-response auth) to find and remove broken devices. |
| `replenish-pool.ts` | Maintains pre-warmed gateway pool at target size (`POOL_TARGET_SIZE` env, default 2). Cleans stale entries first, then creates new ones. |
| `migrate-pooled-gateways.ts` | Restores historically assigned `remclaw-pool-*` volumes into stable per-user Fly apps. Defaults to dry-run; `--apply` snapshots and health-checks the restored gateway before an atomic database cutover, while retaining the stopped source for rollback. Run only after credential-reconciling clients are rolled out. |
| `repair-canonical-brief.ts` | Staging-only repair for a target user/day whose durable transcript has an exact verified work brief but legacy fallback rows own `/brief`. Requires immutable Railway + database-resident staging identity, a SHA-256 digest (and message ID when exposed), defaults to dry-run, and may wake the target Fly gateway while verifying history. It never prints prose/credentials, refuses active authoring/delivery, and commits fallback invalidation + canonical adoption in one transaction only with `--commit`. |
| `run-brief-authoring.ts` | Delivery-only recovery for recent canonical gateway-authored Daily Brief artifacts missing either rollout transcript delivery. It never selects users from tasks/check-ins and never creates a fresh artifact; enabled, due check-ins are the sole scheduled authoring authority. |
| `repair-cross-environment-gateway-pointer.ts` | Audits one exact backend user/app/machine pointer against the Fly machine's `REMCLAW_USER_ID` + `BACKEND_URL` ownership stamps. Dry-run by default; `--apply` releases only a proven cross-environment DB pointer and never wakes/destroys the app or copies tokens, workspace data, or Composio grants. |
| `patch-controlui-all-gateways.sh` | One-time Bash migration script adding controlUi config to Fly gateways via `fly ssh console`. Required for backend auto-approve (gateway v2026.2.25+). |
| `revoke-native-channels.ts` | Off switch for the deleted native Discord/WhatsApp channel product. A native grant lived in the user's gateway config (`channels.<provider>.enabled` + a Discord bot token / a linked WhatsApp Web session on the volume), so deleting `/api/v1/channels` alone would have left a running connector nobody could turn off. WhatsApp goes through upstream `channels.logout` first (a config-only disable strands `creds.json` and silently relinks); then a `config.patch` disable over the WS hot-reload path; then the `user_channels` mirror. Deliberately self-contained — it does not import the deleted service, so it still works after the deletion. Dry-run by default; the dry run's `live grants: N` line is also how you confirm nothing was stranded. **Delete this script, and drop `user_channels`, once a run reports 0.** |

## Common Patterns

- **`--dry-run` / `--apply`**: All scripts default to dry-run; `--apply` or explicit flags enable changes.
- **`--limit=N`**: Cap the number of gateways processed (useful for staged rollouts).
- **Batch iteration**: For-loop over users with per-item try-catch. Success/skipped/failed counters. Exit code 1 if any failures.
- **Token decryption**: Gateway tokens decrypted from `gateway_token_encrypted` (AES-256-GCM) before use.
- **Logging**: `[script-name]` prefix convention for all console output.

## Usage

```bash
# Dry-run config patch (preview only)
npx tsx src/scripts/patch-config-all-gateways.ts

# Apply config patch to all gateways
npx tsx src/scripts/patch-config-all-gateways.ts --apply

# Update model for first 5 gateways
npx tsx src/scripts/patch-default-model-all-gateways.ts --apply --limit=5

# Update gateway image
npx tsx src/scripts/update-gateway-image-all.ts --apply --image=registry.fly.io/remclaw-gateways:latest

# Verify every backend-referenced active Fly gateway is on the intended image
npm run verify:image:rollout -- --image=registry.fly.io/remclaw-gateways:latest

# Replenish pool
npx tsx src/scripts/replenish-pool.ts

# Validate remaining pooled users without changing infrastructure
npm run pool:migrate -- --limit=5

# Audit one exact gateway pointer against its external Fly ownership stamps
npm run gateway:ownership:repair -- \
  --user-id UUID --expected-app APP --expected-machine MACHINE
```
