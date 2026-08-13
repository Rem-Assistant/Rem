import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Real-SQL tests for the tier-2 signal producer. These run the ACTUAL migration 039 and the ACTUAL
 * `ingestSignalDetailed` upsert against an in-process pglite Postgres — no injected writer — so the
 * things a mock cannot prove are proven here:
 *
 *   - re-ingesting the same source_ref leaves ONE row (the unique key, not a local dedupe);
 *   - `inserted` really distinguishes the INSERT arm from the ON CONFLICT arm, so `ingested` and
 *     `duplicates` are read from the database rather than assumed by the caller;
 *   - two users can hold the same provider message id without colliding;
 *   - the candidate select's `last_active_at` predicate compiles and filters.
 *
 * Mirrors suggestions.service.db.test.ts.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.join(__dirname, '..', 'db', 'migrations');

// Holder so the hoisted vi.mock can reach the pglite instance created in beforeAll.
const h: { db: any } = { db: null };

vi.mock('../db/pool.js', () => ({
  pool: {
    query: (text: string, params?: unknown[]) => h.db.query(text, params ?? []),
  },
}));

const USER_ID = '11111111-1111-1111-1111-111111111111';
const OTHER_USER = '22222222-2222-2222-2222-222222222222';
const NOW = new Date('2026-08-10T12:00:00.000Z');

let runSignalIngestBatch: typeof import('./signal-ingest.service.js').runSignalIngestBatch;
let selectSignalIngestUsers: typeof import('./signal-ingest.service.js').selectSignalIngestUsers;
let SIGNAL_TEXT_LIMITS: typeof import('./signal-ingest.service.js').SIGNAL_TEXT_LIMITS;
type ConnectorSignalDescriptor = import('./connector-signals.registry.js').ConnectorSignalDescriptor;
type SignalIngestDependencies = import('./signal-ingest.service.js').SignalIngestDependencies;

interface RawItem {
  id: string;
  sender?: string;
  summary?: string;
  timestamp?: string;
}

function gmailDescriptor(): ConnectorSignalDescriptor {
  return {
    source: 'gmail',
    toolkitSlug: 'gmail',
    action: 'GMAIL_FETCH_EMAILS',
    actionVersion: '20260721_00',
    displayName: 'Gmail',
    buildQuery: (windowStart, windowEnd) => ({
      query: `after:${windowStart.toISOString()} before:${windowEnd.toISOString()}`,
    }),
    mapItem: (item, connectedAccountId) => {
      const value = item as RawItem;
      return {
        source: 'gmail',
        sourceRef: `${connectedAccountId}:${value.id}`,
        sender: value.sender ?? null,
        summary: value.summary ?? 'message',
        suggestedTitle: null,
        receivedAt: value.timestamp ?? NOW.toISOString(),
      };
    },
  };
}

/** Real service, real SQL — only the PROVIDER is faked. No `write` override anywhere in this file. */
function providerDeps(items: RawItem[]): SignalIngestDependencies {
  return {
    accounts: {
      listActiveAccountIdsByToolkit: async (_userId, toolkitSlugs) =>
        new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']])),
    },
    executor: { fetchPage: async () => ({ items, nextPageToken: null }) },
  };
}

async function signalRows(userId?: string) {
  const { rows } = await h.db.query(
    userId
      ? `SELECT user_id, source, source_ref, sender, summary, received_at FROM channel_signals WHERE user_id = $1 ORDER BY source_ref`
      : `SELECT user_id, source, source_ref, sender, summary, received_at FROM channel_signals ORDER BY source_ref`,
    userId ? [userId] : [],
  );
  return rows as Array<Record<string, any>>;
}

beforeAll(async () => {
  const { PGlite } = await import('@electric-sql/pglite');
  h.db = new PGlite();

  await h.db.exec(`
    CREATE TABLE users (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      last_active_at TIMESTAMPTZ
    )
  `);
  await h.db.query(`INSERT INTO users (id) VALUES ($1), ($2)`, [USER_ID, OTHER_USER]);

  // The real channel_signals migration — the unique key under test is defined there, not here.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '039_create_channel_signals.sql'), 'utf8'),
  );
  // The relevance-verdict columns. The shared upsert now clears a stored verdict when a
  // re-delivery changes the content, so the ON CONFLICT clause does not compile without them.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '118_add_signal_relevance.sql'), 'utf8'),
  );
  // The judge's recommended start time — same reason: the shared upsert clears it on a content
  // change, so the ON CONFLICT clause does not compile without the column.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '122_add_signal_suggested_time.sql'), 'utf8'),
  );

  const svc = await import('./signal-ingest.service.js');
  runSignalIngestBatch = svc.runSignalIngestBatch;
  selectSignalIngestUsers = svc.selectSignalIngestUsers;
  SIGNAL_TEXT_LIMITS = svc.SIGNAL_TEXT_LIMITS;
  // pglite's first boot (wasm init + CREATE TABLE + migration) exceeds vitest's 10s default on a
  // cold cache, and does so more often when the whole suite is competing for the disk. A timed-out
  // hook skips every test in the file and still reports "failed" — an infrastructure flake that
  // looks exactly like a broken feature. 60s is slack, not a claim that the boot is slow.
}, 60_000);

