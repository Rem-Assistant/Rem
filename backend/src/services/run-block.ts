/**
 * WHY A RUN COULD NOT PROCEED — the structured contract, and the mode that picks its remedy.
 *
 * Two facts belong together and are therefore decided in ONE place:
 *
 *   1. `RunBlockCode`  — the machine-readable class of the failure.
 *   2. `ModelRuntimeMode` — WHOSE key was going to pay for the run.
 *
 * They travel together because the remedy is the product of both, and only the client may
 * phrase it. A Rem-managed user out of quota is told to upgrade; a BYOK user whose provider
 * refused the credential is told to fix their key. Those are different sentences for what
 * would otherwise be one code, which is exactly why the mode is not optional metadata.
 *
 * THE BACKEND NEVER SHIPS THE SENTENCE (CLAUDE.md principle 5). Nothing in this file returns
 * user-facing copy, and no consumer should pattern-match one. `task-agent.service.ts` still
 * writes a prose comment because a `task_comments` row IS the user-visible artifact of a run,
 * but the comment is now accompanied by `{ code, mode }` on the same record, and the client is
 * expected to render from those and treat the prose as a legacy fallback for older servers.
 *
 * ── HOW THE MODE IS ESTABLISHED ──────────────────────────────────────────────────────────
 * Runtime payer ownership is durable product state (`users.model_runtime_mode`, migration 126),
 * not an inference from deployment topology or gateway reachability. Existing users are
 * `rem_managed`; a future BYOK credential migration must atomically install the credential and
 * change this field. Until then, no current product mutation writes `byok`.
 *
 * This separation is load-bearing for the Rem-owned shared runtime: a user does not stop being
 * Rem-managed merely because they have no personal OpenClaw gateway. A missing/invalid row or a
 * failed lookup still resolves to `unknown` and therefore fails closed for billing.
 */

/**
 * Whose key pays for this user's model runs. A GLOBAL per-user fact — never per-feature.
 *
 * Wire values; the client maps `(code, mode)` to copy and a call to action. Do not rename,
 * and do not add a member without shipping the client's unknown-case fallback first.
 */
export const MODEL_RUNTIME_MODES = ['rem_managed', 'byok', 'unknown'] as const;
export type ModelRuntimeMode = (typeof MODEL_RUNTIME_MODES)[number];

/**
 * Why a run could not proceed. Wire values — do not rename.
 *
 * `quota_exhausted` and `credential_rejected` are deliberately separate members even though
 * both mean "the model would not serve us": they have different remedies (upgrade the plan vs
 * fix the key) and different payers, so collapsing them would force the client to guess.
 */
export const RUN_BLOCK_CODES = [
  /** The request allowance for this billing period is spent. Remedy: upgrade (Rem-managed). */
  'quota_exhausted',
  /** A provider refused the credential — absent, invalid, expired, revoked. Remedy: fix the key. */
  'credential_rejected',
  /** No runtime to run on: the user has no gateway, or it never became ready. */
  'runtime_unavailable',
  /** The run started but produced nothing inside its budget. */
  'runtime_timeout',
  /** Anything else. The honest bucket — never a guess dressed as a diagnosis. */
  'runtime_error',
  /**
   * Rem DECLINED to run it. A product decision, not a failure — the orchestrator sweep's
   * deny-list (`routine-governance.ts`) refusing to perform a blocked action autonomously.
   *
   * Separate from every `runtime_*` member because nothing is broken and the remedy is neither
   * "upgrade" nor "fix your key": the user runs it themselves. Without it, a policy denial and
   * a dead gateway would both surface as "blocked" with no code, which is the ambiguity this
   * contract exists to remove.
   */
  'policy_blocked',
] as const;
export type RunBlockCode = (typeof RUN_BLOCK_CODES)[number];

/** The persisted, returned reason a run did not happen. Both halves are always present. */
export interface RunBlock {
  code: RunBlockCode;
  mode: ModelRuntimeMode;
}

/**
 * Validate a stored runtime mode at the trust boundary. Deployment and gateway fields are not
 * inputs: they describe infrastructure, not payer ownership.
 */
export function modeForRuntime(storedMode: unknown): ModelRuntimeMode {
  return isModelRuntimeMode(storedMode) ? storedMode : 'unknown';
}

