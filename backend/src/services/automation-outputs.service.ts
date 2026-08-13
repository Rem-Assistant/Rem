import { pool, type DatabaseQueryable } from '../db/pool.js';

/**
 * Derived automation OUTPUT contract — the server-authored answer to "what does this automation
 * actually produce?".
 *
 * This is the second half of the defect `automation-inputs.service.ts` fixed. Inputs stopped being
 * a Swift literal in #1302; Outputs did not, and kept a hand-typed `.planned` on
 * `AutomationOutput.taskSuggestions`. That literal had already gone stale in the SAME direction the
 * connector row did: `deriveSuggestions` produces task suggestions today — tier-1 (overdue /
 * calendar) and tier-2 connected-source signals read out of `channel_signals` — and
 * `GET /api/v1/brief` serves them alongside the brief. The app was telling the user a shipped
 * output was a future plan.
 *
 * Every `state` here is COMPUTED from two observed facts, never written by hand:
 *   (a) whether a PRODUCER is registered for the output — a registered producer is one whose real
 *       production this file can observe, so an output this screen can name is exactly an output
 *       some code path actually emits
 *   (b) what that producer actually produced FOR THIS USER — the artifact row the authoring
 *       pipeline wrote, the attention buckets `gatherBrief` computes, the suggestions
 *       `deriveSuggestions` returns
 *
 * SOURCE OF TRUTH
 *   - producer existence  → `PRODUCERS` below; each entry observes the producer itself, never a
 *                           reimplementation of it (see `observeAutomationOutputs`)
 *   - production evidence → `daily_brief_artifacts` (written only by the authoring lease holder),
 *                           `gatherBrief`, `deriveSuggestions`
 *   Nothing is cached; every request re-observes.
 *
 * RECOVERY
 *   - A producer observation that throws degrades that ONE row to `idle` with null evidence — we
 *     never upgrade a row to `included` on faith, and one slow producer cannot fail the route.
 *   - Unknown `kind` → 404 at the route, not a guessed contract.
 *
 * NON-GOAL: this route does not decide whether an output is GOOD, only whether it exists and
 * whether it produced. Brief `source = 'fallback'` is deliberately NOT read as a failure — per
 * migration 109 it marks the deterministic all-clear composer, which is the empty-day path, not a
 * degraded one. Treating it as failure would be exactly the kind of plausible-looking derivation
 * that put `.planned` in the client in the first place.
 */

/** The output families the client renders. Wire values — do not rename. */
export const AUTOMATION_OUTPUT_KINDS = [
  'daily_orientation',
  'attention_triage',
  'task_suggestions',
] as const;
export type AutomationOutputKind = (typeof AUTOMATION_OUTPUT_KINDS)[number];

/**
 * The three derived states. Wire values — do not rename, and do not add a fourth without shipping
 * the client's `unrecognized(String)` fallback first.
 *
 * `idle` is the state the founder's rule names directly: an output reads "Nothing yet" because
 * there is no production record, not because someone typed a status.
 */
export const AUTOMATION_OUTPUT_STATES = ['included', 'idle', 'coming_soon'] as const;
export type AutomationOutputState = (typeof AUTOMATION_OUTPUT_STATES)[number];

/** One row of the Outputs list. Every nullable field here is Optional in the Swift model. */
export interface AutomationOutputRow {
  output: AutomationOutputKind;
  state: AutomationOutputState;
  detail: string;
  lastProducedAt: string | null;
  lastItemCount: number | null;
}

export interface AutomationOutputsResponse {
  outputs: AutomationOutputRow[];
}

/**
 * What one producer actually produced for one user.
 *
 * `itemCount === null` means "this producer has no meaningful count", NOT zero. The distinction
 * matters: the authored brief is one artifact, so counting it says nothing, while a suggestion
 * list of length 0 is a real, load-bearing zero.
 */
export interface OutputProductionFact {
  output: AutomationOutputKind;
  producedAt: string | null;
  itemCount: number | null;
}

/**
 * A registered producer: an output some code path emits, plus the copy for each state it can be
 * in. `observe` is not part of this type on purpose — the pure derivation must not be able to do
 * I/O, so observation lives in `observeAutomationOutputs` and arrives here as plain facts.
 */
export interface AutomationOutputProducer {
  output: AutomationOutputKind;
  /** Shown when the producer emitted something for this user. */
  includedDetail: string;
  /** Shown when the producer is wired but has produced nothing for this user yet. */
  idleDetail: string;
}

/**
 * The canonical list of outputs this automation emits.
 *
 * An entry belongs here only if `observeAutomationOutputs` observes the REAL producer for it. That
 * is what keeps this from being the old Swift literal wearing a server hat: the list cannot claim
 * an output that nothing produces, because there would be nothing to observe.
 */
