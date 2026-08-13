import { pool, type DatabaseQueryable } from '../db/pool.js';
import { GMAIL_BRIEF_WINDOW_HOURS } from './brief-input.service.js';

/**
 * Derived automation input contract — the server-authored answer to "what does this automation
 * actually read?".
 *
 * The defect this replaces: `Shared/Automations/AutomationContract.swift` hand-typed the Inputs
 * rows, including a literal `.planned` for connectors. A human typing state cannot self-correct,
 * so the app claimed a capability it did not have (and, once the Gmail collector was wired,
 * denied one it did). Same defect class as an agent asserting it can "check my photos".
 *
 * Every `state` on this route is COMPUTED from three observed facts, never written by hand:
 *   (a) which connector descriptors exist          — the registry (code that actually runs)
 *   (b) >= 1 ACTIVE Composio account for a toolkit — the live connection authority
 *   (c) the newest per-source availability recorded in `daily_brief_artifacts.input_manifest`
 *       — our own trusted backend collect provenance (migration 114)
 *
 * SOURCE OF TRUTH
 *   - descriptor existence  → the connector signal registry (injected; see automation-input-descriptors.ts)
 *   - connection state      → Composio connected accounts, ACTIVE only (never paused/INACTIVE)
 *   - collect outcome       → `daily_brief_artifacts.input_manifest` (written only by the lease holder)
 *   Nothing here caches those; every request re-derives.
 *
 * RECOVERY
 *   - Composio unreachable  → we never upgrade a row to `included` on faith. See `deriveConnected`.
 *   - No artifact history   → last-collect fields are null; state still resolves from (a) + (b).
 *   - Unknown `kind`        → 404, not a guessed contract.
 */

/** The four capability families the client renders. Wire values — do not rename. */
export const AUTOMATION_INPUT_CAPABILITIES = [
  'rem_tasks',
  'rem_calendar_items',
  'connector',
  'cloud_browser',
] as const;
export type AutomationInputCapability = (typeof AUTOMATION_INPUT_CAPABILITIES)[number];

/**
 * The four derived states. Wire values — do not rename, do not add a fifth without shipping the
 * client's `unrecognized(String)` fallback first.
 */
export const AUTOMATION_INPUT_STATES = [
  'included',
  'not_connected',
  'unavailable',
  'coming_soon',
] as const;
export type AutomationInputState = (typeof AUTOMATION_INPUT_STATES)[number];

/** Product-facing automation kinds addressable as `:kind`. */
export const AUTOMATION_KINDS = ['daily-brief'] as const;
export type AutomationKind = (typeof AUTOMATION_KINDS)[number];

export function isAutomationKind(value: unknown): value is AutomationKind {
  return typeof value === 'string' && (AUTOMATION_KINDS as readonly string[]).includes(value);
}

/** Attribution for a connector row. `source` is `source` at every layer — never renamed. */
export interface AutomationInputConnector {
  source: string;
  displayName: string;
}

/** One row of the Inputs list. Every nullable field here is Optional in the Swift model. */
export interface AutomationInputRow {
  capability: AutomationInputCapability;
  state: AutomationInputState;
  detail: string;
  connector: AutomationInputConnector | null;
  lastCollectedAt: string | null;
  lastItemCount: number | null;
  lastUnavailableReason: string | null;
}

export interface AutomationInputsResponse {
  inputs: AutomationInputRow[];
}

/**
 * The facts this read API needs from a connector signal descriptor.
 *
 * Deliberately a structural SUBSET of `ConnectorSignalDescriptor` (the registry lane's type):
 * a read API has no business with `buildQuery`/`mapItem`/`action`/`actionVersion`. Because the
 * field names and types are identical, a real `ConnectorSignalDescriptor[]` is assignable to
 * `ConnectorInputDescriptorFacts[]` with no adapter — and if the registry ever renames `source`
 * or `toolkitSlug`, the compiler fails at the wiring point instead of the client failing to decode.
 */
