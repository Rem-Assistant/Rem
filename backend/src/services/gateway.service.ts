import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { GatewayLifecycleDatabaseClient } from './gateway-lifecycle-lock.service.js';
import { pool } from '../db/pool.js';
import { env } from '../config/env.js';
import { resolveGatewayUpdateReadiness, type GatewayUpdateReadiness } from './gateway-update.service.js';
import { tryWithUserGatewayLifecycleLock } from './gateway-lifecycle-lock.service.js';
import { getHostedGatewayProvisioning } from './gateway/hosted-provisioning.js';

const ALG = 'aes-256-gcm';
const IV_LEN = 12;
const TAG_LEN = 16;
const KEY_LEN = 32;

function getKey(): Buffer {
  const raw = env.GATEWAY_ENCRYPTION_KEY;
  if (raw.length >= KEY_LEN * 2 && /^[0-9a-fA-F]+$/i.test(raw)) {
    return Buffer.from(raw.slice(0, KEY_LEN * 2), 'hex');
  }
  return crypto.scryptSync(raw, 'remclaw-gateway', KEY_LEN);
}

function encrypt(plain: string): string {
  const key = getKey();
  const iv = crypto.randomBytes(IV_LEN);
  const cipher = crypto.createCipheriv(ALG, key, iv);
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv.toString('base64'), tag.toString('base64'), enc.toString('base64')].join(':');
}

function decrypt(encrypted: string): string {
  const parts = encrypted.split(':');
  if (parts.length !== 3) throw new Error('Invalid encrypted format');
  const key = getKey();
  const iv = Buffer.from(parts[0], 'base64');
  const tag = Buffer.from(parts[1], 'base64');
  const enc = Buffer.from(parts[2], 'base64');
  const decipher = crypto.createDecipheriv(ALG, key, iv);
  decipher.setAuthTag(tag);
  return decipher.update(enc) + decipher.final('utf8');
}

/**
 * Encrypt / decrypt an arbitrary secret with the same AES-256-GCM key used for gateway
 * tokens (`GATEWAY_ENCRYPTION_KEY`). Exposed so other services can persist third-party
 * credentials at rest without re-deriving the cipher.
 */
export function encryptSecret(plain: string): string {
  return encrypt(plain);
}

export function decryptSecret(encrypted: string): string {
  return decrypt(encrypted);
}

export interface GatewayMetadata {
  url: string | null;
  hostingProvider: string;
  isConnected: boolean;
}

export interface GatewayCredentials {
  gateway_url: string;
  gateway_token: string;
  hosting_provider: string;
}

/** Returns the canonical local-dev target, including the wrapper-persisted token when present. */
export function getLocalGatewayCredentials(): GatewayCredentials | null {
  const gatewayUrl = env.LOCAL_GATEWAY_URL?.trim();
  if (!gatewayUrl) return null;
  const stateDir = env.LOCAL_GATEWAY_STATE_DIR;
  let gatewayToken: string | undefined;
  try {
    gatewayToken = fs.readFileSync(path.join(stateDir, 'gateway.token'), 'utf8').trim() || undefined;
  } catch {}
  if (!gatewayToken) {
    try {
      const config = JSON.parse(fs.readFileSync(path.join(stateDir, 'openclaw.json'), 'utf8'));
      gatewayToken = String(config?.gateway?.auth?.token ?? '').trim() || undefined;
    } catch {}
  }
  gatewayToken ??= env.LOCAL_GATEWAY_TOKEN?.trim();
  return gatewayToken ? { gateway_url: gatewayUrl, gateway_token: gatewayToken, hosting_provider: 'local' } : null;
}

export interface FlyDeploymentMetadata {
  fly_app_name: string | null;
  fly_machine_id: string | null;
  fly_volume_id: string | null;
}

export interface ManagedTalkTargetRecord extends GatewayCredentials, FlyDeploymentMetadata {
  managed_talk_credential_fingerprint: string | null;
  managed_talk_desired_credential_fingerprint: string | null;
  managed_talk_credential_generation: number;
  managed_talk_reconcile_required: boolean;
}

export interface GatewayWakeResult {
  ok: true;
  provider: string;
  action: 'noop' | 'start';
  machineState: string;
  gatewayReady: boolean;
}

