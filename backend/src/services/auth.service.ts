import jwt, { SignOptions } from 'jsonwebtoken';
import { OAuth2Client } from 'google-auth-library';
import crypto from 'node:crypto';
import { pool } from '../db/pool.js';
import {
  canRemoveInterruptedMigrationCheckpoint,
  flyAppsForAccountDeletion,
  isFlyAppAlreadyDeletedError,
} from './auth-deletion-policy.js';
import { withUserGatewayLifecycleLock } from './gateway-lifecycle-lock.service.js';
import { getHostedGatewayProvisioning } from './gateway/hosted-provisioning.js';
import { env } from '../config/env.js';

// ── Types ──────────────────────────────────────────────

export interface User {
  id: string;
  email: string;
  full_name: string | null;
  first_name: string | null;
  last_name: string | null;
  profile_picture_url: string | null;
  locale: string | null;
  created_at: Date;
}

export interface AuthIdentity {
  id: string;
  user_id: string;
  provider: 'apple' | 'google';
  provider_sub: string;
  email: string | null;
}

// ── Token helpers ──────────────────────────────────────

export function generateToken(userId: string): string {
  return jwt.sign(
    { sub: userId, type: 'rem_access' },
    env.JWT_SECRET,
    { expiresIn: '7d' } as SignOptions,
  );
}

export function verifyToken(token: string): { sub: string } {
  const decoded = jwt.verify(token, env.JWT_SECRET) as { sub: string; type?: string };
  if (!decoded.sub) throw new Error('Invalid token: missing sub');
  return { sub: decoded.sub };
}

export function verifyTokenAllowExpired(token: string): { sub: string } {
  const decoded = jwt.verify(token, env.JWT_SECRET, { ignoreExpiration: true }) as { sub: string; type?: string };
  if (!decoded.sub) throw new Error('Invalid token: missing sub');
  return { sub: decoded.sub };
}

// ── Provider verification ──────────────────────────────

const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_ALG = 'RS256';
type AppleJwk = { kty: string; kid: string; use?: string; alg?: string; n?: string; e?: string };
type AppleJwtHeader = { alg?: string; kid?: string };
type AppleJwtPayload = { iss?: string; aud?: string | string[]; sub?: string; email?: string; exp?: number };
let appleJwksCache: { keys: AppleJwk[]; expiresAt: number } | null = null;

function base64UrlDecodeToUtf8(input: string): string {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padding = normalized.length % 4;
  const padded = padding === 0 ? normalized : normalized + '='.repeat(4 - padding);
  return Buffer.from(padded, 'base64').toString('utf8');
}

function base64UrlDecodeToBuffer(input: string): Buffer {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padding = normalized.length % 4;
  const padded = padding === 0 ? normalized : normalized + '='.repeat(4 - padding);
  return Buffer.from(padded, 'base64');
}

async function getAppleJwks(): Promise<AppleJwk[]> {
  if (appleJwksCache && Date.now() < appleJwksCache.expiresAt) return appleJwksCache.keys;
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error('Failed to fetch Apple public keys');
  const cacheControl = res.headers.get('cache-control') ?? '';
  const maxAgeMatch = cacheControl.match(/max-age=(\d+)/i);
  const maxAgeSec = Number.parseInt(maxAgeMatch?.[1] ?? '300', 10);
  const body = (await res.json()) as { keys?: AppleJwk[] };
  if (!Array.isArray(body.keys) || body.keys.length === 0) {
    throw new Error('Apple JWKS response missing keys');
  }
  appleJwksCache = {
    keys: body.keys,
    expiresAt: Date.now() + Math.max(60, maxAgeSec) * 1000,
  };
  return body.keys;
}

function verifyAppleJwtSignature(idToken: string, jwk: AppleJwk): void {
  const parts = idToken.split('.');
  if (parts.length !== 3) throw new Error('Invalid Apple token');
  const verifier = crypto.createVerify('RSA-SHA256');
  verifier.update(`${parts[0]}.${parts[1]}`);
  verifier.end();
  const signature = base64UrlDecodeToBuffer(parts[2]);
  const publicKey = crypto.createPublicKey({ key: jwk as crypto.JsonWebKey, format: 'jwk' });
  const ok = verifier.verify(publicKey, signature);
  if (!ok) throw new Error('Invalid Apple token signature');
}