export interface ConnectorInputDescriptorFacts {
  source: string;
  toolkitSlug: string;
  displayName: string;
}

/** Newest recorded collect outcome for one source, read from `input_manifest`. */
export interface LastCollectFact {
  source: string;
  availability: string | null;
  unavailableReason: string | null;
  collectedAt: string | null;
  itemCount: number | null;
}

/**
 * Live ACTIVE-account lookup, as a discriminated result.
 *
 * `ok: false` is NOT "no accounts" — it means we could not ask. Collapsing the two is how a
 * connected user gets told to connect (or worse, a disconnected user gets told they're covered).
 */
export type ActiveToolkitLookup =
  | { ok: true; slugs: ReadonlySet<string> }
  | { ok: false; reason: string };

export interface ActiveConnectorAccountSource {
  /** Toolkit slugs with >= 1 ACTIVE connected account for this user. Paused (INACTIVE) is not ACTIVE. */
  listActiveToolkitSlugs(
    userId: string,
    toolkitSlugs: readonly string[],
    timeoutMs: number,
  ): Promise<string[]>;
}

/** Wall-clock bound on the connection lookup. A slow Composio degrades one row, never the route. */
export const AUTOMATION_INPUTS_LOOKUP_TIMEOUT_MS = process.env.NODE_ENV === 'test' ? 50 : 4_000;

/** How far back we scan a user's artifacts for per-source collect provenance. */
export const AUTOMATION_INPUTS_ARTIFACT_SCAN_LIMIT = 60;

/**
 * The collector writes this exact reason when a user has zero ACTIVE accounts. It is a machine
 * enum emitted by our own code (`brief-input.service.ts`), not a parsed human string.
 *
 * It is the one recorded reason that says nothing about the CURRENT connection: if Composio now
 * reports an ACTIVE account, that collect predates the connection and its verdict is superseded.
 * Without this, a user who connects Gmail sees "unavailable" until the next brief runs.
 */
export const SUPERSEDED_BY_LIVE_CONNECTION_REASON = 'no_active_connection';

function sanitizeReason(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  return text.length <= 120 ? text : `${text.slice(0, 119)}…`;
}

/**
 * Tolerant ISO 8601 → canonical ISO 8601.
 *
 * `Date.parse` accepts BOTH fractional and non-fractional seconds ("...T01:00:00Z" and
 * "...T01:00:00.123Z"), which is required: manifests were written by more than one producer
 * version. Output is always re-serialized so the client sees one shape.
 */
export function toIsoOrNull(value: unknown): string | null {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value.toISOString();
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  const parsed = Date.parse(trimmed);
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
}

function nonNegativeInt(value: unknown): number | null {
  const numeric = typeof value === 'string' ? Number(value) : value;
  if (typeof numeric !== 'number' || !Number.isFinite(numeric)) return null;
  const rounded = Math.trunc(numeric);
  return rounded >= 0 ? rounded : null;
}

/**
 * Newest recorded collect outcome per source for this user.
 *
 * `DISTINCT ON (source)` over the manifest entries of the most recent artifacts: different sources
 * legitimately have different "most recent" artifacts, so this is per-source, not per-artifact.
 * The lateral is guarded by `jsonb_typeof` because `input_manifest` is nullable AND can hold JSON
 * `null` (the authoring INSERT stringifies `null` when no snapshot was collected) — `IS NOT NULL`
 * would let both through and `jsonb_array_elements` would raise on a non-array.
 */
