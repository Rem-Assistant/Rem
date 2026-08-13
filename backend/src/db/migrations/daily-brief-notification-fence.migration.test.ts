import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let db: any;

describe('daily brief notification fence migration', () => {
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
  });

  afterAll(async () => {
    await db?.close?.();
  });

  it('is replayable and retains one monotonic slot per account/local-day', async () => {
    const sql = fs.readFileSync(
      path.join(__dirname, '111_create_daily_brief_notification_fence.sql'),
      'utf8',
    );
    const userId = '11111111-1111-4111-8111-111111111111';
    await db.query('INSERT INTO users (id) VALUES ($1::uuid)', [userId]);

    await db.exec(sql);
    await db.exec(sql);
    await db.query(
      `INSERT INTO daily_brief_notification_fences
         (user_id, latest_brief_date, latest_slot, last_notified_at)
       VALUES ($1::uuid, '2026-08-08'::date, 'afternoon', NOW())`,
      [userId],
    );

    const rows = await db.query(
      `SELECT latest_brief_date::text, latest_slot
         FROM daily_brief_notification_fences
        WHERE user_id = $1::uuid`,
      [userId],
    );
    expect(rows.rows).toEqual([{ latest_brief_date: '2026-08-08', latest_slot: 'afternoon' }]);
    await expect(db.query(
      `UPDATE daily_brief_notification_fences
          SET latest_slot = 'invalid'
        WHERE user_id = $1::uuid`,
      [userId],
    )).rejects.toThrow();
  });
});
