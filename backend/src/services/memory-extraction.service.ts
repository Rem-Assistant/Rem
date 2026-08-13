/**
 * Memory auto-extraction — the "Dreaming" auto-update.
 *
 * The user-managed memory store (user-memory.service.ts) lets the user type facts Rem should
 * remember. This service is the EXTRACTION layer: on a schedule (Railway cron — see
 * src/scripts/extract-memories.ts) it reads a user's recent activity (tasks + comments) and
 * asks THE USER'S OWN GATEWAY AGENT to distill 2-3 *durable* facts worth remembering
 * (preferences, ongoing goals, recurring context). Each fact is then written via
 * user-memory.service.addMemory(userId, fact, 'auto').
 *
 * Mirrors digest.service.ts: a deterministic gather step → a built prompt → one gateway turn.
 * There is no model-free fallback — if there is nothing to summarize, or the gateway cannot
 * take the turn, we simply extract nothing (we never invent facts).
 *
 * ── THE GMI FALLBACK IS GONE (and this is why) ───────────────────────────────────────────
 * A failed gateway turn used to fall through to `gmiChat` on the org `GMI_API_KEY`. That made
 * a user who runs on their OWN key (a Mac local gateway, a self-hosted or Railway-deployed
 * one — see `run-block.ts`) spend Rem's key instead, silently, whenever their gateway hiccuped
 * — writing facts into their durable memory that Rem paid a different provider to infer. BYOK
 * is a global per-user mode, so no per-feature path may pick the key. `task-agent.service.ts`
 * dropped the identical fallback in #1327; this finishes the same job.
 *
 * A skipped pass costs nothing durable: extraction is idempotent-by-design (the dedupe pass
 * drops anything close to an existing fact), so the next nightly tick re-reads the same
 * 14-day activity window and writes what this one did not.
 *
 * Dedupe is the safety valve: the same durable fact surfaces across many days of activity, so
 * before writing we drop any candidate that is a near-duplicate of an existing fact (or of an
 * earlier candidate in the same run). The dedupe helpers are pure and unit-tested.
 *
 * See docs/agentbox/DIGESTS.md for the sibling proactive-cloud pattern.
 */

import { pool } from '../db/pool.js';
// NOTE: no `gmi.service` import, deliberately. `tsconfig.json` does not set `noUnusedLocals`, so
// an orphaned import here would compile silently and read to the next person as "the org-key
// fallback is still reachable from this file". It is not, and the import is gone so that the
// module graph says so too.
import { runAgentTurnOnGateway, utcDateStamp } from './gateway-agent.service.js';
import { MEMORY_FACT_MAX_LENGTH } from './user-memory.service.js';
import { classifyVolatileFact } from './volatile-runtime-facts.service.js';

/** How far back "recent activity" reaches when gathering context for one extraction pass. */
export const RECENT_ACTIVITY_DAYS = 14;

/** Most facts written for a single user in one pass — keeps the list from ballooning. */
export const MAX_FACTS_PER_RUN = 3;

/**
 * Token-overlap (Jaccard) threshold above which two facts are treated as the "same" durable
 * fact. 0.6 catches rephrasings ("calls mom on Sundays" vs "calls his mom every Sunday")
 * without collapsing genuinely distinct facts.
 */
export const DEFAULT_DEDUP_THRESHOLD = 0.6;

export interface ActivityTask {
  title: string;
  type: string | null;
  status: string | null;
  priority: string | null;
}

export interface ActivityComment {
  body: string;
  task_title: string;
}

export interface ActivityContext {
  /** Inclusive lower bound (ISO-8601 UTC) of the activity window. */
  since: string;
  tasks: ActivityTask[];
  completedTasks: string[];
  /** Comments the user themselves authored (their own words → richest signal). */
  userComments: ActivityComment[];
}

// ---------------------------------------------------------------------------
// Gather (read-only side effects)
// ---------------------------------------------------------------------------

