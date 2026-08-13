import { afterAll, describe, expect, it, vi } from 'vitest';

vi.mock('../config/env.js', () => ({
  env: { DATABASE_URL: 'postgresql://test:test@localhost:5432/remclaw_test' },
}));

const { DATABASE_CONNECTION_TIMEOUT_MS, createDedicatedDatabaseClient, pool } = await import('./pool.js');

afterAll(async () => {
  await pool.end();
});

describe('shared PostgreSQL pool', () => {
  it('uses the native connection timeout so stalled handshakes cannot consume the pool forever', () => {
    expect(DATABASE_CONNECTION_TIMEOUT_MS).toBe(2_000);
    expect(pool.options.connectionTimeoutMillis).toBe(DATABASE_CONNECTION_TIMEOUT_MS);
  });

  it('gives dedicated lifecycle sessions the same bounded handshake and TCP keepalive', () => {
    const client = createDedicatedDatabaseClient();
    const connectionParameters = (client as unknown as {
      connectionParameters: { connect_timeout: number; keepalives: number };
    }).connectionParameters;
    expect(connectionParameters.connect_timeout).toBe(
      DATABASE_CONNECTION_TIMEOUT_MS / 1_000,
    );
    expect(connectionParameters.keepalives).toBe(1);
  });
});
