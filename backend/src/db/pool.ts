import pg from 'pg';
import { env } from '../config/env.js';

// `pg.Pool` cannot cancel a checkout wrapper after it starts opening a new socket. Its native
// timeout owns that lifecycle and destroys handshakes that never complete, preserving capacity for
// authentication and ordinary task traffic when PostgreSQL is unreachable.
export const DATABASE_CONNECTION_TIMEOUT_MS = 2_000;

export const pool = new pg.Pool({
  connectionString: env.DATABASE_URL,
  connectionTimeoutMillis: DATABASE_CONNECTION_TIMEOUT_MS,
});

/** Pool or checked-out client accepted by reads that join a caller-owned transaction. */
export type DatabaseQueryable = Pick<pg.PoolClient, 'query'>;

/**
 * Long-running gateway lifecycle owners must not retain a checkout from the shared application
 * pool while they wait for another replica's advisory lock. A dedicated client keeps that wait
 * visible to PostgreSQL (and therefore to older replicas) without starving ordinary requests.
 */
export function createDedicatedDatabaseClient(): pg.Client {
  return new pg.Client({
    connectionString: env.DATABASE_URL,
    connectionTimeoutMillis: DATABASE_CONNECTION_TIMEOUT_MS,
    keepAlive: true,
  });
}