export async function readLastCollectFacts(
  userId: string,
  db: DatabaseQueryable = pool,
  scanLimit: number = AUTOMATION_INPUTS_ARTIFACT_SCAN_LIMIT,
): Promise<Map<string, LastCollectFact>> {
  const result = await db.query<{
    source: string | null;
    availability: string | null;
    unavailable_reason: string | null;
    manifest_captured_at: string | null;
    column_captured_at: Date | string | null;
    item_count: number | string | null;
  }>(
    `WITH recent AS (
       SELECT input_manifest, input_captured_at, updated_at
         FROM daily_brief_artifacts
        WHERE user_id = $1::uuid
          AND jsonb_typeof(input_manifest) = 'object'
        ORDER BY input_captured_at DESC NULLS LAST, updated_at DESC
        LIMIT $2
     )
     SELECT DISTINCT ON (entry->>'source')
            entry->>'source'                  AS source,
            entry->>'availability'            AS availability,
            entry->>'unavailableReason'       AS unavailable_reason,
            r.input_manifest->>'capturedAt'   AS manifest_captured_at,
            r.input_captured_at               AS column_captured_at,
            CASE WHEN jsonb_typeof(entry->'stableIds') = 'array'
                 THEN jsonb_array_length(entry->'stableIds')
                 ELSE NULL END                AS item_count
       FROM recent r
       CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(r.input_manifest->'manifest') = 'array'
                   THEN r.input_manifest->'manifest'
                   ELSE '[]'::jsonb END
            ) AS entry
      WHERE jsonb_typeof(entry) = 'object'
        AND COALESCE(entry->>'source', '') <> ''
      ORDER BY entry->>'source', r.input_captured_at DESC NULLS LAST, r.updated_at DESC`,
    [userId, scanLimit],
  );

  const facts = new Map<string, LastCollectFact>();
  for (const row of result.rows) {
    const source = typeof row.source === 'string' ? row.source.trim() : '';
    if (!source) continue;
    facts.set(source, {
      source,
      availability: typeof row.availability === 'string' ? row.availability : null,
      // Passed through sanitized but NEVER interpolated into prose: today it is a closed machine
      // enum, and a future producer must not be able to push arbitrary text into UI copy.
      unavailableReason: sanitizeReason(row.unavailable_reason),
      collectedAt: toIsoOrNull(row.manifest_captured_at) ?? toIsoOrNull(row.column_captured_at),
      itemCount: nonNegativeInt(row.item_count),
    });
  }
  return facts;
}

/**
 * Is this connector connected right now? Three-valued, deliberately.
 *
 * `'unknown'` is NOT a third shade of connected — it is the honest answer when the live lookup
 * failed. The previous shape of this function was boolean and, on `{ok:false}`, returned
 * `last?.availability === 'available'`: a PAST successful collect was treated as proof of a
 * CURRENT active account. That is exactly how a user who disconnected Gmail keeps seeing
 * "Connected — Rem reads the last 24 hours of Gmail", indefinitely, because the manifest entry
 * that vouches for the connection is frozen at the last time it worked and Composio being down is
 * the one moment we lean on it. A stale `available` says an account existed THEN; it cannot say
 * one exists NOW, and the only two things it could produce were a false claim of coverage or a
 * false Connect prompt.
 *
 * So we derive from the live answer, and when there is no live answer we say so.
 */
export type ConnectorConnectedness = 'connected' | 'disconnected' | 'unknown';

export function deriveConnected(
  descriptor: ConnectorInputDescriptorFacts,
  lookup: ActiveToolkitLookup,
): ConnectorConnectedness {
  if (!lookup.ok) return 'unknown';
  return lookup.slugs.has(descriptor.toolkitSlug) ? 'connected' : 'disconnected';
}

/**
 * The pinned state ladder. The ONLY place an input state is decided.
 *
 * Keys off `last.availability` — the STRUCTURED enum the collector writes into the manifest — not
 * off the free-text `unavailableReason` (CLAUDE.md principle 5). The reason string is for COPY;
 * it is sanitized but open-ended, a future producer can add a token, and treating "some string is
 * present" as "the collect failed" makes every new reason code a silent state regression. The
 * enum is the field that answers "did the read succeed".
 *
 * `unknown` connectedness reports `unavailable`: we could not ask, so we do not claim coverage and
 * we do not tell an already-connected user to connect. It is the one state that describes our own
 * ignorance rather than the user's setup.
 */
