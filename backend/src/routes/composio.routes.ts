import { Router, Request, Response } from 'express';
import { ComposioAuthConfigNotFoundError } from '@composio/core';
import { requireJwt } from '../middleware/auth.js';
import * as gatewayService from '../services/gateway.service.js';
import {
  COMPOSIO_TOOLKITS,
  createConnectSession,
  getConnectionStatus,
  listToolkitsSummary,
  disconnectToolkit,
  setToolkitEnabled,
  ensureComposioMcpWired,
  ComposioNotConfiguredError,
  ComposioStatusUnavailableError,
  ComposioToolkitError,
  ComposioMutationTimeoutError,
  type ComposioMutationScope,
  type ComposioToolkit,
} from '../services/composio.service.js';

/**
 * Composio connections — OAuth connectors for the agent (Gmail, Calendar, Drive, Docs, Sheets, GitHub, Slack, Notion, Linear, Todoist, Asana).
 *
 *   GET  /api/v1/composio/toolkits            — toolkits + logo + this user's per-toolkit status
 *   POST /api/v1/composio/connect             — start an OAuth connect { toolkit, callbackUrl? }
 *                                               → { redirectUrl, connectionId, toolkit }
 *   GET  /api/v1/composio/status/:connectionId — poll a connection request's status
 *   POST /api/v1/composio/toolkit/:toolkit/enabled — pause/resume { enabled } ALL of a toolkit's accounts
 *   DELETE /api/v1/composio/toolkit/:toolkit/connections — disconnect+revoke ALL of a toolkit's accounts
 *
 * All JWT-scoped to the authed user (Rem's userId == Composio's user_id). The client opens
 * `redirectUrl` in the system browser via `openURL`; Composio captures the token via its own
 * callback. See composio.service.ts.
 *
 * ── Wiring the agent's tools (#1087) ────────────────────────────────────────────────────────────
 * Connecting a toolkit here (Composio's OAuth) is necessary but not sufficient for the agent to
 * actually USE it — the gateway also needs `mcp.servers.composio` pointed at this user's per-user
 * Composio hosted-MCP endpoint (composio.service.ts `getMcpConfig` / `ensureComposioMcpWired`).
 * The routes below start `ensureComposioMcpWired` after every authoritative lifecycle transition,
 * but observe it for only a small fraction of the clients' 30-second request deadline. Responses
 * expose `runtimeReady` and `runtimeSyncing` separately from the committed Composio grant. Slow
 * reconciliation continues safely through the service's existing per-user coalescing lane; a later
 * read observes the acknowledged config. This prevents both optimistic "Active" UI and a client
 * timeout that would make a successful grant mutation look reverted.
 */
const router = Router();

function withUserId(req: Request): string {
  return (req as Request & { userId: string }).userId;
}

/**
 * Awaited sync of this user's Composio MCP endpoint into their gateway config. Grant state and
 * runtime readiness are independent: a missing gateway, busy lane, missing MCP session, or thrown
 * reconciliation error all produce an inspectable not-ready result without rewriting OAuth truth.
 */
async function syncComposioMcpRuntime(userId: string): Promise<{ ready: boolean; reason?: string }> {
  try {
    const creds = await gatewayService.getGatewayCredentials(userId)
      ?? gatewayService.getLocalGatewayCredentials();
    if (!creds) return { ready: false, reason: 'no_gateway' };
    const setupPassword = creds.hosting_provider === 'local'
      ? undefined
      : await gatewayService.getSetupPassword(userId).catch(() => undefined);
    const result = await ensureComposioMcpWired(userId, creds.gateway_url, creds.gateway_token, setupPassword);
    if (!result.wired) {
      console.warn(`[composio] mcp wiring skipped for user ${userId}: ${result.reason}`);
      return { ready: false, reason: result.reason };
    }
    return { ready: true };
  } catch (err) {
    console.error(`[composio] mcp wiring failed for user ${userId}:`, err);
    return { ready: false, reason: 'reconciliation_failed' };
  }
}

interface ComposioRuntimeReadiness {
  ready: boolean;
  syncing: boolean;
}

class ComposioConnectTimeoutError extends Error {
  constructor() {
    super("Couldn't start this connection right now. Try again in a moment.");
    this.name = 'ComposioConnectTimeoutError';
  }
}

