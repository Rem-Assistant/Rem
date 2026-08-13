/**
 * Connector signal DESCRIPTORS — the one place that knows how a given connected source is read.
 *
 * WHY THIS EXISTS
 * ---------------
 * `collectGmailBriefInput` was a hand-written Gmail adapter: the action, the pinned action
 * version, the query syntax, the field extraction, the bounds and the loop were all one function.
 * Adding a second source meant copying that function; and nothing else in the backend could ask
 * "which sources can we actually read?" without importing Gmail specifics.
 *
 * A descriptor is the provider-specific part ONLY: which Composio action at which pinned version,
 * how to phrase a time-window query, and how to turn one raw provider item into a
 * `NormalizedSignal`. Everything that must hold for EVERY source — account cap, item cap, page
 * cap, window length, wall-time budget, dedupe, the timestamp re-check, availability
 * classification — lives in the shared runner (`connector-signals.runner.ts`) where a descriptor
 * cannot reach it.
 *
 * SOURCE OF TRUTH
 * ---------------
 * `DESCRIPTORS` below is the canonical answer to "which connected sources can Rem read?".
 * `listDescriptors()` is how other layers (e.g. the derived automation-inputs API) answer that
 * question WITHOUT importing Gmail specifics — so the answer can never drift from the code that
 * actually does the reading. That is the whole point: state is derived, never hand-written.
 *
 * NOT A REWRITE. The Gmail descriptor below is the existing collector's constants, query syntax
 * and field extraction moved verbatim. Its observable output is byte-identical — the Daily Brief
 * snapshot fingerprints are pinned in `brief-input.service.test.ts`.
 */

import type { GmailBriefItem } from './brief-input.service.js';

/** One external event that MIGHT imply work. Maps 1:1 onto a `channel_signals` row (migration 039). */
export interface NormalizedSignal {
  /** `channel_signals.source` — 'gmail' | 'slack' | … */
  source: string;
  /** `channel_signals.source_ref` — stable per-source id; ingest idempotency. */
  sourceRef: string;
  /** `channel_signals.sender` — display attribution. */
  sender: string | null;
  /** `channel_signals.summary` — human text the deriver reasons over. */
  summary: string;
  /** `channel_signals.suggested_title` */
  suggestedTitle: string | null;
  /** `channel_signals.received_at` — ISO 8601. */
  receivedAt: string;
}

/**
 * How to read ONE connected source. Provider-specific knowledge and nothing else.
 *
 * A descriptor CANNOT set bounds. Account/item/page caps, the window length and the wall-time
 * budget are the runner's (`CONNECTOR_SIGNAL_BOUNDS`); a descriptor that returns a thousand items
 * or an endless page cursor is still capped by the runner.
 */
export interface ConnectorSignalDescriptor {
  /** MUST equal the `NormalizedSignal.source` it emits. Enforced by the runner and by tests. */
  source: string;
  /** Composio toolkit slug, e.g. 'gmail'. */
  toolkitSlug: string;
  /** e.g. 'GMAIL_FETCH_EMAILS' */
  action: string;
  /** PINNED, e.g. '20260721_00'. Never floats — a provider schema change must be a code change. */
  actionVersion: string;
  /** 'Gmail' — for UI. */
  displayName: string;
  /** Provider-specific query for a time window. Pure. */
  buildQuery(windowStart: Date, windowEnd: Date): Record<string, unknown>;
  /** Map ONE raw provider item to a normalized signal. Return null to drop it. Pure. */
  mapItem(raw: unknown, connectedAccountId: string): NormalizedSignal | null;
}

/**
 * Gmail-only extension. The Daily Brief's snapshot row carries subject / snippet / threadId, which
 * `NormalizedSignal` deliberately does NOT — a signal is "something happened", not a mail record.
 * Rather than re-parse the raw item in the brief service (two copies of the field extraction, the
 * exact drift this refactor exists to prevent), the descriptor that owns the extraction also owns
 * the projection.
 */
export interface GmailSignalDescriptor extends ConnectorSignalDescriptor {
  source: typeof GMAIL_SIGNAL_SOURCE;
  /** Project ONE raw item + its normalized signal into the Daily Brief's Gmail row. Pure. */
  toBriefItem(raw: unknown, signal: NormalizedSignal): GmailBriefItem | null;
}

