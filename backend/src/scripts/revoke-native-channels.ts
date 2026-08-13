import { pool } from '../db/pool.js';
import { decrypt, getSetupPassword } from '../services/gateway.service.js';
import { patchGatewayConfig, logoutGatewayChannel } from '../services/gateway-pair.service.js';

/**
 * One-shot teardown for the retired NATIVE messaging-channel product (Discord / WhatsApp).
 *
 * ## Why this exists
 *
 * The native channels stack — `channels.service.ts`, `/api/v1/channels`, `SharedChannelsSettingsView`,
 * and the "Manage previous channel connections" row under Connectors — was removed once Composio
 * became the single connector catalog (PR #1228: "Connectors offers Slack, Discord, WhatsApp
 * Business, and Telegram ... instead of a separate fake channels list").
 *
 * Deleting the UI alone would have been unsafe: a grant lives in the USER'S GATEWAY CONFIG
 * (`channels.<provider>.enabled: true`, plus a Discord bot token or a linked WhatsApp Web session
 * on the Fly volume), not in the app. With the app surface gone there would be no way to turn a
 * still-running connector off. This script is that missing off switch, and it is deliberately
 * INDEPENDENT of the deleted service so it keeps working after the deletion lands.
 *
 * ## What it does
 *
 * For every `user_channels` row still in `connecting`/`connected`, or still holding a credential:
 *   1. WhatsApp only — upstream `channels.logout`, which resolves the configured account, stops its
 *      runtime, and runs the plugin's guarded credential cleanup. A config-only disable would leave
 *      `creds.json` on the volume and silently relink later.
 *   2. `config.patch` `{ channels: { <provider>: { enabled: false } } }` over the WS hot-reload path
 *      (no gateway restart — the wrapper's HTTP path restarts and drops the app's socket, #953).
 *   3. Mark the DB mirror `disconnected` and NULL its stored credential.
 *
 * Gateway work happens BEFORE the DB write, so a failure leaves a retryable row rather than a
 * database that claims a still-running connector is off. Re-running is safe: `channels.logout` is
 * idempotent upstream, and an already-disabled connector accepts the same patch.
 *
 * ## Usage
 *
 *   npm run revoke:channels               # DRY RUN (default) — reports what exists, changes nothing
 *   npm run revoke:channels -- --apply    # actually revoke
 *   npm run revoke:channels -- --apply --limit=5
 *
 * The dry run is also the answer to "does anyone still hold a native grant?". If it reports
 * `live grants: 0`, nothing was ever stranded by the deletion and this script can be deleted too.
 */

export type NativeChannelProvider = 'discord' | 'whatsapp';

export interface NativeChannelGrantRow {
  user_id: string;
  provider: NativeChannelProvider;
  status: string;
  has_credential: boolean;
  gateway_url: string | null;
  gateway_token_encrypted: string | null;
}

/**
 * A grant is "live" when the connector may still be running on the gateway: an explicit
 * connecting/connected status, or a stored credential a `disconnected` row failed to clear.
 * Pure so the selection rule is testable without a database.
 */
export function isLiveGrant(row: Pick<NativeChannelGrantRow, 'status' | 'has_credential'>): boolean {
  return row.status === 'connecting' || row.status === 'connected' || row.has_credential;
}

/** The disable patch. Mirrors the deleted `buildChannelConfigPatch(provider, { enabled: false })`. */
export function buildDisablePatch(provider: NativeChannelProvider): Record<string, unknown> {
  return { channels: { [provider]: { enabled: false } } };
}

export function parseArgs(argv: string[]) {
  const apply = argv.includes('--apply');
  const limitArg = argv.find((arg) => arg.startsWith('--limit='));
  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : null;
  if (limitArg && (!Number.isFinite(limit) || (limit as number) <= 0)) {
    throw new Error('Invalid --limit value. Example: --limit=25');
  }
  return { apply, limit };
}

