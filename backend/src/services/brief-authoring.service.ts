/**
 * AI-authored daily brief prose (docs/rebuild/27-BRIEF-AS-AI-AND-LANDING.md).
 *
 * The daily brief is a REGENERATING ARTIFACT (a snapshot), not a chat. Its PROSE — the
 * full-brief `markdown` the app expands into — is written by the user's OWN gateway agent
 * (Move-2, gateway-agent.service.ts), in Rem's voice, instead of the deterministic
 * template `composeBriefProse` assembles.
 *
 * TWO SESSIONS, decoupled (Phase 1 re-architecture):
 *
 *   1. AUTHORING — the prose for a cron cycle is written in a FRESH context every time.
 *      `authoringSessionKey` mints an EPHEMERAL, per-run key (`rem-brief-author-<localday>-<runId>`)
 *      so the authoring turn NEVER replays prior turns. This is what kills the old failure
 *      mode: the previous design re-prompted ONE stable session every cycle, so history
 *      accumulated → the model started replying "NO_REPLY", the prose went stale, and it
 *      read like a chat. A fresh context per cycle produces clean, current prose each time.
 *
 *   2. CONVERSATION — the durable session the USER replies into is SEPARATE
 *      (`conversationSessionKey` = `rem-orchestrator`). Capability-aware Summary clients receive
 *      this key; legacy clients retain their per-day bridge. It is NOT the authoring session, so
 *      machine's authoring turns never cross-contaminate. Authored prose is appended as a visible
 *      assistant artifact with `chat.inject`; unlike `chat.send`, that executes no turn and leaks
 *      no internal context prompt or acknowledgement. `chat.inject.label` is deliberately unused
 *      because upstream renders it; ambiguous delivery reconciles only a new exact-prose occurrence
 *      after the artifact's persisted baseline, with lease ownership fenced before injection.
 *
 * We CACHE the latest card (`markdown`) + a lead `summary` in Postgres (`daily_briefs`,
 * migration 033) so the fast GET /api/v1/brief handler can read it back without ever
 * running a 120s gateway turn inline. Mirrors digest.service.ts.
 *
 * DATE is resolved in the USER'S LOCAL timezone (not UTC) — so the brief says "Sunday
 * evening", not "Monday" at 8pm Sunday Pacific. Timezone source: `user_checkins.timezone`
 * (IANA, app-sent via TimeZone.current when a check-in slot is enabled). See
 * `resolveUserTimezone`.
 *
 * OFF BY DEFAULT: authoring only runs when `BRIEF_AI_AUTHORING_ENABLED` is truthy. With
 * the flag off, no rows are written and the read override is skipped — the brief keeps
 * returning the deterministic prose, so shipping this is fully reversible.
 *
 * Lifecycle (principle 2), never-throws per user:
 *   - create/update : `authorBriefForUser` gathers today's brief. An empty live snapshot
 *                     returns without claiming, persisting, or delivering an assistant turn.
 *                     Non-empty snapshots run one FRESH-context gateway turn, UPSERT the
 *                     markdown for (user_id, today's local date), and seed the conversation
 *                     session. A later cron tick re-authors as the day's tasks move.
 *   - read          : `readAuthoredBrief` returns today's cached card + summary (or null).
 *   - recover       : any gateway failure (no gateway / wake / timeout / error) returns a
 *                     structured skip and writes NOTHING — the read path falls back to the
 *                     deterministic prose, and a good prior row is never overwritten by a
 *                     failed turn.
 */

import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { pool, type DatabaseQueryable } from '../db/pool.js';
import { gatherBrief, type BriefItem, type DailyBrief } from './brief.service.js';
import {
  hasAuthorableBriefInput,
  renderBriefInputPrompt,
  type BriefInputSnapshot,
} from './brief-input.service.js';
import {
  runAgentTurnOnGateway,
  injectAssistantMessageOnGateway,
} from './gateway-agent.service.js';
import { gmiChat } from './gmi.service.js';
import { mayChargeRemManagedKey, resolveModelRuntimeMode } from './run-block.js';
import {
  briefSurfacedTaskIds,
  briefWithoutStaleTasks,
  recordBriefSurfacing,
} from './task-staleness.service.js';

/**
 * Feature flag. Fleet-wide brief authoring (a per-user gateway turn on a cron) stays OFF
 * unless an operator opts in via `BRIEF_AI_AUTHORING_ENABLED` (truthy: 1/true/yes/on).
 * Mirrors `isSweepEnabled` (orchestrator-sweep.service.ts).
 */
export function isBriefAuthoringEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return /^(1|true|yes|on)$/i.test((env.BRIEF_AI_AUTHORING_ENABLED ?? '').trim());
}

/**
 * Safe default when a user has no stored timezone yet (never launched a build that captures
 * the device tz, and never enabled a check-in). UTC is the conservative last resort: the
 * date/time-of-day may be off for users west/east of UTC, but it never crashes and matches
 * the check-in scheduler's own fallback (checkin.service.ts `getCheckinSettings`
 * fallbackTimezone).
 */
export const DEFAULT_BRIEF_TIMEZONE = 'UTC';

/**
 * Resolve the user's IANA timezone — the SINGLE source of truth every brief surface uses
 * (the cron authoring loop, `GET /api/v1/brief`, `localTimeOfDay` / `localDateHeading` /
 * `authoringSlot`). Resolution chain, most-authoritative first:
 *
 *   1. `users.timezone` — the DEVICE tz the app persists best-effort on launch/foreground/
 *      login (migration 101, POST /api/v1/users/timezone). Always available once the app has
 *      run, regardless of whether any check-in slot is enabled. This is the fix for issue
 *      #1097: without it, a negative-offset user with no check-in fell back to UTC and got an
 *      "evening" greeting in the afternoon + a stuck authoring slot.
 *   2. `user_checkins.timezone` — the legacy source (migration 027), written only once a slot
 *      is enabled. Picks the MOST RECENTLY UPDATED row's tz. Kept as a fallback so users who
 *      enabled a check-in on an older build still resolve correctly before their next launch.
 *   3. UTC — conservative last resort.
 *
 * Never throws. A future manual account-level tz-override SETTING would layer on step 1
 * (`users.timezone`) — it is the same column, so no new resolution step is needed.
 */
export async function resolveUserTimezone(
  userId: string,
  fallback: string = DEFAULT_BRIEF_TIMEZONE,
  db: DatabaseQueryable = pool,
): Promise<string> {
  try {
    return await resolveStoredUserTimezone(userId, db) ?? fallback;
  } catch {
    return fallback;
  }
}

/**
 * Resolve only persisted timezone state. Unlike `resolveUserTimezone`, database failures are
 * intentionally allowed to escape and missing/invalid state returns null. Mutation paths use
 * this strict form so a transient read failure can never turn the display-only UTC fallback into
 * a destructive gateway config update.
 */
export async function resolveStoredUserTimezone(
  userId: string,
  db: DatabaseQueryable = pool,
): Promise<string | null> {
  // 1) Device tz persisted on the user row (top of the chain).
  const userRow = await db.query<{ timezone: string | null }>(
    `SELECT timezone FROM users WHERE id = $1::uuid LIMIT 1`,
    [userId],
  );
  const userTz = userRow.rows[0]?.timezone?.trim();
  if (userTz && isValidTimezone(userTz)) return userTz;

  // 2) Legacy check-in tz (most recently updated slot).
  const checkinRow = await db.query<{ timezone: string }>(
    `SELECT timezone FROM user_checkins
      WHERE user_id = $1::uuid AND timezone IS NOT NULL AND timezone <> ''
      ORDER BY updated_at DESC
      LIMIT 1`,
    [userId],
  );
  const checkinTz = checkinRow.rows[0]?.timezone?.trim();
  return checkinTz && isValidTimezone(checkinTz) ? checkinTz : null;
}

/** True if `tz` is an IANA zone Intl accepts — guards against a garbage stored value.
 * Exported so the write path (POST /api/v1/users/timezone) validates with the SAME rule the
 * read path trusts, and no other module has to re-implement it. */
export function isValidTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * `yyyymmdd` for an instant in a given IANA timezone — the LOCAL calendar day. Used to
 * date-scope session keys and the `daily_briefs` row to the user's own day, so an 8pm
 * Sunday brief in Pacific is "Sunday", not the UTC "Monday". Pure (deterministic per
 * now+tz).
 */
export function localDateStamp(now: Date, timezone: string): string {
  // en-CA yields yyyy-mm-dd; strip the dashes for the compact stamp.
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
  return parts.replace(/-/g, '');
}

/** `yyyy-mm-dd` LOCAL calendar day (the `daily_briefs.brief_date` value). Pure. */
export function localBriefDate(now: Date, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
}

