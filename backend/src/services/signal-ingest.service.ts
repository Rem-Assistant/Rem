/**
 * Tier-2 SIGNAL PRODUCER — the thing that finally puts rows in `channel_signals`.
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
 * Migration 039 shipped the CONSUMER (`deriveSuggestions` reads `channel_signals`; POST
 * /api/v1/suggestions/signals + `ingestSignal` accept writes) and said the PRODUCER would be
 * WS1's gateway `message_received` hook — in its own words, "WS2 does not build the hook". The
 * hook was never built. `channel_signals` has therefore had 0 rows, ever: every tier-2 suggestion
 * in the product is dead code behind an empty table.
 *
 * Upstream OpenClaw does have a `message_received` plugin hook (openclaw/src/plugins/hook-types.ts)
 * — but it fires on the user's GATEWAY for channels the gateway itself owns, and our connected
 * sources arrive through Composio, which gives us a POLLABLE action and no inbound webhook to this
 * backend. So the producer is a bounded poller on the existing Railway cron, not a push hook. That
 * is the only deviation from the upstream pattern, and it is forced by the transport.
 *
 * ── SOURCE OF TRUTH ──────────────────────────────────────────────────────────────────────────
 *   - which sources exist          → the descriptor registry (connector-signals.registry.ts).
 *     ONE registry, shared with the Daily Brief collector and the derived-inputs API. This
 *     service used to import a lane-local stub whose `listSignalDescriptors()` returned `[]`,
 *     which is why the gate reported `no_descriptors` and the job wrote zero rows forever.
 *   - whether a user authorized a read → Composio ACTIVE connected accounts for the toolkit.
 *     There is no local mirror of that grant, and we do not cache one: the provider is asked every
 *     tick, so a revoked connector stops being read on the next tick with no reconciliation step.
 *   - what has already been ingested → `channel_signals (user_id, source, source_ref)`. Dedupe is
 *     the DATABASE's unique key, reached through `ingestSignalDetailed`, never a local high-water
 *     mark we could drift from.
 *
 * ── STATE TRANSITIONS (per user × descriptor, per tick) ──────────────────────────────────────
 *   no ACTIVE account      → skipped, ZERO provider calls          (`sourcesSkipped`)
 *   > maxAccounts active   → refused, ZERO provider calls          (`sourcesFailed`)
 *   collect ok             → items mapped → written                (`ingested` / `duplicates`)
 *   collect partially fails→ items already mapped are still written, and the source is ALSO
 *                            counted failed. We never discard work we already did, and we never
 *                            hide that the read was incomplete.
 *
 * ── RECOVERY ─────────────────────────────────────────────────────────────────────────────────
 * Every failure path is a no-op that the next tick retries: nothing is stamped, no cursor is
 * advanced, no partial row is left half-written. Re-running is safe by construction because the
 * write is idempotent on `source_ref`. A signal missed while a user was outside the activity
 * window is picked up on the next tick after they open the app (requireJwt stamps last_active_at),
 * provided it is still inside the 24h collection window.
 *
 * ── PRIVACY ──────────────────────────────────────────────────────────────────────────────────
 * `channel_signals.summary` is DESIGNED to hold message-derived text (migration 039: it is what
 * the deriver reasons over). It stays a SUMMARY: every field is clamped here, at the ingest
 * boundary, so a descriptor cannot widen it into a body dump. Nothing derived from a message is
 * ever logged — logs carry counters, source names and reason codes only.
 *
 * Mirrors src/scripts/run-keepwarm.ts (pure exported helpers + injectable batch + kill-switch) and
 * src/scripts/daily-checkins.ts / run-routines.ts (never-throw per user).
 */

import { ingestSignalDetailed } from './suggestions.service.js';
import {
  parseConnectorInstant,
  type ConnectorSignalDescriptor,
  type NormalizedSignal,
} from './connector-signals.registry.js';
import type {
  ActiveConnectorAccountSource,
  ActiveConnectorAccountsByToolkitSource,
} from './connector-signals.runner.js';
import {
  runRelevancePassForUser,
  type RelevancePassCounters,
} from './signal-relevance.service.js';

export type { ActiveConnectorAccountSource, ActiveConnectorAccountsByToolkitSource };

/**
 * The ONLY place collection bounds live. A descriptor cannot widen them: it contributes query
 * arguments and per-item mapping, and the runner counts pages/items/accounts itself rather than
 * trusting anything the descriptor asked the provider for.
 *
 * Values are the ones `collectGmailBriefInput` already runs in production, kept identical so this
 * poller cannot be a heavier read than the Daily Brief collector it sits beside.
 */
