/**
 * The SHARED bounded runner for connector signal collection.
 *
 * Every rule that must hold for EVERY connected source lives here, not in a descriptor:
 * the account cap, the item cap, the page cap, the window length, the wall-time budget, the
 * dedupe, the post-fetch timestamp re-check, and the availability classification. A descriptor
 * (`connector-signals.registry.ts`) supplies provider knowledge only; it has no field with which
 * to widen a bound, and the fetch input is assembled so a descriptor's own query keys can never
 * overwrite `maxResults`, `pageToken` or `timeoutMs`.
 *
 * STATE / SOURCE OF TRUTH
 * -----------------------
 * The returned `ConnectorSignalCollection` is the source of truth for one collect attempt. It is
 * either `available` (a complete, bounded read — possibly of zero items) or `unavailable` with a
 * machine-readable `unavailableReason`. There is no partial state: a later-page failure discards
 * the prefix rather than presenting a truncated read as a complete one, because a Daily Brief that
 * silently drops half the window is worse than one that says it could not look.
 *
 * RECOVERY
 * --------
 * Failure is per-attempt and non-destructive: nothing is written here, so the next cron tick
 * simply tries again. `unavailableReason` is what the derived-inputs API surfaces to the user
 * ("Gmail — couldn't read this morning"), so it must stay a STRUCTURED token, never prose.
 */

import {
  parseConnectorInstant,
  type ConnectorSignalDescriptor,
  type NormalizedSignal,
} from './connector-signals.registry.js';

/**
 * The bounds. A descriptor cannot widen these — they are read here and nowhere else.
 * These are the values `collectGmailBriefInput` has always enforced; moving them did not change
 * one of them.
 */
export const CONNECTOR_SIGNAL_BOUNDS = Object.freeze({
  /** Fail closed above this many ACTIVE grants rather than fan out unboundedly. */
  maxAccounts: 3,
  /** Hard cap on collected items across all accounts. */
  maxItems: 20,
  /** Hard cap on provider pages per account. */
  maxPages: 3,
  /** Rolling window length. */
  windowHours: 24,
  /** Total wall-time budget for the whole collect, account enumeration included. */
  timeoutMs: 2_500,
});

/** Structured reasons a collect produced nothing. Machine tokens, never user prose. */
export type ConnectorSignalUnavailableReason =
  | 'no_active_connection'
  | 'active_connection_cap_exceeded'
  | 'timeout'
  | 'connector_unavailable';

export type ConnectorSignalAvailability = 'available' | 'unavailable';

/** The base fetch input the runner always controls. Descriptor query keys are merged UNDER it. */
export interface ConnectorSignalFetchBase {
  userId: string;
  connectedAccountId: string;
  action: string;
  version: string;
  maxResults: number;
  pageToken?: string;
  timeoutMs: number;
}

export type ConnectorSignalFetchInput = ConnectorSignalFetchBase & Record<string, unknown>;

export interface ConnectorSignalPage<Item = unknown> {
  items: Item[];
  nextPageToken: string | null;
}

/** The provider I/O boundary. Implementations live next to the SDK they call (composio.service.ts). */
export interface ConnectorSignalAdapter<Item = unknown> {
  fetchPage(input: ConnectorSignalFetchInput): Promise<ConnectorSignalPage<Item>>;
}

/**
 * ACTIVE connected accounts for ONE toolkit — the authorization to read that source at all.
 *
 * `toolkitSlug` is a REQUIRED parameter, not an implicit binding baked into the implementation.
 * This interface was originally two-arg, which meant the "shared" runner could never tell its
 * account source WHICH toolkit authorized the read: `descriptor.toolkitSlug` was declared on the
 * descriptor and then never read by anything on this path, so a second descriptor would silently
 * have been handed Gmail's accounts. The runner now threads it on every call.
 *
 * Declared HERE and imported by `signal-ingest.service.ts` — one shape, one declaration, so the
 * two collectors cannot drift into wanting different things from the same Composio binding.
 */
export interface ActiveConnectorAccountSource {
  listActiveAccountIds(
    userId: string,
    toolkitSlug: string,
    timeoutMs: number,
  ): Promise<string[]>;
}

