import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../db/pool.js', () => ({ pool: { query: vi.fn() } }));
vi.mock('../../config/env.js', () => ({ env: {} }));
import {
  DISABLE_CURRENT_INSTALLATION_SQL,
  LIST_DELIVERABLE_DEVICE_TOKENS_SQL,
  REGISTER_CURRENT_DEVICE_TOKEN_SQL,
} from '../../services/push.service.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let db: any;

// Exact pre-PR writer and reader shapes. The old route ignores installationId/generation, and the
// old sender ignores enabled; rollout coverage must not fabricate fields that binary never writes.
const OLD_REGISTER_SQL = `INSERT INTO device_tokens (user_id, apns_token, environment, platform)
  VALUES ($1::uuid, $2, $3, $4)
  ON CONFLICT (user_id, apns_token) DO UPDATE
    SET environment = EXCLUDED.environment,
        platform = EXCLUDED.platform,
        updated_at = NOW(),
        last_seen_at = NOW()
  RETURNING id, apns_token, environment, platform`;
const OLD_LIST_SQL = `SELECT id, apns_token, environment, platform
  FROM device_tokens
  WHERE user_id = $1::uuid`;

// Shipped clients persist only these three fields. When APNs returns the same token on a later
// launch, this cache prevents any registration request, so migration safety cannot depend on a
// client POST occurring after backend rollout.
const shippedClientWouldSkipRegistration = (
  token: string,
  environment: string,
  userId: string,
  cache: { token: string; environment: string; userId: string },
): boolean => cache.token === token
  && cache.environment === environment
  && cache.userId === userId;

