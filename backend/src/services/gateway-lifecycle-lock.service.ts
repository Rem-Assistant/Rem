import type { Client, PoolClient } from 'pg';
import { createDedicatedDatabaseClient, pool } from '../db/pool.js';

const LOCK_NAMESPACE = 'remclaw-gateway-lifecycle';
export const MAX_CONCURRENT_GATEWAY_LIFECYCLE_CLIENTS = 2;
export const MAX_CONCURRENT_GATEWAY_WAKE_CLIENTS = 2;
export const MAX_CONCURRENT_GATEWAY_CONFIG_RECONCILIATIONS = 4;
export const GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS = 2_000;
export const GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS = 2_000;
export const GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS = 120_000;
export const GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_MS = 5_000;
export const GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS = 2_000;
export const GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS = 2_000;
export const GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS = 2_000;

export type GatewayLifecycleDatabaseClient = Pick<PoolClient, 'query'>;

/**
 * Makes a short caller-owned PostgreSQL transaction participate in the same durable per-user fence
 * as gateway lifecycle mutations. Acquire this before any row lock; pool claiming uses it to reserve
 * one durable assignment without opening a long-lived lifecycle-owner session.
 */
export async function acquireUserGatewayLifecycleTransactionLock(
  client: GatewayLifecycleDatabaseClient,
  userId: string,
): Promise<void> {
  await client.query(
    'SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))',
    [LOCK_NAMESPACE, userId],
  );
}

class LifecycleClientLimiter {
  private active = 0;

  constructor(private readonly maximum: number) {}

  tryAcquire(): (() => void) | null {
    if (this.active >= this.maximum) return null;
    this.active += 1;
    return this.makeRelease();
  }

  private makeRelease(): () => void {
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active -= 1;
    };
  }
}

class FairLifecycleClientLimiter {
  private active = 0;
  private readonly waiters: Array<(release: () => void) => void> = [];

  constructor(private readonly maximum: number) {}

  acquire(): Promise<() => void> {
    if (this.active < this.maximum) {
      this.active += 1;
      return Promise.resolve(this.makeRelease());
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  tryAcquire(): (() => void) | null {
    // Do not let an interactive caller jump ahead of an owner already queued FIFO.
    if (this.active >= this.maximum || this.waiters.length > 0) return null;
    this.active += 1;
    return this.makeRelease();
  }

  private makeRelease(): () => void {
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const next = this.waiters.shift();
      if (next) {
        // Transfer the reserved slot directly to the FIFO head. A new caller cannot race a queued
        // owner for capacity between release and wake-up.
        next(this.makeRelease());
      } else {
        this.active -= 1;
      }
    };
  }
}

// Blocking owners use dedicated PostgreSQL sessions, never the shared application pool. Admission
// is FIFO and bounded so a burst cannot create an unbounded number of database connections.
const blockingLifecycleClientLimiter = new FairLifecycleClientLimiter(
  MAX_CONCURRENT_GATEWAY_LIFECYCLE_CLIENTS,
);

// Wake remains best-effort and non-blocking. Give it a separate bounded share of the shared pool so
// it cannot race or starve queued destructive owners for their dedicated capacity.
const wakeLifecycleClientLimiter = new LifecycleClientLimiter(
  MAX_CONCURRENT_GATEWAY_WAKE_CLIENTS,
);
// Config reconciliation may spend most of its callback doing remote Composio/gateway I/O. Keep
// those dedicated sessions out of the destructive-owner FIFO so routine status bursts cannot
// delay migration/deletion. Admission is deliberately fail-fast: there is no local waiter queue.
const configReconciliationClientLimiter = new LifecycleClientLimiter(
  MAX_CONCURRENT_GATEWAY_CONFIG_RECONCILIATIONS,
);

class PerUserLifecycleLimiter {
  private readonly active = new Set<string>();

  tryAcquire(userId: string): (() => void) | null {
    if (this.active.has(userId)) return null;
    this.active.add(userId);
    return this.makeRelease(userId);
  }