/**
 * ACTIVE connected accounts for EVERY toolkit a tick needs — in ONE round trip.
 *
 * WHY A SECOND SHAPE. `listActiveAccountIds` above answers for one toolkit, which is the right
 * shape for the Daily Brief collector: one descriptor, one call, inside a user-facing turn. The
 * tier-2 poller is different — it runs EVERY descriptor for EVERY recently-active user on a
 * 15-minute cron, so the one-toolkit shape costs a Composio round trip per descriptor per user per
 * tick, all of them spent before a single message is fetched. At one descriptor that is invisible;
 * at the connector catalog this product is heading toward it is 13 sequential round trips per user
 * against the wall-clock budget that decides how many users the tick reaches at all.
 *
 * The provider already supports asking once: `composio.connectedAccounts.list` takes
 * `toolkitSlugs` as an ARRAY (`toolkit_slugs?: Array<string> | null`, @composio/client), and each
 * item in the response carries its own `toolkit: { slug: string }` — a REQUIRED field in the SDK's
 * parsed response type — so the answers can be attributed back per toolkit without a second call.
 *
 * CONTRACT: the returned map has an entry for EVERY requested slug, an empty array where the user
 * has no ACTIVE grant. A caller must never have to tell "key absent" from "no accounts" — those
 * are the same fact and only one of them should be representable.
 */
export interface ActiveConnectorAccountsByToolkitSource {
  listActiveAccountIdsByToolkit(
    userId: string,
    toolkitSlugs: readonly string[],
    timeoutMs: number,
  ): Promise<ReadonlyMap<string, readonly string[]>>;
}

/** One kept item: its normalized signal, plus the raw it came from for source-specific projection. */
export interface CollectedConnectorSignal<Item = unknown> {
  /** `<source>:<sourceRef>` — the dedupe key and the durable identity downstream. */
  stableId: string;
  connectedAccountId: string;
  signal: NormalizedSignal;
  raw: Item;
}

export interface ConnectorSignalCollection<Item = unknown> {
  source: string;
  availability: ConnectorSignalAvailability;
  unavailableReason: ConnectorSignalUnavailableReason | null;
  windowStart: string;
  windowEnd: string;
  connectedAccountIds: string[];
  collected: CollectedConnectorSignal<Item>[];
  /**
   * Items whose `mapItem` THREW and were dropped. A complete read with a non-zero count here is
   * still `available` — that is the point of the per-item guard — but the count must be visible,
   * because "we silently discarded a third of the inbox" and "the inbox had a third fewer
   * messages" are different facts and a bare item count cannot tell them apart.
   */
  malformedItems: number;
}

/**
 * The runner's own deadline breach. A CLASS, not a message — classification reads the type first
 * so a provider error whose text happens to contain "timeout" cannot be mistaken for ours.
 */
export class ConnectorSignalTimeoutError extends Error {
  constructor(message = 'timeout') {
    super(message);
    this.name = 'ConnectorSignalTimeoutError';
  }
}

/**
 * Structured-first classification (CLAUDE.md principle 5). Type and `name` are the real signals;
 * the message compare is retained ONLY because `listActiveAccountIdsForToolkit`
 * (composio.service.ts) still throws `new Error('timeout')` on its own deadline. Fix that upstream
 * and this line can go.
 */
function classifyUnavailableReason(error: unknown): ConnectorSignalUnavailableReason {
  if (error instanceof ConnectorSignalTimeoutError) return 'timeout';
  if (error instanceof Error && error.name === 'TimeoutError') return 'timeout';
  if (error instanceof Error && error.message === 'timeout') return 'timeout';
  return 'connector_unavailable';
}

/**
 * Keys the runner owns outright. A descriptor's `buildQuery` is provider knowledge, not a place to
 * reach a bound: anything it returns under one of these names is dropped before the merge, so a
 * descriptor cannot raise `maxResults`, stretch `timeoutMs`, seed a `pageToken`, or impersonate a
 * different action/version/account.
 */
const RUNNER_OWNED_FETCH_KEYS = [
  'userId',
  'connectedAccountId',
  'action',
  'version',
  'maxResults',
  'pageToken',
  'timeoutMs',
] as const;