afterAll(async () => {
  await h.db?.close?.();
});

beforeEach(async () => {
  await h.db.query('DELETE FROM channel_signals');
  await h.db.query('UPDATE users SET last_active_at = NULL');
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

/**
 * ── THE WIRING TEST ─────────────────────────────────────────────────────────────────────────────
 *
 * Everything else in this file hands `runSignalIngestBatch` a descriptor built by `gmailDescriptor()`
 * — a fixture defined at the top of this file. Those tests pass whether or not the REGISTRY is
 * connected to the ingester, which is exactly how the previous run shipped a green suite over a
 * feature that wrote zero rows: `connector-signals.ts` was a stub whose `listSignalDescriptors()`
 * returned `[]`, the cron gate reported `no_descriptors`, and no test noticed because no test ever
 * asked the registry for anything.
 *
 * These tests take the descriptor from `listDescriptors()` — the real registry, the same call the
 * cron entrypoint makes — and assert a row lands in the real `channel_signals` table through the
 * real `ingestSignalDetailed` upsert.
 *
 * What would this look like if the feature were absent? `listDescriptors()` would be empty,
 * `runSignalIngestBatch` would return on its `descriptors.length === 0` guard, and the SELECT
 * below would find nothing. That is the failure this test exists to produce.
 */
describe('the registry is actually connected to the ingester', () => {
  /**
   * An item as it looks AFTER the transport has normalized it — NOT as Composio puts it on the
   * wire. Gmail's wire naming is `messageId` / `preview` / `messageTimestamp`; these are the names
   * `normalizeGmailWireMessage` (composio.service.ts) renames them to, and the only names
   * `parseGmailItem` reads.
   *
   * ⚠️ THIS HELPER WAS CALLED `rawGmailItem()` AND IT WAS NEVER RAW. That single misnomer is why
   * this suite stayed green over a producer that wrote zero rows for two review rounds: it made
   * "the ingester works" look proven while the REAL executor was handing `mapItem` wire-named
   * objects that matched none of these fields. The name now says which side of the transport
   * boundary it sits on.
   *
   * These tests still legitimately start here — their subject is registry↔ingester wiring, not
   * field naming. The naming boundary is owned by `signal-ingest.executor-shape.db.test.ts`, which
   * drives the REAL `composioSignalExecutor` and hand-writes no item at all. If you are about to
   * add an item literal to this file, that is the file it probably belongs in.
   */
  function normalizedGmailItem(overrides: Record<string, unknown> = {}) {
    return {
      providerMessageId: 'msg-abc',
      providerThreadId: 'thread-1',
      sender: 'Ada Lovelace',
      subject: 'Friday',
      snippet: 'are you free',
      timestamp: '2026-08-10T11:30:00.000Z',
      ...overrides,
    };
  }

  it('writes a channel_signals row when a descriptor EXISTS and an account is ACTIVE', async () => {
    const { listDescriptors } = await import('./connector-signals.registry.js');
    const descriptors = [...listDescriptors()];

    // Guard the premise: if the registry is empty, the assertions below would pass vacuously on a
    // "no rows expected" reading. Fail loudly instead, naming the actual defect.
    expect(
      descriptors.length,
      'the connector signal registry is EMPTY — the ingester has nothing to poll',
    ).toBeGreaterThan(0);

    const summary = await runSignalIngestBatch(
      [USER_ID],
      descriptors,
      NOW,
      providerDeps([normalizedGmailItem()] as any),
    );

    expect(summary.ingested).toBeGreaterThan(0);
    const rows = await signalRows(USER_ID);
    expect(rows.length).toBeGreaterThan(0);

    // The row must carry the REGISTRY's identity and the REGISTRY's field extraction, not this
    // file's. `source_ref` is `<connectedAccountId>:<providerMessageId>` and `summary` is
    // "<subject> — <snippet>" only because `gmailSignalDescriptor.mapItem` built them.
    const row = rows.find((r) => r.source_ref === 'acct-1:msg-abc');
    expect(row, 'no row carrying the real Gmail descriptor\'s source_ref').toBeTruthy();
    expect(row).toMatchObject({
      user_id: USER_ID,
      source: 'gmail',
      source_ref: 'acct-1:msg-abc',
      sender: 'Ada Lovelace',
      summary: 'Friday — are you free',
    });
  });

  it('asks the account source for the descriptor\'s OWN toolkit, not a hardcoded one', async () => {
    const { listDescriptors } = await import('./connector-signals.registry.js');
    const descriptors = [...listDescriptors()];
    // Without this the assertion below is `[] === []` — a vacuous pass on an empty registry, i.e.
    // exactly the state this suite exists to catch.
    expect(descriptors.length, 'empty registry — nothing to thread a toolkit through')
      .toBeGreaterThan(0);
    const asked: string[][] = [];

    await runSignalIngestBatch([USER_ID], descriptors, NOW, {
      accounts: {
        listActiveAccountIdsByToolkit: async (_userId, toolkitSlugs) => {
          asked.push([...toolkitSlugs]);
          return new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']]));
        },
      },
      executor: { fetchPage: async () => ({ items: [normalizedGmailItem()], nextPageToken: null }) },
    });

    // `descriptor.toolkitSlug` has a live read: the toolkits asked for are the ones the descriptors
    // declare. An undefined here is the toolkit threading regressing.
    expect(asked.flat().sort()).toEqual([...new Set(descriptors.map((d) => d.toolkitSlug))].sort());
    expect(asked.flat().every((slug) => typeof slug === 'string' && slug.length > 0)).toBe(true);
    // ONE round trip for the whole tick, not one per descriptor. This is the assertion that fails
    // if a future edit moves the lookup back inside the per-descriptor loop.
    expect(asked, 'connection discovery must cost ONE provider call per user per tick').toHaveLength(1);
  });

  it('the cron entrypoint reads the SAME registry — no second descriptor list', async () => {
    // The stub this replaced was a whole second module. Pin the import so a future lane cannot
    // reintroduce a lane-local registry and leave this suite green.
    const script = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'ingest-signals.ts'), 'utf8');
    expect(script).toContain("from '../services/connector-signals.registry.js'");
    expect(script).toContain('listDescriptors()');
    expect(script).not.toContain('listSignalDescriptors');
  });
});