  private makeRelease(userId: string): () => void {
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active.delete(userId);
    };
  }
}

class FairPerUserLifecycleLimiter {
  private readonly active = new Set<string>();
  private readonly waiters = new Map<string, Array<(release: () => void) => void>>();

  acquire(userId: string): Promise<() => void> {
    if (!this.active.has(userId)) {
      this.active.add(userId);
      return Promise.resolve(this.makeRelease(userId));
    }
    return new Promise((resolve) => {
      const queue = this.waiters.get(userId) ?? [];
      queue.push(resolve);
      this.waiters.set(userId, queue);
    });
  }

  tryAcquire(userId: string): (() => void) | null {
    if (this.active.has(userId) || (this.waiters.get(userId)?.length ?? 0) > 0) return null;
    this.active.add(userId);
    return this.makeRelease(userId);
  }

  private makeRelease(userId: string): () => void {
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const queue = this.waiters.get(userId);
      const next = queue?.shift();
      if (next) {
        if (queue?.length === 0) this.waiters.delete(userId);
        next(this.makeRelease(userId));
      } else {
        this.waiters.delete(userId);
        this.active.delete(userId);
      }
    };
  }
}

// Collapse duplicate non-blocking wakes before they can reserve one of the two wake pool slots.
const perUserLifecycleLimiter = new PerUserLifecycleLimiter();
// Only one blocking owner per user may consume a dedicated session. Later same-user owners wait
// locally in FIFO order, leaving the second global slot available to unrelated users.
const blockingPerUserLifecycleLimiter = new FairPerUserLifecycleLimiter();

export type GatewayLifecycleLockAttempt<T> =
  | { acquired: true; value: T }
  | { acquired: false };

