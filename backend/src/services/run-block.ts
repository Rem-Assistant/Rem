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
 * There is no "I am BYOK" flag anywhere in this product. What the backend can establish is
 * narrower than it first appears, and getting it wrong in the obvious way is worse than not
 * answering, so the reasoning is written out.
 *
 * THE OBVIOUS ANSWER IS WRONG. `users.hosting_provider` looks like the signal: Fly gateways
 * are Rem's, Railway/local/manual ones are the user's. An earlier revision of this file shipped
 * exactly that, on the grounds that "the Railway pipeline sets the provider env var from
 * `req.apiKey`, so Rem never supplies one". Checked, and it is false:
 *
 *   - `runRailwayPipeline` onboards with `buildGatewayConfigPatch(...)`
 *     (the managed deploy pipeline) — the SAME builder the Fly pipeline uses.
 *     That patch embeds the ORG `GMI_API_KEY` as `models.providers.gmi.apiKey`
 *     (`config/gateway-defaults.ts:489`) AND sets `agents.defaults.model.primary` to
 *     `DEFAULT_PRIMARY_MODEL` = `gmi/MiniMaxAI/MiniMax-M2.7` (`:152`, `:59`). So a Railway
 *     gateway's DEFAULT BRAIN is Rem's key. The user's pasted key is installed alongside it,
 *     not instead of it.
 *   - the fleet config-patch job selects EVERY user with a `gateway_url` —
 *     no `hosting_provider` filter — and applies the same patch. One fleet run installs Rem's
 *     provider, as primary, on local and manual gateways too.
 *
 * So `hosting_provider` describes where Rem DEPLOYS, not whose key PAYS, and those are
 * different sets. Reading it would have told a Railway user "your API key was refused" about
 * a key that is Rem's, and would have withheld their brief's connector enrichment to protect
 * a bill Rem is already paying. Both failures point the wrong way.
 *
 * WHAT IS ACTUALLY TRUE: Rem installs its own model credentials on every gateway it can
 * address. So the honest derivation is about REACHABILITY, not topology:
 *
 *   gateway credentials on record → `rem_managed`. The backend holds this gateway's URL and
 *                                   token, which is precisely the precondition for every site
 *                                   that applies `buildGatewayConfigPatch`. Rem's provider is
 *                                   installed there, or can be at any time, as the primary.
 *   no gateway on record          → `unknown`. Nothing to say. Not "byok" — an absent gateway
 *                                   is an absent fact, and `hosting_provider` DEFAULTs to
 *                                   `'railway'` (`db/migrations/005_add_gateway_fields.sql:4`),
 *                                   so the column is meaningless without one.
 *
 * ── WHAT THIS MEANS TODAY, SAID PLAINLY ──────────────────────────────────────────────────
 * NO USER RESOLVES TO `byok`. The member exists, the gate below reads it, and nothing produces
 * it — because a user cannot currently BE on their own model in a way this backend can see or
 * that survives the next fleet patch:
 *
 *   - `Shared/Views/Settings/SharedBYOKSettingsView.swift` writes a key to the device Keychain
 *     and stops. It has NO instantiation site — unlinked deliberately, and
 *     `docs/architecture/2026-08-09-cloud-gateway-byok-contract.md:29-33` forbids relinking it,
 *     because local Keychain membership is not runtime authentication.
 *   - Nothing reads `BYOKCredentialStore` outside its own file, so an iOS key never reaches the
 *     gateway, the backend, or a second signed-in device.
 *   - A key that DOES reach a gateway (Railway onboarding, the Mac local writer) is not the
 *     primary model, per the two citations above.
 *
 * That is the finding, not a limitation to be worked around: **the payer hybrid this file was
 * written to close does not currently have a victim.** What the file provides is the seam and
 * the enforcement points, wired and tested, so that Phase 1 of the BYOK contract
 * (`…byok-contract.md:135-152`) is a change to ONE function. When the credential-install
 * mutation lands it must record the mode transition, and `resolveModelRuntimeMode` must read
 * that record — it must NOT go back to inferring from topology.
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
 * Classify a runtime into a mode. Pure — the DB read lives in `resolveModelRuntimeMode`, so the
 * rule itself is testable without a database.
 *
 * `hasGatewayCredentials` is the ONLY input, and deliberately so. It means "the backend holds
 * this gateway's URL and token", which is exactly the precondition every site that applies
 * `buildGatewayConfigPatch` needs — so it is also the condition under which Rem's own GMI
 * provider is installed there as the primary model. `hosting_provider` is NOT an input: see the
 * file header for why reading it produced the wrong answer for Railway, local and manual.
 *
 * No branch returns `byok` today. That is not an oversight — it is the finding. Nothing in this
 * product currently makes a user's own key their gateway's primary model in a way the backend
 * can observe, so claiming `byok` would be inventing a fact. The member and the gate exist so
 * that the day a real signal lands, only this function changes.
 */
