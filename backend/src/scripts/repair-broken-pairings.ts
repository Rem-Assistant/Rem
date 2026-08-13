import { pool } from '../db/pool.js';
import { decrypt, getSetupPassword } from '../services/gateway.service.js';
import WebSocket from 'ws';

/**
 * Repairs broken gateway pairing records that contain `operator.admin` in
 * their scopes. The `operator.admin` scope triggers a scope-upgrade repair
 * loop in gateways v2026.2.25+ which silently breaks device pairing.
 *
 * The fix is to remove the broken paired-device record so that the next
 * device connection triggers a fresh pairing request with correct scopes.
 *
 * Usage:
 *   npm run repair:pairings -- --dry-run
 *   npm run repair:pairings
 *   npm run repair:pairings -- --limit=5
 */

const PROTOCOL_VERSION = 3;

function parseArgs(argv: string[]) {
  const dryRun = argv.includes('--dry-run');
  const limitArg = argv.find((arg) => arg.startsWith('--limit='));

  const limit = limitArg ? Number.parseInt(limitArg.split('=')[1], 10) : null;

  if (limitArg && (!Number.isFinite(limit) || (limit as number) <= 0)) {
    throw new Error('Invalid --limit value. Example: --limit=5');
  }

  return { dryRun, limit };
}

interface GatewayRow {
  id: string;
  gateway_url: string;
  gateway_token_encrypted: string;
}

interface PairedDevice {
  deviceId: string;
  displayName?: string;
  scopes?: string[];
}

/**
 * Connects to a gateway, lists paired devices, and returns any that have
 * `operator.admin` in their scopes.
 */
async function findBrokenPairings(
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
): Promise<PairedDevice[]> {
  const wsUrl = gatewayUrl.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:');
  const originUrl = gatewayUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');

  return new Promise<PairedDevice[]>((resolve, reject) => {
    const ws = new WebSocket(wsUrl, setupPassword ? { headers: { Origin: originUrl } } : undefined);
    let msgId = 0;
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) { settled = true; ws.close(); reject(new Error('WebSocket timeout')); }
    }, 15_000);

    const done = (result: PairedDevice[]) => {
      if (!settled) { settled = true; clearTimeout(timer); ws.close(); resolve(result); }
    };
    const fail = (err: Error) => {
      if (!settled) { settled = true; clearTimeout(timer); ws.close(); reject(err); }
    };

    const send = (method: string, params: Record<string, unknown> = {}) => {
      const id = String(++msgId);
      ws.send(JSON.stringify({ type: 'req', id, method, params }));
      return id;
    };

    let connected = false;

    ws.onmessage = (event) => {
      try {
        const frame = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());

        if (frame.type === 'event' && frame.event === 'connect.challenge') {
          const auth: Record<string, string> = { token: gatewayToken };
          let clientId = 'gateway-client';
          if (setupPassword) {
            auth.password = setupPassword;
            clientId = 'openclaw-control-ui';
          }
          send('connect', {
            minProtocol: PROTOCOL_VERSION,
            maxProtocol: PROTOCOL_VERSION,
            client: { id: clientId, version: '1.0.0', platform: 'node', mode: 'backend' },
            auth,
            role: 'operator',
            scopes: ['operator.read', 'operator.write', 'operator.pairing'],
          });
          return;
        }

        if (frame.type !== 'res') return;

        if (!connected) {
          if (!frame.ok) {
            fail(new Error(`Connect rejected: ${frame.error?.message ?? 'unknown'}`));
            return;
          }
          connected = true;
          send('device.pair.list', {});
          return;
        }

        // Handle device.pair.list response
        const resultData = frame.result ?? frame.payload;
        if (resultData?.paired !== undefined) {
          const paired: PairedDevice[] = resultData.paired ?? [];
          const broken = paired.filter(
            (d) => Array.isArray(d.scopes) && d.scopes.includes('operator.admin'),
          );
          done(broken);
          return;
        }

        // Some gateways return pending only — no paired field means no paired devices
        if (resultData?.pending !== undefined && resultData?.paired === undefined) {
          done([]);
          return;
        }
      } catch {
        // ignore parse errors
      }
    };

    ws.onerror = (err) => fail(new Error(`WebSocket error: ${String(err)}`));
    ws.onclose = () => {
      if (!settled) { settled = true; clearTimeout(timer); resolve([]); }
    };
  });
}

/**
 * Removes a paired device record by deviceId.
 */