/** [now - windowDays, now): everything updated/created at or after this instant is "recent". */
export function activityCutoff(now: Date, windowDays: number = RECENT_ACTIVITY_DAYS): Date {
  return new Date(now.getTime() - windowDays * 24 * 60 * 60 * 1000);
}

/**
 * Gather the recent activity a memory pass summarizes, scoped to one user. Deterministic shape
 * so buildExtractionPrompt and tests can both consume it. Only read queries.
 */
export async function gatherActivityContext(
  userId: string,
  now: Date,
  windowDays: number = RECENT_ACTIVITY_DAYS,
): Promise<ActivityContext> {
  const since = activityCutoff(now, windowDays);
  const sinceIso = since.toISOString();

  // Tasks/events the user touched recently — the surface area of what they care about.
  const tasksResult = await pool.query(
    `SELECT title, type, status, priority
       FROM tasks
      WHERE user_id = $1::uuid
        AND updated_at >= $2::timestamptz
      ORDER BY updated_at DESC
      LIMIT 60`,
    [userId, sinceIso],
  );

  // Tasks completed recently — finished goals are strong "what matters to them" signal.
  const completedResult = await pool.query(
    `SELECT title
       FROM tasks
      WHERE user_id = $1::uuid
        AND status = 'completed'
        AND updated_at >= $2::timestamptz
      ORDER BY updated_at DESC
      LIMIT 40`,
    [userId, sinceIso],
  );

  // The user's OWN comments — their words about their tasks, the richest durable-fact source.
  const commentsResult = await pool.query(
    `SELECT c.body, t.title AS task_title
       FROM task_comments c
       JOIN tasks t ON t.id = c.task_id
      WHERE c.user_id = $1::uuid
        AND c.author_kind = 'user'
        AND c.created_at >= $2::timestamptz
      ORDER BY c.created_at DESC
      LIMIT 40`,
    [userId, sinceIso],
  );

  return {
    since: sinceIso,
    tasks: tasksResult.rows.map((r) => ({
      title: r.title,
      type: r.type ?? null,
      status: r.status ?? null,
      priority: r.priority ?? null,
    })),
    completedTasks: completedResult.rows.map((r) => r.title as string),
    userComments: commentsResult.rows.map((r) => ({
      body: r.body,
      task_title: r.task_title,
    })),
  };
}

/** True when there is genuinely nothing to summarize (so we consult no runtime at all). */
export function isActivityEmpty(ctx: ActivityContext): boolean {
  return (
    ctx.tasks.length === 0 &&
    ctx.completedTasks.length === 0 &&
    ctx.userComments.length === 0
  );
}

// ---------------------------------------------------------------------------
// Dedupe (pure)
// ---------------------------------------------------------------------------