export const SIGNAL_INGEST_BOUNDS = {
  /** Connected accounts read per user per source. More than this refuses the read outright. */
  maxAccounts: 3,
  /** Signals kept per user per source per tick. */
  maxItems: 20,
  /** Provider pages requested per connected account. */
  maxPages: 3,
  /** How far back a signal may be. Anything outside [windowStart, now] is dropped. */
  windowHours: 24,
  /** Wall-clock budget for ONE user × source collection. */
  // 2_500 was inherited from the Daily Brief's budget, where the collector runs INSIDE a
  // user-facing authoring turn. This job is a background cron with no one waiting, and a real
  // Composio round trip does not fit: the first live run aborted with
  // `ComposioRequestCancelledError: Request was cancelled by the caller` and reported
  // all_sources_failed on the SAME run that successfully wrote 2 rows.
  timeoutMs: 15_000,
} as const;

/** Clamps applied at the ingest boundary so a descriptor cannot turn a summary into a body. */
export const SIGNAL_TEXT_LIMITS = {
  summary: 500,
  sender: 320,
  suggestedTitle: 200,
  sourceRef: 256,
} as const;

/** Default wall-clock budget for a whole batch, so this job cannot starve the rest of cron:all. */
export const SIGNAL_INGEST_BATCH_BUDGET_MS = 120_000;

/**
 * Default activity window for candidate users. Signals only matter to someone who opens the app,
 * and every candidate costs a Composio round trip per source, so dormant accounts are not polled.
 * `last_active_at` (migration 102) is stamped by requireJwt on any authenticated request.
 */
export const SIGNAL_INGEST_ACTIVE_WINDOW_MINUTES = 24 * 60;

/** Hard ceiling on the candidate window — an operator cannot turn this into a fleet-wide scan. */
export const SIGNAL_INGEST_MAX_WINDOW_MINUTES = 7 * 24 * 60;

/** One bounded page of RAW provider items. Parsing individual items is the descriptor's job. */
export interface ConnectorSignalPage {
  items: unknown[];
  nextPageToken: string | null;
}

/**
 * Provider transport. Mirrors `GmailBriefAdapter` (brief-input.service.ts): declared by the
 * consumer, implemented in composio.service.ts, wired by the script — so the service never imports
 * the Composio client and stays unit-testable without network or an API key.
 *
 * The executor, not the runner, places `pageToken` into the action's argument slot: cursor naming
 * is per-ACTION provider knowledge and must be execution-verified, not guessed by a generic loop.
 */
export interface ConnectorSignalExecutor {
  fetchPage(input: {
    userId: string;
    connectedAccountId: string;
    action: string;
    version: string;
    arguments: Record<string, unknown>;
    pageToken?: string;
    timeoutMs: number;
  }): Promise<ConnectorSignalPage>;
}

/** Writes one normalized signal. Defaults to the existing `ingestSignalDetailed`. */
export type SignalWriter = (
  userId: string,
  signal: NormalizedSignal,
) => Promise<{ id: string; inserted: boolean }>;

export interface SignalIngestDependencies {
  /**
   * BATCHED on purpose — the one-toolkit shape (`ActiveConnectorAccountSource`) is not offered
   * here. This job asks for every descriptor's toolkit at once, once per user per tick, so the
   * N-round-trips-before-any-work shape is not reachable from this path even by a direct call to
   * `collectSignalsForDescriptor`.
   */
  accounts: ActiveConnectorAccountsByToolkitSource;
  executor: ConnectorSignalExecutor;
  /** Defaults to the existing idempotent `channel_signals` upsert. */
  write?: SignalWriter;
  /** Monotonic-ish clock for deadlines. Injected so timeout paths are deterministic in tests. */
  clock?: () => number;
  /** Wall-clock budget for the whole batch. */
  batchBudgetMs?: number;
  /**
   * Judge which of this user's signals deserve to become suggestions, run after their writes.
   * Defaults to the real pass; injected in tests so no test needs a model.
   *
   * Contractually NEVER throws — see `runRelevancePassForUser`. The loop below guards anyway.
   */
  judgeRelevance?: (userId: string) => Promise<RelevancePassCounters>;
}

/** Minimal pg-like shape, so the candidate select is testable without a real database. */
export interface QueryableDb {
  query(sql: string, params?: unknown[]): Promise<{ rows: any[] }>;
}

/**
 * OFF BY DEFAULT. A job that reads user mailboxes on a fleet-wide schedule must be a one-line env
 * change to disable — same kill-switch shape as MEMORY_KEEPER_ENABLED / ORCHESTRATOR_SWEEP_ENABLED
 * / GATEWAY_KEEPWARM_ENABLED, so enabling it is an explicit operator opt-in rather than something a
 * deploy silently turns on for every user.
 */
export function isSignalIngestEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return /^(1|true|yes|on)$/i.test((env.SIGNAL_INGEST_ENABLED ?? '').trim());
}

/**
 * Whether this tick should run at all, as a STRUCTURED decision with a reason code — so the script
 * logs one machine-greppable reason instead of the caller re-deriving it from prose.
 */
export type SignalIngestGate =
  | { run: true }
  | { run: false; reason: 'disabled' | 'composio_unconfigured' | 'no_descriptors' };