async function removePairedDevice(
  gatewayUrl: string,
  gatewayToken: string,
  deviceId: string,
  setupPassword?: string,
): Promise<void> {
  const wsUrl = gatewayUrl.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:');
  const originUrl = gatewayUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');

  return new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(wsUrl, setupPassword ? { headers: { Origin: originUrl } } : undefined);
    let msgId = 0;
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) { settled = true; ws.close(); reject(new Error('WebSocket timeout')); }
    }, 15_000);

    const done = () => {
      if (!settled) { settled = true; clearTimeout(timer); ws.close(); resolve(); }
    };
    const fail = (err: Error) => {
      if (!settled) { settled = true; clearTimeout(timer); ws.close(); reject(err); }
    };

    const send = (method: string, params: Record<string, unknown> = {}) => {
      const id = String(++msgId);
      ws.send(JSON.stringify({ type: 'req', id, method, params }));
      return id;
    };

    let connected = false;

    ws.onmessage = (event) => {
      try {
        const frame = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());

        if (frame.type === 'event' && frame.event === 'connect.challenge') {
          const auth: Record<string, string> = { token: gatewayToken };
          let clientId = 'gateway-client';
          if (setupPassword) {
            auth.password = setupPassword;
            clientId = 'openclaw-control-ui';
          }
          send('connect', {
            minProtocol: PROTOCOL_VERSION,
            maxProtocol: PROTOCOL_VERSION,
            client: { id: clientId, version: '1.0.0', platform: 'node', mode: 'backend' },
            auth,
            role: 'operator',
            scopes: ['operator.read', 'operator.write', 'operator.pairing'],
          });
          return;
        }

        if (frame.type !== 'res') return;

        if (!connected) {
          if (!frame.ok) {
            fail(new Error(`Connect rejected: ${frame.error?.message ?? 'unknown'}`));
            return;
          }
          connected = true;
          send('device.pair.remove', { deviceId });
          return;
        }

        // Handle device.pair.remove response
        if (!frame.ok) {
          fail(new Error(`device.pair.remove failed: ${frame.error?.message ?? 'unknown'}`));
          return;
        }
        done();
      } catch {
        // ignore parse errors
      }
    };

    ws.onerror = (err) => fail(new Error(`WebSocket error: ${String(err)}`));
    ws.onclose = () => {
      if (!settled) { settled = true; clearTimeout(timer); resolve(); }
    };
  });
}

async function run() {
  const { dryRun, limit } = parseArgs(process.argv.slice(2));
  const started = Date.now();

  console.log(`[repair-pairings] starting ${dryRun ? '(dry-run)' : ''}`);

  const { rows } = await pool.query<GatewayRow>(
    `SELECT id, gateway_url, gateway_token_encrypted
     FROM users
     WHERE gateway_url IS NOT NULL
       AND gateway_token_encrypted IS NOT NULL
     ORDER BY id ASC`
  );

  const targets = limit ? rows.slice(0, limit) : rows;
  console.log(`[repair-pairings] users with gateway credentials: ${rows.length}`);
  console.log(`[repair-pairings] users selected for this run: ${targets.length}`);

  let scanned = 0;
  let affected = 0;
  let repaired = 0;
  let failed = 0;

  for (const row of targets) {
    const userId = row.id;
    const gatewayUrl = row.gateway_url;
    try {
      const gatewayToken = decrypt(row.gateway_token_encrypted);
      const setupPassword = await getSetupPassword(userId).catch(() => undefined);

      const brokenDevices = await findBrokenPairings(gatewayUrl, gatewayToken, setupPassword);
      scanned += 1;

      if (brokenDevices.length === 0) continue;

      affected += 1;
      for (const device of brokenDevices) {
        console.log(
          `[repair-pairings] BROKEN user=${userId} gateway=${gatewayUrl} ` +
          `device=${device.deviceId} name=${device.displayName ?? '?'} ` +
          `scopes=${JSON.stringify(device.scopes)}`,
        );

        if (dryRun) continue;

        try {
          await removePairedDevice(gatewayUrl, gatewayToken, device.deviceId, setupPassword);
          repaired += 1;
          console.log(
            `[repair-pairings] REMOVED user=${userId} device=${device.deviceId}`,
          );
        } catch (err: any) {
          failed += 1;
          console.warn(
            `[repair-pairings] remove failed user=${userId} device=${device.deviceId} error=${err?.message ?? String(err)}`,
          );
        }
      }
    } catch (err: any) {
      failed += 1;
      console.warn(
        `[repair-pairings] scan failed user=${userId} gateway=${gatewayUrl} error=${err?.message ?? String(err)}`,
      );
    }
  }

  await pool.end();

  const elapsedMs = Date.now() - started;
  console.log(
    `[repair-pairings] done in ${elapsedMs}ms ` +
    `scanned=${scanned} affected=${affected} repaired=${repaired} failed=${failed}`,
  );

  if (failed > 0) {
    process.exitCode = 1;
  }
}

run().catch(async (err) => {
  console.error('[repair-pairings] fatal:', err);
  await pool.end().catch(() => undefined);
  process.exit(1);
});