export const GMAIL_SIGNAL_SOURCE = 'gmail' as const;
export const GMAIL_BRIEF_ACTION = 'GMAIL_FETCH_EMAILS' as const;
export const GMAIL_BRIEF_ACTION_VERSION = '20260721_00' as const;

/**
 * The one ISO 8601 instant shape this backend accepts: date, `T`, time, OPTIONAL fractional
 * seconds, and a REQUIRED offset (`Z` or `±HH:MM`).
 *
 * Fractional seconds are optional because agents and providers emit both `2026-02-15T01:00:00Z`
 * and `2026-02-15T01:00:00.123Z`, and accepting only one silently drops half the corpus (the
 * standing CLAUDE.md gotcha). The offset is REQUIRED because a bare local timestamp names no
 * single instant and would land in the wrong 24h window.
 */
const ISO_INSTANT_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

/** Signed minutes for an RFC 3339 offset suffix ('Z' | '+01:00' | '-05:30'). */
export function isoOffsetMinutes(suffix: string): number {
  if (suffix === 'Z') return 0;
  const sign = suffix.startsWith('-') ? -1 : 1;
  return sign * (Number(suffix.slice(1, 3)) * 60 + Number(suffix.slice(4, 6)));
}

/**
 * Strict ISO 8601 → Date. Returns null when the value is not a well-formed instant, which is the
 * drop signal for `mapItem` and for the runner's post-fetch window re-check.
 *
 * WHY NOT `new Date(value)`. That was the previous body, under a docblock advertising only the
 * fractional/non-fractional tolerance. It does honour that — and it ALSO accepts everything the
 * Date constructor's implementation-defined fallback accepts: `'Dec 25, 2026'`, `'2026'`,
 * `'Fri Aug 08 2026'`, offset-less local times whose instant depends on the server's TZ. This
 * parser decides which provider timestamps are real and which window they fall in; a value the
 * spec does not define the meaning of must be a DROP, not a guess that differs between Node
 * versions and deploy regions.
 *
 * The shape check alone is not enough: an impossible calendar date can still parse (and, on the
 * legacy path, roll over — '2026-02-30' becoming March 2). So the parsed instant is required to
 * round-trip back to every field that was written. `parsed + offset` recovers the LOCAL wall-clock
 * fields, because `getTime()` is already the UTC instant.
 */
export function parseIsoInstant(value: unknown): Date | null {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  const match = ISO_INSTANT_PATTERN.exec(text);
  if (!match) return null;
  const parsed = new Date(text);
  if (Number.isNaN(parsed.getTime())) return null;
  const local = new Date(parsed.getTime() + isoOffsetMinutes(match[7]) * 60_000);
  return local.getUTCFullYear() === Number(match[1])
    && local.getUTCMonth() + 1 === Number(match[2])
    && local.getUTCDate() === Number(match[3])
    && local.getUTCHours() === Number(match[4])
    && local.getUTCMinutes() === Number(match[5])
    && local.getUTCSeconds() === Number(match[6])
    ? parsed
    : null;
}