export function signalIngestGate(input: {
  env?: NodeJS.ProcessEnv;
  composioConfigured: boolean;
  descriptorCount: number;
}): SignalIngestGate {
  if (!isSignalIngestEnabled(input.env ?? process.env)) return { run: false, reason: 'disabled' };
  if (!input.composioConfigured) return { run: false, reason: 'composio_unconfigured' };
  if (input.descriptorCount <= 0) return { run: false, reason: 'no_descriptors' };
  return { run: true };
}

/**
 * Parse a provider instant. Re-exported from the registry so the ingest path and the descriptor
 * path cannot disagree about which timestamps are real.
 *
 * This WAS a second implementation, and it was wrong for every non-`Z` offset: it recovered the
 * written calendar date with `parsed.getTime() - offset`, but `getTime()` is ALREADY the UTC
 * instant, so subtracting the offset again landed 2× the offset away from the value that was
 * written. `2026-02-15T01:00:00+05:00` round-tripped to Feb 14 and was rejected as malformed —
 * a valid provider timestamp dropped, and invisibly, because every test fixture used `Z` (where
 * the offset is 0 and the bug cancels).
 *
 * Bound to `parseConnectorInstant` (ISO 8601 ∪ epoch numbers), NOT to the ISO-only
 * `parseIsoInstant`. This is the re-check a descriptor's output must survive to be written, so an
 * ISO-only parser here would drop every Slack message — whose `ts` is epoch seconds — after
 * `mapItem` had already accepted it. The registry docblock has the unit rule.
 */
export const parseSignalInstant = parseConnectorInstant;