/** Lowercase, strip punctuation, collapse whitespace — the comparison form of a fact. */
export function normalizeFactForDedup(fact: string): string {
  return fact
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Trivial stopwords dropped before computing token overlap so "the/a/my" don't inflate it. */
const DEDUP_STOPWORDS = new Set([
  'a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'for', 'is', 'are',
  'my', 'his', 'her', 'their', 'i', 'he', 'she', 'they', 'it', 'with', 'every',
]);

/** Crude singularization so "cats"≈"cat" and "Sundays"≈"Sunday" count as the same token. */
function stem(token: string): string {
  return token.length > 3 && token.endsWith('s') ? token.slice(0, -1) : token;
}

function dedupTokens(fact: string): Set<string> {
  return new Set(
    normalizeFactForDedup(fact)
      .split(' ')
      .filter((t) => t.length > 0 && !DEDUP_STOPWORDS.has(t))
      .map(stem),
  );
}

/** Jaccard similarity (|A∩B| / |A∪B|) of two facts' meaningful tokens. 0..1. */
export function factSimilarity(a: string, b: string): number {
  const ta = dedupTokens(a);
  const tb = dedupTokens(b);
  if (ta.size === 0 && tb.size === 0) return 1;
  if (ta.size === 0 || tb.size === 0) return 0;
  let intersection = 0;
  for (const t of ta) if (tb.has(t)) intersection++;
  const union = ta.size + tb.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

/**
 * Are two facts near-duplicates? True when their normalized forms are equal, when one fully
 * contains the other, or when token overlap clears `threshold`.
 */
export function isNearDuplicateFact(
  a: string,
  b: string,
  threshold: number = DEFAULT_DEDUP_THRESHOLD,
): boolean {
  const na = normalizeFactForDedup(a);
  const nb = normalizeFactForDedup(b);
  if (na.length === 0 || nb.length === 0) return na === nb;
  if (na === nb) return true;
  if (na.includes(nb) || nb.includes(na)) return true;
  return factSimilarity(a, b) >= threshold;
}

/**
 * Filter `candidates` down to facts that are NOT near-duplicates of any existing fact, nor of
 * an earlier-accepted candidate in the same batch. Order-preserving. Pure.
 */
export function selectNovelFacts(
  candidates: string[],
  existing: string[],
  threshold: number = DEFAULT_DEDUP_THRESHOLD,
): string[] {
  const accepted: string[] = [];
  for (const candidate of candidates) {
    const trimmed = candidate.trim();
    if (trimmed.length === 0) continue;
    const isDup =
      existing.some((e) => isNearDuplicateFact(trimmed, e, threshold)) ||
      accepted.some((e) => isNearDuplicateFact(trimmed, e, threshold));
    if (!isDup) accepted.push(trimmed);
  }
  return accepted;
}

// ---------------------------------------------------------------------------
// Extract (the user's own gateway)
// ---------------------------------------------------------------------------

const EXTRACTION_SYSTEM =
  "You are Rem's memory keeper. From the user's recent activity, identify up to 3 DURABLE " +
  'facts worth remembering long-term: stable preferences, ongoing goals, recurring routines, ' +
  'relationships, or working context. Ignore one-off task details, dates, and anything ' +
  'transient. Each fact must be a single short sentence, stated about the user, factual and ' +
  'general (not "completed X today"). Output ONE fact per line, no numbering, no bullets, no ' +
  'preamble. If nothing durable stands out, output nothing.';

/** Render the gathered activity (plus the facts we already know) as the model's user prompt. */
export function buildExtractionPrompt(ctx: ActivityContext, existingFacts: string[]): string {
  const lines: string[] = [];

  if (existingFacts.length) {
    lines.push('ALREADY REMEMBERED (do not repeat these or close rephrasings):');
    lines.push(existingFacts.map((f) => `- ${f}`).join('\n'));
    lines.push('');
  }

  lines.push('RECENT TASKS & EVENTS:');
  lines.push(
    ctx.tasks.length
      ? ctx.tasks
          .map((t) => `- ${t.title} [${t.type ?? 'task'}${t.status ? `, ${t.status}` : ''}]`)
          .join('\n')
      : '(none)',
  );

  lines.push('', 'RECENTLY COMPLETED:');
  lines.push(
    ctx.completedTasks.length ? ctx.completedTasks.map((t) => `- ${t}`).join('\n') : '(none)',
  );

  lines.push('', 'NOTES THE USER WROTE:');
  lines.push(
    ctx.userComments.length
      ? ctx.userComments.map((c) => `- (on "${c.task_title}") ${c.body}`).join('\n')
      : '(none)',
  );

  return lines.join('\n');
}

/**
 * Parse a model completion into a clean list of candidate facts. Strips bullets / numbering /
 * surrounding quotes, drops blank or obvious-preamble lines, caps each fact's length, and
 * de-duplicates within the batch. Pure → unit-tested without any model call.
 */
export function parseFactsFromCompletion(
  text: string,
  maxFacts: number = MAX_FACTS_PER_RUN,
): string[] {
  const out: string[] = [];
  for (const rawLine of text.split('\n')) {
    let line = rawLine.trim();
    if (line.length === 0) continue;
    // Strip a leading bullet ("- ", "* ", "• ") or numbering ("1.", "2)").
    line = line.replace(/^[-*•]\s+/, '').replace(/^\d+[.)]\s+/, '');
    // Strip wrapping quotes the model sometimes adds.
    line = line.replace(/^["'“”]+/, '').replace(/["'“”]+$/, '').trim();
    if (line.length < 4) continue;
    // Skip lines that are clearly conversational preamble rather than a fact.
    if (/^(here|based on|the user|sure|okay|i (have|found)|note:)/i.test(line)) continue;
    // Volatile runtime facts are INELIGIBLE for durable memory (#1282/#1277). A stored
    // "the user is on WebChat" or "Rem can check photos" is re-injected into every future
    // session and outranks the correct, regenerated prompt forever. Dropped here so a
    // volatile candidate never reaches the store, and again in addMemory as the backstop.
    // The log line names the rule id only — never the candidate, which is user-derived.
    const verdict = classifyVolatileFact(line);
    if (verdict.volatile) {
      console.warn(`[MEMORY] dropped volatile candidate (rule ${verdict.rule})`);
      continue;
    }
    if (line.length > MEMORY_FACT_MAX_LENGTH) line = line.slice(0, MEMORY_FACT_MAX_LENGTH).trim();
    // De-dupe within the model's own output.
    if (out.some((f) => isNearDuplicateFact(f, line))) continue;
    out.push(line);
    if (out.length >= maxFacts) break;
  }
  return out;
}

export interface ExtractOptions {
  windowDays?: number;
  maxFacts?: number;
  dedupThreshold?: number;
}

/**
 * Extract the NOVEL durable facts for one user: gather recent activity, ask THE USER'S OWN
 * GATEWAY for candidate facts, then dedupe against `existingFacts`. Returns the facts that should
 * be written (already trimmed + deduped) — or `[]` when there is nothing to summarize, the
 * gateway could not take the turn, or everything it surfaced is already known.
 *
 * DOES NOT THROW on a runtime failure. It used to: the org-key GMI path threw on transport/HTTP
 * errors and on an empty completion, and `extract-memories.ts` classified the two apart so a
 * model no-op could not fail the whole cron run (#906). Both are gone — `runAgentTurnOnGateway`
 * never throws, and an empty turn is simply no facts — so that classification is structural now
 * and the script's catch handles only genuine errors (DB, malformed data).
 */
export async function extractNovelFactsForUser(
  userId: string,
  now: Date,
  existingFacts: string[],
  opts: ExtractOptions = {},
): Promise<string[]> {
  const windowDays = opts.windowDays ?? RECENT_ACTIVITY_DAYS;
  const maxFacts = opts.maxFacts ?? MAX_FACTS_PER_RUN;
  const threshold = opts.dedupThreshold ?? DEFAULT_DEDUP_THRESHOLD;

  const ctx = await gatherActivityContext(userId, now, windowDays);
  if (isActivityEmpty(ctx)) return [];

  const userPrompt = buildExtractionPrompt(ctx, existingFacts);

  // ONE RUNTIME: the user's gateway (chat.send). Extraction runs on the gateway's own model,
  // so GMI's empty-completion intolerance (#906) is moot for this path — an empty gateway
  // reply just means "no durable facts", which parses to []. A gateway-less user, or a
  // wake/turn failure, extracts NOTHING. See the fallback note in this file's header.
  const viaGateway = await runAgentTurnOnGateway({
    userId,
    // Date-scoped so each pass is its own session (no unbounded history growth).
    sessionKey: `rem-memory-${utcDateStamp(now)}`,
    message: `${EXTRACTION_SYSTEM}\n\n${userPrompt}`,
  });
  if (!viaGateway.ok) return [];
  const content: string = viaGateway.text;

  const candidates = parseFactsFromCompletion(content, maxFacts);
  return selectNovelFacts(candidates, existingFacts, threshold).slice(0, maxFacts);
}