describe('runSignalIngestBatch — against the real channel_signals table', () => {
  it('writes rows the deriver can actually read, through the shared idempotent upsert', async () => {
    const items: RawItem[] = [
      { id: 'm1', sender: 'Ada', summary: 'Ada asked if you are free Friday' },
      { id: 'm2', sender: 'Bob', summary: 'Invoice overdue' },
    ];
    const summary = await runSignalIngestBatch([USER_ID], [gmailDescriptor()], NOW, providerDeps(items));

    expect(summary).toMatchObject({ users: 1, sources: 1, fetched: 2, ingested: 2, duplicates: 0, failed: 0 });
    const rows = await signalRows();
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({
      user_id: USER_ID,
      source: 'gmail',
      source_ref: 'acct-1:m1',
      sender: 'Ada',
      summary: 'Ada asked if you are free Friday',
    });
  });

  it('IDEMPOTENT re-ingest: the same source_ref twice leaves ONE row and reports a duplicate', async () => {
    const items: RawItem[] = [{ id: 'm1', sender: 'Ada', summary: 'first delivery' }];
    const descriptors = [gmailDescriptor()];

    const first = await runSignalIngestBatch([USER_ID], descriptors, NOW, providerDeps(items));
    expect(first).toMatchObject({ ingested: 1, duplicates: 0 });

    const second = await runSignalIngestBatch([USER_ID], descriptors, NOW, providerDeps(items));
    // The counter that a previous bug in this repo got wrong: a non-throwing write is NOT new work.
    expect(second).toMatchObject({ fetched: 1, ingested: 0, duplicates: 1, failed: 0 });

    const rows = await signalRows();
    expect(rows).toHaveLength(1);
  });

  it('a re-delivery UPDATES the row in place rather than stacking a second suggestion', async () => {
    const descriptors = [gmailDescriptor()];
    await runSignalIngestBatch([USER_ID], descriptors, NOW, providerDeps([
      { id: 'm1', sender: 'Ada', summary: 'first' },
    ]));
    const before = await signalRows();

    await runSignalIngestBatch([USER_ID], descriptors, NOW, providerDeps([
      { id: 'm1', sender: 'Ada Lovelace', summary: 'second (edited)' },
    ]));
    const after = await signalRows();

    expect(after).toHaveLength(1);
    expect(after[0].id).toBe(before[0].id);
    expect(after[0].summary).toBe('second (edited)');
    expect(after[0].sender).toBe('Ada Lovelace');
  });

  it('two users can hold the same provider message id — the unique key is per user', async () => {
    const items: RawItem[] = [{ id: 'm1', sender: 'Ada', summary: 'shared thread' }];
    const summary = await runSignalIngestBatch(
      [USER_ID, OTHER_USER],
      [gmailDescriptor()],
      NOW,
      providerDeps(items),
    );
    expect(summary).toMatchObject({ users: 2, ingested: 2, duplicates: 0 });
    expect(await signalRows(USER_ID)).toHaveLength(1);
    expect(await signalRows(OTHER_USER)).toHaveLength(1);
  });

  it("one user's provider failure never blocks another user's row", async () => {
    const deps: SignalIngestDependencies = {
      accounts: {
        listActiveAccountIdsByToolkit: async (userId, toolkitSlugs) => {
          if (userId === USER_ID) throw new Error('composio 503');
          return new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']]));
        },
      },
      executor: { fetchPage: async () => ({ items: [{ id: 'm1', summary: 'ok' }], nextPageToken: null }) },
    };
    const summary = await runSignalIngestBatch([USER_ID, OTHER_USER], [gmailDescriptor()], NOW, deps);

    expect(summary.users).toBe(2);
    expect(summary.sourcesFailed).toBe(1);
    expect(summary.ingested).toBe(1);
    const rows = await signalRows();
    expect(rows).toHaveLength(1);
    expect(rows[0].user_id).toBe(OTHER_USER);
  });

  it('stores a bounded SUMMARY, never a full body, even if the descriptor hands one over', async () => {
    await runSignalIngestBatch([USER_ID], [gmailDescriptor()], NOW, providerDeps([
      { id: 'm1', sender: 'Ada', summary: 'x'.repeat(20_000) },
    ]));
    const rows = await signalRows();
    expect(rows[0].summary.length).toBe(SIGNAL_TEXT_LIMITS.summary);
  });

  it('preserves the provider instant for both fractional and non-fractional timestamps', async () => {
    await runSignalIngestBatch([USER_ID], [gmailDescriptor()], NOW, providerDeps([
      { id: 'plain', summary: 'a', timestamp: '2026-08-10T09:00:00Z' },
      { id: 'fractional', summary: 'b', timestamp: '2026-08-10T10:30:00.250Z' },
    ]));
    const rows = await signalRows();
    const byRef = Object.fromEntries(rows.map((r) => [r.source_ref, new Date(r.received_at).toISOString()]));
    expect(byRef['acct-1:plain']).toBe('2026-08-10T09:00:00.000Z');
    expect(byRef['acct-1:fractional']).toBe('2026-08-10T10:30:00.250Z');
  });
});