/**
 * Call `buildQuery` with window bounds the descriptor CANNOT reach back through.
 *
 * `Date` is mutable. Handing a descriptor the runner's own `windowStartDate`/`windowEndDate` —
 * and `windowEndDate` was literally the caller's `now` — meant one `setTime()` inside a
 * `buildQuery` would move the window that the post-fetch re-check (`receivedAt < windowStartDate`)
 * measures against, and would mutate the caller's clock besides. The header of this file claims a
 * descriptor "has no field with which to widen a bound"; passing live objects made that a comment
 * the code contradicted.
 *
 * Clones are passed instead, so the worst a descriptor can do is corrupt its OWN query. The
 * runner's bounds, and the caller's `now`, are unreachable from inside `buildQuery`.
 */
function descriptorQuery(
  descriptor: ConnectorSignalDescriptor,
  windowStart: Date,
  windowEnd: Date,
): Record<string, unknown> {
  const query = { ...descriptor.buildQuery(new Date(windowStart.getTime()), new Date(windowEnd.getTime())) };
  for (const key of RUNNER_OWNED_FETCH_KEYS) delete query[key];
  return query;
}

function unavailable<Item>(
  source: string,
  windowStart: string,
  windowEnd: string,
  reason: ConnectorSignalUnavailableReason,
  malformedItems = 0,
): ConnectorSignalCollection<Item> {
  return {
    source,
    availability: 'unavailable',
    unavailableReason: reason,
    windowStart,
    windowEnd,
    connectedAccountIds: [],
    collected: [],
    malformedItems,
  };
}

/**
 * Diagnostic for a failed collect. Names the descriptor's source, the error CLASS and a truncated
 * message — enough to tell "Composio key missing" from "action version rejected" from "we timed
 * out" in a log, which is exactly what six silent `connector_unavailable` artifacts in production
 * could not tell us.
 *
 * Never logs provider content: only the error's own class and message, capped.
 */
function logCollectFailure(source: string, reason: string, error: unknown): void {
  const errorClass = error instanceof Error ? (error.name || error.constructor.name) : typeof error;
  const raw = error instanceof Error ? error.message : String(error);
  const message = raw.length > 200 ? `${raw.slice(0, 199)}…` : raw;
  console.warn(`[connector-signals] ${source} collect ${reason}: ${errorClass}: ${message}`);
}

/**
 * A descriptor's `mapItem` threw on ONE item.
 *
 * Error CLASS only — deliberately not the message. `mapItem` runs directly on a provider item, so
 * a thrown message can quote the mail it choked on (`Cannot read 'subject' of "Re: your invoice"`).
 * The class plus the source is enough to find the descriptor bug; the content is not ours to log.
 */
function logMapItemFailure(source: string, error: unknown): void {
  const errorClass = error instanceof Error ? (error.name || error.constructor.name) : typeof error;
  console.warn(`[connector-signals] ${source} mapItem threw on one item, dropped: ${errorClass}`);
}

/**
 * Collect one source's signals inside the shared bounds.
 *
 * Ordering is deterministic — newest first, then stableId — so an unchanged inbox produces an
 * unchanged fingerprint downstream.
 */