export interface MeProfile {
  id: string;
  email: string | null;
  full_name: string | null;
  first_name: string | null;
  last_name: string | null;
  profile_picture_url: string | null;
  locale: string | null;
  gateway: GatewayMetadata;
}

export async function getGatewayForUser(userId: string): Promise<GatewayMetadata | null> {
  const r = await pool.query(
    `SELECT gateway_url, hosting_provider FROM users WHERE id = $1`,
    [userId]
  );
  const row = r.rows[0];
  if (!row) return null;
  return {
    url: row.gateway_url ?? null,
    hostingProvider: row.hosting_provider ?? 'railway',
    isConnected: !!row.gateway_url,
  };
}

export async function getMe(userId: string): Promise<MeProfile | null> {
  const r = await pool.query(
    `SELECT id, email, full_name, first_name, last_name, profile_picture_url, locale, gateway_url, hosting_provider FROM users WHERE id = $1`,
    [userId]
  );
  const row = r.rows[0];
  if (!row) return null;
  return {
    id: row.id,
    email: row.email ?? null,
    full_name: row.full_name ?? null,
    first_name: row.first_name ?? null,
    last_name: row.last_name ?? null,
    profile_picture_url: row.profile_picture_url ?? null,
    locale: row.locale ?? null,
    gateway: {
      url: row.gateway_url ?? null,
      hostingProvider: row.hosting_provider ?? 'railway',
      isConnected: !!row.gateway_url,
    },
  };
}

export async function setGatewayForUser(
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  hostingProvider: string = 'railway'
): Promise<GatewayMetadata> {
  const encrypted = encrypt(gatewayToken);
  await pool.query(
    `UPDATE users SET gateway_url = $1, gateway_token_encrypted = $2, hosting_provider = $3 WHERE id = $4`,
    [gatewayUrl.trim(), encrypted, hostingProvider.trim() || 'railway', userId]
  );
  const meta = await getGatewayForUser(userId);
  if (!meta) throw new Error('User not found');
  return meta;
}

/**
 * Locked lifecycle work must keep every database write on the lock-owning connection. Using the
 * global pool here can deadlock when concurrent repairs occupy all pooled clients and then each
 * waits for another connection to save its result.
 */
export async function setGatewayForUserWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  hostingProvider: string = 'railway',
): Promise<GatewayMetadata> {
  const encrypted = encrypt(gatewayToken);
  const result = await client.query(
    `UPDATE users
        SET gateway_url = $1, gateway_token_encrypted = $2, hosting_provider = $3
      WHERE id = $4
      RETURNING gateway_url, hosting_provider`,
    [gatewayUrl.trim(), encrypted, hostingProvider.trim() || 'railway', userId],
  );
  const row = result.rows[0];
  if (!row) throw new Error('User not found');
  return {
    url: row.gateway_url ?? null,
    hostingProvider: row.hosting_provider ?? 'railway',
    isConnected: !!row.gateway_url,
  };
}

/**
 * Saves a gateway pointer supplied by an authenticated client. A client-entered URL/token is not
 * proof that this backend owns a Fly app, machine, or volume, even when it labels the provider
 * "fly". Demote that unverified pointer to manual and atomically release stale managed metadata;
 * deploy/repoint flows use the ownership-verified lifecycle above and restore exact Fly metadata.
 */
export async function setUserEnteredGatewayForUserWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  hostingProvider: string = 'manual',
): Promise<GatewayMetadata> {
  const encrypted = encrypt(gatewayToken);
  const requestedProvider = hostingProvider.trim().toLowerCase();
  const storedProvider = requestedProvider === 'local' ? 'local' : 'manual';
  const result = await client.query(
    `UPDATE users
        SET gateway_url = $1,
            gateway_token_encrypted = $2,
            hosting_provider = $3,
            fly_app_name = NULL,
            fly_machine_id = NULL,
            fly_volume_id = NULL,
            managed_talk_credential_fingerprint = NULL,
            managed_talk_desired_credential_fingerprint = NULL,
            managed_talk_credential_generation = 0,
            managed_talk_reconcile_required = FALSE
      WHERE id = $4
      RETURNING gateway_url, hosting_provider`,
    [gatewayUrl.trim(), encrypted, storedProvider, userId],
  );
  const row = result.rows[0];
  if (!row) throw new Error('User not found');
  return {
    url: row.gateway_url ?? null,
    hostingProvider: row.hosting_provider ?? 'manual',
    isConnected: !!row.gateway_url,
  };
}

