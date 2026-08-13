import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.join(__dirname, 'migrations');
const DATABASE_URL = process.env.DATABASE_URL?.trim();
if (!DATABASE_URL) {
  console.error('DATABASE_URL is required');
  process.exit(1);
}

/**
 * Applies pending SQL migrations, tracking which have run in a `schema_migrations`
 * table so each runs **once** instead of re-executing every boot.
 *
 * Migrations are still expected to be idempotent (`CREATE ... IF NOT EXISTS`,
 * guarded `UPDATE ... WHERE col IS NULL`) — that's the belt; the tracking table
 * is the suspenders. On the first boot after this change, `schema_migrations` is
 * empty, so every file runs once more (harmless, since they're idempotent) and is
 * recorded; subsequent boots skip already-applied files.
 *
 * Files are applied in sorted filename order. Two files sharing a numeric prefix
 * (e.g. `110_add_managed_talk_credential_fingerprint` + `110_make_apns_destination_single_owner`)
 * are distinct rows here and both apply — but new migrations should use a unique,
 * increasing prefix to keep ordering unambiguous.
 *
 * NOTE: each file is wrapped in a transaction (BEGIN/COMMIT), so a migration may
 * NOT use `CREATE INDEX CONCURRENTLY` (it cannot run inside a transaction block).
 * If a future zero-downtime index needs CONCURRENTLY, that file must opt out of
 * the wrapper.
 */
async function run() {
  const pool = new pg.Pool({ connectionString: DATABASE_URL });
  const files = fs.readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
  const client = await pool.connect();
  try {
    // Serialize concurrent boots (multiple Railway replicas / overlapping deploys)
    // so they don't race to run the same DDL. Session-level advisory lock; released
    // on disconnect even if the process dies mid-run.
    await client.query('SELECT pg_advisory_lock($1)', [0x52454d43]); // "REMC"
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        filename TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);
    const { rows } = await client.query<{ filename: string }>(
      'SELECT filename FROM schema_migrations',
    );
    const applied = new Set(rows.map((r) => r.filename));

    let ran = 0;
    let skipped = 0;
    for (const file of files) {
      if (applied.has(file)) {
        skipped += 1;
        continue;
      }
      const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
      // Apply + record atomically: a failure rolls back both, so the migration
      // is retried (not silently marked done) on the next boot.
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          'INSERT INTO schema_migrations (filename) VALUES ($1) ON CONFLICT DO NOTHING',
          [file],
        );
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Migration failed: ${file}: ${(err as Error).message}`);
      }
      console.log('Ran:', file);
      ran += 1;
    }
    console.log(`Migrations complete: ${ran} ran, ${skipped} already applied (${files.length} total).`);
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [0x52454d43]).catch(() => {});
    client.release();
    await pool.end();
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