/**
 * ── EPOCH-NUMBER TIMESTAMPS, AND THE SECONDS-vs-MILLISECONDS RULE ─────────────────────────────
 *
 * Not every connector puts ISO 8601 on the wire. Two of the shapes we already know about are bare
 * numbers, in DIFFERENT UNITS:
 *
 *   Slack  `ts`            epoch SECONDS with a fractional part, as a STRING — Composio's own
 *                          output schema documents it as `0123456789.012345`.
 *   Gmail  `internalDate`  epoch MILLISECONDS as a STRING (`'1786620600000'`) — Google's
 *                          documented type is `string (int64 format)`.
 *
 * `parseIsoInstant` refuses both, correctly: they are not ISO. But refusing them where a
 * descriptor reads a provider item is not a safe default — it is a 100% silent drop for that
 * source (`fetched=N dropped=N ingested=0`, exit 0, zero rows), which is the failure this
 * pipeline has already shipped. So the epoch shapes are parsed HERE, once, rather than
 * re-invented per descriptor.
 *
 * THE AMBIGUITY, RESOLVED DELIBERATELY. A bare number names no unit, and guessing wrong is worse
 * than refusing: a 1000× error still WRITES a row — dated 1970, or the year 55000 — and nothing
 * downstream can tell it from a real one. So the rule is written down, and both sides of it are
 * tested:
 *
 *   n < 1e9          REFUSED. Read as seconds that is before 2001-09-09, and a token that small
 *                    is far likelier a year, a counter or an id than an instant. `parseIsoInstant`
 *                    already has '2026' in its must-drop corpus for exactly this reason.
 *   1e9  ≤ n < 1e11  SECONDS       → 2001-09-09 … 5138-11-16
 *   1e11 ≤ n < 1e14  MILLISECONDS  → 1973-03-03 … 5138-11-16
 *   n ≥ 1e14         REFUSED. As millis that is past 5138-11-16 — past where the seconds reading
 *                    itself ran out. Nothing real lands there.
 *
 * WHY 1e11 IS THE SPLIT, and why the guess can never be wrong for real data: as SECONDS, 1e11 is
 * the year 5138; as MILLISECONDS, it is 1973-03-03. Any timestamp a connector could actually send
 * sits between those two dates in EITHER unit, so no genuine seconds value ever reaches 1e11 and
 * no genuine millisecond value ever falls below it. The band where the two readings could be
 * confused contains no message that exists.
 *
 * NOT IN SCOPE HERE: which FIELD carries the instant. Slack reads `ts`, Todoist `posted_at`,
 * Drive `createdTime`, Gmail `internalDate`. That is a per-descriptor MAPPING concern —
 * `mapItem` picks the field, this parser decides only what the picked value MEANS.
 */

/** Smallest bare number read as an epoch at all. Below it, seconds would predate 2001-09-09. */
const EPOCH_MIN = 1e9;
/** The seconds/milliseconds split: the year 5138 as seconds, 1973-03-03 as milliseconds. */
const EPOCH_MILLIS_FLOOR = 1e11;
/** Largest bare number read as an epoch at all — 1e14 ms is the same instant as 1e11 s. */
const EPOCH_MAX = 1e14;

/** Digits, optionally a fractional tail. No sign, no exponent, no separators, no whitespace. */
const EPOCH_NUMBER_PATTERN = /^(\d{1,15})(?:\.(\d{1,9}))?$/;

/**
 * Epoch number (as a string) → Date, under the unit rule above. Returns null for anything outside
 * the accepted band — the same DROP signal `parseIsoInstant` gives, never a guessed instant.
 *
 * STRING ONLY, like `parseIsoInstant`: both known senders quote the value, and accepting a raw
 * JS number here would let an already-parsed millisecond timestamp re-enter as data.
 */
