import { pool } from '../db/pool.js';
import { decrypt, getSetupPassword } from '../services/gateway.service.js';
import { ensureComposioMcpWired, isComposioConfigured } from '../services/composio.service.js';

/**
 * One-shot reconciliation (#1087 follow-up): wires `mcp.servers.composio` into every user's
 * gateway that has both a gateway configured AND Composio configured, regardless of when they
 * connected a toolkit or whether the app ever hit a Composio route since this code shipped.
 *
 * Why this exists: the per-request triggers in composio.routes.ts (`/composio/status/:id` on
 * connect, `/composio/toolkits` on Connectors-screen load) only fire when the APP makes that
 * specific request. A user who connected Gmail before this fix shipped, or whose client cached
 * the toolkits response, never re-hits either route — so their gateway silently never gets wired.
 * This script (and the idempotent `ensureComposioMcpWired` it calls) is the reconciliation pass
 * that doesn't depend on any client behavior at all — it walks every gateway directly.
 *
 * Usage:
 *   npm run sync:composio:all -- --dry-run
 *   npm run sync:composio:all
 *   npm run sync:composio:all -- --limit=5
 *   npm run sync:composio:all -- --user=<userId>            (single user, for a live re-test)
 *   npm run sync:composio:all -- --user=<userId> --force    (re-mint even if already wired — #1099)
 *
 * `--force` (#1099 remediation): re-mints the Composio session and re-patches the gateway EVEN IF
 * `mcp.servers.composio` already exists — needed for a user wired by an earlier build that minted
 * its session without the `toolkits` scope fix in `getMcpConfig` (see that function's doc). The
 * normal idempotent path only checks whether the key is PRESENT, not whether it's correctly
 * configured, so it will never self-heal that specific case on its own. `--force` requires
 * `--user=<id>` — it is a targeted remediation tool for one known-broken account, not a fleet-wide
 * operation (a fleet-wide force would churn a fresh orphaned Composio session for every already-fine
 * user for no reason).
 */

function parseArgs(argv: string[]) {
  const dryRun = argv.includes('--dry-run');
  const force = argv.includes('--force');
  const limitArg = argv.find((arg) => arg.startsWith('--limit='));
  const userArg = argv.find((arg) => arg.startsWith('--user='));

  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : null;
  const userId = userArg ? userArg.split('=').slice(1).join('=').trim() : null;

  if (limitArg && (!Number.isFinite(limit) || (limit as number) <= 0)) {
    throw new Error('Invalid --limit value. Example: --limit=25');
  }
  if (force && !userId) {
    throw new Error('--force requires --user=<id> — it is a targeted single-account remediation, not a fleet-wide operation.');
  }

  return { dryRun, force, limit, userId };
}

interface GatewayRow {
  id: string;
  gateway_url: string;
  gateway_token_encrypted: string;
}

async function run() {
  const { dryRun, force, limit, userId } = parseArgs(process.argv.slice(2));
  const started = Date.now();

  if (!isComposioConfigured()) {
    console.log('[sync-composio-mcp] COMPOSIO_API_KEY is unset on this backend — nothing to sync.');
    await pool.end();
    return;
  }

  console.log(`[sync-composio-mcp] starting ${dryRun ? '(dry-run)' : ''}${force ? ' (force re-wire)' : ''}`);

  const { rows } = await pool.query<GatewayRow>(
    userId
      ? `SELECT id, gateway_url, gateway_token_encrypted
         FROM users
         WHERE id = $1::uuid
           AND gateway_url IS NOT NULL
           AND gateway_token_encrypted IS NOT NULL`
      : `SELECT id, gateway_url, gateway_token_encrypted
         FROM users
         WHERE gateway_url IS NOT NULL
           AND gateway_token_encrypted IS NOT NULL
         ORDER BY id ASC`,
    userId ? [userId] : [],
  );

  const targets = limit ? rows.slice(0, limit) : rows;
  console.log(`[sync-composio-mcp] users with gateway credentials: ${rows.length}`);
  console.log(`[sync-composio-mcp] users selected for this run: ${targets.length}`);

  let wired = 0;
  let alreadyWired = 0;
  let skipped = 0;
  let failed = 0;

  for (const row of targets) {
    const gwUserId = row.id;
    const gatewayUrl = row.gateway_url;
    try {
      if (dryRun) {
        console.log(`[sync-composio-mcp] dry-run user=${gwUserId} gateway=${gatewayUrl}`);
        continue;
      }
      const gatewayToken = decrypt(row.gateway_token_encrypted);
      const setupPassword = await getSetupPassword(gwUserId).catch(() => undefined);
      const result = await ensureComposioMcpWired(gwUserId, gatewayUrl, gatewayToken, setupPassword, { force });
      if (result.wired && result.reason === 'already_wired') {
        alreadyWired += 1;
        console.log(`[sync-composio-mcp] already wired user=${gwUserId} gateway=${gatewayUrl}`);
      } else if (result.wired) {
        wired += 1;
        console.log(`[sync-composio-mcp] wired user=${gwUserId} gateway=${gatewayUrl}`);
      } else {
        skipped += 1;
        console.log(`[sync-composio-mcp] skipped user=${gwUserId} gateway=${gatewayUrl} reason=${result.reason}`);
      }
    } catch (err: any) {
      failed += 1;
      console.warn(`[sync-composio-mcp] failed user=${gwUserId} gateway=${gatewayUrl} error=${err?.message ?? String(err)}`);
    }
  }

  await pool.end();

  const elapsedMs = Date.now() - started;
  console.log(
    `[sync-composio-mcp] done in ${elapsedMs}ms wired=${wired} alreadyWired=${alreadyWired} skipped=${skipped} failed=${failed}`,
  );

  if (failed > 0) {
    process.exitCode = 1;
  }
}

run().catch(async (err) => {
  console.error('[sync-composio-mcp] fatal:', err);
  await pool.end().catch(() => undefined);
  process.exit(1);
});
