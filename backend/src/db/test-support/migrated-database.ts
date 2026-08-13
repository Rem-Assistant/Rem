/**
 * Throwaway PostgreSQL databases with the REAL migrations applied, for integration tests.
 *
 * WHY THIS EXISTS. Integration tests used to hand-write their own `CREATE TABLE` stub of the
 * tables they touched. That stub is a second, silent definition of the schema, and it rots: every
 * column added to a real migration had to be hand-copied into the stub, and when someone forgot,
 * the test failed by naming something else entirely ("expected 500 to be 200", a wrong-brief-text
 * assertion) because the route swallows a query error and serves a fallback. Each miss cost a
 * debugging session that started in the wrong feature. Applying the real `.sql` files removes the
 * second definition instead of asking people to remember to update it.
 *
 * WHY A DATABASE AND NOT A SCHEMA. The obvious cheaper move is `CREATE SCHEMA` + `SET search_path`.
 * It does not work here: migrations may schema-qualify their DDL, and `100_user_channels_connecting_status.sql`
 * already does — its `to_regclass('public.user_channels')` guard returns NULL under a temp schema,
 * so the whole `DO $$ ... $$` block silently RETURNs and its CHECK constraint is never installed.
 * Measured on PostgreSQL 16: temp schema leaves `user_channels_status_check` ABSENT, a throwaway
 * database installs it. A silently-skipped migration is the same class of bug as a silently-missing
 * column, so the schema route would have reintroduced what this file is meant to remove. In a fresh
 * database `public` is the real `public`, and every migration runs exactly as it does in production.
 * Cost measured at ~320ms end to end (create + 62 migrations + drop).
 *
 * Migrations are applied in sorted filename order, matching the production runner
 * (`src/db/run-migrations.ts`). Unlike that runner this does not keep a `schema_migrations` ledger:
 * the database is new every time, so there is nothing to skip.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** The one migrations directory — the same files `npm run migrate` applies in production. */
export const MIGRATIONS_DIR = path.join(__dirname, '..', 'migrations');

/** Every migration, in the order the production runner applies them (sorted filename order). */
export function migrationFilenames(): string[] {
  return fs.readdirSync(MIGRATIONS_DIR).filter((file) => file.endsWith('.sql')).sort();
}

export interface MigratedDatabase {
  /** Connection string for the throwaway database (NOT the server passed in). */
  connectionString: string;
  databaseName: string;
  /** Pool bound to the throwaway database. Closed by `drop()`. */
  pool: pg.Pool;
  /** Closes the pool and destroys the database. Safe to call twice. */
  drop(): Promise<void>;
}

/**
 * Creates a uniquely-named database on the server `adminConnectionString` points at, applies every
 * migration, and hands back a pool bound to it.
 *
 * `label` prefixes the database name so a leaked database is traceable to the suite that made it.
 */
export async function createMigratedDatabase({
  adminConnectionString,
  label,
  max = 4,
}: {
  adminConnectionString: string;
  label: string;
  max?: number;
}): Promise<MigratedDatabase> {
  // Postgres truncates identifiers at 63 bytes; a collision there would make two concurrent suites
  // share (and drop) one database, so keep the name short and assert rather than let it truncate.
  const databaseName = `${label}_${process.pid}_${randomUUID().slice(0, 8)}`.toLowerCase();
  if (databaseName.length > 63) {
    throw new Error(`Database name "${databaseName}" exceeds PostgreSQL's 63-byte identifier limit`);
  }

  const admin = new pg.Client({ connectionString: adminConnectionString });
  await admin.connect();
  try {
    await admin.query(`CREATE DATABASE "${databaseName}"`);
  } catch (error) {
    throw new Error(
      `Could not CREATE DATABASE "${databaseName}": ${(error as Error).message}\n` +
        'Integration tests build a throwaway database so the real migrations run against the real ' +
        '`public` schema. Point TEST_DATABASE_URL at a server whose role may create databases — ' +
        "CI's postgres:16 service role and a local `postgres` superuser both can.",
    );
  } finally {
    await admin.end().catch(() => undefined);
  }

  const url = new URL(adminConnectionString);
  url.pathname = `/${databaseName}`;
  const connectionString = url.toString();

  const pool = new pg.Pool({ connectionString, max });
  const dropDatabase = async () => {
    await pool.end().catch(() => undefined);
    const cleanup = new pg.Client({ connectionString: adminConnectionString });
    await cleanup.connect();
    try {
      // A leaked connection would make DROP DATABASE hang; evict any before dropping.
      await cleanup.query(
        `SELECT pg_terminate_backend(pid) FROM pg_stat_activity
          WHERE datname = $1 AND pid <> pg_backend_pid()`,
        [databaseName],
      );
      await cleanup.query(`DROP DATABASE IF EXISTS "${databaseName}"`);
    } finally {
      await cleanup.end().catch(() => undefined);
    }
  };

  try {
    const client = await pool.connect();
    try {
      for (const file of migrationFilenames()) {
        const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
        try {
          await client.query(sql);
        } catch (error) {
          // Name the file. Mirrors run-migrations.ts, so a migration that breaks in a test breaks
          // with the same sentence it would print on a real boot.
          throw new Error(`Migration failed: ${file}: ${(error as Error).message}`);
        }
      }
    } finally {
      client.release();
    }
  } catch (error) {
    await dropDatabase().catch(() => undefined);
    throw error;
  }

  let dropped = false;
  return {
    connectionString,
    databaseName,
    pool,
    async drop() {
      if (dropped) return;
      dropped = true;
      await dropDatabase();
    },
  };
}