describe('push installation mixed-replica rollout', () => {
  beforeEach(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    await db.exec(fs.readFileSync(path.join(__dirname, '018_create_device_tokens.sql'), 'utf8'));
    await db.exec(fs.readFileSync(
      path.join(__dirname, '110_make_apns_destination_single_owner.sql'),
      'utf8',
    ));
    await db.exec(fs.readFileSync(
      path.join(__dirname, '112_create_push_installation_fences.sql'),
      'utf8',
    ));
  });

  afterEach(async () => {
    await db?.close?.();
    db = undefined;
  });

  it('preserves a cached shipped-client destination and rejects new ambiguous old writes', async () => {
    const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);
    await db.query(OLD_REGISTER_SQL, [userId, 'old-null-token', 'sandbox', 'ios']);
    const before = await db.query(
      `SELECT installation_id FROM device_tokens WHERE apns_token = 'old-null-token'`,
    );
    expect(before.rows).toEqual([{ installation_id: null }]);

    const migration = fs.readFileSync(
      path.join(__dirname, '113_enforce_push_installation_authority.sql'),
      'utf8',
    );
    await db.exec(migration);
    await db.exec(migration);

    // The released app receives the same APNs token and suppresses its POST from this cache. The
    // migrated destination must remain visible to both old and current senders without that POST.
    expect(shippedClientWouldSkipRegistration(
      'old-null-token',
      'sandbox',
      userId,
      { token: 'old-null-token', environment: 'sandbox', userId },
    )).toBe(true);
    expect((await db.query(
      `SELECT apns_token, installation_id, ownership_generation, enabled
         FROM device_tokens
        WHERE user_id = $1::uuid`,
      [userId],
    )).rows).toEqual([{
      apns_token: 'old-null-token',
      installation_id: `legacy:${userId}`,
      ownership_generation: 0,
      enabled: true,
    }]);
    expect((await db.query(OLD_LIST_SQL, [userId])).rows.map((row: any) => row.apns_token))
      .toEqual(['old-null-token']);
    expect((await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [userId])).rows)
      .toMatchObject([{ apns_token: 'old-null-token', environment: 'sandbox' }]);

    // A draining old backend may refresh this same authorized destination, but it still cannot
    // create a new NULL-authority row after the NOT NULL rollout fence lands.
    await expect(db.query(
      OLD_REGISTER_SQL,
      [userId, 'old-null-token', 'production', 'ios'],
    )).resolves.toMatchObject({ rows: [{ apns_token: 'old-null-token' }] });
    await expect(db.query(
      OLD_REGISTER_SQL,
      [userId, 'delayed-old-token', 'sandbox', 'ios'],
    )).rejects.toThrow();
  });

  it('physically removes a disabled pre-fence destination from old senders', async () => {
    const userId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);
    await db.query(OLD_REGISTER_SQL, [userId, 'disabled-null-token', 'sandbox', 'ios']);
    await db.query(
      `UPDATE device_tokens SET enabled = FALSE WHERE apns_token = 'disabled-null-token'`,
    );

    const migration = fs.readFileSync(
      path.join(__dirname, '113_enforce_push_installation_authority.sql'),
      'utf8',
    );
    await db.exec(migration);

    expect((await db.query(OLD_LIST_SQL, [userId])).rows).toEqual([]);
  });

  it('cold upgraded-client logout fences the new install and retires only its legacy token', async () => {
    const userId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);
    await db.query(OLD_REGISTER_SQL, [userId, 'this-device-token', 'sandbox', 'ios']);
    await db.query(OLD_REGISTER_SQL, [userId, 'other-device-token', 'sandbox', 'ios']);
    const migration = fs.readFileSync(
      path.join(__dirname, '113_enforce_push_installation_authority.sql'),
      'utf8',
    );
    await db.exec(migration);

    const disabled = await db.query(DISABLE_CURRENT_INSTALLATION_SQL, [
      userId, 'this-device-token', 'new-install-after-upgrade', 40, true,
    ]);
    expect(disabled.rows).toEqual([{
      fenced: true,
      disabled: false,
      legacy_retired: true,
    }]);
    expect((await db.query(
      `SELECT apns_token FROM device_tokens WHERE user_id = $1::uuid ORDER BY apns_token`,
      [userId],
    )).rows).toEqual([{ apns_token: 'other-device-token' }]);
    expect((await db.query(
      `SELECT user_id::text, ownership_generation::text, enabled
         FROM push_installation_fences
        WHERE installation_id = 'new-install-after-upgrade'`,
    )).rows).toEqual([{
      user_id: userId,
      ownership_generation: '40',
      enabled: false,
    }]);
  });

  it('physically retires rotation and logout rows from an old sender', async () => {
    const userId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);

    await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
      userId, 'rotation-old', 'production', 'ios', 'install-rollout', 20,
    ]);
    const migration = fs.readFileSync(
      path.join(__dirname, '113_enforce_push_installation_authority.sql'),
      'utf8',
    );
    await db.exec(migration);
    // A replica on the previous release can still refresh an already-authorized destination:
    // its ON CONFLICT update leaves the installation authority columns untouched.
    await db.query(OLD_REGISTER_SQL, [
      userId, 'rotation-old', 'sandbox', 'ios',
    ]);
    expect((await db.query(
      `SELECT environment, installation_id, ownership_generation
         FROM device_tokens
        WHERE apns_token = 'rotation-old'`,
    )).rows).toEqual([{
      environment: 'sandbox',
      installation_id: 'install-rollout',
      ownership_generation: 20,
    }]);

    await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
      userId, 'rotation-current', 'production', 'ios', 'install-rollout', 20,
    ]);
    expect((await db.query(OLD_LIST_SQL, [userId])).rows.map((row: any) => row.apns_token))
      .toEqual(['rotation-current']);

    const disabled = await db.query(DISABLE_CURRENT_INSTALLATION_SQL, [
      userId, 'rotation-current', 'install-rollout', 21, false,
    ]);
    expect(disabled.rows).toEqual([{
      fenced: true, disabled: true, legacy_retired: false,
    }]);
    expect((await db.query(OLD_LIST_SQL, [userId])).rows).toEqual([]);

    // A delayed old replica cannot recreate a row after the generation tombstone won logout.
    await expect(db.query(
      OLD_REGISTER_SQL,
      [userId, 'rotation-current', 'production', 'ios'],
    )).rejects.toThrow();
  });
});