export function modeForRuntime(hasGatewayCredentials: boolean): ModelRuntimeMode {
  return hasGatewayCredentials ? 'rem_managed' : 'unknown';
}

/**
 * THE mode resolver. Every consumer asks this and nothing re-derives it.
 *
 * Never throws: a lookup failure returns `unknown`, which is the honest answer and the one
 * that makes a caller behave conservatively (see `mayChargeRemManagedKey`). A thrown error
 * here would turn a transient DB hiccup into a failed run.
 *
 * `gateway.service.js` is imported DYNAMICALLY, and that is deliberate rather than stylistic.
 * It transitively pulls in `db/pool.js`, which reads `DATABASE_URL` at module scope and throws
 * when it is absent. A static import would make every consumer of the CONTRACT — the codes,
 * the modes, the guards, the failure mapping, all of which are pure — require a database URL
 * just to name a constant. Node caches the module after the first call, so the cost is one
 * resolution per process. Mirrors `gateway-agent.service.ts:184`, which defers the same import
 * for the same reason; this is not a new pattern.
 *
 * It also reads the SAME source `runAgentTurnOnGateway` reads — `getGatewayCredentials(userId)`,
 * the `users` row — so the runtime whose mode is reported is always the runtime that would have
 * run the turn. (`getLocalGatewayCredentials`, the `LOCAL_GATEWAY_URL` dev override, is consulted
 * by neither; only the Composio path uses it.) The lookup is a primary-key read on `users.id`.
 */
export async function resolveModelRuntimeMode(userId: string): Promise<ModelRuntimeMode> {
  try {
    const { getGatewayCredentials } = await import('./gateway.service.js');
    const creds = await getGatewayCredentials(userId);
    return modeForRuntime(Boolean(creds));
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
 * `unknown` is treated as "no". Note what that does and does not cost, because the naive
 * reading is backwards: `unknown` means "no gateway on record", and a user with no gateway has
 * no runtime for the enrichment's alternative either — so refusing here denies them nothing
 * they could otherwise have had. The rule is still the right default for the case that has not
 * arrived yet (a real BYOK signal that fails to load), where the cost of a wrong `true` is a
 * silent charge to the wrong party and the cost of a wrong `false` is one retryable skip.
 *
 * INERT TODAY, AND THAT IS THE HONEST STATE. `resolveModelRuntimeMode` returns `rem_managed`
 * for every user with a gateway, so this predicate currently blocks nobody who could otherwise
 * proceed. It is wired, tested, and placed at the one call site that spends the operator's key,
 * so that closing the hole later is a resolver change rather than a hunt for call sites. Do not
 * mistake "no user is blocked today" for "this does nothing" — and do not delete it on that
 * basis either.
 */
export function mayChargeRemManagedKey(mode: ModelRuntimeMode): boolean {
  return mode === 'rem_managed';
}

/**
 * The structured failure reasons `runAgentTurnOnGateway` can return, mapped to block codes.
 *
 * Reading the STRUCTURED field, not the message (CLAUDE.md principle 5). The gateway's
 * `GatewayAgentTurnFailureReason` is a closed union, so this mapping is total and no default
 * branch can silently absorb a new member — TypeScript fails the build instead.
 *
 * WHAT THIS MAPPING DELIBERATELY CANNOT PRODUCE, and why that is correct: neither
 * `quota_exhausted` nor `credential_rejected` is reachable from a gateway turn today. A
 * gateway that cannot authenticate with its provider fails `chat.send` with a free-text
 * `error` message and no machine-readable class, so classifying it would mean regexing prose
 * for a machine decision — the exact thing principle 5 forbids and the thing `task-verdict.ts`
 * was written to stop.
 *
 * NOTHING PRODUCES THOSE TWO CODES YET — not this function, not any other caller. They are
 * declared so the wire contract is complete and the client can be built against all five at
 * once, and a test pins that this mapping never invents them. The nearest real signal already
 * exists but is not wired to a run record: `consumeRequestSlotAtomically` returns
 * `{ status: 'quota_exceeded', reason }` for the app's own chat path
 * (`routes/usage.routes.ts:163`), which never touches `run_block_*`. Landing a structured
 * provider-error class on the gateway turn, and routing the quota signal into a run record,
 * are both follow-up work; this function is the one place the first of them changes.
 */
export function blockCodeForGatewayFailure(
  reason: 'no_gateway' | 'wake_failed' | 'timeout' | 'error',
): RunBlockCode {
  switch (reason) {
    case 'no_gateway':
    case 'wake_failed':
      return 'runtime_unavailable';
    case 'timeout':
      return 'runtime_timeout';
    case 'error':
      return 'runtime_error';
  }
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