function isAppleAudienceValid(aud: string | string[] | undefined, expectedAudience: string): boolean {
  if (!aud) return false;
  // Accept both the primary iOS bundle ID and the Mac bundle ID.
  // APPLE_CLIENT_ID_MAC can be set separately; defaults to "samatwork.RemClawMac".
  const validAudiences = [expectedAudience];
  const macClientId = process.env.APPLE_CLIENT_ID_MAC ?? 'samatwork.RemClawMac';
  if (macClientId) validAudiences.push(macClientId);
  if (Array.isArray(aud)) return aud.some((a) => validAudiences.includes(a));
  return validAudiences.includes(aud);
}

async function verifyAppleToken(idToken: string): Promise<{ sub: string; email?: string }> {
  if (!env.APPLE_CLIENT_ID) {
    throw new Error('APPLE_CLIENT_ID is required for Apple sign-in');
  }
  const parts = idToken.split('.');
  if (parts.length !== 3) throw new Error('Invalid Apple token');
  const header = JSON.parse(base64UrlDecodeToUtf8(parts[0])) as AppleJwtHeader;
  const payload = JSON.parse(base64UrlDecodeToUtf8(parts[1])) as AppleJwtPayload;
  if (!header.kid || header.alg !== APPLE_ALG) throw new Error('Invalid Apple token header');

  const jwks = await getAppleJwks();
  const jwk = jwks.find((k) => k.kid === header.kid && k.kty === 'RSA');
  if (!jwk) throw new Error('Apple signing key not found');
  verifyAppleJwtSignature(idToken, jwk);

  if (payload.iss !== APPLE_ISSUER) throw new Error('Invalid Apple token issuer');
  if (!isAppleAudienceValid(payload.aud, env.APPLE_CLIENT_ID)) throw new Error('Invalid Apple token audience');
  if (!payload.exp || payload.exp <= Math.floor(Date.now() / 1000)) throw new Error('Apple token expired');
  if (!payload.sub) throw new Error('Missing sub in Apple token');

  return { sub: payload.sub, email: payload.email };
}

async function verifyGoogleToken(idToken: string): Promise<{
  sub: string;
  email?: string;
  name?: string;
  given_name?: string;
  family_name?: string;
  picture?: string;
  locale?: string;
}> {
  const clientId = env.GOOGLE_CLIENT_ID;
  const client = new OAuth2Client(clientId || undefined);
  const ticket = await client.verifyIdToken({
    idToken,
    audience: clientId || undefined,
  });
  const payload = ticket.getPayload();
  if (!payload?.sub) throw new Error('Invalid Google token');
  return {
    sub: payload.sub,
    email: payload.email,
    name: payload.name,
    given_name: payload.given_name,
    family_name: payload.family_name,
    picture: payload.picture,
    locale: payload.locale,
  };
}

// ── Find or create user ────────────────────────────────