/**
 * THE mode resolver. Every consumer asks this and nothing re-derives it.
 *
 * Never throws: a lookup failure returns `unknown`, which is the honest answer and the one
 * that makes a caller behave conservatively (see `mayChargeRemManagedKey`). A thrown error
 * here would turn a transient DB hiccup into a failed run.
 *
 * The pool is imported dynamically so pure contract consumers can load this module without a
 * configured database. The query is a primary-key read and does not import gateway services.
 */
export async function resolveModelRuntimeMode(userId: string): Promise<ModelRuntimeMode> {
  try {
    const { pool } = await import('../db/pool.js');
    const result = await pool.query<{ model_runtime_mode: unknown }>(
      'SELECT model_runtime_mode FROM users WHERE id = $1::uuid',
      [userId],
    );
    return modeForRuntime(result.rows[0]?.model_runtime_mode);
  } catch (error: unknown) {
    console.warn(
      '[RUN-BLOCK] mode lookup failed, reporting unknown:',
      error instanceof Error ? error.message : String(error),
    );
    return 'unknown';
  }
}

/**
 * MAY THE OPERATOR'S OWN PROVIDER KEY BE SPENT FOR THIS USER?
 *
 * The founder's rule, as one predicate: BYOK is a global mode, so a user who is on their own
 * model must never have a per-feature path quietly pick Rem's key instead.
 *
 * `unknown` is treated as "no". It means durable payer ownership could not be established—not
 * that a gateway is absent. The cost of a wrong `true` is a silent charge to the wrong party;
 * the cost of a wrong `false` is one retryable skip.
 *
 * Existing rows default to `rem_managed`. A future BYOK transition must update the durable mode
 * only in the same lifecycle that makes the user's credential available to the assigned runtime.
 */
export function mayChargeRemManagedKey(mode: ModelRuntimeMode): boolean {
  return mode === 'rem_managed';
}

/**
 * Structured runtime failure reasons mapped to durable block codes.
 *
 * Reading the STRUCTURED field, not the message (CLAUDE.md principle 5). The union is closed,
 * so this mapping is total and no default branch can silently absorb a new member. The Rem-owned
 * shared runtime now produces `quota_exhausted` from atomic admission and
 * `credential_rejected` from its typed provider boundary; the compatibility gateway adapter
 * continues to produce only its narrower legacy subset.
 */
export function blockCodeForRuntimeFailure(
  reason:
    | 'unavailable'
    | 'startup_failed'
    | 'quota_exhausted'
    | 'credential_rejected'
    | 'timeout'
    | 'cancelled'
    | 'error',
): RunBlockCode {
  switch (reason) {
    case 'unavailable':
    case 'startup_failed':
      return 'runtime_unavailable';
    case 'quota_exhausted':
      return 'quota_exhausted';
    case 'credential_rejected':
      return 'credential_rejected';
    case 'timeout':
      return 'runtime_timeout';
    case 'cancelled':
    case 'error':
      return 'runtime_error';
  }
}

/** Compatibility helper for gateway-only callers while they move behind the runtime boundary. */
export function blockCodeForGatewayFailure(
  reason: 'no_gateway' | 'wake_failed' | 'timeout' | 'cancelled' | 'error',
): RunBlockCode {
  return blockCodeForRuntimeFailure(
    reason === 'no_gateway'
      ? 'unavailable'
      : reason === 'wake_failed'
        ? 'startup_failed'
        : reason,
  );
}

/**
 * Narrowing guards for `run_block_*` values crossing a trust boundary.
 *
 * NOT used on the current read path, deliberately. `formatTask`/`formatComment` pass the stored
 * value straight through, because migration 121's CHECK constraints make the database the
 * validator for anything this backend wrote — a guard there would be a second, weaker copy of a
 * rule Postgres already enforces. These exist for the consumers that have no such guarantee:
 * a future ingest of a value the DB did not vet, and the tests that pin the wire sets against
 * the SQL. Keep them exported rather than inlined so that contract stays in one file.
 */
export function isRunBlockCode(value: unknown): value is RunBlockCode {
  return typeof value === 'string' && (RUN_BLOCK_CODES as readonly string[]).includes(value);
}

export function isModelRuntimeMode(value: unknown): value is ModelRuntimeMode {
  return typeof value === 'string' && (MODEL_RUNTIME_MODES as readonly string[]).includes(value);
}