export const PRODUCERS: readonly AutomationOutputProducer[] = Object.freeze([
  {
    output: 'daily_orientation',
    includedDetail:
      'Orients you to what is on deck, overdue, blocked, and already done.',
    idleDetail:
      'Rem has not written a brief for you yet. The first one arrives at your next enabled trigger.',
  },
  {
    output: 'attention_triage',
    includedDetail: 'Surfaces blocked and overdue work that needs your attention.',
    idleDetail: 'Nothing is blocked or overdue right now, so there is nothing to surface.',
  },
  {
    output: 'task_suggestions',
    includedDetail:
      'Proposes tasks from your overdue work, your calendar, and your connected sources. A suggestion becomes a durable task only after you accept it.',
    idleDetail:
      'No suggestions right now. Rem proposes them from overdue work, your calendar, and connected sources.',
  },
]);

/**
 * Outputs named to the user that nothing produces yet.
 *
 * `coming_soon` is derived from ABSENCE from `PRODUCERS`: an entry here is skipped the moment a
 * producer registers the same output, so the row cannot appear twice or contradict itself. This is
 * a ROADMAP list (which unbuilt outputs are worth naming), never a STATE.
 *
 * Empty today — and that emptiness is itself the finding. Every output this surface names is one
 * the runner actually emits; the client's `.planned` on task suggestions was describing a product
 * plan that had already shipped.
 */
export const PLANNED_OUTPUTS: readonly {
  output: AutomationOutputKind;
  detail: string;
}[] = Object.freeze([]);

/**
 * Did this producer produce? The ONLY place an output state is decided.
 *
 * Keyed off STRUCTURED evidence — a timestamp or a count — never off copy or a string match
 * (CLAUDE.md principle 5).
 *
 * A `null` count with a `null` timestamp is the honest "no record": the founder's rule that an
 * output reads as never-run because there is no run record, not because a literal says so.
 */
export function deriveOutputState(fact: OutputProductionFact | undefined): AutomationOutputState {
  if (!fact) return 'idle';
  // A real zero is a real answer: the producer ran and had nothing to emit.
  if (fact.itemCount !== null) return fact.itemCount > 0 ? 'included' : 'idle';
  // No count to speak of, so existence of a production record is the evidence.
  return fact.producedAt ? 'included' : 'idle';
}

export interface DeriveAutomationOutputsArgs {
  producers: readonly AutomationOutputProducer[];
  factsByOutput: ReadonlyMap<AutomationOutputKind, OutputProductionFact>;
  /** Injectable so the absence mechanism stays testable while the real list is empty. */
  planned?: readonly { output: AutomationOutputKind; detail: string }[];
}

/**
 * Pure derivation — no I/O, no clock, no randomness. Given the observed facts, the rows are a
 * total function of them. That is what makes this contract untypeable by hand.
 *
 * Row order is stable: registered producers in declaration order, then not-yet-built outputs.
 */
export function deriveAutomationOutputs(
  args: DeriveAutomationOutputsArgs,
): AutomationOutputRow[] {
  const { producers, factsByOutput, planned = PLANNED_OUTPUTS } = args;
  const rows: AutomationOutputRow[] = [];
  const seen = new Set<AutomationOutputKind>();

  for (const producer of producers) {
    if (seen.has(producer.output)) continue;
    seen.add(producer.output);
    const fact = factsByOutput.get(producer.output);
    const state = deriveOutputState(fact);
    rows.push({
      output: producer.output,
      state,
      detail: state === 'included' ? producer.includedDetail : producer.idleDetail,
      lastProducedAt: fact?.producedAt ?? null,
      lastItemCount: fact?.itemCount ?? null,
    });
  }

  for (const entry of planned) {
    if (seen.has(entry.output)) continue;
    seen.add(entry.output);
    rows.push({
      output: entry.output,
      state: 'coming_soon',
      detail: entry.detail,
      lastProducedAt: null,
      lastItemCount: null,
    });
  }

  return rows;
}

// ── Observation ────────────────────────────────────────────────────────────────────────────────

/**
 * The real producers, injected. Each one is the function (or table) that ACTUALLY emits the
 * output — never a reimplementation of its logic here. Re-deriving "what counts as overdue" in
 * this file is precisely the drift `connector-signals.registry.ts` exists to prevent.
 */