const SELECT_GRANTS = `
  SELECT c.user_id::text AS user_id,
         c.provider,
         c.status,
         (c.credential_encrypted IS NOT NULL) AS has_credential,
         u.gateway_url,
         u.gateway_token_encrypted
    FROM user_channels c
    JOIN users u ON u.id = c.user_id
   ORDER BY c.user_id, c.provider`;

async function run() {
  const { apply, limit } = parseArgs(process.argv.slice(2));
  const started = Date.now();

  // `user_channels` is only dropped by a future migration, never by this script — the table is the
  // record of what existed. A missing table means the teardown already happened.
  const exists = await pool.query(`SELECT to_regclass('public.user_channels') AS t`);
  if (!exists.rows[0]?.t) {
    console.log('[revoke-channels] user_channels table absent — nothing to revoke.');
    await pool.end();
    return;
  }

  const { rows } = await pool.query<NativeChannelGrantRow>(SELECT_GRANTS);
  const live = rows.filter(isLiveGrant);
  const targets = limit ? live.slice(0, limit) : live;

  console.log(`[revoke-channels] mode: ${apply ? 'APPLY' : 'DRY RUN (pass --apply to revoke)'}`);
  console.log(`[revoke-channels] user_channels rows: ${rows.length}`);
  console.log(`[revoke-channels] live grants: ${live.length}`);
  console.log(`[revoke-channels] selected this run: ${targets.length}`);

  let revoked = 0;
  let failed = 0;
  let skipped = 0;

  for (const row of targets) {
    const label = `user=${row.user_id} provider=${row.provider} status=${row.status} hasCredential=${row.has_credential}`;

    if (!row.gateway_url || !row.gateway_token_encrypted) {
      // No gateway to disable the connector on. The row is inert: without a gateway there is no
      // running connector, so clearing the mirror is the whole job.
      if (apply) {
        await pool.query(
          `UPDATE user_channels SET status = 'disconnected', credential_encrypted = NULL, updated_at = NOW()
            WHERE user_id = $1::uuid AND provider = $2`,
          [row.user_id, row.provider],
        );
      }
      console.log(`[revoke-channels] ${apply ? 'cleared' : 'would clear'} (no gateway) ${label}`);
      skipped += 1;
      continue;
    }

    if (!apply) {
      console.log(`[revoke-channels] would revoke ${label} gateway=${row.gateway_url}`);
      continue;
    }

    try {
      const gatewayToken = decrypt(row.gateway_token_encrypted);
      const setupPassword = await getSetupPassword(row.user_id).catch(() => undefined);

      if (row.provider === 'whatsapp') {
        await logoutGatewayChannel(row.gateway_url, gatewayToken, row.provider, setupPassword);
      }

      await patchGatewayConfig(
        row.gateway_url,
        gatewayToken,
        buildDisablePatch(row.provider),
        setupPassword,
      );

      // Only after the live config agrees does the durable mirror change.
      await pool.query(
        `UPDATE user_channels SET status = 'disconnected', credential_encrypted = NULL, updated_at = NOW()
          WHERE user_id = $1::uuid AND provider = $2`,
        [row.user_id, row.provider],
      );

      console.log(`[revoke-channels] revoked ${label}`);
      revoked += 1;
    } catch (err: any) {
      failed += 1;
      console.warn(`[revoke-channels] FAILED ${label} error=${err?.message ?? String(err)}`);
    }
  }

  await pool.end();
  console.log(
    `[revoke-channels] done in ${Date.now() - started}ms revoked=${revoked} cleared=${skipped} failed=${failed}`,
  );
  if (failed > 0) process.exitCode = 1;
}

// Only run when invoked directly, so the pure helpers above stay unit-testable.
if (process.argv[1]?.includes('revoke-native-channels')) {
  run().catch(async (err) => {
    console.error('[revoke-channels] fatal:', err);
    await pool.end().catch(() => undefined);
    process.exit(1);
  });
}