export type TimeOfDay = 'morning' | 'afternoon' | 'evening';

/** Canonical local-day chronology shared by explicit check-ins and the cache write fence. */
export function briefSlotRank(slot: TimeOfDay): number {
  switch (slot) {
    case 'morning': return 1;
    case 'afternoon': return 2;
    case 'evening': return 3;
  }
}

/** Local time-of-day bucket used to ground the brief's tone and authoring cadence. Pure. */
export function localTimeOfDay(now: Date, timezone: string): TimeOfDay {
  const hourStr = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour: '2-digit',
    hour12: false,
  }).format(now);
  // en-US hour12:false can emit "24" for midnight; normalize to 0.
  const hour = Number.parseInt(hourStr, 10) % 24;
  if (hour < 12) return 'morning';
  if (hour < 17) return 'afternoon';
  return 'evening';
}

/**
 * AUTHORING CADENCE (flag for O to tune) — the local-clock hour at/after which each slot
 * becomes eligible to author. Authoring fires on the FIRST cron tick that lands in a new
 * slot each local day, then dedupes for the rest of the slot (see `authorBriefForUser`'s
 * `authored_slot` check), so a user's brief is re-authored at most THREE times/day:
 *
 *   - morning   : from 06:00 local  (the "good morning" brief)
 *   - afternoon : from 12:00 local  (a midday refresh)
 *   - evening   : from 17:00 local  (the evening recap)
 *
 * Ticks before 06:00 local author nothing (no midnight gateway wakes). This replaces the
 * old behaviour of re-authoring on every 15-minute tick (~96 wakes/user/day). Tune the
 * hours here — the slot names line up with `localTimeOfDay`'s buckets and the check-in slots.
 */
export const AUTHORING_SLOT_START_HOURS: Record<TimeOfDay, number> = {
  morning: 6,
  afternoon: 12,
  evening: 17,
};

/**
 * The slot this instant is eligible to author in, or `null` when it's too early in the day
 * to author at all (before the morning slot start). Pure. The dedupe in `authorBriefForUser`
 * then ensures we author only ONCE per returned slot per local day. Because every hour ≥ the
 * morning start falls into exactly one bucket, the first tick to enter each bucket authors
 * and the rest are deduped — yielding ~3 authoring runs/user/day instead of ~96.
 */
export function authoringSlot(now: Date, timezone: string): TimeOfDay | null {
  const hourStr = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hour: '2-digit',
    hour12: false,
  }).format(now);
  const hour = Number.parseInt(hourStr, 10) % 24;
  if (hour < AUTHORING_SLOT_START_HOURS.morning) return null; // too early — no wake
  return localTimeOfDay(now, timezone);
}

/** Human date + time-of-day the prose should ground itself in (e.g. "Sunday, July 6 — evening"). */
export function localDateHeading(now: Date, timezone: string): string {
  const label = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  }).format(now);
  return `${label} — ${localTimeOfDay(now, timezone)}`;
}

/**
 * The EPHEMERAL, per-run authoring session key. A fresh key every cycle means the authoring
 * turn runs in a CLEAN context (no replayed history) — the fix for accumulating-history
 * staleness + "NO_REPLY". `runId` disambiguates concurrent/successive runs in the same
 * local day. This session is a throwaway; the user never opens it.
 */
export function authoringSessionKey(now: Date, timezone: string, runId: string): string {
  return `rem-brief-author-${localDateStamp(now, timezone)}-${runId}`;
}

/**
 * The PERSISTENT orchestrator conversation the USER replies into.
 *
 * Daily brief authoring still uses a fresh throwaway session for each run, but the capability-aware
 * Agenda Summary doorway opens this one durable transcript. Message timestamps are
 * the day boundary; the clients render them as compact dividers instead of creating one chat per
 * date. Keep the unused arguments for source compatibility with callers that already resolve the
 * user's local day before asking for the conversation key.
 */
export function conversationSessionKey(_now: Date, _timezone: string): string {
  return 'rem-orchestrator';
}

/** Legacy per-day route kept live during the two-phase client/backend rollout. */
export function legacyConversationSessionKey(now: Date, timezone: string): string {
  return `rem-today-${localDateStamp(now, timezone)}`;
}

/** Outcome of authoring one user's brief. Structured so the cron can log a summary. */
export type BriefAuthoringStatus =
  | 'authored' // gateway wrote the prose; row upserted
  | 'empty' // nothing worth a brief today; skipped the gateway turn and wrote no chat message
  | 'skipped_slot' // off-slot, or this slot's brief was already authored today → no gateway wake
  | 'skipped_gateway'; // no gateway / wake / timeout / error → wrote nothing, retry later

export interface BriefAuthoringResult {
  userId: string;
  status: BriefAuthoringStatus;
  /** Structured gateway reason on the skipped_gateway path, else null. */
  reason: string | null;
}

/**
 * The connector-enrichment producer was not run because the operator's key may not pay for this
 * user's models (`run-block.ts: mayChargeRemManagedKey`). A named constant rather than a literal
 * because three places must agree on it: the producer, the permanence classifier below, and the
 * tests that prove a BYOK user is not silently charged.
 *
 * Distinct from `connector_model_unavailable` on purpose. That one means "the backend model was
 * asked and could not answer" — an outage, worth retrying. This one means "the backend model was
 * never asked, and would be wrong to ask" — a policy outcome, not a failure. Collapsing them
 * would make a deliberate refusal indistinguishable from a GMI incident in the cron summary.
 */
export const CONNECTOR_MODEL_NOT_OWNED = 'connector_model_not_owned';

/**
 * Is a `skipped_gateway` reason PERMANENT for the rest of the user's local day — i.e. provably
 * unchanged by waiting?
 *
 * ⚠️ ADVISORY, NOT LOAD-BEARING, as of #1285. The docblock below still describes the original
 * intent (short-circuit the check-in scheduler's retry budget), but `daily-checkins.ts:492-494`
 * deliberately stopped consulting it for that decision: the attempt budget is now the single
 * bound, because a per-reason denylist "could only ever delete recovery paths". This function
 * survives for callers that want the distinction for LOGGING. Classifying a reason here
 * therefore changes no retry behaviour today — do not read an addition to the list as one.
 *
 * This is deliberately an ALLOWLIST of permanence, not the complement of a transient list, and the
 * direction matters more than the contents. The attempt budget in `daily-checkins.ts` is already a
 * hard backstop: a reason wrongly called transient costs at most CHECKIN_MAX_DELIVERY_ATTEMPTS
 * authoring runs and then stops. A reason wrongly called permanent costs the user their whole day's
 * brief on the first blip, with no error surface anywhere. The two mistakes are not symmetric, so
 * anything unrecognized — including a reason some future producer adds — keeps its budget.
 *
 * PERMANENT:
 *   - `no_gateway` — the user has never deployed one (gateway-agent.service). Deploying is a
 *     multi-minute onboarding flow, not something that completes between two 15-minute ticks.
 *   - `connector_model_not_owned` — the operator's key may not pay for this user's models. The
 *     input is `users.hosting_provider`, a stable row that changes only by re-deploying the
 *     gateway. That is the SAME multi-minute onboarding flow the `no_gateway` clause already
 *     reasons about, so it qualifies under the identical argument rather than a new one. This is
 *     a policy answer, not a blip, and re-asking it 15 minutes later cannot return anything else.
 *
 * Everything else retries within the budget. Two classes are easy to mistake for hard failures:
 *   - the BARE `error` from `runAgentTurnOnGateway` — a dropped socket, a rejected `chat.send`, or
 *     "gateway connection closed before final". That is transport, and transport recovers.
 *   - `error: <message>` from this service's own catch, which wraps `gatherBrief`, the upsert, AND
 *     `deliverBriefArtifactForRollout`. A throw in that last call means the artifact is COMMITTED
 *     but undelivered; consuming the slot there strands a brief that exists and can never be sent.
 *     The next tick converges because `claimBriefAuthoring` re-runs the rollout delivery.
 *
 * Classify by matching the reason a producer actually emits — never by substring-sniffing the
 * message. That is precisely why permanence is an equality check against a closed set: `error: …`
 * is an open-ended interpolation, and recognizing it would mean parsing a human-readable string
 * for a machine decision.
 */
export function isPermanentGatewaySkip(reason: string | null): boolean {
  return reason === 'no_gateway' || reason === CONNECTOR_MODEL_NOT_OWNED;
}