// Production gets a brief chance to report an already-current/fast gateway as ready. Vitest uses
// a tiny deterministic window; both remain far below AuthenticatedHttpClient's 30-second timeout.
const RUNTIME_READINESS_OBSERVATION_MS = process.env.NODE_ENV === 'test' ? 10 : 2_000;
const CATALOG_OBSERVATION_MS = process.env.NODE_ENV === 'test' ? 10 : 5_000;
const MUTATION_ACK_OBSERVATION_MS = process.env.NODE_ENV === 'test' ? 10 : 2_000;
const CONNECT_SESSION_OBSERVATION_MS = process.env.NODE_ENV === 'test' ? 200 : 20_000;
const CATALOG_MUTATION_WAIT_MS = process.env.NODE_ENV === 'test' ? 100 : 5_000;
// An aborted SDK promise is not proof that the already-admitted provider request cannot commit.
// Hold the lane for a bounded quarantine, then let the newest queued desired-state operation
// authoritatively re-list and converge. The bound also prevents an abort-ignoring call from
// wedging this process forever.
const MUTATION_TIMEOUT_QUARANTINE_MS = process.env.NODE_ENV === 'test' ? 25 : 10_000;

function mutationTimeoutQuarantine(): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, MUTATION_TIMEOUT_QUARANTINE_MS));
}

/** Bounds route ownership of provider session creation. Promise.race retains handlers on the SDK
 * promise, so a late resolve/reject is consumed but cannot resume marker publication after the
 * deadline has released the admission token. */
