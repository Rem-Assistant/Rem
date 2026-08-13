/**
 * Real-Postgres concurrency coverage for migration 113. PGlite serializes transactions inside one
 * process, so it cannot prove that the compatibility trigger and a current logout overlap safely.
 * Run through `npm run test:integration` with TEST_DATABASE_URL pointed at a throwaway database.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import pg from 'pg';

const testDatabaseUrl = process.env.TEST_DATABASE_URL?.trim();
if (!testDatabaseUrl) {
  throw new Error('TEST_DATABASE_URL is required for integration tests');
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const schema = `push_rollout_${process.pid}`;
const userId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const oldRegisterSql = `INSERT INTO device_tokens (user_id, apns_token, environment, platform)
  VALUES ($1::uuid, $2, $3, $4)
  ON CONFLICT (user_id, apns_token) DO UPDATE
    SET environment = EXCLUDED.environment,
        platform = EXCLUDED.platform,
        updated_at = NOW(),
        last_seen_at = NOW()
  RETURNING id`;

let pool: pg.Pool;

async function setSearchPath(client: pg.PoolClient): Promise<void> {
  await client.query(`SET search_path TO "${schema}", public`);
}

beforeAll(async () => {
  pool = new pg.Pool({ connectionString: testDatabaseUrl });
  const setup = await pool.connect();
  try {
    await setup.query('CREATE EXTENSION IF NOT EXISTS pgcrypto');
    await setup.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
    await setup.query(`CREATE SCHEMA "${schema}"`);
    await setSearchPath(setup);
    await setup.query('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    for (const migration of [
      '018_create_device_tokens.sql',
      '110_make_apns_destination_single_owner.sql',
      '112_create_push_installation_fences.sql',
    ]) {
      await setup.query(fs.readFileSync(path.join(__dirname, migration), 'utf8'));
    }
    await setup.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);
    await setup.query(
      `INSERT INTO push_installation_fences
         (installation_id, user_id, ownership_generation, enabled)
       VALUES ('install-concurrent', $1::uuid, 10, TRUE)`,
      [userId],
    );
    await setup.query(
      `INSERT INTO device_tokens
         (user_id, apns_token, environment, platform, installation_id, ownership_generation)
       VALUES ($1::uuid, 'concurrent-token', 'sandbox', 'ios', 'install-concurrent', 10)`,
      [userId],
    );
    await setup.query(fs.readFileSync(
      path.join(__dirname, '113_enforce_push_installation_authority.sql'),
      'utf8',
    ));
  } finally {
    setup.release();
  }
});

afterAll(async () => {
  if (!pool) return;
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

describe('push installation mixed-replica concurrency', () => {
  it('does not let an old writer resurrect a destination deleted by current logout', async () => {
    const retiring = await pool.connect();
    const oldWriter = await pool.connect();
    const observer = await pool.connect();
    try {
      await Promise.all([setSearchPath(retiring), setSearchPath(oldWriter)]);
      const oldWriterPid = Number((await oldWriter.query('SELECT pg_backend_pid() AS pid')).rows[0].pid);

      await retiring.query('BEGIN');
      await retiring.query(
        `SELECT pg_advisory_xact_lock(hashtextextended('install-concurrent', 0))`,
      );
      await retiring.query(
        `DELETE FROM device_tokens
          WHERE user_id = $1::uuid AND apns_token = 'concurrent-token'`,
        [userId],
      );

      // The old trigger can see the pre-delete row, but `FOR UPDATE` must wait for retirement and
      // then re-evaluate it as gone. Capture the rejection so it cannot become an unhandled promise.
      const oldWrite = oldWriter.query(
        oldRegisterSql,
        [userId, 'concurrent-token', 'production', 'ios'],
      ).then(
        (value) => ({ ok: true as const, value }),
        (error: { code?: string }) => ({ ok: false as const, error }),
      );

      let observedLockWait = false;
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const activity = await observer.query(
          `SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1`,
          [oldWriterPid],
        );
        if (activity.rows[0]?.wait_event_type === 'Lock') {
          observedLockWait = true;
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      expect(observedLockWait).toBe(true);

      await retiring.query('COMMIT');
      const outcome = await oldWrite;
      expect(outcome.ok).toBe(false);
      if (!outcome.ok) expect(outcome.error.code).toBe('23502');

      const remaining = await observer.query(
        `SELECT id FROM "${schema}".device_tokens WHERE apns_token = 'concurrent-token'`,
      );
      expect(remaining.rows).toEqual([]);
    } finally {
      await retiring.query('ROLLBACK').catch(() => undefined);
      retiring.release();
      oldWriter.release();
      observer.release();
    }
  });
});