const BRIEF_SYSTEM_PROMPT =
  // The brief is an ORCHESTRATOR TRIAGE opener, not a flat recap (docs/rebuild/34, O's
  // 2026-07-05 direction): tapping the brief lands the user in this chat, so its latest
  // message should update them on the day AND help them triage. Same gateway turn / session /
  // cache — only the instruction is sharpened from "summarize" to "summarize + offer a
  // concrete triage action per attention item." Still strictly grounded in the provided data.
  "You are Rem, opening the user's daily triage in your own voice — warm, concise, and " +
  'specific. Speak to the user directly, as the orchestrator who is on top of their day. ' +
  'BEGIN WITH A HEADLINE: the very first line must be `## ` followed by a title of two to five ' +
  'words naming this brief (for example `## The Day`, `## Your Monday Evening`). The apps render ' +
  'that headline as the title of BOTH the Agenda summary and this conversation, so it must be a ' +
  'title, not a sentence: no trailing punctuation, no counts, no task names. ' +
  'Do NOT greet — no "Good morning", "Good afternoon", "Good evening", or other greeting, in the ' +
  'headline or the body. After the headline, open with a short, ' +
  'substantive sentence describing what matters in the brief. Ground EVERY ' +
  'sentence in the data provided; never invent tasks, events, times, or facts that are not ' +
  'listed. Structure it in three beats: (1) a short opening line on how the day looks; ' +
  '(2) what needs a decision now — lead with blocked, then overdue, and for each say ' +
  'briefly why it needs the user (fold in what Rem last did if shown); (3) for those ' +
  'attention items, OFFER a concrete next action per item — reschedule it, have Rem take a ' +
  'first pass, or drop it — and invite the user to reply with which to do. Then note what is ' +
  'on deck today and what is already done. Keep it tight: compact markdown sections (use ' +
  '`## ` headings and `- ` bullets) only for the buckets that have items; do not restate ' +
  'empty buckets. When nothing needs a decision, skip the triage offer and just orient them. ' +
  'No preamble like "Here is your brief" — just write it. Always write the brief; never reply ' +
  'with a control token or a refusal like "NO_REPLY".';

/** One clean inline line from free text (task titles are user/AI-authored). */
function inlineTitle(text: string): string {
  const collapsed = text.replace(/\s+/g, ' ').trim();
  if (!collapsed) return 'Untitled task';
  return collapsed.length > 120 ? `${collapsed.slice(0, 119)}…` : collapsed;
}

/** Render one bucket as labelled lines for the agent's context (capped). */
function renderBucket(label: string, items: BriefItem[], withActivity = false): string[] {
  if (items.length === 0) return [];
  const lines = [`${label}:`];
  for (const it of items.slice(0, 12)) {
    const activity = withActivity ? it.latest_activity?.summary?.trim() : '';
    lines.push(`- ${inlineTitle(it.title)}${activity ? ` — (Rem last: ${activity})` : ''}`);
  }
  if (items.length > 12) lines.push(`- …and ${items.length - 12} more`);
  return lines;
}

/**
 * Render the gathered brief as the user-message CONTEXT the agent authors from. Pure. The
 * agent turns this structured context into prose; we never ship this raw to the client.
 *
 * `dateHeading` grounds the prose in the user's LOCAL day + time-of-day (e.g.
 * "Sunday, July 6 — evening") so the greeting and date match reality, not a UTC stamp.
 */
export function buildBriefAuthoringPrompt(
  brief: DailyBrief,
  dateHeading?: string,
  inputSnapshot?: BriefInputSnapshot,
): string {
  const c = brief.counts;
  const connectorLines = renderBriefInputPrompt(inputSnapshot);
  const lines: string[] = [
    BRIEF_SYSTEM_PROMPT,
    '',
    ...(dateHeading ? [`LOCAL DATE & TIME: ${dateHeading}.`, ''] : []),
    `TODAY: ${c.done} of ${c.total} done · ${c.blocked} blocked · ${c.overdue} overdue · ${c.scheduled_today} on deck.`,
    '',
    ...renderBucket('BLOCKED — needs a decision', brief.blocked, true),
    ...(brief.blocked.length ? [''] : []),
    ...renderBucket('OVERDUE', brief.overdue),
    ...(brief.overdue.length ? [''] : []),
    ...renderBucket('ON DECK TODAY', brief.scheduled_today),
    ...(brief.scheduled_today.length ? [''] : []),
    ...renderBucket('DONE TODAY', brief.completed_today),
    ...(connectorLines.length ? ['', ...connectorLines] : []),
  ];
  return lines.join('\n').trim();
}

/** True when there is genuinely nothing to author (all buckets empty) — skip the turn. */
export function isBriefEmpty(brief: DailyBrief, inputSnapshot?: BriefInputSnapshot): boolean {
  const c = brief.counts;
  return isTaskBriefEmpty(brief) && !hasAuthorableBriefInput(inputSnapshot);
}

function isTaskBriefEmpty(brief: DailyBrief): boolean {
  const c = brief.counts;
  return c.blocked === 0 && c.overdue === 0 && c.scheduled_today === 0 && c.completed_today === 0;
}

function hasRetryableUnavailableInput(snapshot?: BriefInputSnapshot): boolean {
  return snapshot?.manifest.some((source) =>
    source.availability === 'unavailable'
    && (source.unavailableReason === 'connector_unavailable' || source.unavailableReason === 'timeout')
  ) === true;
}

/**
 * Control tokens the model can emit when it has "nothing to add" (a chat reflex we must
 * never surface as brief prose). Matches a standalone line that is ONLY the token, with
 * optional surrounding brackets/punctuation — e.g. `NO_REPLY`, `[NO_REPLY]`, `NOREPLY.`,
 * `(no reply)`. Case-insensitive. We deliberately DON'T strip these mid-sentence so real
 * prose that happens to contain the phrase is left intact.
 */
const CONTROL_TOKEN_LINE =
  /^[\s>*_-]*[[(]?\s*(?:no[_\s-]?reply|noreply|no[_\s-]?response|silent)\s*[\])]?[\s.!]*$/i;

/**
 * Strip standalone control-token lines from authored prose so "NO_REPLY" (and kin) can
 * NEVER reach the stored/returned brief. Returns the cleaned, trimmed prose (may be empty
 * if the whole turn was just a control token — the caller then treats it as empty text and
 * writes nothing, preserving any good prior card).
 */
export function stripControlTokens(text: string): string {
  return text
    .split('\n')
    .filter((line) => !CONTROL_TOKEN_LINE.test(line))
    .join('\n')
    .trim();
}

/** The card's markdown + the landing summary derived from it (the chat's latest message). */
export interface AuthoredBrief {
  markdown: string;
  /** Short lead extracted from the card = "a summary of the brief chat's latest message". */
  summary: string | null;
}

export interface AuthoredBriefDelivery extends AuthoredBrief {
  /**
   * The artifact's authored headline — the ONE title string. The Agenda summary card and the
   * orchestrator chat both render this; neither derives its own. Null for artifacts authored
   * before migration 119 whose prose opened without a heading, in which case each surface keeps
   * the fallback title it used before (time-of-day on the card, "Rem" in chat).
   */
  headline: string | null;
  /** Delivery proof read from the same database snapshot as this exact prose. */
  delivered: boolean;
  source: BriefArtifact['source'];
  /** Slot owning the current canonical pointer; notification labels must match this value. */
  authoredSlot: TimeOfDay;
  /** Immutable revision of the exact canonical artifact whose delivery was proven. */
  revision: string;
}

const LEGACY_GREETING_HEAD =
  /^(?:good\s+(?:morning|afternoon|evening)|morning|afternoon|evening(?:\s+recap)?|happy\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|hello|hi|hey)\b/iu;

/** Remove a legacy card greeting without mistaking comma-following substance for a name. */
function stripLegacyGreeting(text: string): { text: string; removed: boolean } {
  const greeting = text.match(LEGACY_GREETING_HEAD);
  if (!greeting) return { text, removed: false };

  const remainder = text.slice(greeting[0].length);
  const dash = remainder.match(/^(?:\s*[—–]\s*|\s+-\s+)/u);
  if (dash) return { text: remainder.slice(dash[0].length).trim(), removed: true };

  const recipientBeforeDash = remainder.match(
    /^\s*,?\s*\p{Lu}[\p{L}'’-]*(?:\s+\p{Lu}[\p{L}'’-]*){0,3}(?:\s*[—–]\s*|\s+-\s+)/u,
  );
  if (recipientBeforeDash) {
    return { text: remainder.slice(recipientBeforeDash[0].length).trim(), removed: true };
  }

  const bareTerminator = remainder.match(/^\s*[.!:;](?:\s+|$)/u);
  if (bareTerminator) {
    return { text: remainder.slice(bareTerminator[0].length).trim(), removed: true };
  }

  // A recipient may be comma-separated or bare ("Good morning Sam."). Require every
  // recipient token to be title-cased so "Good morning, three tasks need attention" keeps
  // the substantive clause instead of consuming it as a four-word name.
  const recipient = remainder.match(
    /^\s*,?\s*\p{Lu}[\p{L}'’-]*(?:\s+\p{Lu}[\p{L}'’-]*){0,3}\s*[.!:;](?:\s+|$)/u,
  );
  if (recipient) {
    return { text: remainder.slice(recipient[0].length).trim(), removed: true };
  }

  // A comma with no title-cased recipient introduces the description itself.
  const comma = remainder.match(/^\s*,\s*/u);
  if (comma) return { text: remainder.slice(comma[0].length).trim(), removed: true };
  return { text, removed: false };
}