async function observeConnectSession(
  session: ReturnType<typeof createConnectSession>,
): ReturnType<typeof createConnectSession> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new ComposioConnectTimeoutError()), CONNECT_SESSION_OBSERVATION_MS);
  });
  try {
    return await Promise.race([session, deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Starts reconciliation but bounds how long an HTTP response can wait for it. The sync promise is
 * deliberately retained by its own async work after the timeout wins; it catches every failure and
 * the underlying service coalesces same-user callers, so there is no unhandled rejection or burst. */
async function observeComposioRuntimeReadiness(userId: string): Promise<ComposioRuntimeReadiness> {
  const sync = syncComposioMcpRuntime(userId).then(result => ({
    ready: result.ready,
    // `busy` means another admitted reconciliation owns the lane and is still making progress.
    syncing: !result.ready && result.reason === 'busy',
  }));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<ComposioRuntimeReadiness>(resolve => {
    timer = setTimeout(() => resolve({ ready: false, syncing: true }), RUNTIME_READINESS_OBSERVATION_MS);
  });
  try {
    return await Promise.race([sync, deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

const catalogReads = new Map<string, ReturnType<typeof listToolkitsSummary>>();

function catalogRead(userId: string): ReturnType<typeof listToolkitsSummary> {
  const existing = catalogReads.get(userId);
  if (existing) return existing;
  const read = listToolkitsSummary(userId);
  catalogReads.set(userId, read);
  void read.then(
    () => { if (catalogReads.get(userId) === read) catalogReads.delete(userId); },
    () => { if (catalogReads.get(userId) === read) catalogReads.delete(userId); },
  );
  return read;
}

async function observeCatalogSummary(userId: string) {
  const read = catalogRead(userId);
  let timedOut = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      timedOut = true;
      reject(new ComposioStatusUnavailableError());
    }, CATALOG_OBSERVATION_MS);
  });
  try {
    return await Promise.race([read, deadline]);
  } finally {
    if (timer) clearTimeout(timer);
    // A route-level timeout must not pin a mock, buggy SDK, or otherwise never-settling read into
    // every later refresh. The old completion callback is identity-guarded and cannot evict newer.
    if (timedOut && catalogReads.get(userId) === read) catalogReads.delete(userId);
  }
}

type ComposioMutationCount = { updated: number } | { deleted: number };
const latestMutationJobs = new Map<string, {
  operationKey: string;
  job: Promise<ComposioMutationCount>;
}>();
const mutationLanes = new Map<string, Promise<void>>();
const mutationReconciliationScheduled = new WeakSet<Promise<ComposioMutationCount>>();
const mutationRepairScheduled = new WeakSet<Promise<ComposioMutationCount>>();
type DesiredMutation = {
  operationKey: string;
  operation: (isCurrent: () => boolean, isRepair: boolean) => Promise<ComposioMutationCount>;
};
const latestDesiredMutations = new Map<string, DesiredMutation>();
const mutationGenerations = new Map<string, number>();
const mutationGenerationOperationKeys = new Map<string, string>();
let nextMutationGeneration = 0;
const pendingConnectCompletions = new Map<string, {
  toolkit: ComposioToolkit;
  laneKey: string;
  admittedGeneration: number;
}>();
const inFlightConnectAdmissions = new Map<string, Set<object>>();
type StaleConnectConvergence = {
  operationKey: 'paused' | 'revoked';
  retainedMutationGeneration: number;
  requestedGeneration: number;
  settled: boolean;
  job: Promise<ComposioMutationCount>;
};
const staleConnectConvergenceJobs = new Map<string, StaleConnectConvergence>();
const staleConnectRuntimeReconciliationScheduled = new WeakSet<StaleConnectConvergence>();
const staleConnectRuntimeReconciled = new WeakSet<StaleConnectConvergence>();

/** Generation retention outlives every pending Connect marker, preventing `undefined -> intent ->
 * undefined` ABA when the richer desired-operation cache expires. Keep only one integer per live
 * lane, and retry cleanup while a marker still depends on it. */
function scheduleMutationGenerationExpiry(laneKey: string, generation: number): void {
  const retentionMs = process.env.NODE_ENV === 'test' ? 6_000 : 20 * 60_000;
  const timer = setTimeout(() => {
    if (mutationGenerations.get(laneKey) !== generation) return;
    if ([...pendingConnectCompletions.values()].some(marker => marker.laneKey === laneKey)
      || (inFlightConnectAdmissions.get(laneKey)?.size ?? 0) > 0) {
      scheduleMutationGenerationExpiry(laneKey, generation);
      return;
    }
    mutationGenerations.delete(laneKey);
    mutationGenerationOperationKeys.delete(laneKey);
  }, retentionMs);
  timer.unref?.();
}

/** Captures the original mutation's account identities and supplies only that immutable set to
 * late repairs. Repairs still re-list current provider status, but cannot target an OAuth grant
 * created after the original request even if generation changes while a provider write awaits. */
function identityScopedMutation(
  operation: (scope: ComposioMutationScope) => Promise<ComposioMutationCount>,
): (isCurrent: () => boolean, isRepair: boolean) => Promise<ComposioMutationCount> {
  let originalAccountIds: readonly string[] | undefined;
  return (isCurrent, isRepair) => {
    // A timeout before the original list completes has no safe identity scope. Never reinterpret
    // that unknown set as an authoritative empty result or broaden a repair to replacement grants.
    if (isRepair && !originalAccountIds) {
      return Promise.reject(new ComposioMutationTimeoutError(
        'Composio mutation timed out before its repair account scope was captured',
      ));
    }
    return operation({
      isCurrent,
      repairAccountIds: isRepair ? originalAccountIds : undefined,
      captureRepairAccountIds: isRepair
        ? undefined
        : ids => { originalAccountIds = [...ids]; },
    });
  };
}

/** Test isolation for module-scoped coalescing/ordering state. Production never calls this. */
export function resetComposioRouteStateForTests(): void {
  catalogReads.clear();
  latestMutationJobs.clear();
  mutationLanes.clear();
  latestDesiredMutations.clear();
  mutationGenerations.clear();
  mutationGenerationOperationKeys.clear();
  pendingConnectCompletions.clear();
  inFlightConnectAdmissions.clear();
  staleConnectConvergenceJobs.clear();
}

function unrefDelay(ms: number): Promise<void> {
  return new Promise(resolve => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}

/** An abort acknowledgement cannot prove the remote write will not commit later. Re-run the newest
 * desired state after the quarantine and twice more across a longer uncertainty window. Each pass
 * authoritatively re-lists source statuses before mutating, so a late stale commit is detected and
 * repaired rather than trusted. Timers are unref'd and bounded; ordinary successful work creates
 * none. */
function scheduleLateMutationConvergence(
  userId: string,
  toolkit: string,
  laneKey: string,
  timedOutJob: Promise<ComposioMutationCount>,
): void {
  if (mutationRepairScheduled.has(timedOutJob)) return;
  mutationRepairScheduled.add(timedOutJob);
  const intervalMs = process.env.NODE_ENV === 'test' ? 100 : 15_000;
  void (async () => {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await unrefDelay(intervalMs);
      const desired = latestDesiredMutations.get(laneKey);
      if (!desired) return;
      const repair = enqueueMutation(
        userId, toolkit, desired.operationKey, desired.operation, false, desired,
      );
      const repaired = await repair.then(() => true, () => false);
      // Even an idempotent { updated: 0 } is authoritative convergence after an uncertain remote
      // write. Reconcile the gateway after every successful pass so cached tool scope follows the
      // final provider truth, not merely the first timed-out attempt. Do not await gateway I/O here:
      // a slow RPC must not delay the remaining provider repair passes in this bounded cadence.
      if (repaired) void syncComposioMcpRuntime(userId);
    }
  })();
}

/** A catalog snapshot taken while provider mutation is in flight can publish the old ACTIVE state
 * and clear the client's Updating presentation. Wait for every current user/toolkit lane before
 * starting the authoritative read; if a long mutation exceeds the bounded window, report 503 and
 * let the client preserve its last known state instead of publishing a stale snapshot. */
async function waitForUserMutationLanes(userId: string): Promise<void> {
  const prefix = `${userId}:`;
  const deadlineAt = Date.now() + CATALOG_MUTATION_WAIT_MS;
  while (true) {
    const active = [...mutationLanes.entries()]
      .filter(([laneKey]) => laneKey.startsWith(prefix))
      .map(([, tail]) => tail);
    if (active.length === 0) return;
    const remainingMs = deadlineAt - Date.now();
    if (remainingMs <= 0) throw new ComposioStatusUnavailableError();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new ComposioStatusUnavailableError()), remainingMs);
    });
    try {
      await Promise.race([Promise.all(active), deadline]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

/** Serializes each user's toolkit mutations and deduplicates the same desired-state job while it is
 * in flight. The provider operations are themselves idempotent, so a retry after process restart
 * simply re-lists the remaining out-of-state accounts and converges them. */
function enqueueMutation(
  userId: string,
  toolkit: string,
  operationKey: string,
  operation: (isCurrent: () => boolean, isRepair: boolean) => Promise<ComposioMutationCount>,
  allowRepairSchedule = true,
  repairGeneration?: DesiredMutation,
  deduplicateLatest = true,
): Promise<ComposioMutationCount> {
  // A catalog promise admitted before this write may resolve with pre-mutation provider truth.
  // Evict it now; its identity-guarded completion cannot remove the later post-lane read.
  catalogReads.delete(userId);
  const laneKey = `${userId}:${toolkit}`;
  const existing = latestMutationJobs.get(laneKey);
  // Dedupe only the latest desired state. In pause -> resume -> pause, the final pause must queue
  // behind resume rather than incorrectly joining the already-running first pause.
  if (deduplicateLatest && existing?.operationKey === operationKey) return existing.job;
  const desired = repairGeneration ?? { operationKey, operation };
  if (!repairGeneration) {
    const generation = ++nextMutationGeneration;
    mutationGenerations.set(laneKey, generation);
    mutationGenerationOperationKeys.set(laneKey, operationKey);
    scheduleMutationGenerationExpiry(laneKey, generation);
    latestDesiredMutations.set(laneKey, desired);
    const desiredExpiry = setTimeout(() => {
      if (latestDesiredMutations.get(laneKey) === desired) latestDesiredMutations.delete(laneKey);
    }, process.env.NODE_ENV === 'test' ? 1_000 : 180_000);
    desiredExpiry.unref?.();
  }

  const prior = mutationLanes.get(laneKey) ?? Promise.resolve();
  const job = prior.catch(() => undefined).then(() => {
    // A repair is conditional on the desired generation it observed. A newer OAuth completion or
    // user intent can supersede it while it waits in the lane; never apply stale pause/revoke work
    // to the newly connected ACTIVE grant.
    if (repairGeneration && latestDesiredMutations.get(laneKey) !== repairGeneration) {
      return { updated: 0 };
    }
    return operation(
      () => latestDesiredMutations.get(laneKey) === desired,
      repairGeneration !== undefined,
    );
  });
  const tail = job.then(
    () => undefined,
    err => err instanceof ComposioMutationTimeoutError
      ? mutationTimeoutQuarantine()
      : undefined,
  );
  latestMutationJobs.set(laneKey, { operationKey, job });
  mutationLanes.set(laneKey, tail);
  job.then(
    () => {
      if (latestMutationJobs.get(laneKey)?.job === job) latestMutationJobs.delete(laneKey);
    },
    err => {
      console.error(`[composio] background mutation failed for ${laneKey}:${operationKey}:`, err);
      if (allowRepairSchedule && err instanceof ComposioMutationTimeoutError) {
        scheduleLateMutationConvergence(userId, toolkit, laneKey, job);
      }
      if (latestMutationJobs.get(laneKey)?.job === job) latestMutationJobs.delete(laneKey);
    },
  );
  void tail.then(() => {
    if (mutationLanes.get(laneKey) === tail) mutationLanes.delete(laneKey);
  });
  return job;
}

/** A completed OAuth connection is a newer ACTIVE intent for this toolkit. Serialize an idempotent
 * resume behind any admitted mutation and publish it as the repair generation immediately, so an
 * older timed-out pause/revoke can neither enqueue nor execute against the newly linked grant. */
function recordConnectedGrantIntent(
  userId: string,
  toolkit: ComposioToolkit,
): Promise<ComposioMutationCount> {
  return enqueueMutation(
    userId,
    toolkit,
    'connected-active',
    identityScopedMutation(scope => setToolkitEnabled(userId, toolkit, true, scope)),
  );
}

/** A Connect session admitted before pause/revoke can create a brand-new ACTIVE account after the
 * original mutation authoritatively found zero targets. Reassert the retained non-active intent as
 * a fresh generation so it re-lists that new account, while preserving the ordinary timeout/repair
 * lifecycle. Never deduplicate against the earlier zero-target job: it cannot contain this grant. */
function convergeStaleConnectToRetainedIntent(
  userId: string,
  toolkit: ComposioToolkit,
  operationKey: 'paused' | 'revoked',
): StaleConnectConvergence {
  const laneKey = `${userId}:${toolkit}`;
  const retainedMutationGeneration = mutationGenerations.get(laneKey) ?? 0;
  const existing = staleConnectConvergenceJobs.get(laneKey);
  if (existing
    && !existing.settled
    && existing.operationKey === operationKey
    && existing.retainedMutationGeneration === retainedMutationGeneration) {
    // A second stale completion can become ACTIVE after the running operation has already listed
    // provider accounts. Mark the shared worker dirty instead of merely joining its old snapshot;
    // it must perform another full identity-scoped pass before any waiter can schedule runtime sync.
    existing.requestedGeneration += 1;
    return existing;
  }

  const convergence: StaleConnectConvergence = {
    operationKey,
    retainedMutationGeneration,
    requestedGeneration: 1,
    settled: false,
    job: Promise.resolve({ updated: 0 }),
  };
  convergence.job = (async () => {
    let convergedGeneration = 0;
    let result: ComposioMutationCount = operationKey === 'paused'
      ? { updated: 0 }
      : { deleted: 0 };
    while (convergedGeneration < convergence.requestedGeneration) {
      // A dirty pass is only a request to re-list while this exact retained intent still owns the
      // lane. The preceding pass may have awaited long enough for revoke/resume/a new Connect to
      // publish a newer generation. Recheck before every forced pass so the old worker cannot
      // enqueue behind that replacement and become authoritative again merely by enqueueing.
      if (mutationGenerations.get(laneKey) !== convergence.retainedMutationGeneration
        || mutationGenerationOperationKeys.get(laneKey) !== operationKey) {
        break;
      }
      const targetGeneration = convergence.requestedGeneration;
      const operation = operationKey === 'paused'
        ? identityScopedMutation(scope => setToolkitEnabled(userId, toolkit, false, scope))
        : identityScopedMutation(scope => disconnectToolkit(userId, toolkit, scope));
      const pass = operationKey === 'paused'
        ? enqueueMutation(
          userId,
          toolkit,
          operationKey,
          operation,
          false,
          undefined,
          false,
        )
        : enqueueMutation(
          userId,
          toolkit,
          operationKey,
          operation,
          false,
          undefined,
          false,
        );
      // `enqueueMutation` synchronously publishes this forced pass as the latest retained
      // generation. Track that identity so same-intent observers can dirty this worker, while a
      // later opposite user intent necessarily mismatches and creates its own worker.
      convergence.retainedMutationGeneration = mutationGenerations.get(laneKey) ?? 0;
      const desired = latestDesiredMutations.get(laneKey);
      try {
        result = await pass;
      } catch (err) {
        if (!(err instanceof ComposioMutationTimeoutError) || !desired) throw err;
        // A rejected provider pass is outcome-unknown, never convergence authority. Follow the
        // ordinary repair cadence but keep ownership here: only a successful, still-current repair
        // may resolve this worker and unlock its single runtime synchronization.
        let repaired = false;
        const intervalMs = process.env.NODE_ENV === 'test' ? 100 : 15_000;
        for (let attempt = 0; attempt < 3; attempt += 1) {
          await unrefDelay(intervalMs);
          if (latestDesiredMutations.get(laneKey) !== desired) throw err;
          const repair = enqueueMutation(
            userId,
            toolkit,
            desired.operationKey,
            desired.operation,
            false,
            desired,
          );
          try {
            result = await repair;
            repaired = true;
            break;
          } catch (repairError) {
            if (!(repairError instanceof ComposioMutationTimeoutError)) throw repairError;
          }
        }
        if (!repaired) throw err;
      }
      convergedGeneration = targetGeneration;
    }
    convergence.settled = true;
    return result;
  })();
  staleConnectConvergenceJobs.set(laneKey, convergence);
  void convergence.job.catch(() => {
    convergence.settled = true;
  });
  return convergence;
}

/** Runtime scope may be read only after the newest observed stale completion for this lane has
 * drained. An older worker that just settled follows a replacement worker instead of syncing its
 * stale generation; only the still-current retained intent reaches the runtime boundary. */
function scheduleStaleConnectReconciliation(
  userId: string,
  toolkit: ComposioToolkit,
  convergence: StaleConnectConvergence,
): void {
  if (staleConnectRuntimeReconciliationScheduled.has(convergence)) return;
  staleConnectRuntimeReconciliationScheduled.add(convergence);
  const laneKey = `${userId}:${toolkit}`;
  void (async () => {
    let candidate = convergence;
    while (true) {
      try {
        await candidate.job;
      } catch {
        // Rejection is never provider convergence. A newer replacement worker may still carry the
        // authoritative repair; otherwise stop without exposing stale ACTIVE scope to runtime.
        const replacement = staleConnectConvergenceJobs.get(laneKey);
        if (replacement && replacement !== candidate) {
          candidate = replacement;
          continue;
        }
        return;
      }
      const latest = staleConnectConvergenceJobs.get(laneKey);
      if (latest && latest !== candidate) {
        candidate = latest;
        continue;
      }
      if (latest !== candidate
        || mutationGenerations.get(laneKey) !== candidate.retainedMutationGeneration
        || mutationGenerationOperationKeys.get(laneKey) !== candidate.operationKey) {
        return;
      }
      if (staleConnectRuntimeReconciled.has(candidate)) return;
      staleConnectRuntimeReconciled.add(candidate);
      await syncComposioMcpRuntime(userId);
      return;
    }
  })();
}

function scheduleMutationReconciliation(
  userId: string,
  job: Promise<ComposioMutationCount>,
): void {
  if (mutationReconciliationScheduled.has(job)) return;
  mutationReconciliationScheduled.add(job);
  void job.then(
    () => syncComposioMcpRuntime(userId),
    err => err instanceof ComposioMutationTimeoutError
      ? mutationTimeoutQuarantine().then(() => syncComposioMcpRuntime(userId))
      : undefined,
  );
}

async function observeMutation(job: Promise<ComposioMutationCount>): Promise<{
  completed: boolean;
  result?: ComposioMutationCount;
}> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<{ completed: false }>(resolve => {
    timer = setTimeout(() => resolve({ completed: false }), MUTATION_ACK_OBSERVATION_MS);
  });
  try {
    return await Promise.race([
      job.then(result => ({ completed: true as const, result })),
      deadline,
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Map a service error to an HTTP status; default 500. */
function statusForError(err: unknown): number {
  if (err instanceof ComposioNotConfiguredError) return 503;
  if (err instanceof ComposioStatusUnavailableError) return 503;
  if (err instanceof ComposioConnectTimeoutError) return 503;
  if (err instanceof ComposioToolkitError) return 400;
  // Missing auth config is a one-time-per-toolkit ops/setup gap, not a client input error or a
  // transient failure — 503 groups it with "not configured" so the client's calm-copy path shows
  // the (actionable) message instead of a generic 500, without needing a new status branch client-side.
  if (err instanceof ComposioAuthConfigNotFoundError) return 503;
  return 500;
}

router.get('/composio/toolkits', requireJwt, async (req: Request, res: Response) => {
  const userId = withUserId(req);
  try {
    await waitForUserMutationLanes(userId);
    const summary = await observeCatalogSummary(userId);
    // Self-heal sync on every configured catalog load, including an empty account set: a failed
    // final-disconnect sync must get another chance to remove a stale cached MCP runtime.
    const runtime = summary.configured
      ? await observeComposioRuntimeReadiness(userId)
      : { ready: false, syncing: false };
    return res.json({ ...summary, runtimeReady: runtime.ready, runtimeSyncing: runtime.syncing });
  } catch (err) {
    // Status is grant-management truth, not optional enrichment. A static not-connected fallback
    // would hide live grants and enable duplicate Connect flows, so make the failure retryable and
    // let the client preserve its last known catalog state.
    const status = statusForError(err);
    console.error('[composio] toolkits summary failed:', err);
    return res.status(status).json({
      error: err instanceof Error ? err.message : 'connections status unavailable',
    });
  }
});

router.post('/composio/connect', requireJwt, async (req: Request, res: Response) => {
  const userId = withUserId(req);
  const toolkit = typeof req.body?.toolkit === 'string' ? req.body.toolkit.trim() : '';
  const callbackUrl = typeof req.body?.callbackUrl === 'string' ? req.body.callbackUrl.trim() : undefined;
  if (!toolkit) {
    return res.status(400).json({ error: 'toolkit is required' });
  }
  const admittedToolkit = (COMPOSIO_TOOLKITS as readonly string[]).includes(toolkit)
    ? (toolkit as ComposioToolkit)
    : undefined;
  // Capture lane authority before provider session creation awaits. A pause/revoke admitted while
  // that call is in flight must make the eventual Connect completion marker stale.
  const connectLaneKey = admittedToolkit ? `${userId}:${admittedToolkit}` : undefined;
  const connectAdmissionGeneration = connectLaneKey
    ? (mutationGenerations.get(connectLaneKey) ?? 0)
    : 0;
  const connectAdmissionToken = connectLaneKey ? {} : undefined;
  if (connectLaneKey && connectAdmissionToken) {
    const admissions = inFlightConnectAdmissions.get(connectLaneKey) ?? new Set<object>();
    admissions.add(connectAdmissionToken);
    inFlightConnectAdmissions.set(connectLaneKey, admissions);
  }
  try {
    const session = await observeConnectSession(
      createConnectSession(userId, toolkit, callbackUrl || undefined),
    );
    const sessionToolkit = session.toolkit as ComposioToolkit;
    const completionKey = `${userId}:${session.connectionId}`;
    if (admittedToolkit === sessionToolkit && connectLaneKey) {
      const completion = {
        toolkit: sessionToolkit,
        laneKey: connectLaneKey,
        admittedGeneration: connectAdmissionGeneration,
      };
      pendingConnectCompletions.set(completionKey, completion);
      const completionExpiry = setTimeout(() => {
        if (pendingConnectCompletions.get(completionKey) === completion) {
          pendingConnectCompletions.delete(completionKey);
        }
      }, process.env.NODE_ENV === 'test' ? 5_000 : 15 * 60_000);
      completionExpiry.unref?.();
    }
    return res.json(session);
  } catch (err) {
    const status = statusForError(err);
    if (status === 500) console.error('[composio] connect failed:', err);
    return res.status(status).json({ error: err instanceof Error ? err.message : 'connect failed' });
  } finally {
    if (connectLaneKey && connectAdmissionToken) {
      const admissions = inFlightConnectAdmissions.get(connectLaneKey);
      admissions?.delete(connectAdmissionToken);
      if (admissions?.size === 0) inFlightConnectAdmissions.delete(connectLaneKey);
    }
  }
});

router.get('/composio/status/:connectionId', requireJwt, async (req: Request, res: Response) => {
  const userId = withUserId(req);
  const connectionId = req.params.connectionId?.trim();
  if (!connectionId) {
    return res.status(400).json({ error: 'connectionId is required' });
  }
  // The client passes the toolkit it's polling for so failed/pending/unknown states report the
  // right connector instead of a hardcoded 'gmail'. Only accept a known slug; anything else → null.
  const toolkitParam = typeof req.query.toolkit === 'string' ? req.query.toolkit.trim() : '';
  const toolkit = (COMPOSIO_TOOLKITS as readonly string[]).includes(toolkitParam)
    ? (toolkitParam as ComposioToolkit)
    : null;
  // Status reads are asynchronous and may ignore cancellation. Snapshot every possible toolkit
  // lane before awaiting so a connected response admitted before a newer pause/revoke cannot
  // publish an ACTIVE intent over that newer mutation.
  const admittedMutationGenerations = new Map(
    COMPOSIO_TOOLKITS.map(slug => [slug, mutationGenerations.get(`${userId}:${slug}`) ?? 0]),
  );
  const admittedMutationOperationKeys = new Map(
    COMPOSIO_TOOLKITS.map(slug => [slug, mutationGenerationOperationKeys.get(`${userId}:${slug}`)]),
  );
  try {
    const state = await getConnectionStatus(userId, connectionId, toolkit);
    let runtime: ComposioRuntimeReadiness = { ready: false, syncing: false };
    const statusToolkit = state.toolkit as ComposioToolkit | undefined;
    const statusLaneKey = statusToolkit ? `${userId}:${statusToolkit}` : undefined;
    const admittedOperationKey = statusToolkit
      ? admittedMutationOperationKeys.get(statusToolkit)
      : undefined;
    const completionKey = `${userId}:${connectionId}`;
    const pendingCompletion = pendingConnectCompletions.get(completionKey);
    const isAuthoritativeConnectCompletion = statusToolkit !== undefined
      && pendingCompletion?.toolkit === statusToolkit
      && (mutationGenerations.get(statusLaneKey!) ?? 0)
        === pendingCompletion.admittedGeneration;
    const retainedOperationKey = statusLaneKey
      ? mutationGenerationOperationKeys.get(statusLaneKey)
      : undefined;
    const staleConnectRetainedIntent = state.status === 'connected'
      && statusToolkit !== undefined
      && !isAuthoritativeConnectCompletion
      && (retainedOperationKey === 'revoked'
        || (retainedOperationKey === 'paused' && state.enabled !== false))
      ? retainedOperationKey
      : undefined;
    const connectedIntentIsCurrent = statusToolkit !== undefined
      && (isAuthoritativeConnectCompletion || (
        (mutationGenerations.get(statusLaneKey!) ?? 0)
          === admittedMutationGenerations.get(statusToolkit)
        && admittedOperationKey === 'connected-active'
      ));
    if (state.status === 'connected' || state.status === 'failed') {
      pendingConnectCompletions.delete(completionKey);
    }
    if (staleConnectRetainedIntent && statusToolkit) {
      const retainedConvergence = convergeStaleConnectToRetainedIntent(
        userId,
        statusToolkit,
        staleConnectRetainedIntent,
      );
      await observeMutation(retainedConvergence.job);
      // Reconcile only after the provider has converged (or its bounded job eventually settles).
      // The stale ACTIVE snapshot itself must never be synchronized into gateway runtime scope.
      scheduleStaleConnectReconciliation(userId, statusToolkit, retainedConvergence);
      return res.json({
        ...state,
        status: staleConnectRetainedIntent === 'revoked' ? 'not_connected' : state.status,
        connectedAccountId: staleConnectRetainedIntent === 'revoked'
          ? null
          : state.connectedAccountId,
        enabled: false,
        runtimeReady: false,
        runtimeSyncing: true,
      });
    }
    if (state.status === 'connected'
      && statusToolkit
      && (COMPOSIO_TOOLKITS as readonly string[]).includes(statusToolkit)
      && connectedIntentIsCurrent) {
      const activeJob = recordConnectedGrantIntent(userId, statusToolkit);
      try {
        const activeIntent = await observeMutation(activeJob);
        if (activeIntent.completed) {
          runtime = await observeComposioRuntimeReadiness(userId);
        } else {
          scheduleMutationReconciliation(userId, activeJob);
          runtime = { ready: false, syncing: true };
        }
      } catch {
        // Grant status remains authoritative even if the idempotent active-intent convergence
        // fails. The background job logs the provider error; report runtime-not-ready here.
        runtime = { ready: false, syncing: false };
      }
    } else if (state.status === 'connected') {
      runtime = await observeComposioRuntimeReadiness(userId);
    }
    return res.json({ ...state, runtimeReady: runtime.ready, runtimeSyncing: runtime.syncing });
  } catch (err) {
    const status = statusForError(err);
    if (status === 500) console.error('[composio] status failed:', err);
    return res.status(status).json({ error: err instanceof Error ? err.message : 'status failed' });
  }
});

router.post('/composio/toolkit/:toolkit/enabled', requireJwt, async (req: Request, res: Response) => {
  const userId = withUserId(req);
  const toolkit = req.params.toolkit?.trim();
  if (!toolkit) {
    return res.status(400).json({ error: 'toolkit is required' });
  }
  const enabled = req.body?.enabled;
  if (typeof enabled !== 'boolean') {
    return res.status(400).json({ error: 'enabled (boolean) is required' });
  }
  try {
    // Non-destructive pause/resume: flips EVERY matching account's status (ACTIVE↔INACTIVE) for the
    // toolkit. Idempotent — already in the desired state returns { updated: 0 }. An unknown slug
    // throws ComposioToolkitError (400). Reconcile afterward so OpenClaw disposes its cached MCP
    // runtime and the next turn sees the account's new ACTIVE/INACTIVE lifecycle immediately.
    if (!(COMPOSIO_TOOLKITS as readonly string[]).includes(toolkit)) {
      throw new ComposioToolkitError(`Unsupported Composio toolkit: ${toolkit}`);
    }
    const job = enqueueMutation(
      userId,
      toolkit,
      enabled ? 'enabled' : 'paused',
      identityScopedMutation(scope => setToolkitEnabled(userId, toolkit, enabled, scope)),
    );
    const mutation = await observeMutation(job);
    if (!mutation.completed) {
      scheduleMutationReconciliation(userId, job);
      return res.status(503).json({
        error: 'Composio is still applying this change. Refresh Connections to confirm the final state.',
        mutationStatus: 'unknown',
        mutationCompleted: false,
        runtimeReady: false,
        runtimeSyncing: true,
      });
    }
    const runtime = await observeComposioRuntimeReadiness(userId);
    return res.json({
      ...mutation.result,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: runtime.ready,
      runtimeSyncing: runtime.syncing,
    });
  } catch (err) {
    const status = statusForError(err);
    if (status === 500) console.error('[composio] setEnabled failed:', err);
    return res.status(status).json({ error: err instanceof Error ? err.message : 'setEnabled failed' });
  }
});

router.delete('/composio/toolkit/:toolkit/connections', requireJwt, async (req: Request, res: Response) => {
  const userId = withUserId(req);
  const toolkit = req.params.toolkit?.trim();
  if (!toolkit) {
    return res.status(400).json({ error: 'toolkit is required' });
  }
  try {
    // Revokes+deletes EVERY active account for this toolkit (allowMultiple → possibly >1). Idempotent:
    // zero active returns { deleted: 0 }. An unknown slug throws ComposioToolkitError (400).
    if (!(COMPOSIO_TOOLKITS as readonly string[]).includes(toolkit)) {
      throw new ComposioToolkitError(`Unsupported Composio toolkit: ${toolkit}`);
    }
    const job = enqueueMutation(
      userId,
      toolkit,
      'revoked',
      identityScopedMutation(scope => disconnectToolkit(userId, toolkit, scope)),
    );
    const mutation = await observeMutation(job);
    if (!mutation.completed) {
      scheduleMutationReconciliation(userId, job);
      return res.status(503).json({
        error: 'Composio is still applying this disconnect. Refresh Connections to confirm the final state.',
        mutationStatus: 'unknown',
        mutationCompleted: false,
        runtimeReady: false,
        runtimeSyncing: true,
      });
    }
    // Reconcile even when this was the final connected toolkit. The final revoke removes the shared
    // server entry and hot-reloads the cached MCP runtime; a later reconnect writes it back in full.
    const runtime = await observeComposioRuntimeReadiness(userId);
    return res.json({
      ...mutation.result,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: runtime.ready,
      runtimeSyncing: runtime.syncing,
    });
  } catch (err) {
    const status = statusForError(err);
    if (status === 500) console.error('[composio] disconnect failed:', err);
    return res.status(status).json({ error: err instanceof Error ? err.message : 'disconnect failed' });
  }
});

export default router;