export async function collectConnectorSignals<Item>(
  descriptor: ConnectorSignalDescriptor,
  input: {
    userId: string;
    now: Date;
    accounts: ActiveConnectorAccountSource;
    adapter: ConnectorSignalAdapter<Item>;
  },
): Promise<ConnectorSignalCollection<Item>> {
  const { userId, now, accounts, adapter } = input;
  const bounds = CONNECTOR_SIGNAL_BOUNDS;
  // Cloned, not aliased: `windowEndDate` used to BE the caller's `now`, so the runner's own window
  // was mutable by anyone holding that object. These two are the reference the post-fetch
  // timestamp re-check measures against and must not move once the collect has started.
  const windowEndDate = new Date(now.getTime());
  const windowStartDate = new Date(now.getTime() - bounds.windowHours * 3_600_000);
  const windowEnd = windowEndDate.toISOString();
  const windowStart = windowStartDate.toISOString();
  const deadline = Date.now() + bounds.timeoutMs;
  // Declared outside the try so a later-page failure still reports the items we already dropped.
  let malformedItems = 0;

  try {
    // `descriptor.toolkitSlug` is the live read that makes this runner source-generic: the account
    // source is asked for THIS descriptor's toolkit, never a hardcoded one.
    const ids = [...new Set(
      await accounts.listActiveAccountIds(userId, descriptor.toolkitSlug, bounds.timeoutMs),
    )].sort();
    if (ids.length === 0) {
      return unavailable(descriptor.source, windowStart, windowEnd, 'no_active_connection', malformedItems);
    }
    if (ids.length > bounds.maxAccounts) {
      return unavailable(descriptor.source, windowStart, windowEnd, 'active_connection_cap_exceeded', malformedItems);
    }

    const query = descriptorQuery(descriptor, windowStartDate, windowEndDate);
    const byStableId = new Map<string, CollectedConnectorSignal<Item>>();
    const perAccountLimit = Math.max(1, Math.floor(bounds.maxItems / ids.length));

    for (const connectedAccountId of ids) {
      let pageToken: string | undefined;
      let accountItems = 0;
      for (let page = 0; page < bounds.maxPages && accountItems < perAccountLimit; page++) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) throw new ConnectorSignalTimeoutError();
        const result = await adapter.fetchPage({
          // Runner-owned keys are already stripped from `query`, and it is spread FIRST anyway.
          ...query,
          userId,
          connectedAccountId,
          action: descriptor.action,
          version: descriptor.actionVersion,
          maxResults: perAccountLimit - accountItems,
          ...(pageToken ? { pageToken } : {}),
          timeoutMs: Math.min(remaining, bounds.timeoutMs),
        });
        for (const raw of result.items) {
          // Per-ITEM guard. `mapItem` is descriptor-supplied and runs on provider data we do not
          // control. Unguarded, one malformed item threw straight past the page loop to the outer
          // catch and turned a complete, mostly-good read into `connector_unavailable` — the whole
          // window discarded, and (on the Daily Brief path) a snapshot that says we could not look
          // at all. A bad item is DROPPED and counted; it is not allowed to speak for the batch.
          let signal: NormalizedSignal | null;
          try {
            signal = descriptor.mapItem(raw, connectedAccountId);
          } catch (error) {
            malformedItems += 1;
            logMapItemFailure(descriptor.source, error);
            continue;
          }
          if (!signal) continue;
          // A descriptor that emits a foreign source would corrupt attribution downstream.
          if (signal.source !== descriptor.source) continue;
          const receivedAt = parseConnectorInstant(signal.receivedAt);
          if (!receivedAt) continue;
          // The provider query is allowed to be broader than the window; this is the exact cut.
          if (receivedAt < windowStartDate || receivedAt > windowEndDate) continue;
          const stableId = `${descriptor.source}:${signal.sourceRef}`;
          if (!byStableId.has(stableId)) accountItems += 1;
          byStableId.set(stableId, { stableId, connectedAccountId, signal, raw });
          if (accountItems >= perAccountLimit) break;
        }
        if (!result.nextPageToken) break;
        pageToken = result.nextPageToken;
      }
    }

    // Newest first, ties broken by stableId. Compared as INSTANTS, not as text: `receivedAt` is
    // ISO 8601 with or without fractional seconds, and lexicographic order disagrees with time
    // order across those two forms ('…:00Z' sorts after '…:00.500Z' but happened before it).
    //
    // Parsed with the SAME parser the window re-check above uses, not `Date.parse`. A descriptor
    // may hand back an epoch-number instant (Slack's `ts`), which the re-check accepts and
    // `Date.parse` turns into NaN — and a comparator that returns NaN does not order, it leaves
    // the array in whatever order the engine's sort happened to touch it. Every item here has
    // already passed the re-check, so `?? 0` is unreachable; it exists so a future edit cannot
    // reintroduce a silent NaN.
    const instant = (value: string): number => parseConnectorInstant(value)?.getTime() ?? 0;
    const collected = [...byStableId.values()]
      .sort((a, b) => instant(b.signal.receivedAt) - instant(a.signal.receivedAt)
        || a.stableId.localeCompare(b.stableId))
      .slice(0, bounds.maxItems);

    return {
      source: descriptor.source,
      availability: 'available',
      unavailableReason: null,
      windowStart,
      windowEnd,
      connectedAccountIds: ids,
      collected,
      malformedItems,
    };
  } catch (error) {
    const reason = classifyUnavailableReason(error);
    logCollectFailure(descriptor.source, reason, error);
    return unavailable(descriptor.source, windowStart, windowEnd, reason, malformedItems);
  }
}
