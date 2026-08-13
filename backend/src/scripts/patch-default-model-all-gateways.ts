import { pool } from '../db/pool.js';
import { decrypt } from '../services/gateway.service.js';
import { patchGatewayConfig } from '../services/gateway-pair.service.js';
import { DEFAULT_PRIMARY_MODEL } from '../config/gateway-defaults.js';

// Use the single source of truth so this script can't silently revert the fleet
// off the intended default (was hardcoded to Claude — see review of #822).
const DEFAULT_MODEL = DEFAULT_PRIMARY_MODEL;

function parseArgs(argv: string[]) {
  const dryRun = argv.includes('--dry-run');
  const limitArg = argv.find((arg) => arg.startsWith('--limit='));
  const modelArg = argv.find((arg) => arg.startsWith('--model='));

  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : null;
  const model = modelArg ? modelArg.split('=').slice(1).join('=').trim() : DEFAULT_MODEL;

  if (limitArg && (!Number.isFinite(limit) || (limit as number) <= 0)) {
    throw new Error('Invalid --limit value. Example: --limit=25');
  }

  if (!model) {
    throw new Error('Invalid --model value. Example: --model=anthropic/claude-sonnet-4-5');
  }

  return { dryRun, limit, model };
}

interface GatewayRow {
  id: string;
  gateway_url: string;
  gateway_token_encrypted: string;
}

async function run() {
  const { dryRun, limit, model } = parseArgs(process.argv.slice(2));
  const started = Date.now();

  console.log(`[patch-model] starting ${dryRun ? '(dry-run)' : ''}`);
  console.log(`[patch-model] target model: ${model}`);

  const { rows } = await pool.query<GatewayRow>(
    `SELECT id, gateway_url, gateway_token_encrypted
     FROM users
     WHERE gateway_url IS NOT NULL
       AND gateway_token_encrypted IS NOT NULL
     ORDER BY id ASC`
  );

  const targets = limit ? rows.slice(0, limit) : rows;
  console.log(`[patch-model] users with gateway credentials: ${rows.length}`);
  console.log(`[patch-model] users selected for this run: ${targets.length}`);

  let success = 0;
  let failed = 0;

  for (const row of targets) {
    const userId = row.id;
    const gatewayUrl = row.gateway_url;
    try {
      const gatewayToken = decrypt(row.gateway_token_encrypted);
      if (dryRun) {
        console.log(`[patch-model] dry-run user=${userId} gateway=${gatewayUrl}`);
        success += 1;
        continue;
      }

      await patchGatewayConfig(gatewayUrl, gatewayToken, {
        agents: { defaults: { model: { primary: model } } },
      });
      console.log(`[patch-model] patched user=${userId} gateway=${gatewayUrl}`);
      success += 1;
    } catch (err: any) {
      failed += 1;
      console.warn(`[patch-model] failed user=${userId} gateway=${gatewayUrl} error=${err?.message ?? String(err)}`);
    }
  }

  await pool.end();

  const elapsedMs = Date.now() - started;
  console.log(`[patch-model] done in ${elapsedMs}ms success=${success} failed=${failed}`);

  if (failed > 0) {
    process.exitCode = 1;
  }
}

run().catch(async (err) => {
  console.error('[patch-model] fatal:', err);
  await pool.end().catch(() => undefined);
  process.exit(1);
});
