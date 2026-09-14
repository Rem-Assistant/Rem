import { afterAll, describe, expect, it, vi } from 'vitest';

vi.mock('../config/env.js', () => ({
  env: { DATABASE_URL: 'postgresql://test:test@localhost:5432/remclaw_test' },
}));

const {
  DATABASE_CONNECTION_TIMEOUT_MS,
  createDedicatedDatabaseClient,
  pool,
  routinePolicyLockPool,
  taskConversationPool,
} = await import('./pool.js');

afterAll(async () => {
  await pool.end();
  await taskConversationPool.end();
  await routinePolicyLockPool.end();
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

  it('isolates long task turns behind a small bounded pool', () => {
    expect(taskConversationPool.options.max).toBe(8);
    expect(taskConversationPool.options.connectionTimeoutMillis).toBe(DATABASE_CONNECTION_TIMEOUT_MS);
  });

  it('isolates long routine policy locks from ordinary queries', () => {
    expect(routinePolicyLockPool).not.toBe(pool);
    expect(routinePolicyLockPool.options.max).toBe(8);
    expect(routinePolicyLockPool.options.connectionTimeoutMillis)
      .toBe(DATABASE_CONNECTION_TIMEOUT_MS);
  });
});
