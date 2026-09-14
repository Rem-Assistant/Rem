/**
 * Rem-owned connector READ execution — a backend path that reads a connector via Composio
 * DIRECTLY, without the OpenClaw gateway. This is the first execution seam of "Rem without
 * OpenClaw": the caller names a toolkit + a pinned READ action, and this resolves the user's ACTIVE
 * grant and runs the read against Composio, returning a structured result.
 *
 * It MIRRORS three proven, live production patterns rather than inventing a new one:
 *   • Auth resolution is `listActiveAccountIdsForToolkit` (composio.service.ts) — ACTIVE-only,
 *     because holding an ACTIVE account for a toolkit is what AUTHORIZES a backend read at all.
 *   • Execution is `executeComposioTool` (composio.service.ts) — the SAME
 *     `client().tools.execute(...)` primitive `composioGmailBriefAdapter` and `composioSignalExecutor`
 *     use, lifted to an exported seam so this path can call it without the gateway.
 *   • Envelope validation copies the signal executor's guard (composio.service.ts
 *     `composioSignalExecutor`): a result that is not explicitly `successful` is an error, never an
 *     empty read.
 *
 * WHY AN ALLOW-LIST FIRST. A machine-driven read must never float its action or version — a
 * provider schema change has to be a code change, exactly as the signal registry pins
 * `GMAIL_BRIEF_ACTION` / `GMAIL_BRIEF_ACTION_VERSION`. So an action (or a wrong version of an
 * allowed action) is rejected BEFORE any provider call — it is a code bug in a frozen surface, not
 * a user-facing failure, and it must cost zero provider traffic.
 */
import {
  executeComposioTool,
  listActiveAccountIdsForToolkit,
} from './composio.service.js';
import {
  GMAIL_BRIEF_ACTION,
  GMAIL_BRIEF_ACTION_VERSION,
} from './connector-signals.registry.js';

/**
 * The READ allow-list: action → the ONE pinned version it may run at. Starts with just
 * `GMAIL_FETCH_EMAILS` at the version the signal registry already pins. An action absent from this
 * map, or present at a different version, is refused with `action_not_allowed`.
 */
const READ_ACTION_ALLOWLIST: ReadonlyMap<string, string> = new Map([
  [GMAIL_BRIEF_ACTION, GMAIL_BRIEF_ACTION_VERSION],
]);

/**
 * Sane default wall-time for ONE read, applied independently to the account resolution and the
 * execute call. Overridable per call; deliberately generous versus the 2.5s whole-collect budget of
 * the scheduled signal poller because this is a single interactive read, not a fan-out.
 */
const DEFAULT_READ_TIMEOUT_MS = 10_000;

/** Structured reasons a read failed. Machine tokens, never user prose — mirrors the vocabulary of
 * `ConnectorSignalUnavailableReason` (connector-signals.runner.ts) and the signal executor's
 * envelope guard (composio.service.ts). */
export type ConnectorReadFailureReason =
  | 'action_not_allowed'
  | 'invalid_result'
  | 'action_failed'
  | 'invalid_data'
  | 'timeout'
  | 'connector_unavailable';

export interface ConnectorReadInput {
  userId: string;
  /** Composio toolkit slug, e.g. 'gmail'. Asserted against the curated catalog downstream. */
  toolkit: string;
  /** e.g. 'GMAIL_FETCH_EMAILS'. Must be in the READ allow-list. */
  action: string;
  /** PINNED action version, e.g. '20260721_00'. Must match the allow-listed version. */
  actionVersion: string;
  /** Provider-specific read arguments, forwarded verbatim. */
  arguments: Record<string, unknown>;
  /** Per-call wall-time budget; defaults to DEFAULT_READ_TIMEOUT_MS. */
  timeoutMs?: number;
  /** Optional caller cancellation, merged with the timeout signal. */
  signal?: AbortSignal;
}

export type ConnectorReadResult =
  | { kind: 'ok'; data: Record<string, unknown> }
  | { kind: 'no_active_connection' }
  | { kind: 'failed'; reason: ConnectorReadFailureReason };

/**
 * Injectable dependencies. Only the ACTIVE-account source is injected (tests stub it to control
 * which grants exist); the execute primitive is NOT injected — it runs for real against the mocked
 * `@composio/core` SDK, so the SDK call shape stays proven end to end.
 */
export interface ConnectorReadDeps {
  listActiveAccountIds?: (userId: string, toolkit: string, timeoutMs: number) => Promise<string[]>;
}

/** Map a thrown provider/resolution error to a structured reason. An aborted/timed-out call is
 * `timeout`; anything else is `connector_unavailable` (retryable), never a silent success. */
function classifyThrow(error: unknown): ConnectorReadFailureReason {
  const name = (error as { name?: unknown } | null | undefined)?.name;
  if (name === 'TimeoutError' || name === 'AbortError') return 'timeout';
  return 'connector_unavailable';
}

/**
 * Read a connector via Composio directly (no gateway). Full lifecycle is intentionally total: every
 * branch returns a discriminated result, and `no_active_connection` is distinct from `failed` so a
 * caller can tell "user has not connected this" apart from "we could not read it".
 */
export async function executeConnectorRead(
  input: ConnectorReadInput,
  deps: ConnectorReadDeps = {},
): Promise<ConnectorReadResult> {
  const listActiveAccountIds = deps.listActiveAccountIds ?? listActiveAccountIdsForToolkit;
  const timeoutMs = input.timeoutMs ?? DEFAULT_READ_TIMEOUT_MS;

  // 1) Allow-list gate BEFORE any provider call: unknown action or a floated version is refused
  //    with zero provider traffic. Fail CLOSED on a missing pin — a bare
  //    `.get(action) !== version` would let a type-violating `action=undefined, version=undefined`
  //    through (`undefined !== undefined` is false), spending an account lookup + execute attempt.
  const pinnedVersion = READ_ACTION_ALLOWLIST.get(input.action);
  if (pinnedVersion === undefined || pinnedVersion !== input.actionVersion) {
    return { kind: 'failed', reason: 'action_not_allowed' };
  }

  // 2) Resolve the ACTIVE connected account. Empty → not connected; do NOT call execute.
  let accountIds: string[];
  try {
    accountIds = await listActiveAccountIds(input.userId, input.toolkit, timeoutMs);
  } catch (error) {
    return { kind: 'failed', reason: classifyThrow(error) };
  }
  if (accountIds.length === 0) return { kind: 'no_active_connection' };
  const connectedAccountId = accountIds[0];

  // 3) Execute with the timeout signal merged with any caller signal.
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  const signal = input.signal
    ? AbortSignal.any([timeoutSignal, input.signal])
    : timeoutSignal;
  let result: unknown;
  try {
    result = await executeComposioTool({
      action: input.action,
      userId: input.userId,
      connectedAccountId,
      version: input.actionVersion,
      arguments: input.arguments,
      signal,
    });
  } catch (error) {
    return { kind: 'failed', reason: classifyThrow(error) };
  }

  // 4) Validate the envelope — same guard the signal executor applies: not-explicitly-successful is
  //    an error, never an empty read.
  if (!result || typeof result !== 'object') return { kind: 'failed', reason: 'invalid_result' };
  const envelope = result as Record<string, unknown>;
  if (envelope.successful !== true || envelope.error != null) {
    return { kind: 'failed', reason: 'action_failed' };
  }
  const data = envelope.data;
  if (!data || typeof data !== 'object') return { kind: 'failed', reason: 'invalid_data' };
  return { kind: 'ok', data: data as Record<string, unknown> };
}