/** Collapse control characters + runs of whitespace, then hard-clamp. Never throws. */
export function clampSignalText(value: unknown, max: number): string {
  if (typeof value !== 'string') return '';
  const text = value.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

/**
 * Validate + clamp one descriptor-produced signal. Returns null when the signal cannot be trusted
 * or does not belong in this window.
 *
 * The `source` check is the structural guard that makes the descriptor contract real: a descriptor
 * that emits a source it does not own could write rows attributed to another connector, and
 * `deriveSuggestions` keys dismissals on `<source>:<id>`.
 */
export function normalizeSignalForIngest(
  descriptor: ConnectorSignalDescriptor,
  candidate: NormalizedSignal | null,
  windowStart: Date,
  windowEnd: Date,
): NormalizedSignal | null {
  if (!candidate || typeof candidate !== 'object') return null;
  if (candidate.source !== descriptor.source) return null;

  const sourceRef = clampSignalText(candidate.sourceRef, SIGNAL_TEXT_LIMITS.sourceRef);
  const summary = clampSignalText(candidate.summary, SIGNAL_TEXT_LIMITS.summary);
  // `channel_signals.summary` is NOT NULL and the deriver skips blank summaries, so an empty one
  // would be an invisible row rather than a suggestion.
  if (!sourceRef || !summary) return null;

  const receivedAt = parseSignalInstant(candidate.receivedAt);
  if (!receivedAt) return null;
  if (receivedAt < windowStart || receivedAt > windowEnd) return null;

  const sender = clampSignalText(candidate.sender, SIGNAL_TEXT_LIMITS.sender);
  const suggestedTitle = clampSignalText(candidate.suggestedTitle, SIGNAL_TEXT_LIMITS.suggestedTitle);
  return {
    source: descriptor.source,
    sourceRef,
    sender: sender || null,
    summary,
    suggestedTitle: suggestedTitle || null,
    receivedAt: receivedAt.toISOString(),
  };
}

/**
 * Was this candidate rejected ONLY because it fell outside the rolling window?
 *
 * This is not a failure. A descriptor's `buildQuery` deliberately asks the provider for a range
 * WIDER than the window — gmailSignalDescriptor queries whole calendar days — because provider
 * query languages cannot express an exact rolling 24h bound. The out-of-window remainder is then
 * trimmed here, by design. Counting those trims as "fetched but ingested nothing" turns an
 * ordinary quiet mailbox into a red cron tick.
 */
export function isOutOfWindowSignal(
  candidate: NormalizedSignal | null,
  windowStart: Date,
  windowEnd: Date,
): boolean {
  if (!candidate || typeof candidate !== 'object') return false;
  const receivedAt = parseSignalInstant(candidate.receivedAt);
  if (!receivedAt) return false;
  return receivedAt < windowStart || receivedAt > windowEnd;
}

export interface DescriptorCollectResult {
  /** Raw provider items seen, before any mapping or validation. */
  fetched: number;
  /** Items refused by mapItem, by validation, by the window re-check, by dedupe, or by the cap. */
  dropped: number;
  /** Subset of `dropped` trimmed only because they fell outside the window — expected, not a failure. */
  outOfWindow: number;
  /** Bounded, deduped, window-checked signals ready to write. */
  signals: NormalizedSignal[];
  /** Reason code when the read did not complete. `null` means a clean, complete collection. */
  unavailableReason: string | null;
}

/**
 * Why a collection could not complete. Shared by the account resolution and the fetch loop so the
 * two cannot classify the same error differently.
 *
 * Structured-first (CLAUDE.md principle 5): the error's TYPE and `name` decide it. The message
 * compare survives only because `listActiveAccountIdsForToolkit` / `listActiveAccountIdsByToolkit`
 * (composio.service.ts) still throw `new Error('timeout')` on their own deadline.
 */
function classifyCollectFailure(error: unknown): 'timeout' | 'connector_unavailable' {
  if (error instanceof Error && error.name === 'TimeoutError') return 'timeout';
  if (error instanceof Error && error.message === 'timeout') return 'timeout';
  return 'connector_unavailable';
}

/**
 * One user's ACTIVE accounts for every toolkit this tick needs — the result of ONE provider call.
 *
 * A RESULT, not a thrown error, because the answer is now SHARED across descriptors: when the
 * lookup fails every descriptor must still report its own `unavailableReason` and be counted
 * individually, exactly as it did when each owned its own call. Collapsing that into one thrown
 * error would turn N counted source failures into one lost user.
 */
export type ResolvedActiveAccounts =
  | { ok: true; byToolkit: ReadonlyMap<string, readonly string[]> }
  | { ok: false; reason: 'timeout' | 'connector_unavailable' };

/**
 * THE ROUND-TRIP FIX. One Composio call per user per tick, for every descriptor's toolkit at once,
 * instead of one per descriptor.
 *
 * Before: `collectSignalsForDescriptor` asked for its own toolkit, so a tick cost
 * `users × descriptors` account lookups before fetching anything — 13 sequential round trips per
 * user at the catalog this product is heading toward, every one of them charged against the batch
 * wall-clock budget that decides how many users get read at all.
 *
 * Never throws: a failure is returned as a reason code that each descriptor reports for itself.
 */
export async function resolveActiveAccounts(
  userId: string,
  descriptors: readonly ConnectorSignalDescriptor[],
  dependencies: SignalIngestDependencies,
): Promise<ResolvedActiveAccounts> {
  const toolkitSlugs = [...new Set(descriptors.map((descriptor) => descriptor.toolkitSlug))].sort();
  // Zero descriptors is zero provider traffic. An empty registry must cost nothing, not one call.
  if (toolkitSlugs.length === 0) return { ok: true, byToolkit: new Map() };
  try {
    return {
      ok: true,
      byToolkit: await dependencies.accounts.listActiveAccountIdsByToolkit(
        userId,
        toolkitSlugs,
        SIGNAL_INGEST_BOUNDS.timeoutMs,
      ),
    };
  } catch (error) {
    // Never surface the provider's message: it can quote message content. Reason codes only.
    return { ok: false, reason: classifyCollectFailure(error) };
  }
}

/**
 * Collect one user's signals for ONE descriptor, inside every bound.
 *
 * Deliberately different from `collectGmailBriefInput` in one respect: that collector is
 * all-or-nothing because its output is a provenance snapshot that must describe exactly one
 * complete read. This one keeps whatever it already mapped when a later page fails, and reports the
 * failure alongside it — discarding real messages we already paid to fetch would make `fetched > 0,
 * ingested = 0` look like a defect while quietly losing the user's data for that tick.
 *
 * `resolvedAccounts` is the shared, already-paid-for answer from `resolveActiveAccounts`. Omitting
 * it resolves for this descriptor alone — which is still ONE call, so a direct caller cannot
 * accidentally reintroduce the per-descriptor round trip either.
 */
export async function collectSignalsForDescriptor(
  userId: string,
  descriptor: ConnectorSignalDescriptor,
  now: Date,
  dependencies: SignalIngestDependencies,
  resolvedAccounts?: ResolvedActiveAccounts,
): Promise<DescriptorCollectResult> {
  const clock = dependencies.clock ?? Date.now;
  const deadline = clock() + SIGNAL_INGEST_BOUNDS.timeoutMs;
  const windowEnd = now;
  const windowStart = new Date(now.getTime() - SIGNAL_INGEST_BOUNDS.windowHours * 3_600_000);
  const result: DescriptorCollectResult = {
    fetched: 0,
    dropped: 0,
    outOfWindow: 0,
    signals: [],
    unavailableReason: null,
  };
  // Keyed on source_ref because THAT is what `channel_signals` is unique on. Deduping on anything
  // wider (an account-qualified id, say) would let two in-batch items race for one row and report
  // an insert plus a duplicate for a single message.
  const bySourceRef = new Map<string, NormalizedSignal>();

  const resolved = resolvedAccounts
    ?? await resolveActiveAccounts(userId, [descriptor], dependencies);
  if (!resolved.ok) {
    result.unavailableReason = resolved.reason;
    return result;
  }

  try {
    // An absent key and an empty array are the same fact by contract; both mean "not connected".
    const accountIds = [...new Set(resolved.byToolkit.get(descriptor.toolkitSlug) ?? [])].sort();
    if (accountIds.length === 0) {
      result.unavailableReason = 'no_active_connection';
      return result;
    }
    if (accountIds.length > SIGNAL_INGEST_BOUNDS.maxAccounts) {
      // Refuse rather than silently reading the first N: an account set this large is a state we
      // have not designed for, and picking an arbitrary subset would produce a partial inbox with
      // no way for the user to tell which mailbox was ignored.
      result.unavailableReason = 'active_connection_cap_exceeded';
      return result;
    }

    const queryArguments = descriptor.buildQuery(windowStart, windowEnd);
    const perAccountLimit = Math.max(
      1,
      Math.floor(SIGNAL_INGEST_BOUNDS.maxItems / accountIds.length),
    );

    for (const connectedAccountId of accountIds) {
      let pageToken: string | undefined;
      let accountItems = 0;
      for (
        let page = 0;
        page < SIGNAL_INGEST_BOUNDS.maxPages && accountItems < perAccountLimit;
        page++
      ) {
        const remaining = deadline - clock();
        if (remaining <= 0) throw new Error('timeout');
        const providerPage = await dependencies.executor.fetchPage({
          userId,
          connectedAccountId,
          action: descriptor.action,
          version: descriptor.actionVersion,
          arguments: queryArguments,
          ...(pageToken ? { pageToken } : {}),
          timeoutMs: Math.min(remaining, SIGNAL_INGEST_BOUNDS.timeoutMs),
        });
        const items = Array.isArray(providerPage?.items) ? providerPage.items : [];
        for (const raw of items) {
          result.fetched += 1;
          if (accountItems >= perAccountLimit) {
            result.dropped += 1;
            continue;
          }
          let mapped: NormalizedSignal | null = null;
          try {
            mapped = descriptor.mapItem(raw, connectedAccountId);
          } catch {
            // A descriptor that throws on one malformed item must not lose the whole page.
            mapped = null;
          }
          const signal = normalizeSignalForIngest(descriptor, mapped, windowStart, windowEnd);
          if (!signal) {
            if (isOutOfWindowSignal(mapped, windowStart, windowEnd)) result.outOfWindow += 1;
            result.dropped += 1;
            continue;
          }
          if (bySourceRef.has(signal.sourceRef)) {
            result.dropped += 1;
            continue;
          }
          bySourceRef.set(signal.sourceRef, signal);
          accountItems += 1;
        }
        if (!providerPage?.nextPageToken) break;
        pageToken = providerPage.nextPageToken;
      }
    }
  } catch (error) {
    // Never surface the provider's message: it can quote message content. Reason codes only.
    result.unavailableReason = classifyCollectFailure(error);
  }

  // Newest first, then by source_ref for a stable tie-break, so the cap keeps the most useful
  // signals rather than whichever account happened to be listed first.
  const ordered = [...bySourceRef.values()].sort(
    (left, right) =>
      right.receivedAt.localeCompare(left.receivedAt)
      || left.sourceRef.localeCompare(right.sourceRef),
  );
  result.signals = ordered.slice(0, SIGNAL_INGEST_BOUNDS.maxItems);
  result.dropped += ordered.length - result.signals.length;
  return result;
}

/**
 * Honest counters. The previous shape of this bug in the repo was a `delivered=1` log for a slot
 * that delivered nothing, because one counter incremented on any non-throwing return. Every
 * outcome here has its own counter and they reconcile:
 *
 *   fetched === dropped + ingested + duplicates + writesFailed
 *   failed  === sourcesFailed + writesFailed
 */
export interface SignalIngestCounters {
  /** (user × descriptor) collections ATTEMPTED — i.e. the user had ≥1 ACTIVE account for it. */
  sources: number;
  /** (user × descriptor) pairs with no ACTIVE account. No provider call was made. */
  sourcesSkipped: number;
  /** Collections that ended with an unavailableReason (including partial reads). */
  sourcesFailed: number;
  /** Raw provider items seen. */
  fetched: number;
  /** Items refused by mapItem / validation / window / dedupe / cap. */
  dropped: number;
  /** Subset of `dropped` that were merely outside the rolling window. Expected; never a failure. */
  outOfWindow: number;
  /** NEW `channel_signals` rows. */
  ingested: number;
  /** Items that matched an existing (user, source, source_ref) — the idempotency payoff. */
  duplicates: number;
  /** Writes that threw. */
  writesFailed: number;
  /** Total failures = sourcesFailed + writesFailed. Never let a zero here imply success. */
  failed: number;

  // ── relevance judgment ──────────────────────────────────────────────────────────────────────
  // DELIBERATELY OUTSIDE the `failed` arithmetic above and outside `signalIngestFailureReason`.
  // Ingestion and judgment are different jobs with different failure meanings: once a signal is in
  // `channel_signals` the ingest run did what it exists to do, and an unjudged row still reaches
  // the user (the deriver only suppresses an explicit 'drop'). Reddening the tick — and with it
  // all of `cron:all`, which fails whole when one job fails — because a classifier was unreachable
  // would be a false red on a run that lost nothing.
  /** Rows the judge considered (unjudged, or judged under an older policy). */
  judged: number;
  /** Verdicts stored as 'act' — these become suggestions, titled by the judge. */
  judgedAct: number;
  /** Verdicts stored as 'drop' — these will NOT become suggestions. */
  judgedDrop: number;
  /** Considered rows that got no usable verdict. They stay unjudged and SURFACE (fail-open). */
  judgeUnjudged: number;
  /** Users whose relevance pass could not run at all. Not a failure; their rows surface. */
  judgeUnavailable: number;
}

export function emptySignalIngestCounters(): SignalIngestCounters {
  return {
    sources: 0,
    sourcesSkipped: 0,
    sourcesFailed: 0,
    fetched: 0,
    dropped: 0,
    outOfWindow: 0,
    ingested: 0,
    duplicates: 0,
    writesFailed: 0,
    failed: 0,
    judged: 0,
    judgedAct: 0,
    judgedDrop: 0,
    judgeUnjudged: 0,
    judgeUnavailable: 0,
  };
}

function addCounters(into: SignalIngestCounters, from: SignalIngestCounters): void {
  into.sources += from.sources;
  into.sourcesSkipped += from.sourcesSkipped;
  into.sourcesFailed += from.sourcesFailed;
  into.fetched += from.fetched;
  into.dropped += from.dropped;
  into.outOfWindow += from.outOfWindow;
  into.ingested += from.ingested;
  into.duplicates += from.duplicates;
  into.writesFailed += from.writesFailed;
  into.failed += from.failed;
  into.judged += from.judged;
  into.judgedAct += from.judgedAct;
  into.judgedDrop += from.judgedDrop;
  into.judgeUnjudged += from.judgeUnjudged;
  into.judgeUnavailable += from.judgeUnavailable;
}

/**
 * Collect + write every descriptor for ONE user. NEVER throws: one source's failure (or one bad
 * write) is counted and the next source still runs, and the batch above is unaffected.
 */
export async function ingestSignalsForUser(
  userId: string,
  descriptors: ConnectorSignalDescriptor[],
  now: Date,
  dependencies: SignalIngestDependencies,
): Promise<SignalIngestCounters> {
  const counters = emptySignalIngestCounters();
  const write = dependencies.write ?? ((user, signal) => ingestSignalDetailed(user, {
    source: signal.source,
    sourceRef: signal.sourceRef,
    summary: signal.summary,
    ...(signal.sender ? { sender: signal.sender } : {}),
    ...(signal.suggestedTitle ? { suggestedTitle: signal.suggestedTitle } : {}),
    receivedAt: signal.receivedAt,
  }));

  // ONE account lookup for this user's whole tick, for every descriptor's toolkit at once. Asking
  // per descriptor cost a Composio round trip each, all of them before a single message was
  // fetched. Resolved here rather than inside the loop precisely so adding a descriptor cannot
  // quietly add a round trip.
  const resolvedAccounts = await resolveActiveAccounts(userId, descriptors, dependencies);

  for (const descriptor of descriptors) {
    let collected: DescriptorCollectResult;
    try {
      collected = await collectSignalsForDescriptor(
        userId,
        descriptor,
        now,
        dependencies,
        resolvedAccounts,
      );
    } catch (error) {
      // collectSignalsForDescriptor is never-throw by design; guard anyway so a future edit
      // cannot turn one source into a lost user.
      counters.sources += 1;
      counters.sourcesFailed += 1;
      counters.failed += 1;
      console.error(
        `[signals] user ${userId} source ${descriptor.source} collect crashed:`,
        error instanceof Error ? error.name : 'unknown_error',
      );
      continue;
    }

    if (collected.unavailableReason === 'no_active_connection') {
      counters.sourcesSkipped += 1;
      continue;
    }
    counters.sources += 1;
    counters.fetched += collected.fetched;
    counters.dropped += collected.dropped;
    counters.outOfWindow += collected.outOfWindow;
    if (collected.unavailableReason) {
      counters.sourcesFailed += 1;
      counters.failed += 1;
      console.warn(
        `[signals] user ${userId} source ${descriptor.source} incomplete: ${collected.unavailableReason}`,
      );
    }

    for (const signal of collected.signals) {
      try {
        const written = await write(userId, signal);
        if (written.inserted) counters.ingested += 1;
        else counters.duplicates += 1;
      } catch (error) {
        counters.writesFailed += 1;
        counters.failed += 1;
        // Name only — an error message from the driver can echo the parameter values it bound,
        // and those parameters are message-derived text.
        console.error(
          `[signals] user ${userId} source ${descriptor.source} write failed:`,
          error instanceof Error ? error.name : 'unknown_error',
        );
      }
    }
  }

  // ── judge what deserves to become a suggestion ────────────────────────────────────────────
  // Runs HERE — same tick, immediately after this user's writes — rather than as its own cron job.
  // A row written at 12:00 and judged at 12:15 would spend fifteen minutes on the user's agenda as
  // "Reply to Deploybot", which is the exact defect being fixed. Same tick makes that window seconds.
  //
  // It reads back from `channel_signals` rather than judging `collected.signals` in memory, because
  // the table is what the deriver reads: this also picks up rows written by the POST /signals route
  // and rows whose verdict a policy bump invalidated, and it naturally skips the duplicates that
  // dominate a steady-state tick (already judged, so not in the queue → no model call).
  //
  // NOT counted into `failed`. See the note on the relevance counters.
  const judge = dependencies.judgeRelevance ?? ((user: string) => runRelevancePassForUser(user));
  try {
    const relevance = await judge(userId);
    counters.judged += relevance.considered;
    counters.judgedAct += relevance.act;
    counters.judgedDrop += relevance.drop;
    counters.judgeUnjudged += relevance.unjudged;
    if (relevance.unavailableReason) {
      counters.judgeUnavailable += 1;
      console.warn(
        `[signals] user ${userId} relevance unavailable: ${relevance.unavailableReason} `
        + `(${relevance.considered} signal(s) left unjudged and will still surface)`,
      );
    }
  } catch (error) {
    // runRelevancePassForUser is never-throw by design; this is the last line of isolation, and it
    // still must not fail the user's ingest — their signals are already durably written.
    counters.judgeUnavailable += 1;
    console.error(
      `[signals] user ${userId} relevance pass crashed:`,
      error instanceof Error ? error.name : 'unknown_error',
    );
  }

  return counters;
}

export interface SignalIngestSummary extends SignalIngestCounters {
  /** Users actually processed this tick. */
  users: number;
  /** Users not reached because the batch wall-clock budget ran out. */
  usersSkipped: number;
}

/**
 * Run the batch, one user at a time (mirrors run-routines.ts / daily-checkins.ts). Sequential, not
 * concurrent: each user is already bounded to `timeoutMs` per source, and a serial loop keeps the
 * counters trivially correct while bounding how much provider traffic this job can generate at once.
 *
 * The wall-clock budget is the guard that this job cannot starve the rest of `cron:all`: once it is
 * spent we stop and report the users we never reached, rather than running long and delaying
 * `checkins:run` on a 15-minute tick.
 */
export async function runSignalIngestBatch(
  userIds: string[],
  descriptors: ConnectorSignalDescriptor[],
  now: Date,
  dependencies: SignalIngestDependencies,
): Promise<SignalIngestSummary> {
  const clock = dependencies.clock ?? Date.now;
  const budgetMs = dependencies.batchBudgetMs ?? SIGNAL_INGEST_BATCH_BUDGET_MS;
  const deadline = clock() + budgetMs;
  const summary: SignalIngestSummary = {
    ...emptySignalIngestCounters(),
    users: 0,
    usersSkipped: 0,
  };
  if (descriptors.length === 0) return summary;

  for (let index = 0; index < userIds.length; index++) {
    if (clock() >= deadline) {
      summary.usersSkipped = userIds.length - index;
      break;
    }
    const userId = userIds[index];
    summary.users += 1;
    try {
      addCounters(summary, await ingestSignalsForUser(userId, descriptors, now, dependencies));
    } catch (error) {
      // ingestSignalsForUser is never-throw; this is the last line of per-user isolation.
      summary.failed += 1;
      console.error(
        `[signals] user ${userId} failed:`,
        error instanceof Error ? error.name : 'unknown_error',
      );
    }
  }

  return summary;
}

/**
 * Candidate users: anyone who touched the app inside `windowMinutes`. Connecting a source is what
 * AUTHORIZES a read (checked per user against Composio); recent activity is what makes it WORTH
 * one, since a signal only ever surfaces in an app the user opens.
 *
 * `windowMinutes` is coerced to a bounded integer and bound as a parameter — never concatenated —
 * and the predicate matches migration 102's `idx_users_last_active_at`.
 */
export async function selectSignalIngestUsers(
  db: QueryableDb,
  windowMinutes: number = SIGNAL_INGEST_ACTIVE_WINDOW_MINUTES,
): Promise<string[]> {
  // `Math.floor(NaN)` is NaN and `Math.max(1, NaN)` is NaN, which would bind the literal string
  // 'NaN' and make the whole predicate NULL — every user silently excluded, with a clean-looking
  // `users=0` run. A non-finite window falls back to the default; a finite one is clamped.
  const minutes = Number.isFinite(windowMinutes)
    ? Math.min(SIGNAL_INGEST_MAX_WINDOW_MINUTES, Math.max(1, Math.floor(windowMinutes)))
    : SIGNAL_INGEST_ACTIVE_WINDOW_MINUTES;
  const { rows } = await db.query(
    `SELECT id
       FROM users
      WHERE last_active_at IS NOT NULL
        AND last_active_at >= NOW() - ($1 || ' minutes')::interval
      ORDER BY last_active_at DESC`,
    [String(minutes)],
  );
  return rows.map((row) => String(row.id));
}

/**
 * Why one `signals:ingest` run is red — a STRUCTURED token, decided once and used by both the exit
 * code and the log line, so the two can never disagree about whether a run failed.
 *
 * `null` is a clean run.
 */
export type SignalIngestFailureReason =
  | 'writes_failed'
  | 'all_sources_failed'
  | 'fetched_but_ingested_nothing';

/**
 * Classify one run.
 *
 * Surface a TOTAL failure, tolerate partials — the convention the other cron scripts use. Some
 * users having a flaky connector is not an outage; every attempted source failing is.
 *
 * `writes_failed` is a SEPARATE limb and not folded into the source arithmetic, because the two
 * failure modes are independent. The write path can be down while every collect succeeds:
 * Postgres unreachable, a constraint violation, a bad `DATABASE_URL` on rem-cron. That run
 * previously exited 0 with `sourcesFailed = 0` — a green cron tick that fetched real mail and
 * persisted none of it. Any write failure is red.
 *
 * ── `fetched_but_ingested_nothing` — THE PRODUCTIVITY CHECK ───────────────────────────────────
 * Every counter above measures whether a STEP errored. None of them measures whether the job did
 * its job. A producer can fetch real messages, refuse every one of them on a silent path (a
 * `mapItem` that no longer recognizes the transport's field names — the raw/parsed shape mismatch
 * this predicate was added for), and report `fetched=2 dropped=2 ingested=0 failed=0`: no
 * exception, no failed source, no failed write, exit 0. That green tick is what let a producer
 * that had never written a row survive two review rounds.
 *
 * So: items came in, and NOTHING reached the table. Red.
 *
 * `duplicates` counts as reaching the table, and that is deliberate — not a loophole. This poller
 * re-reads a rolling 24h window every 15 minutes, so the healthy steady state is
 * `fetched=20 ingested=0 duplicates=20`: every message is already a row. Firing on `ingested === 0`
 * alone would make the cron permanently red within one window and train everyone to ignore it,
 * which is the same disease as a permanently green one. The condition is therefore "fetched
 * something, and NOT ONE of those items is in the table" — `ingested + duplicates === 0` — which
 * is exactly the dead-producer shape and is unreachable from a healthy run.
 *
 * Zero attempted sources, or zero fetched items, stays clean: nobody had a connector to read, or
 * nothing arrived in the window, is not a failure.
 */
export function signalIngestFailureReason(
  summary: SignalIngestSummary,
): SignalIngestFailureReason | null {
  if (summary.writesFailed > 0) return 'writes_failed';
  if (summary.sources > 0 && summary.sourcesFailed === summary.sources) return 'all_sources_failed';
  // Subtract the out-of-window remainder FIRST. A descriptor's buildQuery deliberately asks the
  // provider for a wider range than the window (whole calendar days for Gmail), so trimming the
  // excess is the design working, not a producer that wrote nothing. Counting those turned any
  // quiet mailbox into exit 1, and cron-all.ts:67 reddens the whole 15-minute tick when one job
  // fails — a false red every quarter hour. Observed: one legitimate message dated inside the
  // query's calendar day but before the window gave fetched=1 dropped=1 ingested=0 -> exit 1.
  if (summary.fetched - summary.outOfWindow > 0 && summary.ingested + summary.duplicates === 0) {
    return 'fetched_but_ingested_nothing';
  }
  return null;
}

/** Process exit code for one run. Derived from `signalIngestFailureReason` — never re-decided. */
export function signalIngestExitCode(summary: SignalIngestSummary): 0 | 1 {
  return signalIngestFailureReason(summary) === null ? 0 : 1;
}

/**
 * Operator-facing explanation for a red run. The REASON token is the machine-readable part; this
 * is the sentence that says what to go look at. Never includes provider or message content.
 */
export const SIGNAL_INGEST_FAILURE_MESSAGES: Record<SignalIngestFailureReason, string> = {
  writes_failed:
    'every collected signal failed to persist — check DATABASE_URL and the channel_signals schema',
  all_sources_failed:
    'every attempted source ended with an unavailableReason — check Composio reachability and the pinned action versions',
  fetched_but_ingested_nothing:
    'the provider returned items and NOT ONE reached channel_signals — the descriptor is refusing every item, '
    + 'which is what a raw/normalized field-shape mismatch between the executor and mapItem looks like',
};

/** One-line, fully reconciled run log. Every counter is printed; none of them stands in for another. */
export function formatSignalIngestSummary(summary: SignalIngestSummary): string {
  return (
    `users=${summary.users} skippedUsers=${summary.usersSkipped} `
    + `sources=${summary.sources} skippedSources=${summary.sourcesSkipped} `
    + `fetched=${summary.fetched} dropped=${summary.dropped} `
    + `outOfWindow=${summary.outOfWindow} `
    + `ingested=${summary.ingested} duplicates=${summary.duplicates} `
    + `judged=${summary.judged} (act=${summary.judgedAct} drop=${summary.judgedDrop} `
    + `unjudged=${summary.judgeUnjudged} unavailable=${summary.judgeUnavailable}) `
    + `failed=${summary.failed} (sources=${summary.sourcesFailed} writes=${summary.writesFailed})`
  );
}
