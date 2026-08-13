import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

vi.mock('../../db/pool.js', () => ({ pool: { query: vi.fn() } }));
vi.mock('../../config/env.js', () => ({ env: {} }));
import {
  DISABLE_CURRENT_INSTALLATION_SQL,
  LIST_DELIVERABLE_DEVICE_TOKENS_SQL,
  REGISTER_CURRENT_DEVICE_TOKEN_SQL,
} from '../../services/push.service.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let db: any;

describe('push installation generation fence migration', () => {
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    await db.exec(fs.readFileSync(path.join(__dirname, '018_create_device_tokens.sql'), 'utf8'));
    await db.exec(fs.readFileSync(
      path.join(__dirname, '110_make_apns_destination_single_owner.sql'),
      'utf8',
    ));
  });

  afterAll(async () => {
    await db?.close?.();
  });

  it('is replayable and preserves the strongest known installation generation', async () => {
    const sql = fs.readFileSync(
      path.join(__dirname, '112_create_push_installation_fences.sql'),
      'utf8',
    );
    const userId = '11111111-1111-4111-8111-111111111111';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);
    await db.query(
      `INSERT INTO device_tokens
         (user_id, platform, apns_token, environment, installation_id,
          ownership_generation, enabled)
       VALUES ($1::uuid, 'ios', 'rotated-token', 'sandbox', 'install-1', 7, TRUE)`,
      [userId],
    );

    await db.exec(sql);
    await db.exec(sql);

    const rows = await db.query(
      `SELECT user_id::text AS user_id, ownership_generation::text AS generation, enabled
         FROM push_installation_fences
        WHERE installation_id = 'install-1'`,
    );
    expect(rows.rows).toEqual([{ user_id: userId, generation: '7', enabled: true }]);
  });

  it('rejects a delayed registration when sign-out fences the installation before token insert', async () => {
    const userId = '22222222-2222-4222-8222-222222222222';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);

    const fence = await db.query(
      `INSERT INTO push_installation_fences
         (installation_id, user_id, ownership_generation, enabled)
       VALUES ('install-race', $1::uuid, 11, FALSE)
       ON CONFLICT (installation_id) DO UPDATE
         SET ownership_generation = EXCLUDED.ownership_generation,
             enabled = FALSE,
             updated_at = NOW()
       WHERE push_installation_fences.user_id = EXCLUDED.user_id
         AND push_installation_fences.ownership_generation <= EXCLUDED.ownership_generation
       RETURNING installation_id`,
      [userId],
    );
    expect(fence.rows).toHaveLength(1);

    const delayed = await db.query(
      `WITH claimed_installation AS (
         INSERT INTO push_installation_fences
           (installation_id, user_id, ownership_generation, enabled)
         VALUES ('install-race', $1::uuid, 10, TRUE)
         ON CONFLICT (installation_id) DO UPDATE
           SET user_id = EXCLUDED.user_id,
               ownership_generation = EXCLUDED.ownership_generation,
               enabled = TRUE,
               updated_at = NOW()
         WHERE EXCLUDED.ownership_generation > push_installation_fences.ownership_generation
            OR (
              EXCLUDED.ownership_generation = push_installation_fences.ownership_generation
              AND push_installation_fences.user_id = EXCLUDED.user_id
              AND push_installation_fences.enabled = TRUE
            )
         RETURNING installation_id
       )
       INSERT INTO device_tokens
         (user_id, platform, apns_token, environment, installation_id,
          ownership_generation)
       SELECT $1::uuid, 'ios', 'late-token', 'sandbox', 'install-race', 10
         FROM claimed_installation
       RETURNING id`,
      [userId],
    );
    expect(delayed.rows).toEqual([]);

    const destination = await db.query(
      `SELECT id FROM device_tokens WHERE apns_token = 'late-token'`,
    );
    expect(destination.rows).toEqual([]);
    const retainedFence = await db.query(
      `SELECT ownership_generation::text AS generation, enabled
         FROM push_installation_fences
        WHERE installation_id = 'install-race'`,
    );
    expect(retainedFence.rows).toEqual([{ generation: '11', enabled: false }]);
  });

  it('retires every rotated sibling and disables the whole installation on logout', async () => {
    const userId = '33333333-3333-4333-8333-333333333333';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);

    for (const token of ['rotation-a', 'rotation-b', 'rotation-c']) {
      const registered = await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
        userId, token, 'sandbox', 'ios', 'install-rotation', 20,
      ]);
      expect(registered.rows).toHaveLength(1);
    }

    const beforeLogout = await db.query(
      `SELECT apns_token, enabled
         FROM device_tokens
        WHERE installation_id = 'install-rotation'
        ORDER BY apns_token`,
    );
    expect(beforeLogout.rows).toEqual([
      { apns_token: 'rotation-c', enabled: true },
    ]);
    const deliverableBefore = await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [userId]);
    expect(deliverableBefore.rows.map((row: any) => row.apns_token)).toContain('rotation-c');
    expect(deliverableBefore.rows.map((row: any) => row.apns_token)).not.toContain('rotation-a');

    const disabled = await db.query(DISABLE_CURRENT_INSTALLATION_SQL, [
      userId, 'rotation-c', 'install-rotation', 21, false,
    ]);
    expect(disabled.rows).toEqual([{
      fenced: true, disabled: true, legacy_retired: false,
    }]);
    const afterLogout = await db.query(
      `SELECT apns_token, enabled
         FROM device_tokens
        WHERE installation_id = 'install-rotation'
        ORDER BY apns_token`,
    );
    expect(afterLogout.rows).toEqual([]);
    const deliverableAfter = await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [userId]);
    expect(deliverableAfter.rows.map((row: any) => row.apns_token)).not.toContain('rotation-c');
  });

  it('transfers an installation across accounts without letting the stale owner reclaim it', async () => {
    const oldUser = '44444444-4444-4444-8444-444444444444';
    const newUser = '55555555-5555-4555-8555-555555555555';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid), ($2::uuid)', [oldUser, newUser]);

    await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
      oldUser, 'account-old', 'sandbox', 'ios', 'install-transfer', 30,
    ]);
    await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
      newUser, 'account-new', 'sandbox', 'ios', 'install-transfer', 31,
    ]);

    const oldDestinations = await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [oldUser]);
    const newDestinations = await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [newUser]);
    expect(oldDestinations.rows.map((row: any) => row.apns_token)).not.toContain('account-old');
    expect(newDestinations.rows.map((row: any) => row.apns_token)).toContain('account-new');

    const staleDisable = await db.query(DISABLE_CURRENT_INSTALLATION_SQL, [
      oldUser, 'account-old', 'install-transfer', 32, false,
    ]);
    expect(staleDisable.rows).toEqual([{
      fenced: false, disabled: false, legacy_retired: false,
    }]);
    const retained = await db.query(LIST_DELIVERABLE_DEVICE_TOKENS_SQL, [newUser]);
    expect(retained.rows.map((row: any) => row.apns_token)).toContain('account-new');
  });

  it('replay adopts a stronger old-replica transfer and repairs its enabled siblings', async () => {
    const sql = fs.readFileSync(
      path.join(__dirname, '112_create_push_installation_fences.sql'),
      'utf8',
    );
    const oldUser = '88888888-8888-4888-8888-888888888888';
    const newUser = '99999999-9999-4999-8999-999999999999';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid), ($2::uuid)', [oldUser, newUser]);
    await db.query(REGISTER_CURRENT_DEVICE_TOKEN_SQL, [
      oldUser, 'replay-old', 'sandbox', 'ios', 'install-replay', 50,
    ]);
    await db.query(
      `INSERT INTO device_tokens
         (user_id, platform, apns_token, environment, installation_id,
          ownership_generation, enabled, updated_at)
       VALUES
         ($1::uuid, 'ios', 'replay-stale', 'sandbox', 'install-replay', 51, TRUE,
          '2026-08-09T06:00:00Z'),
         ($1::uuid, 'ios', 'replay-current', 'production', 'install-replay', 51, TRUE,
          '2026-08-09T07:00:00Z')`,
      [newUser],
    );

    await db.exec(sql);
    await db.exec(sql);

    const fence = await db.query(
      `SELECT user_id::text AS user_id, ownership_generation::text AS generation, enabled
         FROM push_installation_fences
        WHERE installation_id = 'install-replay'`,
    );
    expect(fence.rows).toEqual([{ user_id: newUser, generation: '51', enabled: true }]);
    const rows = await db.query(
      `SELECT apns_token, enabled
         FROM device_tokens
        WHERE installation_id = 'install-replay'
        ORDER BY apns_token`,
    );
    expect(rows.rows).toEqual([
      { apns_token: 'replay-current', enabled: true },
    ]);
  });
});