export function deriveConnectorState(
  connected: ConnectorConnectedness,
  last: LastCollectFact | undefined,
): AutomationInputState {
  if (connected === 'disconnected') return 'not_connected';
  if (connected === 'unknown') return 'unavailable';
  // Connected. The last collect decides whether we can promise it actually gets read.
  if (!last?.availability) return 'included';
  if (last.availability === 'available') return 'included';
  // The collector records this when the user had zero ACTIVE accounts. Composio just told us they
  // have one, so that verdict predates the connection and is superseded — otherwise a user who
  // connects Gmail reads "unavailable" until the next brief runs.
  if (last.unavailableReason === SUPERSEDED_BY_LIVE_CONNECTION_REASON) return 'included';
  return 'unavailable';
}

function connectorDetail(
  state: AutomationInputState,
  connected: ConnectorConnectedness,
  displayName: string,
  reason: string | null,
): string {
  const window = `${GMAIL_BRIEF_WINDOW_HOURS} hours`;
  switch (state) {
    case 'included':
      return `Connected — Rem reads the last ${window} of ${displayName} when it writes this brief.`;
    case 'not_connected':
      return `Connect ${displayName} to let Rem read the last ${window} of it when it writes this brief.`;
    case 'unavailable':
      // We could not reach the connection authority. Say THAT — asserting "Connected, but…" here
      // would be inventing the very fact the lookup failed to establish.
      if (connected === 'unknown') {
        return `Rem couldn't check your ${displayName} connection just now. Pull to refresh.`;
      }
      // Closed set of reasons our collector emits; anything else falls through to a generic
      // sentence rather than leaking an unrecognized string into UI copy.
      switch (reason) {
        case 'timeout':
          return `Connected, but reading ${displayName} timed out on the last brief.`;
        case 'connector_unavailable':
          return `Connected, but Rem couldn't reach ${displayName} on the last brief.`;
        case 'active_connection_cap_exceeded':
          return `Too many ${displayName} accounts are connected for Rem to read them safely.`;
        default:
          return `Connected, but Rem couldn't read ${displayName} on the last brief.`;
      }
    case 'coming_soon':
      return `${displayName} isn't wired into this brief yet.`;
  }
}

export interface DeriveAutomationInputsArgs {
  kind: AutomationKind;
  descriptors: readonly ConnectorInputDescriptorFacts[];
  lookup: ActiveToolkitLookup;
  lastCollectBySource: ReadonlyMap<string, LastCollectFact>;
}

/**
 * Pure derivation — no I/O, no clock, no randomness. Given the three observed fact sets, the rows
 * are a total function of them. This is what makes the contract untypeable by hand.
 *
 * Row order is stable: Rem-owned sources, then connectors sorted by `source`, then not-yet-built
 * capabilities. Connectors sort by `source` so the list does not reshuffle between requests.
 */