export function parseEpochInstant(value: unknown): Date | null {
  if (typeof value !== 'string') return null;
  const match = EPOCH_NUMBER_PATTERN.exec(value.trim());
  if (!match) return null;
  const whole = Number(match[1]);
  // The unit is decided on the INTEGER part alone, so a fractional tail can never move a value
  // across the split and no float comparison is involved in the decision.
  if (!Number.isSafeInteger(whole) || whole < EPOCH_MIN || whole >= EPOCH_MAX) return null;
  const millis = whole < EPOCH_MILLIS_FLOOR
    // Sub-millisecond digits are not representable in a JS Date. Slack sends microseconds; they
    // round to the nearest millisecond — never invented, and at most 0.5ms of movement, which
    // cannot carry a signal across a 24h window boundary.
    ? whole * 1000 + Math.round(Number(`0.${match[2] ?? '0'}`) * 1000)
    // A fractional tail on a MILLISECOND value is already below a Date's resolution; discard it.
    : whole;
  const parsed = new Date(millis);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * The parser every connector-signal path uses: ISO 8601 first, then the epoch-number shapes.
 *
 * `parseIsoInstant` stays exactly as strict as it was — this is a UNION, not a loosening. The two
 * grammars are disjoint (an ISO instant must carry `-` and `T`; an epoch number is digits and at
 * most one `.`), so no value is claimed by both and the order cannot change any outcome.
 *
 * Use THIS wherever a provider-supplied instant is read. Use `parseIsoInstant` only where the
 * value is required to already be ISO.
 */
export function parseConnectorInstant(value: unknown): Date | null {
  return parseIsoInstant(value) ?? parseEpochInstant(value);
}

/** C0 controls plus DEL become spaces; the caller then collapses whitespace runs. */
function stripControlCharacters(value: string): string {
  let out = '';
  for (const character of value) {
    const code = character.codePointAt(0) ?? 0;
    out += code < 0x20 || code === 0x7f ? ' ' : character;
  }
  return out;
}

/** Strip control characters, collapse whitespace, then ellipsize to `max`. */
export function cleanSignalText(value: unknown, max: number): string {
  const raw = typeof value === 'string' ? value : '';
  const text = stripControlCharacters(raw).replace(/\s+/g, ' ').trim();
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

/** Gmail's fields after cleaning, shared by `mapItem` and `toBriefItem` so extraction exists once. */
interface ParsedGmailItem {
  providerMessageId: string;
  providerThreadId: string | null;
  sender: string;
  subject: string;
  snippet: string;
  /** Normalized ISO 8601 instant. */
  timestamp: string;
}

/**
 * The Gmail field extraction, moved from `collectGmailBriefInput`. An item without a usable
 * message id or a parseable timestamp is DROPPED (null) — one malformed row must not throw away
 * the whole collection.
 *
 * FIELD NAMES HERE ARE A CONTRACT WITH THE TRANSPORT, NOT WITH THE PROVIDER. The names read below
 * (`providerMessageId`, `snippet`, `timestamp`) are NOT what `GMAIL_FETCH_EMAILS` puts on the wire.
 * What it DOES put on the wire is still unconfirmed — nobody has captured a payload — so the
 * transport reads either candidate spelling (`messageId`|`id`, `preview`|`snippet`,
 * `messageTimestamp`|`timestamp`|`internalDate`) and logs which one arrived. Every item reaching
 * here has passed through `normalizeGmailWireMessage` (composio.service.ts) — the ONE rename that
 * BOTH Gmail consumers apply: `composioGmailBriefAdapter` (inside `parseGmailFetchEmailsResult`)
 * and `composioSignalExecutor` (via `COMPOSIO_SIGNAL_ENVELOPES.GMAIL_FETCH_EMAILS.normalizeItems`).
 *
 * This docblock used to name `parseGmailFetchEmailsResult` as the ONLY way in, and that claim was
 * FALSE the moment the signal-ingest path shipped: its executor returned `data.messages` verbatim,
 * so every real message arrived in wire naming, matched none of these fields, and was dropped —
 * `fetched=2 dropped=2 ingested=0`, exit 0, zero rows, twice. A comment the code contradicts is
 * worse than no comment. `signal-ingest.executor-shape.db.test.ts` drives the REAL executor into
 * this function so the claim cannot rot back into a lie.
 *
 * The normalizer guarantees strings, so the defensive coercion in `cleanSignalText` is unreachable
 * in production; it exists so a future adapter cannot turn one bad field into an unavailable
 * snapshot.
 */
function parseGmailItem(raw: unknown): ParsedGmailItem | null {
  if (!raw || typeof raw !== 'object') return null;
  const item = raw as Record<string, unknown>;
  const providerMessageId = cleanSignalText(item.providerMessageId, 256);
  const timestamp = parseConnectorInstant(typeof item.timestamp === 'string' ? item.timestamp : '');
  if (!providerMessageId || !timestamp) return null;
  return {
    providerMessageId,
    providerThreadId: item.providerThreadId ? cleanSignalText(item.providerThreadId, 256) : null,
    sender: cleanSignalText(item.sender, 320),
    subject: cleanSignalText(item.subject, 500),
    snippet: cleanSignalText(item.snippet, 1_000),
    timestamp: timestamp.toISOString(),
  };
}

/** Gmail's documented query grammar wants calendar days: `2026/08/08`. */
function gmailCalendarDate(date: Date): string {
  return date.toISOString().slice(0, 10).replace(/-/g, '/');
}

export const gmailSignalDescriptor: GmailSignalDescriptor = {
  source: GMAIL_SIGNAL_SOURCE,
  toolkitSlug: 'gmail',
  action: GMAIL_BRIEF_ACTION,
  actionVersion: GMAIL_BRIEF_ACTION_VERSION,
  displayName: 'Gmail',

  /**
   * Gmail's documented calendar-day query is deliberately BROADER than the exact rolling window
   * (whole days, and `before:` is exclusive so it must reach into tomorrow). The runner re-checks
   * every item's timestamp against `[windowStart, windowEnd]`, so only the exact window survives.
   */
  buildQuery(windowStart: Date, windowEnd: Date): Record<string, unknown> {
    const before = new Date(windowEnd.getTime() + 86_400_000);
    return { query: `after:${gmailCalendarDate(windowStart)} before:${gmailCalendarDate(before)}` };
  },

  mapItem(raw: unknown, connectedAccountId: string): NormalizedSignal | null {
    const parsed = parseGmailItem(raw);
    if (!parsed) return null;
    return {
      source: GMAIL_SIGNAL_SOURCE,
      // Account-qualified: the same message id under two grants is two rows, and this is exactly
      // the identity the Daily Brief has always deduped on (`gmail:<account>:<messageId>`).
      sourceRef: `${connectedAccountId}:${parsed.providerMessageId}`,
      sender: parsed.sender || null,
      summary: parsed.subject && parsed.snippet
        ? `${parsed.subject} — ${parsed.snippet}`
        : parsed.subject || parsed.snippet,
      // Deliberately null: a subject line is not a task title. Migration 039 documents the
      // deriver's fallback ("Reply to <sender>"), which reads better than a raw subject.
      suggestedTitle: null,
      receivedAt: parsed.timestamp,
    };
  },

  toBriefItem(raw: unknown, signal: NormalizedSignal): GmailBriefItem | null {
    const parsed = parseGmailItem(raw);
    if (!parsed) return null;
    // Key ORDER is load-bearing: the snapshot fingerprint is a sha256 over JSON.stringify.
    return {
      stableId: `${GMAIL_SIGNAL_SOURCE}:${signal.sourceRef}`,
      providerMessageId: parsed.providerMessageId,
      providerThreadId: parsed.providerThreadId,
      sender: parsed.sender,
      subject: parsed.subject,
      snippet: parsed.snippet,
      timestamp: parsed.timestamp,
    };
  },
};

/**
 * Deep-freeze one descriptor: the object AND its own enumerable property values.
 *
 * `Object.freeze([descriptor])` froze only the ARRAY — the descriptors inside stayed live
 * singletons handed out by `listDescriptors()`/`getDescriptor()`, so any consumer could have
 * written `d.actionVersion = '20260801_00'` and floated the pinned version for the whole process.
 * A pinned action version that a caller can reassign is not pinned, and this file exists to make
 * it un-floatable.
 *
 * `Object.freeze` on a function is a no-op for its behaviour, which is fine: `buildQuery` and
 * `mapItem` cannot be REPLACED once the owning descriptor is frozen, and that is the property
 * that matters.
 */
function deepFreezeDescriptor<T extends object>(descriptor: T): T {
  for (const value of Object.values(descriptor)) {
    if (value !== null && (typeof value === 'object' || typeof value === 'function')) {
      Object.freeze(value);
    }
  }
  return Object.freeze(descriptor);
}

/** Every source Rem can actually read. Adding a connector means adding a descriptor HERE. */
const DESCRIPTORS: readonly ConnectorSignalDescriptor[] = Object.freeze(
  [gmailSignalDescriptor].map(deepFreezeDescriptor),
);

const BY_SOURCE: ReadonlyMap<string, ConnectorSignalDescriptor> = (() => {
  const map = new Map<string, ConnectorSignalDescriptor>();
  for (const descriptor of DESCRIPTORS) {
    if (map.has(descriptor.source)) {
      // Two descriptors claiming one source would make lookup order-dependent and silently drop
      // one of them. Fail at module load, not at 6am on a cron.
      throw new Error(`duplicate connector signal descriptor source: ${descriptor.source}`);
    }
    map.set(descriptor.source, descriptor);
  }
  return map;
})();

/**
 * Every registered descriptor. This is the seam other lanes build on (e.g. the derived
 * `GET /api/v1/automations/:kind/inputs`) so they never import Gmail specifics: a row is
 * `coming_soon` precisely when no descriptor claims its source.
 */
export function listDescriptors(): readonly ConnectorSignalDescriptor[] {
  return DESCRIPTORS;
}

/** Look up one descriptor. `undefined` for an unknown source — never a thrown error, never a guess. */
export function getDescriptor(source: string): ConnectorSignalDescriptor | undefined {
  return BY_SOURCE.get(source);
}
