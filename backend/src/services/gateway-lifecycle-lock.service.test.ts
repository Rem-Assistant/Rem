import { beforeEach, describe, expect, it, vi } from 'vitest';

const dedicatedClientMock = vi.hoisted(() => ({
  connect: vi.fn(),
  query: vi.fn(),
  end: vi.fn(),
  connection: { stream: { destroy: vi.fn() } },
}));
const poolClientMock = vi.hoisted(() => ({ query: vi.fn(), release: vi.fn() }));
const databaseMock = vi.hoisted(() => ({
  pool: { connect: vi.fn() },
  createDedicatedDatabaseClient: vi.fn(),
}));
vi.mock('../db/pool.js', () => databaseMock);

const {
  GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS,
  GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS,
  GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS,
  GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS,
  GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_MS,
  GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS,
  GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS,
  MAX_CONCURRENT_GATEWAY_LIFECYCLE_CLIENTS,
  MAX_CONCURRENT_GATEWAY_CONFIG_RECONCILIATIONS,
  MAX_CONCURRENT_GATEWAY_WAKE_CLIENTS,
  acquireUserGatewayLifecycleTransactionLock,
  tryWithUserGatewayLifecycleMutationLock,
  tryWithUserGatewayConfigReconciliationLock,
  tryWithUserGatewayLifecycleLock,
  withUserGatewayLifecycleLock,
} = await import('./gateway-lifecycle-lock.service.js');

function lockResult(sql: string) {
  if (sql.includes('pg_try_advisory_lock')) return { rows: [{ acquired: true }] };
  if (sql.includes('pg_advisory_unlock')) return { rows: [{ unlocked: true }] };
  return { rows: [{}] };
}

function makeDedicatedClient() {
  return {
    connect: vi.fn().mockResolvedValue(undefined),
    query: vi.fn().mockImplementation(async (sql: string) => lockResult(sql)),
    end: vi.fn().mockResolvedValue(undefined),
    connection: { stream: { destroy: vi.fn() } },
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  dedicatedClientMock.connect.mockResolvedValue(undefined);
  dedicatedClientMock.query.mockImplementation(async (sql: string) => lockResult(sql));
  dedicatedClientMock.end.mockResolvedValue(undefined);
  databaseMock.createDedicatedDatabaseClient.mockReturnValue(dedicatedClientMock);
  databaseMock.pool.connect.mockResolvedValue(poolClientMock);
  poolClientMock.query.mockImplementation(async (sql: string) => lockResult(sql));
});

