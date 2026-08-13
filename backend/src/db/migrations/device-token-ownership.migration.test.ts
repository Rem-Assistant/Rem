import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let db: any;

describe('device token destination ownership migration', () => {
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    await db.exec(fs.readFileSync(path.join(__dirname, '018_create_device_tokens.sql'), 'utf8'));
  });

  afterAll(async () => {
    await db?.close?.();
  });

  it('is replayable and installs the generation tombstone contract', async () => {
    const sql = fs.readFileSync(
      path.join(__dirname, '110_make_apns_destination_single_owner.sql'),
      'utf8',
    );
    const oldUser = '11111111-1111-4111-8111-111111111111';
    const currentUser = '22222222-2222-4222-8222-222222222222';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid), ($2::uuid)', [oldUser, currentUser]);
    await db.query(
      `INSERT INTO device_tokens
         (user_id, platform, apns_token, environment, created_at, updated_at, last_seen_at)
       VALUES
         ($1::uuid, 'ios', 'shared-device', 'sandbox', '2026-08-08T10:00:00Z', '2026-08-08T10:00:00Z', '2026-08-08T10:00:00Z'),
         ($2::uuid, 'ios', 'shared-device', 'sandbox', '2026-08-08T11:00:00Z', '2026-08-08T11:00:00Z', '2026-08-08T11:00:00Z')`,
      [oldUser, currentUser],
    );

    for (let attempt = 0; attempt < 2; attempt += 1) {
      await db.exec('BEGIN');
      try {
        await db.exec(sql);
        await db.exec('COMMIT');
      } catch (error) {
        await db.exec('ROLLBACK');
        throw error;
      }
    }

    const columns = await db.query(
      `SELECT column_name
         FROM information_schema.columns
        WHERE table_name = 'device_tokens'`,
    );
    const names = new Set(columns.rows.map((row: { column_name: string }) => row.column_name));
    expect(names.has('installation_id')).toBe(true);
    expect(names.has('ownership_generation')).toBe(true);
    expect(names.has('enabled')).toBe(true);

    const constraints = await db.query(
      `SELECT COUNT(*)::text AS count
         FROM pg_constraint
        WHERE conrelid = 'device_tokens'::regclass
          AND conname = 'device_tokens_apns_token_environment_key'`,
    );
    expect(constraints.rows[0].count).toBe('1');

    const owners = await db.query(
      `SELECT user_id::text AS user_id, id::text AS id
         FROM device_tokens
        WHERE apns_token = 'shared-device' AND environment = 'sandbox'`,
    );
    expect(owners.rows).toHaveLength(1);
    expect(owners.rows[0].user_id).toBe(currentUser);

    // Model a current-client transfer to the new account, then both forms of a delayed old-account
    // unregister. The user/install predicates must leave the transferred destination untouched.
    await db.query(
      `UPDATE device_tokens
          SET installation_id = 'install-current', ownership_generation = 10, enabled = TRUE
        WHERE id = $1::uuid`,
      [owners.rows[0].id],
    );
    const delayedDisable = await db.query(
      `UPDATE device_tokens
          SET enabled = FALSE, ownership_generation = 11
        WHERE user_id = $1::uuid AND apns_token = 'shared-device'
          AND installation_id = 'install-old' AND ownership_generation <= 11
        RETURNING id`,
      [oldUser],
    );
    expect(delayedDisable.rows).toEqual([]);
    const delayedLegacyDelete = await db.query(
      `DELETE FROM device_tokens
        WHERE user_id = $1::uuid AND apns_token = 'shared-device'
        RETURNING id`,
      [oldUser],
    );
    expect(delayedLegacyDelete.rows).toEqual([]);
    const retained = await db.query(
      `SELECT user_id::text AS user_id, enabled, ownership_generation::text AS generation
         FROM device_tokens
        WHERE apns_token = 'shared-device' AND environment = 'sandbox'`,
    );
    expect(retained.rows).toEqual([{
      user_id: currentUser,
      enabled: true,
      generation: '10',
    }]);
  });
});