/** First sentence without splitting common titles or clock abbreviations. */
function firstBriefSentence(text: string): string {
  const placeholder = '\u0000';
  const protectedText = text
    .replace(/\b(?:[ap]\.m|e\.g|i\.e|u\.s|u\.k)\./giu, (token) =>
      token.replaceAll('.', placeholder),
    )
    .replace(/\b(?:Mr|Mrs|Ms|Mx|Dr|Prof|Sr|Jr|Sen|Rep|Gov|Pres|Gen|Lt|Col|Capt|Rev|Hon|Sgt|Adm|Cmdr|Cpl|Maj)\./gu, (token) =>
      token.replaceAll('.', placeholder),
    )
    .replace(/\b\p{Lu}\.(?=\s+\p{Lu})/gu, (token) => token.replace('.', placeholder));
  const first = protectedText.match(/^.*?[.!?](?=\s|$)/u)?.[0] ?? protectedText;
  return first.replaceAll(placeholder, '.');
}

/** Normalize either a stored summary or one prose line from authored markdown. */
function normalizeBriefSummary(text: string): string | null {
  const collapsed = text.replace(/\s+/g, ' ').trim();
  if (!collapsed) return null;

  const greeting = stripLegacyGreeting(collapsed);
  const withoutGreeting = greeting.text;
  const greetingRemoved = greeting.removed;
  // A greeting-only summary has no useful description. Let callers fall back to markdown
  // or the deterministic summary instead of displaying a duplicate card title.
  if (!withoutGreeting && greetingRemoved) return null;

  const substantive = greetingRemoved
    ? withoutGreeting.replace(/^(\p{Ll})/u, (letter) => letter.toLocaleUpperCase())
    : collapsed;
  const firstSentence = firstBriefSentence(substantive);
  return firstSentence.length > 200 ? `${firstSentence.slice(0, 199)}…` : firstSentence;
}

/**
 * Extract the landing summary from the authored card: the first meaningful line of prose
 * (skipping markdown headings / bullets / blank lines), collapsed to its first sentence and capped.
 * The client already owns the time-of-day card title, so strip a legacy generic greeting
 * prefix rather than repeating "Good morning" above the actual description.
 * This is the founder's "summary of the chat's LATEST message" — the card IS that message.
 * Returns null when no prose line can be found; response assembly must then omit the summary
 * rather than retain prose derived from a different artifact.
 */