async function unlock(client: GatewayLifecycleDatabaseClient, userId: string): Promise<boolean> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    const result = await Promise.race([
      client.query<{ unlocked: boolean }>(
        'SELECT pg_advisory_unlock(hashtext($1), hashtext($2)) AS unlocked',
        [LOCK_NAMESPACE, userId],
      ),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(`advisory unlock timed out after ${GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS}ms`)),
          GATEWAY_LIFECYCLE_UNLOCK_TIMEOUT_MS,
        );
      }),
    ]);
    const unlocked = result.rows[0]?.unlocked === true;
    if (!unlocked) {
      console.error(`[gateway-lifecycle] database did not confirm unlock for user ${userId}`);
    }
    return unlocked;
  } catch (error) {
    // Closing or discarding this session releases any advisory lock automatically. Log cleanup
    // failures without replacing a completed lifecycle operation's result.
    console.error(`[gateway-lifecycle] failed to release lock for user ${userId}:`, error);
    return false;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function connectPooledLifecycleClient(): Promise<PoolClient> {
  const checkout = pool.connect();
  return new Promise((resolve, reject) => {
    let finished = false;
    const timeout = setTimeout(() => {
      finished = true;
      reject(new Error(`database client checkout timed out after ${GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS}ms`));
    }, GATEWAY_LIFECYCLE_CONNECT_TIMEOUT_MS);

    checkout.then(
      (client) => {
        if (finished) {
          // PostgreSQL cannot cancel a queued pool checkout. Return a late unused client rather
          // than silently leaking it.
          client.release(false);
          return;
        }
        finished = true;
        clearTimeout(timeout);
        resolve(client);
      },
      (error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        reject(error);
      },
    );
  });
}

async function tryAcquireDatabaseLock(client: GatewayLifecycleDatabaseClient, userId: string): Promise<boolean> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    const result = await Promise.race([
      client.query<{ acquired: boolean }>(
        'SELECT pg_try_advisory_lock(hashtext($1), hashtext($2)) AS acquired',
        [LOCK_NAMESPACE, userId],
      ),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(`advisory lock attempt timed out after ${GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS}ms`)),
          GATEWAY_LIFECYCLE_ACQUIRE_TIMEOUT_MS,
        );
      }),
    ]);
    return result.rows[0]?.acquired === true;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function acquireBlockingDatabaseLock(client: Client, userId: string): Promise<void> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      client.query(
        'SELECT pg_advisory_lock(hashtext($1), hashtext($2))',
        [LOCK_NAMESPACE, userId],
      ),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(
            `blocking advisory lock acquisition timed out after ${GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS}ms`,
          )),
          GATEWAY_LIFECYCLE_BLOCKING_ACQUIRE_TIMEOUT_MS,
        );
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function configureLifecycleStatementTimeout(client: Client): Promise<void> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      client.query(
        "SELECT set_config('statement_timeout', $1, false)",
        [`${GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_MS}ms`],
      ),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(
            `lifecycle statement timeout setup exceeded ${GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS}ms`,
          )),
          GATEWAY_LIFECYCLE_STATEMENT_TIMEOUT_SETUP_MS,
        );
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function closeDedicatedClient(client: Client): Promise<void> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      client.end(),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error(`database client close timed out after ${GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS}ms`)),
          GATEWAY_LIFECYCLE_CLOSE_TIMEOUT_MS,
        );
      }),
    ]);
  } catch (error) {
    console.error('[gateway-lifecycle] failed to close dedicated database client:', error);
    // pg.Client.end() normally destroys the stream immediately when a query is active. Force the
    // same terminal state if end itself rejects or exceeds our cleanup deadline, so local capacity
    // is never released while a hidden session could still retain its advisory lock.
    const stream = (client as unknown as {
      connection?: { stream?: { destroy: () => void } };
    }).connection?.stream;
    // Do not pass the close error into Socket.destroy(). An error argument makes the socket emit an
    // `error` event; these dedicated clients have no long-lived error listener, so that cleanup path
    // could otherwise become an unhandled event and terminate the backend.
    stream?.destroy();
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function destroyDedicatedClient(client: Client): void {
  (client as unknown as { connection?: { stream?: { destroy: () => void } } })
    .connection?.stream?.destroy();
}

/**
 * Serializes destructive gateway lifecycle work for one user across backend processes.
 * The owner waits on a dedicated PostgreSQL session so old and new replicas see the same native
 * advisory-lock queue without consuming an application-pool checkout.
 */
export async function withUserGatewayLifecycleLock<T>(
  userId: string,
  work: (client: GatewayLifecycleDatabaseClient) => Promise<T>,
): Promise<T> {
  // Serialize duplicates before global admission so one busy user cannot consume every dedicated
  // slot. Neither local wait opens a socket.
  const releaseUser = await blockingPerUserLifecycleLimiter.acquire(userId);
  let releasePermit: (() => void) | undefined;
  let client: Client | undefined;
  let acquired = false;
  try {
    // Once admitted, PostgreSQL's own advisory-lock queue is the cross-replica source of truth,
    // including during rolling deploys with older replicas.
    releasePermit = await blockingLifecycleClientLimiter.acquire();
    client = createDedicatedDatabaseClient();
    await client.connect();
    await acquireBlockingDatabaseLock(client, userId);
    acquired = true;
    // Install the bound only after the intentionally longer advisory-lock wait. Every database
    // read/write performed by the callback then inherits PostgreSQL's server-side deadline,
    // including callers that spend most of their HTTP budget on Fly or gateway work first.
    await configureLifecycleStatementTimeout(client);
    return await work(client);
  } finally {
    if (client) {
      if (acquired) await unlock(client, userId);
      await closeDedicatedClient(client);
    }
    releasePermit?.();
    releaseUser();
  }
}

/**
 * Attempts the dedicated lifecycle-owner lane without joining either FIFO queue. Interactive
 * mutations use this form so they fail fast behind migration/deletion work while retaining the
 * dedicated PostgreSQL session required by a long-running destructive callback.
 */
export async function tryWithUserGatewayLifecycleMutationLock<T>(
  userId: string,
  work: (client: GatewayLifecycleDatabaseClient) => Promise<T>,
): Promise<GatewayLifecycleLockAttempt<T>> {
  const releaseUser = blockingPerUserLifecycleLimiter.tryAcquire(userId);
  if (!releaseUser) return { acquired: false };

  const releasePermit = blockingLifecycleClientLimiter.tryAcquire();
  if (!releasePermit) {
    releaseUser();
    return { acquired: false };
  }

  let client: Client | undefined;
  let acquired = false;
  try {
    client = createDedicatedDatabaseClient();
    await client.connect();
    acquired = await tryAcquireDatabaseLock(client, userId);
    if (!acquired) return { acquired: false };
    await configureLifecycleStatementTimeout(client);
    return { acquired: true, value: await work(client) };
  } finally {
    if (client) {
      if (acquired) await unlock(client, userId);
      await closeDedicatedClient(client);
    }
    releasePermit();
    releaseUser();
  }
}

/**
 * Attempts a dedicated, bounded config-reconciliation lane without joining any local queue.
 * PostgreSQL uses the same advisory namespace as destructive lifecycle work, so a successful
 * callback is fenced across replicas while its local capacity remains completely independent.
 */
export async function tryWithUserGatewayConfigReconciliationLock<T>(
  userId: string,
  work: (client: GatewayLifecycleDatabaseClient) => Promise<T>,
): Promise<GatewayLifecycleLockAttempt<T>> {
  // Share the destructive per-user gate so an active or already-queued owner has priority. This
  // does not share destructive global capacity: reconciliation still uses its own four permits.
  const releaseUser = blockingPerUserLifecycleLimiter.tryAcquire(userId);
  if (!releaseUser) return { acquired: false };

  const releasePermit = configReconciliationClientLimiter.tryAcquire();
  if (!releasePermit) {
    releaseUser();
    return { acquired: false };
  }

  let client: Client | undefined;
  let acquired = false;
  let discardClient = false;
  try {
    client = createDedicatedDatabaseClient();
    await client.connect();
    // A rejected/timed-out try-lock query is ambiguous: PostgreSQL may have processed it. Never
    // gracefully return that session to a state where a hidden advisory lock could linger.
    discardClient = true;
    acquired = await tryAcquireDatabaseLock(client, userId);
    discardClient = false;
    if (!acquired) return { acquired: false };
    await configureLifecycleStatementTimeout(client);
    return { acquired: true, value: await work(client) };
  } finally {
    if (client) {
      if (discardClient) {
        destroyDedicatedClient(client);
      } else if (acquired) {
        const unlocked = await unlock(client, userId);
        if (unlocked) await closeDedicatedClient(client);
        else destroyDedicatedClient(client);
      } else {
        await closeDedicatedClient(client);
      }
    }
    releasePermit();
    releaseUser();
  }
}

/**
 * Attempts the same per-user lifecycle lock without waiting. A false result means another owner
 * has the gateway and the caller must not read stale metadata or start its source Machine.
 */
export async function tryWithUserGatewayLifecycleLock<T>(
  userId: string,
  work: (client: PoolClient) => Promise<T>,
): Promise<GatewayLifecycleLockAttempt<T>> {
  const releaseUser = perUserLifecycleLimiter.tryAcquire(userId);
  if (!releaseUser) return { acquired: false };

  // Wake has its own bounded pool share. Blocking owners never compete for these permits and are
  // already visible through PostgreSQL's native advisory-lock queue.
  const releasePermit = wakeLifecycleClientLimiter.tryAcquire();
  if (!releasePermit) {
    releaseUser();
    return { acquired: false };
  }

  let client: PoolClient | undefined;
  let acquired = false;
  let discardClient = false;
  try {
    client = await connectPooledLifecycleClient();
    // Until PostgreSQL confirms the result, the session may own the advisory lock even if the
    // query rejects after processing. An ambiguous pool session must be discarded.
    discardClient = true;
    acquired = await tryAcquireDatabaseLock(client, userId);
    discardClient = false;
    if (!acquired) return { acquired: false };
    return { acquired: true, value: await work(client) };
  } finally {
    if (client) {
      if (acquired) discardClient = !(await unlock(client, userId));
      client.release(discardClient);
    }
    releasePermit();
    releaseUser();
  }
}