export function deriveAutomationInputs(args: DeriveAutomationInputsArgs): AutomationInputRow[] {
  const { descriptors, lookup, lastCollectBySource } = args;

  // Rem's own stores are read directly by `gatherBrief`; there is no connection to derive. The
  // copy is carried over verbatim from the hand-written contract because it was already accurate.
  const rows: AutomationInputRow[] = [
    {
      capability: 'rem_tasks',
      state: 'included',
      detail: 'Reads scheduled, overdue, blocked, and completed task rows stored by Rem.',
      connector: null,
      lastCollectedAt: null,
      lastItemCount: null,
      lastUnavailableReason: null,
    },
    {
      capability: 'rem_calendar_items',
      state: 'included',
      detail: "Includes calendar-event rows that are already available in Rem's task store.",
      connector: null,
      lastCollectedAt: null,
      lastItemCount: null,
      lastUnavailableReason: null,
    },
  ];

  const seen = new Set<string>();
  const ordered = [...descriptors].sort((a, b) => a.source.localeCompare(b.source));
  for (const descriptor of ordered) {
    if (seen.has(descriptor.source)) continue;
    seen.add(descriptor.source);
    const last = lastCollectBySource.get(descriptor.source);
    const connected = deriveConnected(descriptor, lookup);
    const state = deriveConnectorState(connected, last);
    rows.push({
      capability: 'connector',
      state,
      detail: connectorDetail(state, connected, descriptor.displayName, last?.unavailableReason ?? null),
      connector: { source: descriptor.source, displayName: descriptor.displayName },
      lastCollectedAt: last?.collectedAt ?? null,
      lastItemCount: last?.itemCount ?? null,
      lastUnavailableReason: last?.unavailableReason ?? null,
    });
  }

  /**
   * Capabilities we intend to feed this brief but have not wired yet.
   *
   * `coming_soon` is derived from ABSENCE from the registry — and now actually is. This used to be
   * an unconditional `rows.push({ capability: 'cloud_browser', state: 'coming_soon' })` sitting
   * directly beneath a comment claiming the state was derived from absence. Register a
   * `cloud_browser` descriptor and the screen would have shown the row TWICE, once derived and
   * once hardcoded, disagreeing with itself. The `seen` guard is what makes the claim true: the
   * row appears only while nothing in the registry claims that source, and it disappears the day
   * one does.
   *
   * What is listed here is a ROADMAP entry (which not-yet-built capabilities are worth naming to
   * the user), never a STATE.
   */
  for (const planned of PLANNED_CAPABILITIES) {
    if (seen.has(planned.source)) continue;
    rows.push({
      capability: planned.capability,
      state: 'coming_soon',
      detail: planned.detail,
      connector: null,
      lastCollectedAt: null,
      lastItemCount: null,
      lastUnavailableReason: null,
    });
  }

  return rows;
}

/**
 * Capabilities the brief does not read yet. `source` is the registry source that would REPLACE
 * the row — so registering a descriptor for it removes this entry automatically.
 */
const PLANNED_CAPABILITIES: readonly {
  capability: AutomationInputCapability;
  source: string;
  detail: string;
}[] = Object.freeze([
  {
    capability: 'cloud_browser',
    source: 'cloud_browser',
    detail: 'Cloud-browser findings are not passed into this brief yet.',
  },
]);

/**
 * Full read path: observe, then derive.
 *
 * The Composio lookup is wrapped so a connector outage degrades to a call-to-action row instead
 * of a 500. The DB read is NOT wrapped — losing our own provenance means we cannot honestly
 * answer, and a 500 the client can retry beats a confidently wrong contract.
 */
export async function getAutomationInputs(
  userId: string,
  kind: AutomationKind,
  descriptors: readonly ConnectorInputDescriptorFacts[],
  accounts: ActiveConnectorAccountSource,
  db: DatabaseQueryable = pool,
): Promise<AutomationInputsResponse> {
  const slugs = [...new Set(descriptors.map((descriptor) => descriptor.toolkitSlug))].sort();
  const [lastCollectBySource, lookup] = await Promise.all([
    readLastCollectFacts(userId, db),
    resolveActiveToolkitLookup(userId, slugs, accounts),
  ]);
  return { inputs: deriveAutomationInputs({ kind, descriptors, lookup, lastCollectBySource }) };
}

async function resolveActiveToolkitLookup(
  userId: string,
  slugs: readonly string[],
  accounts: ActiveConnectorAccountSource,
): Promise<ActiveToolkitLookup> {
  if (slugs.length === 0) return { ok: true, slugs: new Set<string>() };
  try {
    const active = await accounts.listActiveToolkitSlugs(
      userId,
      slugs,
      AUTOMATION_INPUTS_LOOKUP_TIMEOUT_MS,
    );
    return { ok: true, slugs: new Set(active) };
  } catch (error: unknown) {
    const reason = error instanceof Error ? error.message : String(error);
    // Never logs the user id or any account identifier — only why the lookup failed.
    console.warn('[AUTOMATION-INPUTS] active-account lookup unavailable:', reason);
    return { ok: false, reason };
  }
}