export function summarizeBriefLead(markdown: string): string | null {
  const lines = markdown
    .split('\n')
    .map((l) => l.trim())
    // Skip headings (#), bullets (-, *), quotes (>), and blank lines — we want the prose.
    .filter((l) => l.length > 0 && !/^([#>*-]|\d+\.)/.test(l));
  for (const line of lines) {
    const summary = normalizeBriefSummary(line);
    if (summary) return summary;
  }
  return null;
}

/**
 * Longest headline we persist. Matches `daily_brief_artifacts.headline VARCHAR(120)` and the
 * `LEFT(..., 120)` cap in migration 119, so the SQL backfill and this extractor cannot disagree
 * about a long heading.
 */
const BRIEF_HEADLINE_MAX_LENGTH = 120;

/**
 * The brief's authored HEADLINE: the `## Title` line the authoring turn is instructed to emit as
 * line 1 (see BRIEF_SYSTEM_PROMPT).
 *
 * This runs ONCE, at authoring time, and the result is stored in `daily_brief_artifacts.headline`.
 * It is deliberately not a render-time parse: the Agenda summary card and the orchestrator chat
 * title must show the same string, and they can only do that if the string is a field of the
 * artifact rather than something each surface re-derives from prose.
 *
 * Returns null when the artifact does not open with a heading — an older-style brief, or a turn
 * that ignored the instruction. Null means "no authored headline", and every client keeps the
 * fallback title it already had. Migration 116 applies this same rule to pre-existing rows.
 */
export function extractBriefHeadline(markdown: string): string | null {
  const firstLine = markdown
    .split('\n')
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  if (!firstLine) return null;

  const heading = firstLine.match(/^#{1,3}[ \t]+(.+)$/u);
  if (!heading) return null;

  // Strip emphasis/backticks and any closing `#`s so `## **The Day** ##` and `## The Day` store
  // the same value. Mirrors the `[*_`#]` character class in migration 119's backfill.
  const cleaned = heading[1].replace(/[*_`#]/gu, '').replace(/\s+/g, ' ').trim();
  if (!cleaned) return null;
  return cleaned.slice(0, BRIEF_HEADLINE_MAX_LENGTH).trim() || null;
}

export interface BriefArtifact {
  id: string;
  revision: string;
  markdown: string;
  summary: string | null;
  /** Authored title shared by the Agenda summary and the orchestrator chat; null on older rows. */
  headline: string | null;
  slot: TimeOfDay;
  source: 'gateway' | 'fallback';
}

interface AuthoringClaim {
  leaseToken: string | null;
  artifact: BriefArtifact | null;
}

/** Claim one authoring lease per user/day/slot. A crashed worker becomes retryable after 5 min. */
async function claimBriefAuthoring(
  userId: string,
  briefDate: string,
  slot: TimeOfDay,
  source: BriefArtifact['source'],
): Promise<AuthoringClaim> {
  const leaseToken = randomUUID();
  const claimed = await pool.query<{
    id: string;
    revision: string;
    markdown: string | null;
    summary: string | null;
    headline: string | null;
    source: BriefArtifact['source'];
  }>(
    `INSERT INTO daily_brief_artifacts
       (user_id, brief_date, authored_slot, authoring_lease_token, authoring_lease_expires_at, source)
     VALUES ($1::uuid, $2::date, $3, $4::uuid, NOW() + INTERVAL '5 minutes', $5)
     ON CONFLICT (user_id, brief_date, authored_slot)
     DO UPDATE SET authoring_lease_token = EXCLUDED.authoring_lease_token,
                   authoring_lease_expires_at = EXCLUDED.authoring_lease_expires_at,
                   updated_at = NOW()
       WHERE (
         daily_brief_artifacts.markdown IS NULL
         AND (daily_brief_artifacts.authoring_lease_expires_at IS NULL
           OR daily_brief_artifacts.authoring_lease_expires_at <= NOW())
       ) OR (
         daily_brief_artifacts.source <> EXCLUDED.source
         AND (daily_brief_artifacts.authoring_lease_expires_at IS NULL
           OR daily_brief_artifacts.authoring_lease_expires_at <= NOW())
         AND (daily_brief_artifacts.delivery_fence_expires_at IS NULL
           OR daily_brief_artifacts.delivery_fence_expires_at <= NOW())
       )
     RETURNING id, revision, markdown, summary, headline, source`,
    [userId, briefDate, slot, leaseToken, source],
  );
  const claimedRow = claimed.rows[0];
  if (claimedRow) {
    // A changed empty/non-empty state may supersede the completed artifact in the same slot.
    // The lease is acquired while prior prose remains readable; only successful replacement
    // persistence changes it, so a failed gateway turn cannot erase the last good card.
    if (claimedRow.source !== source) {
      return { leaseToken, artifact: null };
    }
    if (claimedRow.markdown === null) return { leaseToken, artifact: null };
  }

  const existing = await pool.query<{
    id: string;
    revision: string;
    markdown: string | null;
    summary: string | null;
    headline: string | null;
    source: BriefArtifact['source'];
    authoring_active: boolean;
  }>(
    `SELECT id, revision, markdown, summary, headline, source,
            authoring_lease_expires_at > NOW() AS authoring_active
       FROM daily_brief_artifacts
      WHERE user_id = $1::uuid AND brief_date = $2::date AND authored_slot = $3
      LIMIT 1`,
    [userId, briefDate, slot],
  );
  const row = existing.rows[0];
  if (row && typeof row.markdown === 'string' && row.markdown.trim()) {
    if (row.authoring_active) {
      return { leaseToken: null, artifact: null };
    }
    // Different provenance means live emptiness changed while replacement is in progress. Wait
    // for the next tick instead of returning the stale artifact or racing a second injection.
    if (row.source !== source) {
      return { leaseToken: null, artifact: null };
    }
    return {
      leaseToken: null,
      artifact: {
        id: row.id,
        revision: row.revision,
        markdown: row.markdown,
        summary: row.summary,
        headline: row.headline,
        slot,
        source: row.source,
      },
    };
  }
  return { leaseToken: null, artifact: null };
}

async function releaseBriefAuthoring(
  userId: string,
  briefDate: string,
  slot: TimeOfDay,
  leaseToken: string,
): Promise<void> {
  await pool.query(
    `WITH preserved AS (
       UPDATE daily_brief_artifacts
          SET authoring_lease_token = NULL, authoring_lease_expires_at = NULL, updated_at = NOW()
        WHERE user_id = $1::uuid AND brief_date = $2::date AND authored_slot = $3
          AND markdown IS NOT NULL AND authoring_lease_token = $4::uuid
     )
     DELETE FROM daily_brief_artifacts
      WHERE user_id = $1::uuid AND brief_date = $2::date AND authored_slot = $3
        AND markdown IS NULL AND authoring_lease_token = $4::uuid`,
    [userId, briefDate, slot, leaseToken],
  );
}

/** Persist the canonical artifact and Agenda cache in one statement owned by the lease holder. */
async function completeBriefArtifact(
  userId: string,
  briefDate: string,
  slot: TimeOfDay,
  leaseToken: string,
  markdown: string,
  summary: string | null,
  headline: string | null,
  source: BriefArtifact['source'],
  inputSnapshot?: BriefInputSnapshot,
  authoringProducer: 'gateway' | 'backend_model' = 'gateway',
  authoringModel: string | null = 'gateway',
): Promise<BriefArtifact | null> {
  const result = await pool.query<{
    id: string;
    revision: string;
    markdown: string;
    summary: string | null;
    headline: string | null;
    source: BriefArtifact['source'];
  }>(
    `WITH artifact AS (
       UPDATE daily_brief_artifacts
          SET markdown = $5, summary = $6, source = $7, revision = gen_random_uuid(),
              input_producer = $8, input_manifest = $9::jsonb,
              input_fingerprint = $10, input_captured_at = $11::timestamptz,
              authoring_producer = $12, authoring_model = $13,
              headline = $14,
              authoring_lease_token = NULL, authoring_lease_expires_at = NULL,
              updated_at = NOW()
        WHERE user_id = $1::uuid AND brief_date = $2::date AND authored_slot = $3
          AND authoring_lease_token = $4::uuid
        RETURNING id, revision, markdown, summary, headline, source
     ), reset_deliveries AS (
       UPDATE daily_brief_artifact_deliveries
          SET state = 'pending', lease_token = NULL, lease_expires_at = NULL,
              gateway_message_id = NULL, baseline_match_count = NULL,
              artifact_revision = (SELECT revision FROM artifact),
              last_error = NULL, delivered_at = NULL, updated_at = NOW()
        WHERE artifact_id IN (SELECT id FROM artifact)
     ), cached AS (
       INSERT INTO daily_briefs
         (user_id, brief_date, markdown, summary, source, model, session_key, authored_slot, generated_at)
       SELECT $1::uuid, $2::date, markdown, summary, source,
              $13,
              'rem-orchestrator', $3, NOW()
         FROM artifact
       ON CONFLICT (user_id, brief_date)
       DO UPDATE SET markdown = EXCLUDED.markdown,
                     summary = EXCLUDED.summary,
                     source = EXCLUDED.source,
                     model = EXCLUDED.model,
                     session_key = EXCLUDED.session_key,
                     authored_slot = EXCLUDED.authored_slot,
                     conversation_seeded = FALSE,
                     generated_at = NOW()
       WHERE COALESCE(
         CASE daily_briefs.authored_slot
           WHEN 'morning' THEN 1 WHEN 'afternoon' THEN 2 WHEN 'evening' THEN 3 ELSE 0
         END,
         0
       ) <= CASE EXCLUDED.authored_slot
         WHEN 'morning' THEN 1 WHEN 'afternoon' THEN 2 WHEN 'evening' THEN 3 ELSE 0
       END
       RETURNING 1
     )
     SELECT id, revision, markdown, summary, headline, source
       FROM artifact
      WHERE EXISTS (SELECT 1 FROM cached)`,
    [
      userId, briefDate, slot, leaseToken, markdown, summary, source,
      inputSnapshot?.producer ?? 'remclaw-backend', JSON.stringify(inputSnapshot ? {
        producer: inputSnapshot.producer,
        producerVersion: inputSnapshot.producerVersion,
        capturedAt: inputSnapshot.capturedAt,
        manifest: inputSnapshot.manifest,
        fingerprint: inputSnapshot.fingerprint,
      } : null),
      inputSnapshot?.fingerprint ?? null, inputSnapshot?.capturedAt ?? null,
      authoringProducer, authoringModel, headline,
    ],
  );
  const row = result.rows[0];
  return row
    ? {
        id: row.id,
        revision: row.revision,
        markdown: row.markdown,
        summary: row.summary,
        headline: row.headline,
        slot,
        source: row.source,
      }
    : null;
}

async function claimArtifactDelivery(
  artifactId: string,
  artifactRevision: string,
  sessionKey: string,
): Promise<{ leaseToken: string; baselineMatchCount: number | null } | null> {
  const leaseToken = randomUUID();
  await pool.query(
    `INSERT INTO daily_brief_artifact_deliveries (artifact_id, session_key, artifact_revision)
     VALUES ($1::uuid, $2, $3::uuid)
     ON CONFLICT (artifact_id, session_key) DO NOTHING`,
    [artifactId, sessionKey, artifactRevision],
  );
  const claimed = await pool.query<{ baseline_match_count: number | null }>(
    `UPDATE daily_brief_artifact_deliveries
        SET state = 'delivering', lease_token = $4::uuid,
            lease_expires_at = NOW() + INTERVAL '2 minutes', updated_at = NOW()
      WHERE artifact_id = $1::uuid AND session_key = $2 AND artifact_revision = $3::uuid
        AND (state = 'pending' OR (state = 'delivering' AND lease_expires_at <= NOW()))
      RETURNING baseline_match_count`,
    [artifactId, sessionKey, artifactRevision, leaseToken],
  );
  const row = claimed.rows[0];
  return row
    ? { leaseToken, baselineMatchCount: row.baseline_match_count ?? null }
    : null;
}

/** Persist the first transcript baseline and renew/revalidate lease ownership before injection. */
async function prepareArtifactDeliveryAttempt(
  client: PoolClient,
  artifactId: string,
  artifactRevision: string,
  sessionKey: string,
  leaseToken: string,
  baselineMatchCount: number,
): Promise<boolean> {
  const prepared = await client.query(
    `WITH locked_artifact AS (
       SELECT artifact.id
         FROM daily_brief_artifacts artifact
         JOIN daily_briefs canonical
           ON canonical.user_id = artifact.user_id
          AND canonical.brief_date = artifact.brief_date
          AND canonical.authored_slot = artifact.authored_slot
          AND canonical.source = artifact.source
          AND canonical.markdown = artifact.markdown
        WHERE artifact.id = $1::uuid AND artifact.revision = $2::uuid
          AND (artifact.authoring_lease_expires_at IS NULL
            OR artifact.authoring_lease_expires_at <= NOW())
        FOR UPDATE OF artifact, canonical
     ), prepared AS (
       UPDATE daily_brief_artifact_deliveries
          SET baseline_match_count = COALESCE(baseline_match_count, $5),
              lease_expires_at = NOW() + INTERVAL '2 minutes', updated_at = NOW()
        WHERE artifact_id = $1::uuid AND artifact_revision = $2::uuid AND session_key = $3
          AND state = 'delivering' AND lease_token = $4::uuid
          AND lease_expires_at > NOW()
          AND artifact_id IN (SELECT id FROM locked_artifact)
        RETURNING artifact_id
     ), fenced AS (
       UPDATE daily_brief_artifacts
          SET delivery_fence_expires_at = NOW() + INTERVAL '2 minutes',
              updated_at = NOW()
        WHERE id IN (SELECT artifact_id FROM prepared)
        RETURNING id
     )
     SELECT id FROM fenced`,
    [artifactId, artifactRevision, sessionKey, leaseToken, baselineMatchCount],
  );
  return prepared.rows.length > 0;
}

/**
 * Revalidate the committed preparation and hold its canonical ordering fence through chat.inject.
 * The baseline is deliberately persisted before this transaction: if the process dies after the
 * gateway commits, the next worker can still reconcile the new exact-prose occurrence.
 */
async function lockArtifactDeliverySideEffect(
  client: PoolClient,
  artifactId: string,
  artifactRevision: string,
  sessionKey: string,
  leaseToken: string,
): Promise<boolean> {
  const locked = await client.query(
    `SELECT artifact.id
       FROM daily_brief_artifacts artifact
       JOIN daily_briefs canonical
         ON canonical.user_id = artifact.user_id
        AND canonical.brief_date = artifact.brief_date
        AND canonical.authored_slot = artifact.authored_slot
        AND canonical.source = artifact.source
        AND canonical.markdown = artifact.markdown
       JOIN daily_brief_artifact_deliveries delivery
         ON delivery.artifact_id = artifact.id
        AND delivery.artifact_revision = artifact.revision
      WHERE artifact.id = $1::uuid AND artifact.revision = $2::uuid
        AND delivery.session_key = $3
        AND delivery.state = 'delivering' AND delivery.lease_token = $4::uuid
        AND delivery.lease_expires_at > NOW()
        AND delivery.baseline_match_count IS NOT NULL
        AND (artifact.authoring_lease_expires_at IS NULL
          OR artifact.authoring_lease_expires_at <= NOW())
      FOR UPDATE OF artifact, canonical, delivery`,
    [artifactId, artifactRevision, sessionKey, leaseToken],
  );
  return locked.rows.length > 0;
}

async function finishArtifactDelivery(
  client: PoolClient,
  artifactId: string,
  artifactRevision: string,
  sessionKey: string,
  leaseToken: string,
  messageId?: string,
): Promise<void> {
  await client.query(
    `UPDATE daily_brief_artifact_deliveries
        SET state = 'delivered', lease_token = NULL, lease_expires_at = NULL,
            gateway_message_id = $5, last_error = NULL, delivered_at = NOW(), updated_at = NOW()
      WHERE artifact_id = $1::uuid AND artifact_revision = $2::uuid
        AND session_key = $3 AND lease_token = $4::uuid`,
    [artifactId, artifactRevision, sessionKey, leaseToken, messageId ?? null],
  );
}

async function releaseArtifactDelivery(
  client: PoolClient,
  artifactId: string,
  artifactRevision: string,
  sessionKey: string,
  leaseToken: string,
  reason?: string,
): Promise<void> {
  await client.query(
    `UPDATE daily_brief_artifact_deliveries
        SET state = 'pending', lease_token = NULL, lease_expires_at = NULL,
            last_error = $5, updated_at = NOW()
      WHERE artifact_id = $1::uuid AND artifact_revision = $2::uuid
        AND session_key = $3 AND lease_token = $4::uuid`,
    [artifactId, artifactRevision, sessionKey, leaseToken, reason ?? null],
  );
}

async function deliverBriefArtifact(
  userId: string,
  briefDate: string,
  artifact: BriefArtifact,
  sessionKey: string,
): Promise<void> {
  const claim = await claimArtifactDelivery(artifact.id, artifact.revision, sessionKey);
  if (!claim) return;
  const { leaseToken, baselineMatchCount } = claim;
  const clientState: { value: PoolClient | null } = { value: null };
  let transactionOpen = false;
  const databaseClient = async (): Promise<PoolClient> => {
    if (!clientState.value) clientState.value = await pool.connect();
    return clientState.value;
  };
  try {
    const delivered = await injectAssistantMessageOnGateway({
      userId,
      sessionKey,
      message: artifact.markdown,
      allowNonEmptySession: true,
      artifactId: `brief:${briefDate}:${artifact.slot}:${artifact.revision}`,
      reconciliationBaseline: baselineMatchCount,
      // This preparation locks both the artifact and its canonical daily_briefs pointer on this
      // statement and durably commits the reconciliation baseline. A second exact-state
      // revalidation then holds those row locks through chat.inject: a newer slot's canonical
      // upsert waits in PostgreSQL across replicas instead of advancing before the irreversible
      // gateway side effect.
      prepareArtifactAttempt: async (baseline) => {
        const deliveryClient = await databaseClient();
        const prepared = await prepareArtifactDeliveryAttempt(
          deliveryClient,
          artifact.id,
          artifact.revision,
          sessionKey,
          leaseToken,
          baseline,
        );
        if (!prepared) return false;

        // Gateway wake/history and the durable baseline commit happen before this transaction.
        // Open it only at the irreversible boundary, then keep it through the immediately
        // following chat.inject and delivery completion below.
        await deliveryClient.query('BEGIN');
        transactionOpen = true;
        const locked = await lockArtifactDeliverySideEffect(
          deliveryClient,
          artifact.id,
          artifact.revision,
          sessionKey,
          leaseToken,
        );
        if (!locked) {
          await deliveryClient.query('ROLLBACK');
          transactionOpen = false;
        }
        return locked;
      },
    });
    const deliveryClient = await databaseClient();
    if (delivered.ok) {
      await finishArtifactDelivery(
        deliveryClient,
        artifact.id,
        artifact.revision,
        sessionKey,
        leaseToken,
        delivered.messageId,
      );
    } else {
      await releaseArtifactDelivery(
        deliveryClient,
        artifact.id,
        artifact.revision,
        sessionKey,
        leaseToken,
        delivered.reason,
      );
    }
    if (transactionOpen) {
      await deliveryClient.query('COMMIT');
      transactionOpen = false;
    }
  } catch (error) {
    if (transactionOpen && clientState.value) {
      await clientState.value.query('ROLLBACK').catch(() => undefined);
    }
    throw error;
  } finally {
    clientState.value?.release();
  }
}

/** Dual-deliver during rollout so old and capability-aware clients both open a populated chat. */
async function deliverBriefArtifactForRollout(
  userId: string,
  briefDate: string,
  artifact: BriefArtifact,
): Promise<void> {
  await Promise.all([
    deliverBriefArtifact(userId, briefDate, artifact, `rem-today-${briefDate.replaceAll('-', '')}`),
    deliverBriefArtifact(userId, briefDate, artifact, 'rem-orchestrator'),
  ]);
}

/**
 * Retry rollout delivery for already-authored canonical artifacts without gathering current work
 * or claiming a new authoring slot. Scheduled trigger disablement must stop creation, while an
 * artifact that was authored before disablement still needs its interrupted transcript delivery
 * to converge.
 */
export async function recoverBriefArtifactDeliveriesForUser(userId: string): Promise<number> {
  const result = await pool.query<{
    id: string;
    revision: string;
    brief_date: string;
    authored_slot: TimeOfDay;
    markdown: string;
    summary: string | null;
    headline: string | null;
    source: 'gateway';
  }>(
    `SELECT a.id, a.revision, a.brief_date::text, a.authored_slot,
            a.markdown, a.summary, a.headline, a.source
       FROM daily_brief_artifacts a
       JOIN daily_briefs b
         ON b.user_id = a.user_id
        AND b.brief_date = a.brief_date
        AND b.authored_slot = a.authored_slot
        AND b.source = a.source
        AND b.markdown = a.markdown
      WHERE a.user_id = $1::uuid
        AND a.source = 'gateway'
        AND a.markdown IS NOT NULL AND BTRIM(a.markdown) <> ''
        AND a.brief_date BETWEEN CURRENT_DATE - 1 AND CURRENT_DATE + 1
        AND (
          NOT EXISTS (
            SELECT 1 FROM daily_brief_artifact_deliveries d
             WHERE d.artifact_id = a.id
               AND d.artifact_revision = a.revision
               AND d.session_key = 'rem-orchestrator' AND d.state = 'delivered'
          ) OR NOT EXISTS (
            SELECT 1 FROM daily_brief_artifact_deliveries d
             WHERE d.artifact_id = a.id
               AND d.artifact_revision = a.revision
               AND d.session_key = 'rem-today-' || TO_CHAR(a.brief_date, 'YYYYMMDD')
               AND d.state = 'delivered'
          )
        )
      ORDER BY a.brief_date, a.authored_slot`,
    [userId],
  );

  for (const row of result.rows) {
    await deliverBriefArtifactForRollout(userId, row.brief_date, {
      id: row.id,
      revision: row.revision,
      markdown: row.markdown,
      summary: row.summary,
      headline: row.headline,
      slot: row.authored_slot,
      source: row.source,
    });
  }
  return result.rows.length;
}

/**
 * Read today's AUTHORED brief (card markdown + landing summary), or null when none exists
 * yet. `briefDate` is the user's LOCAL yyyy-mm-dd (resolved by the caller via
 * `localBriefDate`). Used by the GET /api/v1/brief read path (flag-gated) to override the
 * deterministic prose. Only ever returns the current local day's row so a stale prior-day
 * brief can't leak in.
 */
export async function readAuthoredBrief(
  userId: string,
  briefDate: string,
): Promise<AuthoredBrief | null> {
  const result = await pool.query(
    `SELECT markdown, summary FROM daily_briefs
      WHERE user_id = $1::uuid AND brief_date = $2::date
      LIMIT 1`,
    [userId, briefDate],
  );
  const row = result.rows[0];
  const md = row?.markdown;
  if (typeof md !== 'string' || !md.trim()) return null;
  const rawSummary =
    typeof row.summary === 'string' && row.summary.trim() ? row.summary : null;
  const storedSummary = rawSummary ? normalizeBriefSummary(rawSummary) : null;
  // Normalize cached rows immediately; when an old row contains only a greeting, derive the
  // description from its markdown instead of waiting for the next authoring slot.
  const summary = storedSummary ?? summarizeBriefLead(md);
  return { markdown: md, summary };
}

/**
 * Atomically read today's authored prose and whether that exact authored slot was delivered to
 * `sessionKey`. Keeping both values in one PostgreSQL statement prevents a newer slot from
 * authorizing an older prose snapshot between separate reads.
 */
export async function readAuthoredBriefDelivery(
  userId: string,
  briefDate: string,
  sessionKey: string,
  db: DatabaseQueryable = pool,
): Promise<AuthoredBriefDelivery | null> {
  const result = await db.query(
    `SELECT a.markdown, a.summary, a.headline, a.source, a.revision, b.authored_slot,
            TRUE AS delivered
       FROM daily_briefs b
       JOIN daily_brief_artifacts a
         ON a.user_id = b.user_id
        AND a.brief_date = b.brief_date
        AND a.authored_slot = b.authored_slot
        AND a.source = 'gateway'
        AND a.markdown = b.markdown
       JOIN daily_brief_artifact_deliveries d
         ON d.artifact_id = a.id
        AND d.artifact_revision = a.revision
        AND d.session_key = $3
        AND d.state = 'delivered'
      WHERE b.user_id = $1::uuid AND b.brief_date = $2::date
        AND b.source = 'gateway'
        AND a.markdown IS NOT NULL AND BTRIM(a.markdown) <> ''
      LIMIT 1`,
    [userId, briefDate, sessionKey],
  );
  const row = result.rows[0];
  const md = row?.markdown;
  if (typeof md !== 'string' || !md.trim()) return null;
  const rawSummary =
    typeof row.summary === 'string' && row.summary.trim() ? row.summary : null;
  const storedSummary = rawSummary ? normalizeBriefSummary(rawSummary) : null;
  const summary = storedSummary ?? summarizeBriefLead(md);
  // Stored column only — never a fallback parse of `md`. Re-deriving here would reintroduce the
  // per-surface derivation this field exists to remove, and would silently disagree with a
  // headline the authoring turn actually wrote.
  const headline =
    typeof row.headline === 'string' && row.headline.trim() ? row.headline.trim() : null;
  return {
    markdown: md,
    summary,
    headline,
    delivered: true,
    source: row.source,
    revision: row.revision,
    authoredSlot: row.authored_slot as TimeOfDay,
  };
}

/**
 * True only after the latest cached brief artifact has visibly landed in the requested gateway
 * transcript. The API uses this as the authority for advertising `brief_session_key`; a cache row
 * alone is insufficient because delivery may still be pending after a gateway failure.
 */
export async function hasDeliveredBriefArtifact(
  userId: string,
  briefDate: string,
  sessionKey: string,
): Promise<boolean> {
  const result = await pool.query<{ delivered: boolean }>(
    `SELECT EXISTS (
       SELECT 1
         FROM daily_briefs b
         JOIN daily_brief_artifacts a
           ON a.user_id = b.user_id
          AND a.brief_date = b.brief_date
          AND a.authored_slot = b.authored_slot
          AND a.source = 'gateway'
          AND a.markdown = b.markdown
         JOIN daily_brief_artifact_deliveries d
           ON d.artifact_id = a.id
          AND d.artifact_revision = a.revision
          AND d.session_key = $3
          AND d.state = 'delivered'
        WHERE b.user_id = $1::uuid
          AND b.brief_date = $2::date
          AND b.source = 'gateway'
          AND a.markdown IS NOT NULL
     ) AS delivered`,
    [userId, briefDate, sessionKey],
  );
  return result.rows[0]?.delivered === true;
}

export interface AuthorBriefOptions {
  /** A pre-gathered brief to reuse (e.g. a check-in already gathered it) — avoids a re-query. */
  brief?: DailyBrief;
  /** Override the resolved timezone (tests); defaults to `resolveUserTimezone(userId)`. */
  timezone?: string;
  /**
   * Scheduler-owned slot for an explicit user check-in. The general fleet cron keeps the normal
   * 06:00/12:00/17:00 eligibility gate, while a user-selected 05:xx Morning trigger may author its
   * Morning artifact at the time the UI promised. Callers must pass a structured TimeOfDay, never
   * derive this from display text.
   */
  requestedSlot?: TimeOfDay;
  /** Trusted backend-collected connector snapshot. Client signal rows are never accepted here. */
  inputSnapshot?: BriefInputSnapshot;
  /** Due-check-in-only collector, invoked only after this worker owns the fresh authoring lease. */
  collectInput?: () => Promise<BriefInputSnapshot>;
}

/**
 * Author (and cache) one user's daily brief prose via their gateway agent, in a FRESH
 * context each cycle (ephemeral `rem-brief-author-<localday>-<runId>` session — no replayed
 * history, so the prose never goes stale or degrades into "NO_REPLY"). The card is cached in
 * `daily_briefs` and the persistent CONVERSATION session key (`rem-orchestrator`) — the
 * one the app opens and the user replies into — is recorded on the row. Authored prose is
 * appended with `chat.inject`, which does not execute a turn or persist a hidden prompt. Called
 * by BOTH the cron and
 * each check-in. Never throws. On a gateway failure it writes NOTHING (the read path falls
 * back to the deterministic prose, and a good prior card is preserved). On an empty day it
 * skips the AI turn and writes nothing into Today. The deterministic Agenda all-clear remains a
 * live task-store state, not an assistant-authored chat message.
 */
export async function authorBriefForUser(
  userId: string,
  now: Date,
  opts: AuthorBriefOptions = {},
): Promise<BriefAuthoringResult> {
  const base = { userId };
  try {
    const timezone = opts.timezone ?? (await resolveUserTimezone(userId));
    const briefDate = localBriefDate(now, timezone);
    // TIME-GATE (NIT 1): only author at/after a meaningful slot start, and only ONCE per slot
    // per local day. Before this, run-brief-authoring re-authored on every */15 tick (~96
    // gateway wakes/user/day). `authoringSlot` returns null before the morning start (no
    // midnight wakes); the `authored_slot` dedupe below caps us to ~3 wakes/user/day.
    const slot = opts.requestedSlot ?? authoringSlot(now, timezone);
    if (slot === null) {
      return { ...base, status: 'skipped_slot', reason: 'before_morning_slot' };
    }

    // Explicit check-ins may be processed after multiple slots became overdue. Once a later slot
    // owns today's canonical pointer, an older requested slot is terminally superseded: do not
    // spend a gateway turn or append stale prose to Today. The conditional cache upsert below is
    // the cross-worker race fence; this read is the cheap retry/recovery fast path.
    if (opts.requestedSlot) {
      const canonical = await pool.query<{ authored_slot: TimeOfDay | null }>(
        `SELECT authored_slot
           FROM daily_briefs
          WHERE user_id = $1::uuid AND brief_date = $2::date
          LIMIT 1`,
        [userId, briefDate],
      );
      const canonicalSlot = canonical.rows[0]?.authored_slot;
      if (canonicalSlot && briefSlotRank(canonicalSlot) > briefSlotRank(slot)) {
        return { ...base, status: 'skipped_slot', reason: `superseded_by_${canonicalSlot}` };
      }
    }

    // Gather in the user's LOCAL tz so the buckets match the local date/heading we author with.
    //
    // STALENESS (migration 116): drop tasks Rem has already raised BRIEF_STALE_THRESHOLD times with
    // no user action in between. The filter is applied HERE, after gathering, rather than inside
    // `gatherBrief`, for two reasons: (1) `gatherBrief` also serves GET /api/v1/brief, where a
    // silently-vanishing task would be a worse bug than the repetition; (2) `opts.brief` lets a
    // check-in pass a pre-gathered brief, so filtering at the gather site would miss that path
    // entirely. Everything downstream — the emptiness check, the authoring prompt, and the
    // surfacing counter — reads this filtered view, so a day whose only remaining work is stale
    // authors nothing at all rather than an empty-sounding nag.
    const brief = briefWithoutStaleTasks(opts.brief ?? (await gatherBrief(userId, now, timezone)));
    // Cross-process authoring lease: cron and check-in can overlap, but only one gateway turn may
    // become the canonical Agenda/chat artifact for this user/day/slot.
    const artifactSource: BriefArtifact['source'] = 'gateway';
    const claim = await claimBriefAuthoring(userId, briefDate, slot, artifactSource);
    if (claim.artifact) {
      await deliverBriefArtifactForRollout(userId, briefDate, claim.artifact);
      return { ...base, status: 'skipped_slot', reason: `already_authored_${slot}` };
    }
    if (!claim.leaseToken) {
      return { ...base, status: 'skipped_slot', reason: `authoring_in_progress_${slot}` };
    }
    const leaseToken = claim.leaseToken;

    let artifact: BriefArtifact | null = null;
    try {
      const inputSnapshot = opts.inputSnapshot ?? (await opts.collectInput?.());
      if (isBriefEmpty(brief, inputSnapshot)) {
        if (hasRetryableUnavailableInput(inputSnapshot)) {
          return { ...base, status: 'skipped_gateway', reason: 'connector_input_unavailable' };
        }
        // The lease is released in finally. An unavailable connector is not an empty successful
        // read; it simply cannot make an otherwise empty task snapshot authorable.
        return { ...base, status: 'empty', reason: null };
      }
      let authoredText: string | null = null;
      let authoringProducer: 'gateway' | 'backend_model' = 'gateway';
      let authoringModel: string | null = 'gateway';
      if (hasAuthorableBriefInput(inputSnapshot)) {
        // TWO boundaries meet on this branch, and they are independent. Both must hold before
        // the backend model runs; failing either degrades to task-only authoring.
        //
        // 1. SECURITY BOUNDARY (unchanged): raw connector text must never enter gateway
        //    chat.send, whose agent runtime has tools and persists the authoring turn. GMI
        //    chat-completions is a plain backend model call with no tool declaration; only its
        //    final prose is injected later. THIS is why the branch cannot simply be rerouted to
        //    the owner's gateway the way #1327 rerouted task runs.
        //
        // 2. PAYER BOUNDARY (new): this call spends the operator's own `GMI_API_KEY`. It is the
        //    only remaining model call in this backend that does, and — unlike the digest and
        //    memory-extraction fallbacks that were deleted alongside this change — it is not a
        //    fallback but the PRIMARY producer for connector-derived input, so deleting it
        //    would delete the capability rather than redirect it. BYOK is a global per-user
        //    mode, so a user whose runtime Rem did not provision must not have this one feature
        //    quietly pick Rem's key: `mayChargeRemManagedKey` is the gate, and it fails closed
        //    on `unknown`. What `run-block.ts` can and cannot prove about the mode — and the
        //    managed-Fly BYOK case it cannot yet see — is documented there, not restated here.
        //
        // Ordering: the mode read happens BEFORE the model call, so a blocked user costs one
        // indexed lookup and no provider request at all.
        const runtimeMode = await resolveModelRuntimeMode(userId);
        if (!mayChargeRemManagedKey(runtimeMode)) {
          // WHAT THIS COSTS, STATED HONESTLY. On a day that also has TASKS, we fall through and
          // author from task data only: the brief still ships, minus the connector enrichment.
          // On a CONNECTOR-ONLY day there is nothing left to author from — connector text cannot
          // fall through to the tool-capable gateway (boundary 1) — so the user gets NO BRIEF
          // that day. That is a real loss, not just a degraded one, and it is the deliberate
          // trade: a brief nobody may pay for is worse than a brief that did not arrive.
          //
          // Unreachable today. `resolveModelRuntimeMode` returns `rem_managed` for every user
          // with a gateway (see run-block.ts — Rem's provider is the primary model on every
          // gateway this backend can address), so nothing currently takes this branch. It is the
          // enforcement point for when that stops being true.
          if (isTaskBriefEmpty(brief)) {
            return { ...base, status: 'skipped_gateway', reason: CONNECTOR_MODEL_NOT_OWNED };
          }
        } else {
          try {
            const generated = await gmiChat(
              [{
                role: 'user',
                content: buildBriefAuthoringPrompt(
                  brief,
                  localDateHeading(now, timezone),
                  inputSnapshot,
                ),
              }],
              { temperature: 0.2, maxTokens: 700, timeoutMs: 15_000 },
            );
            authoredText = generated.content;
            authoringProducer = 'backend_model';
            authoringModel = generated.model;
          } catch {
            // Connector-only input cannot safely fall through to the tool-capable gateway. When
            // tasks exist, preserve availability by authoring from task data only.
            if (isTaskBriefEmpty(brief)) {
              return { ...base, status: 'skipped_gateway', reason: 'connector_model_unavailable' };
            }
          }
        }
      }

      if (authoredText === null) {
        // FRESH context: a throwaway per-run key means the task-only turn replays no history.
        const authorKey = authoringSessionKey(now, timezone, randomUUID());
        const turn = await runAgentTurnOnGateway({
          userId,
          sessionKey: authorKey,
          message: buildBriefAuthoringPrompt(brief, localDateHeading(now, timezone)),
        });
        if (!turn.ok) {
          return { ...base, status: 'skipped_gateway', reason: turn.reason };
        }
        authoredText = turn.text;
      }

      // Guard: never surface a control token as prose. If the whole turn was one, or the turn
      // was empty, treat it as empty text and write nothing (a good prior card is preserved).
      const markdown = stripControlTokens(authoredText);
      if (!markdown) {
        return { ...base, status: 'skipped_gateway', reason: 'empty_text' };
      }
      const summary = summarizeBriefLead(markdown);
      // Authored WITH the brief, in the same transaction that persists its prose — the headline is
      // part of the artifact, not something a client re-derives at render time.
      const headline = extractBriefHeadline(markdown);

      artifact = await completeBriefArtifact(
        userId,
        briefDate,
        slot,
        leaseToken,
        markdown,
        summary,
        headline,
        artifactSource,
        inputSnapshot,
        authoringProducer,
        authoringModel,
      );
      if (!artifact) {
        return { ...base, status: 'skipped_slot', reason: `authoring_lease_lost_${slot}` };
      }

      // THE ASK IS NOW ON THE RECORD. This is the only place a task's nag counter advances, and it
      // sits here — after `completeBriefArtifact` committed — for a precise reason: the authoring
      // lease has already fenced that write to at most once per (user, local day, slot), so "how
      // many briefs have asked about this task" cannot be inflated by a redelivery retry, by a
      // second cron worker, or by the user refreshing the app. Every earlier return path (empty
      // day, gateway failure, lost lease) leaves the counter alone, which is correct: if no brief
      // was written, nobody was asked.
      //
      // Never fatal. A brief that was authored and delivered but whose bookkeeping failed costs the
      // user exactly one extra ask on some future day; throwing here would instead strand a
      // committed artifact undelivered (the catch below turns it into a retry), which is far worse.
      await recordBriefSurfacing(userId, briefSurfacedTaskIds(brief), now).catch((error: unknown) => {
        console.error(
          '[BRIEF] staleness bookkeeping failed (brief still delivered):',
          error instanceof Error ? error.message : String(error),
        );
      });
    } finally {
      // Covers structured gateway failures, empty/control-only output, thrown authoring calls,
      // and persistence failures. The ownership predicate makes this harmless after completion.
      if (!artifact) {
        await releaseBriefAuthoring(userId, briefDate, slot, leaseToken).catch(() => undefined);
      }
    }

    await deliverBriefArtifactForRollout(userId, briefDate, artifact);

    return { ...base, status: 'authored', reason: null };
  } catch (error: unknown) {
    // `gatherBrief`, the upsert, or `deliverBriefArtifactForRollout` threw. Never crash the cron —
    // and this MUST stay retryable, which `isPermanentGatewaySkip` guarantees by not listing it.
    //
    // The rollout call above is the load-bearing case. It is two `deliverBriefArtifact` writes, and
    // it runs AFTER `completeBriefArtifact` has committed: a throw here means the brief exists but
    // was not delivered. Treating that as permanent strands it forever — the user sees nothing, with
    // no error anywhere. Retrying converges because `claimBriefAuthoring` hands the existing
    // artifact back on the next tick and re-runs the same rollout delivery (#1285).
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, status: 'skipped_gateway', reason: `error: ${message}` };
  }
}