describe('gateway lifecycle advisory lock', () => {
  it('gives entitlement transactions the exact same durable cross-replica lock key', async () => {
    const transactionClient = { query: vi.fn().mockResolvedValue({ rows: [{}] }) };

    await acquireUserGatewayLifecycleTransactionLock(transactionClient as never, 'user-1');

    expect(transactionClient.query).toHaveBeenCalledWith(
      expect.stringContaining('pg_advisory_xact_lock'),
      ['remclaw-gateway-lifecycle', 'user-1'],
    );
  });

  it('holds a native blocking lock through work and closes its dedicated session', async () => {
    const events: string[] = [];
    dedicatedClientMock.query.mockImplementation(async (sql: string) => {
      events.push(
        sql.includes('pg_advisory_unlock') ? 'unlock'
          : sql.includes('set_config') ? 'statement-timeout'
            : 'lock',
      );
      return lockResult(sql);
    });

    await expect(withUserGatewayLifecycleLock('user-1', async () => {
      events.push('work');
      return 'done';
    })).resolves.toBe('done');

    expect(events).toEqual(['lock', 'statement-timeout', 'work', 'unlock']);
    expect(dedicatedClientMock.connect).toHaveBeenCalledOnce();
    expect(dedicatedClientMock.query).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining('pg_advisory_lock'),
      ['remclaw-gateway-lifecycle', 'user-1'],
    );
    expect(dedicatedClientMock.end).toHaveBeenCalledOnce();
    expect(databaseMock.pool.connect).not.toHaveBeenCalled();
  });

  it('uses the old-replica-compatible lock key for blocking owners and non-blocking wakes', async () => {
    await withUserGatewayLifecycleLock('shared-user', async () => undefined);
    await tryWithUserGatewayLifecycleLock('shared-user', async () => undefined);

    expect(dedicatedClientMock.query).toHaveBeenCalledWith(
      'SELECT pg_advisory_lock(hashtext($1), hashtext($2))',
      ['remclaw-gateway-lifecycle', 'shared-user'],
    );
    expect(poolClientMock.query).toHaveBeenCalledWith(
      'SELECT pg_try_advisory_lock(hashtext($1), hashtext($2)) AS acquired',
      ['remclaw-gateway-lifecycle', 'shared-user'],
    );
    const allSql = [
      ...dedicatedClientMock.query.mock.calls.map(([sql]) => sql),
      ...poolClientMock.query.mock.calls.map(([sql]) => sql),
    ].join('\n');
    expect(allSql).not.toContain('gateway_lifecycle_waiters');
  });

  it('refuses wake work immediately while another owner holds the lock', async () => {
    poolClientMock.query.mockResolvedValueOnce({ rows: [{ acquired: false }] });
    const work = vi.fn();

    await expect(tryWithUserGatewayLifecycleLock('user-1', work))
      .resolves.toEqual({ acquired: false });
    expect(work).not.toHaveBeenCalled();
    expect(poolClientMock.release).toHaveBeenCalledWith(false);
  });

  it('uses a dedicated session for a successful fail-fast interactive mutation', async () => {
    await expect(tryWithUserGatewayLifecycleMutationLock('interactive-success', async () => 42))
      .resolves.toEqual({ acquired: true, value: 42 });

    expect(dedicatedClientMock.connect).toHaveBeenCalledOnce();
    expect(dedicatedClientMock.query).toHaveBeenCalledWith(
      'SELECT pg_try_advisory_lock(hashtext($1), hashtext($2)) AS acquired',
      ['remclaw-gateway-lifecycle', 'interactive-success'],
    );
    expect(dedicatedClientMock.query).toHaveBeenCalledWith(
      "SELECT set_config('statement_timeout', $1, false)",
      [`${GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_MS}ms`],
    );
    expect(dedicatedClientMock.end).toHaveBeenCalledOnce();
    expect(databaseMock.pool.connect).not.toHaveBeenCalled();
  });

  it('fails an interactive mutation immediately while the dedicated owner lane is occupied', async () => {
    const releases: Array<() => void> = [];
    const clients = [makeDedicatedClient(), makeDedicatedClient()];
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const held = (label: string) => withUserGatewayLifecycleLock(label, async () => {
      await new Promise<void>((resolve) => releases.push(resolve));
    });
    const first = held('owner-1');
    const second = held('owner-2');
    while (releases.length < 2) await Promise.resolve();

    const work = vi.fn();
    await expect(tryWithUserGatewayLifecycleMutationLock('interactive-busy', work))
      .resolves.toEqual({ acquired: false });
    expect(work).not.toHaveBeenCalled();

    releases.forEach((release) => release());
    await Promise.all([first, second]);
  });

  it('fails an interactive mutation immediately behind an active same-user owner', async () => {
    let releaseOwner: (() => void) | undefined;
    const owner = withUserGatewayLifecycleLock('same-user', async () => {
      await new Promise<void>((resolve) => { releaseOwner = resolve; });
    });
    while (!releaseOwner) await Promise.resolve();

    const work = vi.fn();
    await expect(tryWithUserGatewayLifecycleMutationLock('same-user', work))
      .resolves.toEqual({ acquired: false });
    expect(work).not.toHaveBeenCalled();

    releaseOwner();
    await owner;
  });

  it('unlocks after successful non-blocking wake work', async () => {
    await expect(tryWithUserGatewayLifecycleLock('wake-success', async () => 42))
      .resolves.toEqual({ acquired: true, value: 42 });
    expect(poolClientMock.query).toHaveBeenCalledTimes(2);
    expect(poolClientMock.release).toHaveBeenCalledWith(false);
  });

  it('discards a pooled wake client when advisory unlock cannot be confirmed', async () => {
    poolClientMock.query
      .mockResolvedValueOnce({ rows: [{ acquired: true }] })
      .mockRejectedValueOnce(new Error('connection interrupted'));

    await expect(tryWithUserGatewayLifecycleLock('wake-discard', async () => 'done'))
      .resolves.toEqual({ acquired: true, value: 'done' });
    expect(poolClientMock.release).toHaveBeenCalledWith(true);
  });

  it('discards a pooled wake client when lock acquisition is ambiguous', async () => {
    poolClientMock.query.mockRejectedValueOnce(new Error('response lost after query'));

    await expect(tryWithUserGatewayLifecycleLock('wake-ambiguous', async () => 'unused'))
      .rejects.toThrow('response lost after query');
    expect(poolClientMock.release).toHaveBeenCalledWith(true);
  });

  it('bounds a stalled unlock and closes the dedicated session', async () => {
    expect(GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS).toBe(2_000);
    vi.useFakeTimers();
    dedicatedClientMock.query
      .mockResolvedValueOnce({ rows: [{}] })
      .mockResolvedValueOnce({ rows: [{}] })
      .mockImplementationOnce(() => new Promise(() => {}));

    const operation = withUserGatewayLifecycleLock('blocking-stalled-unlock', async () => 'done');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS);

    await expect(operation).resolves.toBe('done');
    expect(dedicatedClientMock.end).toHaveBeenCalledOnce();
    vi.useRealTimers();
  });

  it('does not expose lifecycle work when statement-timeout setup stalls', async () => {
    expect(GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS).toBe(2_000);
    expect(GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_MS).toBe(5_000);
    vi.useFakeTimers();
    dedicatedClientMock.query
      .mockResolvedValueOnce({ rows: [{}] })
      .mockImplementationOnce(() => new Promise(() => {}));
    const work = vi.fn();

    const operation = withUserGatewayLifecycleLock('statement-timeout-stalled', work);
    const rejection = expect(operation).rejects.toThrow('lifecycle statement timeout setup exceeded');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS);
    await rejection;

    expect(work).not.toHaveBeenCalled();
    expect(dedicatedClientMock.end).toHaveBeenCalledOnce();
    vi.useRealTimers();
  });

  it('bounds a stalled blocking acquisition and releases fair local capacity', async () => {
    expect(GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS).toBe(120_000);
    vi.useFakeTimers();
    dedicatedClientMock.query.mockImplementationOnce(() => new Promise(() => {}));

    const stalled = withUserGatewayLifecycleLock('blocking-stalled-acquire', vi.fn());
    const rejection = expect(stalled).rejects.toThrow('blocking advisory lock acquisition timed out');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS);
    await rejection;
    expect(dedicatedClientMock.end).toHaveBeenCalledOnce();

    const recovered = makeDedicatedClient();
    databaseMock.createDedicatedDatabaseClient.mockReturnValueOnce(recovered);
    await expect(withUserGatewayLifecycleLock('blocking-recovered', async () => 'done'))
      .resolves.toBe('done');
    vi.useRealTimers();
  });

  it('admits blocking owners in FIFO order with bounded dedicated connections', async () => {
    expect(MAX_CONCURRENT_GATEWAY_LIFECYCLE_CLIENTS).toBe(2);
    const clients = Array.from({ length: 4 }, () => makeDedicatedClient());
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const started: string[] = [];
    const releases = new Map<string, () => void>();
    const held = (label: string) => withUserGatewayLifecycleLock(label, async () => {
      started.push(label);
      await new Promise<void>((resolve) => releases.set(label, resolve));
    });

    const first = held('first');
    const second = held('second');
    while (started.length < 2) await Promise.resolve();
    const third = held('third');
    const fourth = held('fourth');
    await Promise.resolve();
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(2);

    releases.get('first')?.();
    while (started.length < 3) await Promise.resolve();
    expect(started).toEqual(['first', 'second', 'third']);
    releases.get('second')?.();
    while (started.length < 4) await Promise.resolve();
    expect(started).toEqual(['first', 'second', 'third', 'fourth']);

    releases.get('third')?.();
    releases.get('fourth')?.();
    await Promise.all([first, second, third, fourth]);
  });

  it('does not let duplicate owners for one user consume unrelated-user capacity', async () => {
    const clients = Array.from({ length: 3 }, () => makeDedicatedClient());
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const started: string[] = [];
    const releases = new Map<string, () => void>();
    const held = (userId: string, label: string) => withUserGatewayLifecycleLock(userId, async () => {
      started.push(label);
      await new Promise<void>((resolve) => releases.set(label, resolve));
    });

    const first = held('same-user', 'same-1');
    while (started.length < 1) await Promise.resolve();
    const duplicate = held('same-user', 'same-2');
    const unrelated = held('other-user', 'other');
    while (started.length < 2) await Promise.resolve();

    expect(started).toEqual(['same-1', 'other']);
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(2);
    releases.get('same-1')?.();
    while (started.length < 3) await Promise.resolve();
    expect(started).toEqual(['same-1', 'other', 'same-2']);

    releases.get('other')?.();
    releases.get('same-2')?.();
    await Promise.all([first, duplicate, unrelated]);
  });

  it('does not make wakes compete with occupied blocking-owner capacity', async () => {
    expect(MAX_CONCURRENT_GATEWAY_WAKE_CLIENTS).toBe(2);
    const clients = [makeDedicatedClient(), makeDedicatedClient()];
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const releases: Array<() => void> = [];
    const held = (label: string) => withUserGatewayLifecycleLock(label, async () => {
      await new Promise<void>((resolve) => releases.push(resolve));
    });
    const first = held('owner-1');
    const second = held('owner-2');
    while (releases.length < 2) await Promise.resolve();

    await expect(tryWithUserGatewayLifecycleLock('wake-user', async () => 'awake'))
      .resolves.toEqual({ acquired: true, value: 'awake' });
    expect(databaseMock.pool.connect).toHaveBeenCalledOnce();

    releases.forEach((release) => release());
    await Promise.all([first, second]);
  });

  it('caps config reconciliation at four dedicated clients and fails excess work without queuing', async () => {
    expect(MAX_CONCURRENT_GATEWAY_CONFIG_RECONCILIATIONS).toBe(4);
    const clients = Array.from({ length: 4 }, () => makeDedicatedClient());
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const releases: Array<() => void> = [];
    const held = Array.from({ length: 4 }, (_, index) =>
      tryWithUserGatewayConfigReconciliationLock(`reconcile-${index}`, async () => {
        await new Promise<void>(resolve => releases.push(resolve));
      }));
    while (releases.length < 4) await Promise.resolve();

    await expect(tryWithUserGatewayConfigReconciliationLock('reconcile-excess', async () => 'unused'))
      .resolves.toEqual({ acquired: false });
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(4);

    releases.forEach(release => release());
    await Promise.all(held);
  });

  it('fails a duplicate reconciliation fast and gives an active destructive owner priority', async () => {
    const clients = [makeDedicatedClient(), makeDedicatedClient()];
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    let releaseOwner: (() => void) | undefined;
    const owner = withUserGatewayLifecycleLock('priority-user', async () => {
      await new Promise<void>(resolve => { releaseOwner = resolve; });
    });
    while (!releaseOwner) await Promise.resolve();

    await expect(tryWithUserGatewayConfigReconciliationLock('priority-user', async () => 'unused'))
      .resolves.toEqual({ acquired: false });
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(1);

    releaseOwner();
    await owner;
  });

  it('fails a same-user reconciliation duplicate without opening or queueing another client', async () => {
    const client = makeDedicatedClient();
    databaseMock.createDedicatedDatabaseClient.mockReturnValue(client);
    let releaseFirst: (() => void) | undefined;
    const first = tryWithUserGatewayConfigReconciliationLock('duplicate-user', async () => {
      await new Promise<void>(resolve => { releaseFirst = resolve; });
    });
    while (!releaseFirst) await Promise.resolve();

    await expect(tryWithUserGatewayConfigReconciliationLock('duplicate-user', async () => 'unused'))
      .resolves.toEqual({ acquired: false });
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(1);

    releaseFirst();
    await first;
  });

  it('keeps reconciliation capacity independent from the destructive owner FIFO', async () => {
    const clients = Array.from({ length: 6 }, () => makeDedicatedClient());
    databaseMock.createDedicatedDatabaseClient.mockImplementation(() => clients.shift());
    const releases: Array<() => void> = [];
    const reconciliations = Array.from({ length: 4 }, (_, index) =>
      tryWithUserGatewayConfigReconciliationLock(`config-${index}`, async () => {
        await new Promise<void>(resolve => releases.push(resolve));
      }));
    while (releases.length < 4) await Promise.resolve();

    let ownerStarted = false;
    const owner = withUserGatewayLifecycleLock('unrelated-owner', async () => {
      ownerStarted = true;
    });
    while (!ownerStarted) await Promise.resolve();
    await owner;
    expect(databaseMock.createDedicatedDatabaseClient).toHaveBeenCalledTimes(5);

    releases.forEach(release => release());
    await Promise.all(reconciliations);
  });

  it('destroys a config-reconciliation session when try-lock ownership is ambiguous', async () => {
    dedicatedClientMock.query.mockRejectedValueOnce(new Error('response lost after try-lock'));

    await expect(tryWithUserGatewayConfigReconciliationLock('ambiguous-config', async () => 'unused'))
      .rejects.toThrow('response lost after try-lock');
    expect(dedicatedClientMock.connection.stream.destroy).toHaveBeenCalledOnce();
    expect(dedicatedClientMock.end).not.toHaveBeenCalled();
  });

  it('destroys a config-reconciliation session when unlock ownership is ambiguous', async () => {
    dedicatedClientMock.query
      .mockResolvedValueOnce({ rows: [{ acquired: true }] })
      .mockResolvedValueOnce({ rows: [{}] })
      .mockRejectedValueOnce(new Error('response lost after unlock'));

    await expect(tryWithUserGatewayConfigReconciliationLock('ambiguous-unlock', async () => 'done'))
      .resolves.toEqual({ acquired: true, value: 'done' });
    expect(dedicatedClientMock.connection.stream.destroy).toHaveBeenCalledOnce();
    expect(dedicatedClientMock.end).not.toHaveBeenCalled();
  });

  it('bounds a stalled non-blocking lock attempt and discards the pooled client', async () => {
    expect(GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS).toBe(2_000);
    vi.useFakeTimers();
    poolClientMock.query.mockImplementationOnce(() => new Promise(() => {}));

    const operation = tryWithUserGatewayLifecycleLock('wake-stalled-acquire', vi.fn());
    const rejection = expect(operation).rejects.toThrow('advisory lock attempt timed out');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS);
    await rejection;
    expect(poolClientMock.release).toHaveBeenCalledWith(true);
    vi.useRealTimers();
  });

  it('releases wake capacity when pooled database checkout stalls', async () => {
    expect(GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS).toBe(2_000);
    vi.useFakeTimers();
    databaseMock.pool.connect.mockImplementationOnce(() => new Promise(() => {}));

    const stalled = tryWithUserGatewayLifecycleLock('checkout-stalled', vi.fn());
    const rejection = expect(stalled).rejects.toThrow('database client checkout timed out');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS);
    await rejection;

    await expect(tryWithUserGatewayLifecycleLock('checkout-recovered', async () => 'done'))
      .resolves.toEqual({ acquired: true, value: 'done' });
    vi.useRealTimers();
  });

  it('returns a pooled checkout delivered after timeout and releases the user slot', async () => {
    vi.useFakeTimers();
    let deliverLateClient: ((client: typeof poolClientMock) => void) | undefined;
    databaseMock.pool.connect.mockImplementationOnce(() => new Promise((resolve) => {
      deliverLateClient = resolve;
    }));

    const stalled = tryWithUserGatewayLifecycleLock('late-checkout', vi.fn());
    const rejection = expect(stalled).rejects.toThrow('database client checkout timed out');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS);
    await rejection;

    deliverLateClient?.(poolClientMock);
    await Promise.resolve();
    expect(poolClientMock.release).toHaveBeenCalledWith(false);
    await expect(tryWithUserGatewayLifecycleLock('late-checkout', async () => 'recovered'))
      .resolves.toEqual({ acquired: true, value: 'recovered' });
    vi.useRealTimers();
  });

  it('bounds a stalled dedicated-client close without consuming local capacity forever', async () => {
    expect(GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS).toBe(2_000);
    vi.useFakeTimers();
    dedicatedClientMock.end.mockImplementationOnce(() => new Promise(() => {}));

    const operation = withUserGatewayLifecycleLock('close-stalled', async () => 'done');
    await vi.advanceTimersByTimeAsync(GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS);
    await expect(operation).resolves.toBe('done');
    expect(dedicatedClientMock.connection.stream.destroy).toHaveBeenCalledOnce();
    expect(dedicatedClientMock.connection.stream.destroy).toHaveBeenCalledWith();

    const recovered = makeDedicatedClient();
    databaseMock.createDedicatedDatabaseClient.mockReturnValueOnce(recovered);
    await expect(withUserGatewayLifecycleLock('close-recovered', async () => 'done'))
      .resolves.toBe('done');
    vi.useRealTimers();
  });
});