export interface AutomationOutputObservers {
  /** Newest authored brief artifact for this user, or null if the pipeline never wrote one. */
  readNewestBriefArtifact(userId: string, db: DatabaseQueryable): Promise<string | null>;
  /** `gatherBrief`'s own attention buckets. Returns blocked + overdue for this user, right now. */
  countAttentionItems(userId: string, now: Date, timezone: string): Promise<number>;
  /** `deriveSuggestions`' own output length for this user, right now. */
  countTaskSuggestions(userId: string, now: Date, timezone: string): Promise<number>;
}

/**
 * Newest production timestamp of the authoring pipeline.
 *
 * Reads the table the pipeline WRITES (`daily_brief_artifacts`, migration 107/114), so the answer
 * cannot drift from the producer. `markdown` must be non-empty: a lease row with no prose is a
 * reservation, not a produced brief, and counting it would make "Rem wrote you a brief" true
 * before one existed.
 */
export async function readNewestBriefArtifact(
  userId: string,
  db: DatabaseQueryable = pool,
): Promise<string | null> {
  const result = await db.query<{ produced_at: Date | string | null }>(
    `SELECT COALESCE(updated_at, created_at) AS produced_at
       FROM daily_brief_artifacts
      WHERE user_id = $1::uuid
        AND markdown IS NOT NULL
        AND btrim(markdown) <> ''
      ORDER BY COALESCE(updated_at, created_at) DESC
      LIMIT 1`,
    [userId],
  );
  const row = result.rows[0];
  if (!row) return null;
  return toIsoOrNull(row.produced_at);
}

/** Tolerant ISO 8601 → canonical ISO 8601. Mirrors `automation-inputs.service.ts`. */
export function toIsoOrNull(value: unknown): string | null {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value.toISOString();
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  const parsed = Date.parse(trimmed);
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
}

/**
 * Observe every registered producer.
 *
 * Each observation is isolated: a producer that throws yields NO fact, which `deriveOutputState`
 * reads as `idle`. It never yields `included`. A settings screen that cannot observe a producer
 * must not claim the producer is delivering — that is the whole failure mode this lane exists to
 * end.
 */
export async function observeAutomationOutputs(
  userId: string,
  now: Date,
  timezone: string,
  observers: AutomationOutputObservers,
  db: DatabaseQueryable = pool,
): Promise<Map<AutomationOutputKind, OutputProductionFact>> {
  const facts = new Map<AutomationOutputKind, OutputProductionFact>();

  const [artifact, attention, suggestions] = await Promise.all([
    settle(() => observers.readNewestBriefArtifact(userId, db), 'daily_orientation'),
    settle(() => observers.countAttentionItems(userId, now, timezone), 'attention_triage'),
    settle(() => observers.countTaskSuggestions(userId, now, timezone), 'task_suggestions'),
  ]);

  if (artifact.ok) {
    facts.set('daily_orientation', {
      output: 'daily_orientation',
      producedAt: artifact.value,
      // One authored artifact is not a count of anything the user would recognize.
      itemCount: null,
    });
  }
  if (attention.ok) {
    facts.set('attention_triage', {
      output: 'attention_triage',
      // Computed fresh on every read, so there is no "last produced" instant to report.
      producedAt: null,
      itemCount: nonNegativeInt(attention.value),
    });
  }
  if (suggestions.ok) {
    facts.set('task_suggestions', {
      output: 'task_suggestions',
      producedAt: null,
      itemCount: nonNegativeInt(suggestions.value),
    });
  }

  return facts;
}

type Settled<T> = { ok: true; value: T } | { ok: false };

async function settle<T>(run: () => Promise<T>, output: string): Promise<Settled<T>> {
  try {
    return { ok: true, value: await run() };
  } catch (error: unknown) {
    // Message only — never the user id and never any produced content.
    const reason = error instanceof Error ? error.message : String(error);
    console.warn(`[AUTOMATION-OUTPUTS] producer "${output}" unobservable:`, reason);
    return { ok: false };
  }
}

function nonNegativeInt(value: unknown): number | null {
  const numeric = typeof value === 'string' ? Number(value) : value;
  if (typeof numeric !== 'number' || !Number.isFinite(numeric)) return null;
  const rounded = Math.trunc(numeric);
  return rounded >= 0 ? rounded : null;
}

/** Full read path: observe, then derive. */
export async function getAutomationOutputs(
  userId: string,
  now: Date,
  timezone: string,
  observers: AutomationOutputObservers,
  db: DatabaseQueryable = pool,
  producers: readonly AutomationOutputProducer[] = PRODUCERS,
): Promise<AutomationOutputsResponse> {
  const factsByOutput = await observeAutomationOutputs(userId, now, timezone, observers, db);
  return { outputs: deriveAutomationOutputs({ producers, factsByOutput }) };
}