export async function getGatewayCredentials(userId: string): Promise<GatewayCredentials | null> {
  return getGatewayCredentialsWithClient(pool, userId);
}

/** Reads the authoritative gateway target through a caller-owned lifecycle-lock session. */
export async function getGatewayCredentialsWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
): Promise<GatewayCredentials | null> {
  const r = await client.query(
    `SELECT gateway_url, gateway_token_encrypted, hosting_provider FROM users WHERE id = $1`,
    [userId]
  );
  const row = r.rows[0];
  if (!row?.gateway_url || !row?.gateway_token_encrypted) return null;
  return {
    gateway_url: row.gateway_url,
    gateway_token: decrypt(row.gateway_token_encrypted),
    hosting_provider: row.hosting_provider ?? 'railway',
  };
}

export async function getFlyDeploymentMetadata(userId: string): Promise<FlyDeploymentMetadata | null> {
  const r = await pool.query(
    `SELECT fly_app_name, fly_machine_id, fly_volume_id FROM users WHERE id = $1`,
    [userId]
  );
  const row = r.rows[0];
  if (!row) return null;
  return {
    fly_app_name: row.fly_app_name ?? null,
    fly_machine_id: row.fly_machine_id ?? null,
    fly_volume_id: row.fly_volume_id ?? null,
  };
}

export async function getManagedTalkTargetWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
): Promise<ManagedTalkTargetRecord | null> {
  const result = await client.query(
    `SELECT gateway_url,
            gateway_token_encrypted,
            hosting_provider,
            fly_app_name,
            fly_machine_id,
            fly_volume_id,
            managed_talk_credential_fingerprint,
            managed_talk_desired_credential_fingerprint,
            managed_talk_credential_generation,
            managed_talk_reconcile_required
       FROM users
      WHERE id = $1`,
    [userId],
  );
  const row = result.rows[0];
  if (!row?.gateway_url || !row?.gateway_token_encrypted) return null;
  return {
    gateway_url: row.gateway_url,
    gateway_token: decrypt(row.gateway_token_encrypted),
    hosting_provider: row.hosting_provider ?? 'railway',
    fly_app_name: row.fly_app_name ?? null,
    fly_machine_id: row.fly_machine_id ?? null,
    fly_volume_id: row.fly_volume_id ?? null,
    managed_talk_credential_fingerprint: row.managed_talk_credential_fingerprint ?? null,
    managed_talk_desired_credential_fingerprint: row.managed_talk_desired_credential_fingerprint ?? null,
    managed_talk_credential_generation: Number(row.managed_talk_credential_generation ?? 0),
    managed_talk_reconcile_required: row.managed_talk_reconcile_required === true,
  };
}

export async function setManagedTalkCredentialFingerprintWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
  fingerprint: string | null,
): Promise<void> {
  const result = await client.query(
    `UPDATE users
        SET managed_talk_credential_fingerprint = $1
      WHERE id = $2
      RETURNING id`,
    [fingerprint, userId],
  );
  if (result.rows.length !== 1) {
    throw new Error('user disappeared while updating managed Talk credential ownership');
  }
}

export async function promoteManagedTalkDesiredCredentialWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
  fingerprint: string,
  generation: number,
): Promise<{ fingerprint: string | null; generation: number }> {
  const result = await client.query(
    `UPDATE users
        SET managed_talk_desired_credential_fingerprint = $1,
            managed_talk_credential_generation = $2,
            managed_talk_reconcile_required = TRUE
      WHERE id = $3
        AND managed_talk_credential_generation < $2
      RETURNING managed_talk_desired_credential_fingerprint, managed_talk_credential_generation`,
    [fingerprint, generation, userId],
  );
  if (result.rows.length === 1) {
    return { fingerprint: result.rows[0].managed_talk_desired_credential_fingerprint, generation };
  }
  const current = await client.query(
    `SELECT managed_talk_desired_credential_fingerprint, managed_talk_credential_generation
       FROM users WHERE id = $1`,
    [userId],
  );
  if (current.rows.length !== 1) throw new Error('user disappeared while reading managed Talk desired state');
  return {
    fingerprint: current.rows[0].managed_talk_desired_credential_fingerprint ?? null,
    generation: Number(current.rows[0].managed_talk_credential_generation ?? 0),
  };
}