async function findOrCreateUser(
  provider: 'apple' | 'google',
  providerSub: string,
  profile: {
    email?: string;
    name?: string;
    given_name?: string;
    family_name?: string;
    picture?: string;
    locale?: string;
  },
): Promise<{ user: User; isNewUser: boolean }> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Check for existing auth identity
    const existing = await client.query(
      `SELECT * FROM auth_identities WHERE provider = $1 AND provider_sub = $2`,
      [provider, providerSub],
    );

    if (existing.rows.length > 0) {
      // Existing user — update profile fields from provider
      const userId = existing.rows[0].user_id;
      const fullName =
        profile.name || (profile.given_name && profile.family_name ? `${profile.given_name} ${profile.family_name}` : null);

      await client.query(
        `UPDATE users SET
           first_name = COALESCE($1, first_name),
           last_name = COALESCE($2, last_name),
           full_name = COALESCE($3, full_name),
           profile_picture_url = COALESCE($4, profile_picture_url),
           locale = COALESCE($5, locale)
         WHERE id = $6`,
        [profile.given_name ?? null, profile.family_name ?? null, fullName, profile.picture ?? null, profile.locale ?? null, userId],
      );

      const userResult = await client.query('SELECT * FROM users WHERE id = $1', [userId]);
      await client.query('COMMIT');
      return { user: userResult.rows[0], isNewUser: false };
    }

    // New user
    const email = profile.email;
    if (!email) throw new Error('Email is required for new user registration');

    const fullName =
      profile.name || (profile.given_name && profile.family_name ? `${profile.given_name} ${profile.family_name}` : null);

    // Check if user with this email already exists (link provider)
    const existingUser = await client.query('SELECT * FROM users WHERE email = $1', [email]);
    let userId: string;
    let isNewUser: boolean;

    if (existingUser.rows.length > 0) {
      userId = existingUser.rows[0].id;
      isNewUser = false;
    } else {
      const newUser = await client.query(
        `INSERT INTO users (email, full_name, first_name, last_name, profile_picture_url, locale)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
        [email, fullName, profile.given_name ?? null, profile.family_name ?? null, profile.picture ?? null, profile.locale ?? null],
      );
      userId = newUser.rows[0].id;
      isNewUser = true;
    }

    // Link auth identity
    await client.query(
      `INSERT INTO auth_identities (user_id, provider, provider_sub, email) VALUES ($1, $2, $3, $4)`,
      [userId, provider, providerSub, email],
    );

    const userResult = await client.query('SELECT * FROM users WHERE id = $1', [userId]);
    await client.query('COMMIT');
    return { user: userResult.rows[0], isNewUser };
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// ── Apple token revocation ────────────────────────────

/**
 * Generate a client_secret JWT for Apple's REST API.
 * Required for revoking Sign in with Apple tokens.
 * See: https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens
 */
function generateAppleClientSecret(): string | null {
  const teamId = env.APPLE_TEAM_ID;
  const keyId = env.APPLE_KEY_ID;
  const clientId = env.APPLE_CLIENT_ID;
  const rawKey = env.APPLE_PRIVATE_KEY;

  if (!teamId || !keyId || !clientId || !rawKey) {
    return null;
  }

  // Support both raw PEM and base64-encoded PEM
  let privateKey = rawKey;
  if (!privateKey.includes('-----BEGIN')) {
    privateKey = Buffer.from(privateKey, 'base64').toString('utf8');
  }

  const now = Math.floor(Date.now() / 1000);
  return jwt.sign(
    {
      iss: teamId,
      iat: now,
      exp: now + 300, // 5 minutes
      aud: 'https://appleid.apple.com',
      sub: clientId,
    },
    privateKey,
    { algorithm: 'ES256', header: { alg: 'ES256', kid: keyId } } as SignOptions,
  );
}

/**
 * Revoke an Apple Sign-In authorization code so Apple considers
 * the user's account fully disconnected. Best-effort — failures
 * are logged but do not block account deletion.
 */
async function revokeAppleToken(authCode: string): Promise<void> {
  const clientId = env.APPLE_CLIENT_ID;
  const clientSecret = generateAppleClientSecret();

  if (!clientId || !clientSecret) {
    console.warn('[AUTH] Apple revocation skipped — missing APPLE_TEAM_ID, APPLE_KEY_ID, or APPLE_PRIVATE_KEY');
    return;
  }

  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    token: authCode,
    token_type_hint: 'authorization_code',
  });

  const res = await fetch('https://appleid.apple.com/auth/revoke', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
    signal: AbortSignal.timeout(10_000),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    console.warn(`[AUTH] Apple token revocation failed: ${res.status} ${text}`);
  } else {
    console.log('[AUTH] Apple token revoked successfully');
  }
}

// ── Account deletion ──────────────────────────────────

export async function deleteUser(userId: string): Promise<void> {
  // Staging may intentionally share the production database while Fly mutations are disabled.
  // Refuse before opening the deletion transaction: committing the user delete and only then
  // discovering that the current gateway cannot be destroyed would orphan a live app containing
  // the deleted user's data with no durable cleanup record.
  if (env.GATEWAY_MUTATIONS_DISABLED) {
    throw new Error(
      'Account deletion is unavailable while gateway mutations are disabled; retry on the production service',
    );
  }
  const appleAuthCode = await withUserGatewayLifecycleLock(userId, async (client) => {
    try {
      await client.query('BEGIN');

      // Fetch Fly.io app info before deleting the DB row
      const userRow = await client.query(
        'SELECT fly_app_name, fly_machine_id, hosting_provider FROM users WHERE id = $1',
        [userId],
      );

      // Retain both a migration rollback app and an unconsumed claim whose Machine may already have
      // been stamped with this user and received a managed credential. Keep the row durable through
      // post-commit Fly deletion. Deleting the user sets `claimed_by = NULL`; only a confirmed (or
      // already-complete) Fly deletion may remove this cleanup record.
      const retainedGatewayRows = await client.query(
        `SELECT id, fly_app_name, status
           FROM gateway_pool
          WHERE claimed_by = $1
            AND status IN ('claimed', 'migrated')`,
        [userId],
      );
      const interruptedMigrations = await client.query(
        `SELECT source_app_name, target_app_name, target_ownership_state
           FROM gateway_pool_migrations
          WHERE user_id = $1`,
        [userId],
      );

      // Every direct Fly app must have durable cleanup ownership before the user row disappears.
      // This also adopts canonical apps created before the ownership table existed. A provisioning
      // row is already present before Fly create, so deletion can safely retire an in-flight deploy.
      // `fly_app_name` is Fly-specific metadata, including legacy rows that predate a reliable
      // hosting_provider value, so its presence is sufficient to require durable cleanup.
      const canonicalFlyAppName = userRow.rows[0]?.fly_app_name?.trim() || null;
      if (canonicalFlyAppName) {
        const adopted = await client.query(
          `INSERT INTO gateway_fly_app_ownership (fly_app_name, user_id, state)
           VALUES ($1, $2, 'delete_pending')
           ON CONFLICT (fly_app_name) DO UPDATE
             SET user_id = EXCLUDED.user_id, state = 'delete_pending', updated_at = NOW()
             WHERE gateway_fly_app_ownership.user_id = EXCLUDED.user_id
                OR gateway_fly_app_ownership.user_id IS NULL
           RETURNING fly_app_name`,
          [canonicalFlyAppName, userId],
        );
        if (adopted.rows.length !== 1) {
          throw new Error(`Fly app ${canonicalFlyAppName} has conflicting durable ownership`);
        }
      }
      await client.query(
        `UPDATE gateway_fly_app_ownership
            SET state = 'delete_pending', updated_at = NOW()
          WHERE user_id = $1`,
        [userId],
      );
      const ownedFlyApps = await client.query<{ fly_app_name: string }>(
        `SELECT fly_app_name FROM gateway_fly_app_ownership
          WHERE user_id = $1 AND state = 'delete_pending'`,
        [userId],
      );

      // Fetch Apple auth code for token revocation before deleting
      const appleIdentity = await client.query(
        `SELECT apple_auth_code FROM auth_identities
         WHERE user_id = $1 AND provider = 'apple' AND apple_auth_code IS NOT NULL`,
        [userId],
      );

      // Delete usage records (VARCHAR user_id, no CASCADE)
      await client.query('DELETE FROM usage_counters WHERE user_id = $1', [userId]);
      await client.query('DELETE FROM usage_events WHERE user_id = $1', [userId]);

      // Delete the user row (auth_identities, tasks, IAP records cascade)
      await client.query('DELETE FROM users WHERE id = $1', [userId]);

      await client.query('COMMIT');

      // Destroy Fly.io gateway — awaited so deletion isn't reported as complete
      // while the gateway is still running and could write more usage data
      const flyAppNames = flyAppsForAccountDeletion(
        userRow.rows[0]?.fly_app_name,
        [
          ...ownedFlyApps.rows.map((row) => row.fly_app_name),
          ...retainedGatewayRows.rows.map((row) => row.fly_app_name),
          ...interruptedMigrations.rows.map((row) => row.source_app_name),
          ...interruptedMigrations.rows
            .filter((row) => row.target_ownership_state === 'owned')
            .map((row) => row.target_app_name),
        ],
      );
      const retainedAppNames = new Set(retainedGatewayRows.rows.map((row) => row.fly_app_name));
      const confirmedDeletedAppNames = new Set<string>();
      if (flyAppNames.length > 0) {
        const { destroyApp } = getHostedGatewayProvisioning();
        for (const flyAppName of flyAppNames) {
          let deletionConfirmed = false;
          try {
            await destroyApp(flyAppName);
            deletionConfirmed = true;
          } catch (err: any) {
            if (isFlyAppAlreadyDeletedError(err)) {
              deletionConfirmed = true;
            } else {
              // Any retained claimed/migrated pool row remains durable and is retried by cleanup.
              console.error(`[AUTH] Failed to destroy Fly app ${flyAppName}:`, err.message);
            }
          }
          if (deletionConfirmed && retainedAppNames.has(flyAppName)) {
            confirmedDeletedAppNames.add(flyAppName);
            await client.query(
              `DELETE FROM gateway_pool
                WHERE fly_app_name = $1
                  AND status IN ('claimed', 'migrated')
                  AND claimed_by IS NULL`,
              [flyAppName],
            ).catch((error) => {
              // App deletion is complete; retaining the row is safe and lets periodic cleanup
              // confirm the 404 and retry metadata removal later.
              console.error(`[AUTH] Failed to remove retained gateway cleanup row ${flyAppName}:`, error);
            });
          }
          if (deletionConfirmed) confirmedDeletedAppNames.add(flyAppName);
          if (deletionConfirmed) {
            await client.query(
              `DELETE FROM gateway_fly_app_ownership
                WHERE fly_app_name = $1
                  AND state = 'delete_pending'
                  AND user_id IS NULL`,
              [flyAppName],
            ).catch((error) => {
              console.error(`[AUTH] Failed to remove Fly ownership cleanup row ${flyAppName}:`, error);
            });
          }
        }

        for (const migration of interruptedMigrations.rows) {
          if (!canRemoveInterruptedMigrationCheckpoint(migration, confirmedDeletedAppNames)) continue;
          await client.query(
            `WITH removed_source AS (
               DELETE FROM gateway_pool
                WHERE fly_app_name = $2
                  AND claimed_by IS NULL
             )
             DELETE FROM gateway_pool_migrations
              WHERE user_id = $1
                AND source_app_name = $2
                AND target_app_name = $3`,
            [userId, migration.source_app_name, migration.target_app_name],
          ).catch((error) => {
            // Both apps are gone. Keeping the checkpoint is safe and lets scheduled cleanup
            // confirm both 404s before retrying metadata removal.
            console.error(`[AUTH] Failed to remove migration cleanup row for ${userId}:`, error);
          });
        }
      }

      console.log(`[AUTH] Deleted user ${userId}, fly_apps=${flyAppNames.join(',') || 'none'}`);
      return appleIdentity.rows[0]?.apple_auth_code as string | undefined;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw err;
    }
  });

  // Apple revocation is best-effort and does not participate in gateway lifecycle ownership.
  // Run it only after the advisory lock, bounded lifecycle permit, and database client are released.
  if (appleAuthCode) {
    try {
      await revokeAppleToken(appleAuthCode);
    } catch (err: any) {
      console.warn(`[AUTH] Apple token revocation error (non-fatal):`, err.message);
    }
  }
}

// ── Public API ─────────────────────────────────────────

export async function authenticateUser(
  provider: 'apple' | 'google',
  idToken: string,
  clientProfile?: {
    email?: string;
    name?: string;
    given_name?: string;
    family_name?: string;
    picture?: string;
    locale?: string;
  },
  appleAuthCode?: string,
): Promise<{ user: User; accessToken: string; isNewUser: boolean }> {
  let providerData: { sub: string; email?: string; name?: string; given_name?: string; family_name?: string; picture?: string; locale?: string };

  if (provider === 'apple') {
    const apple = await verifyAppleToken(idToken);
    providerData = { sub: apple.sub, email: apple.email };
  } else {
    providerData = await verifyGoogleToken(idToken);
  }

  const profile = {
    email: providerData.email,
    name: providerData.name || clientProfile?.name,
    given_name: providerData.given_name || clientProfile?.given_name,
    family_name: providerData.family_name || clientProfile?.family_name,
    picture: providerData.picture,
    locale: providerData.locale || clientProfile?.locale,
  };

  const { user, isNewUser } = await findOrCreateUser(provider, providerData.sub, profile);
  const accessToken = generateToken(user.id);

  // Store Apple authorization code for future token revocation (best-effort)
  if (provider === 'apple' && appleAuthCode) {
    try {
      await pool.query(
        `UPDATE auth_identities SET apple_auth_code = $1
         WHERE user_id = $2 AND provider = 'apple'`,
        [appleAuthCode, user.id],
      );
    } catch (err: any) {
      console.warn('[AUTH] Failed to store Apple auth code:', err.message);
    }
  }

  return { user, accessToken, isNewUser };
}