describe('selectSignalIngestUsers — against a real users table', () => {
  it('returns only users active inside the window, newest first', async () => {
    await h.db.query(`UPDATE users SET last_active_at = NOW() - INTERVAL '5 minutes' WHERE id = $1`, [USER_ID]);
    await h.db.query(`UPDATE users SET last_active_at = NOW() - INTERVAL '3 days' WHERE id = $1`, [OTHER_USER]);

    // Default 24h window: the 3-day-dormant user is not worth a provider round trip.
    expect(await selectSignalIngestUsers(h.db)).toEqual([USER_ID]);
    // Widen to 5 days and they come back, newest first.
    expect(await selectSignalIngestUsers(h.db, 5 * 24 * 60)).toEqual([USER_ID, OTHER_USER]);
  });

  it('the 7-day ceiling holds even when a caller asks for a wider window', async () => {
    await h.db.query(`UPDATE users SET last_active_at = NOW() - INTERVAL '5 minutes' WHERE id = $1`, [USER_ID]);
    await h.db.query(`UPDATE users SET last_active_at = NOW() - INTERVAL '30 days' WHERE id = $1`, [OTHER_USER]);

    expect(await selectSignalIngestUsers(h.db, 60 * 24 * 60)).toEqual([USER_ID]);
  });

  it('never polls a user who has never opened the app', async () => {
    expect(await selectSignalIngestUsers(h.db)).toEqual([]);
  });
});