export async function markManagedTalkReconciledWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
): Promise<void> {
  await client.query(
    'UPDATE users SET managed_talk_reconcile_required = FALSE WHERE id = $1',
    [userId],
  );
}

export async function getGatewayUpdateReadinessForUser(userId: string): Promise<GatewayUpdateReadiness> {
  const credentials = await getGatewayCredentials(userId);
  const flyMetadata = credentials?.hosting_provider === 'fly'
    ? await getFlyDeploymentMetadata(userId)
    : null;

  return resolveGatewayUpdateReadiness(credentials, flyMetadata);
}

async function waitForGatewayHealth(gatewayUrl: string, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${gatewayUrl}/setup/healthz`, {
        signal: AbortSignal.timeout(2_000),
      });
      if (res.ok) return true;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  return false;
}

interface GatewayWakeRow {
  gateway_url: string | null;
  hosting_provider: string | null;
  fly_app_name: string | null;
  fly_machine_id: string | null;
}

const missingGatewayWakeRow: GatewayWakeRow = {
  gateway_url: null,
  hosting_provider: null,
  fly_app_name: null,
  fly_machine_id: null,
};

function requiresFlyLifecycleFence(row: GatewayWakeRow): boolean {
  return (row.hosting_provider ?? 'railway') === 'fly'
    && Boolean(row.gateway_url && row.fly_app_name && row.fly_machine_id);
}

interface PreparedFlyWake {
  provider: string;
  gatewayUrl: string;
  appName: string;
  machineId: string;
  initialState: string;
}

// The per-user advisory lock must span the Fly start mutation so account deletion and migration
// cannot race it. Share one short deadline across both the state read and start request, keeping
// the shared database pool unavailable for at most this window rather than flyFetch's 60 seconds.
export const GATEWAY_WAKE_FLY_LOCK_TIMEOUT_MS = 5_000;

async function prepareGatewayWakeFromRow(
  row: GatewayWakeRow,
): Promise<GatewayWakeResult | PreparedFlyWake> {
  if (!row.gateway_url) {
    return {
      ok: true,
      provider: 'none',
      action: 'noop',
      machineState: 'missing_gateway',
      gatewayReady: false,
    };
  }

  const provider = row.hosting_provider ?? 'railway';
  if (provider !== 'fly' || !row.fly_app_name || !row.fly_machine_id) {
    return {
      ok: true,
      provider,
      action: 'noop',
      machineState: 'unsupported',
      gatewayReady: true,
    };
  }

  const flyService = getHostedGatewayProvisioning();
  const wakeSignal = AbortSignal.timeout(GATEWAY_WAKE_FLY_LOCK_TIMEOUT_MS);
  const machine = await flyService.getMachine(row.fly_app_name, row.fly_machine_id, {
    signal: wakeSignal,
  });
  const initialState = machine.state;

  if (machine.state !== 'started') {
    try {
      await flyService.startMachine(row.fly_app_name, row.fly_machine_id, {
        signal: wakeSignal,
      });
    } catch (err: any) {
      // Fly may race us here if proxy autostart already triggered.
      const message = String(err?.message ?? err);
      if (!message.includes('409') && !message.includes('already') && !message.includes('started')) {
        throw err;
      }
    }
  }

  return {
    provider,
    gatewayUrl: row.gateway_url,
    appName: row.fly_app_name,
    machineId: row.fly_machine_id,
    initialState,
  };
}

async function finishPreparedFlyWake(prepared: PreparedFlyWake): Promise<GatewayWakeResult> {
  const flyService = getHostedGatewayProvisioning();
  if (prepared.initialState !== 'started') {
    try {
      await flyService.waitForMachineReady(prepared.appName, prepared.machineId, 25);
    } catch {}
  }

  let machine;
  try {
    machine = await flyService.getMachine(prepared.appName, prepared.machineId);
  } catch (error) {
    if (String(error).includes('Fly API 404')) {
      return {
        ok: true,
        provider: 'none',
        action: 'noop',
        machineState: 'missing_gateway',
        gatewayReady: false,
      };
    }
    throw error;
  }
  const gatewayReady = await waitForGatewayHealth(prepared.gatewayUrl, 10_000);

  return {
    ok: true,
    provider: prepared.provider,
    action: prepared.initialState === 'started' ? 'noop' : 'start',
    machineState: machine.state,
    gatewayReady,
  };
}

async function finishGatewayWake(
  wake: GatewayWakeResult | PreparedFlyWake,
): Promise<GatewayWakeResult> {
  return 'ok' in wake ? wake : finishPreparedFlyWake(wake);
}

export async function wakeGatewayForUser(userId: string): Promise<GatewayWakeResult> {
  const initial = await pool.query<GatewayWakeRow>(
    `SELECT gateway_url, hosting_provider, fly_app_name, fly_machine_id
       FROM users
      WHERE id = $1`,
    [userId],
  );
  const initialRow = initial.rows[0] ?? missingGatewayWakeRow;

  // Every Fly mutation shares the user lifecycle fence. A dedicated wake can otherwise race
  // account deletion just like a pooled wake: deletion removes the user, its Fly delete fails,
  // and a stale pre-delete wake restarts the now-orphaned gateway.
  if (!requiresFlyLifecycleFence(initialRow)) {
    return finishGatewayWake(await prepareGatewayWakeFromRow(initialRow));
  }

  const attempt = await tryWithUserGatewayLifecycleLock(userId, async (client) => {
    const current = await client.query<GatewayWakeRow>(
      `SELECT gateway_url, hosting_provider, fly_app_name, fly_machine_id
         FROM users
        WHERE id = $1`,
      [userId],
    );
    // The locked read is authoritative. Account deletion can remove the user after the initial
    // read but before this callback acquires the lifecycle lock; never revive that deleted
    // gateway from stale metadata captured before the lock.
    // Only the authoritative read and the Fly start mutation belong inside the advisory-lock
    // callback. Readiness and HTTP health polling run after the callback releases its pg client.
    return prepareGatewayWakeFromRow(current.rows[0] ?? missingGatewayWakeRow);
  });

  if (!attempt.acquired) {
    return {
      ok: true,
      provider: 'fly',
      action: 'noop',
      machineState: 'migration_fenced',
      gatewayReady: false,
    };
  }
  return finishGatewayWake(attempt.value);
}

/**
 * Reads the SETUP_PASSWORD from the Fly machine's env vars.
 * Returns undefined for non-Fly gateways or if the machine can't be reached.
 */
export async function getSetupPassword(userId: string): Promise<string | undefined> {
  return getSetupPasswordWithClient(pool, userId);
}

/** Reads setup metadata through a caller-owned lifecycle session to preserve lock ordering. */
export async function getSetupPasswordWithClient(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
): Promise<string | undefined> {
  const r = await client.query(
    `SELECT fly_app_name, fly_machine_id FROM users WHERE id = $1`,
    [userId]
  );
  const row = r.rows[0];
  if (!row?.fly_app_name || !row?.fly_machine_id) return undefined;
  try {
    const flyService = getHostedGatewayProvisioning();
    const machine = await flyService.getMachine(row.fly_app_name, row.fly_machine_id);
    return machine.config?.env?.SETUP_PASSWORD;
  } catch {
    return undefined;
  }
}

export async function getUserIdByGatewayToken(gatewayToken: string): Promise<string | null> {
  if (!gatewayToken?.trim()) return null;
  const r = await pool.query(
    `SELECT id, gateway_token_encrypted FROM users
     WHERE gateway_token_encrypted IS NOT NULL AND gateway_url IS NOT NULL`
  );
  for (const row of r.rows) {
    try {
      const decrypted = decrypt(row.gateway_token_encrypted);
      if (decrypted === gatewayToken.trim()) return row.id;
    } catch {
      continue;
    }
  }
  return null;
}

export { encrypt, decrypt };
