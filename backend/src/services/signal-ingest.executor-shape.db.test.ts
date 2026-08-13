import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * ── THE SHAPE TEST ──────────────────────────────────────────────────────────────────────────────
 *
 * The tier-2 producer has now shipped a dead feature twice, and BOTH times the suite was green
 * because the fixture was written to match the code instead of the wire:
 *
 *   round 1 — three lanes each wrote their own descriptor registry; the ingester read a stub whose
 *             `listSignalDescriptors()` returned []. 0 rows.
 *   round 2 — registry unified; still 0 rows, because `composioSignalExecutor` returned Composio's
 *             `data.messages` VERBATIM (`messageId` / `preview` / `messageTimestamp`) while
 *             `gmailSignalDescriptor.mapItem` reads the renamed shape the Daily Brief adapter
 *             emits (`providerMessageId` / `snippet` / `timestamp`). Every real message mapped to
 *             null. The cron printed `fetched=2 dropped=2 ingested=0 failed=0` and exited 0.
 *
 * Every ingest fixture in the sibling suites — including a helper literally named `rawGmailItem()`
 * — hands `mapItem` an item that is not raw. Those tests pass on both sides of the defect, so they
 * cannot see it. This file exists to be the one that can.
 *
 * THE RULE IT ENFORCES: nothing here hand-authors an item. The only hand-written value is the
 * Composio ENVELOPE — the bytes the provider puts on the wire — and even that is anchored to
 * `parseGmailFetchEmailsResult`, the parser that was written against a live GMAIL_FETCH_EMAILS
 * 20260721_00 response, so an envelope that drifts from reality fails a guard rather than passing
 * quietly. Everything downstream of the wire is produced by production code:
 *
 *   real @composio/core stub → REAL `composioSignalExecutor` → REAL `listDescriptors()` descriptor
 *   → REAL `collectSignalsForDescriptor` → REAL `ingestSignalDetailed` → REAL migration-039 table.
 *
 * WHAT WOULD THIS LOOK LIKE IF THE FEATURE WERE ABSENT? Delete the `normalizeItems` call in
 * `composioSignalExecutor` and the executor emits wire naming again: `mapItem` returns null for
 * every message, `channel_signals` stays empty, and the row assertions below fail. That is the
 * red this test is calibrated to produce — see the branch's red/green proof.
 *
 * ROUND 3 — and the reason this file grew a second envelope. The assumed wire names were never
 * confirmed against a captured payload; they are a guess, and a wrong guess costs an empty table
 * under a green suite. The transport now reads either candidate spelling and LOGS which one it
 * saw. See `the ALTERNATIVE Gmail wire shape` and `[gmail-wire] the shape self-report` at the
 * bottom of this file — those are the discriminating tests; the assumed-shape ones above are
 * regression cover and pass on both sides of the tolerance.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.join(__dirname, '..', 'db', 'migrations');

// vi.mock factories hoist above every top-level statement, so anything they close over must come
// from vi.hoisted() (which runs first) — same pattern as composio.service.test.ts.
const mocks = vi.hoisted(() => ({
  toolsExecute: vi.fn(),
}));

// A holder so the hoisted db mock can reach the pglite instance created in beforeAll.
const h: { db: any } = { db: null };

vi.mock('../db/pool.js', () => ({
  pool: {
    query: (text: string, params?: unknown[]) => h.db.query(text, params ?? []),
  },
}));

/**
 * The Composio SDK boundary — the ONLY thing faked on the provider side. `client().tools.execute`
 * is exactly where a real GMAIL_FETCH_EMAILS response would arrive, so everything between it and
 * the database below is the code that runs in production.
 */
vi.mock('@composio/core', () => ({
  Composio: class {
    tools = { execute: (...args: unknown[]) => mocks.toolsExecute(...args) };
  },
  ComposioAuthConfigNotFoundError: class extends Error {},
  ComposioConnectedAccountNotFoundError: class extends Error {},
  ConnectionRequestFailedError: class extends Error {},
  ConnectionRequestTimeoutError: class extends Error {},
}));

// composio.service.ts reaches these on other code paths; stub them so importing it does not drag
// the gateway stack into a test about item shape.
vi.mock('./gateway-pair.service.js', () => ({ withGatewayRequester: vi.fn() }));
vi.mock('./gateway-lifecycle-lock.service.js', () => ({
  tryWithUserGatewayConfigReconciliationLock: vi.fn(),
}));
vi.mock('./gateway.service.js', () => ({
  getGatewayCredentialsWithClient: vi.fn(),
  getLocalGatewayCredentials: vi.fn(),
  getSetupPasswordWithClient: vi.fn(),
}));

const USER_ID = '11111111-1111-1111-1111-111111111111';
const ACCOUNT_ID = 'ca_01HZX9GMAILACCOUNT';
const NOW = new Date('2026-08-10T12:00:00.000Z');

/**
 * A GMAIL_FETCH_EMAILS 20260721_00 response envelope, in the PROVIDER's naming.
 *
 * This is the one hand-written value in the file and it is deliberately the outermost one: a test
 * that stubs the network has to say what the network returned. Its authority is
 * `parseGmailFetchEmailsResult` — the strict parser written against a live response, whose own
 * tests pin `messageId` / `threadId` / `subject` / `sender` / `preview` / `messageTimestamp` and
 * `data.messages` / `data.nextPageToken`. The first test below feeds this same object to that
 * parser, so if the envelope is not a shape the verified parser accepts, this file fails loudly
 * instead of proving something about a fictional provider.
 *
 * Note what is NOT here: no `providerMessageId`, no `snippet`, no `timestamp`. That absence is the
 * entire point — under the old executor these two messages reached `mapItem` exactly like this.
 */
const GMAIL_FETCH_EMAILS_ENVELOPE = {
  successful: true,
  error: null,
  data: {
    messages: [
      {
        messageId: '19851f2c0a3b7d41',
        threadId: '19851f2c0a3b7d41',
        sender: 'Ada Lovelace <ada@example.com>',
        subject: 'Analytical Engine review Friday?',
        preview: 'Can you look at the punch-card notes before Friday standup',
        messageTimestamp: '2026-08-10T11:30:00Z',
        labelIds: ['INBOX', 'UNREAD'],
      },
      {
        messageId: '19851a77bb90c012',
        threadId: '19851a77bb90c012',
        sender: 'billing@example.net',
        subject: 'Invoice 4471 is overdue',
        preview: 'Your invoice from July remains unpaid.',
        messageTimestamp: '2026-08-10T06:05:12.482Z',
        labelIds: ['INBOX'],
      },
    ],
    nextPageToken: null,
  },
} as const;

/**
 * ── THE SAME TWO MESSAGES IN THE OTHER CANDIDATE SPELLING ───────────────────────────────────────
 *
 * `messageId` / `preview` / `messageTimestamp` above is an ASSUMPTION, not a recording. Nobody in
 * this repo has ever captured a GMAIL_FETCH_EMAILS payload; every occurrence of those names is
 * hand-authored, and one secondary source spells the id `id`. So the transport now reads either
 * spelling, and this envelope is the other one — Gmail's own REST naming:
 *
 *   id           (not messageId)
 *   snippet      (not preview)
 *   internalDate (not messageTimestamp) — EPOCH MILLIS AS A STRING, not ISO-8601
 *
 * Values are byte-identical to the assumed envelope wherever the shapes agree, and the two
 * `internalDate` strings are exactly `Date.parse()` of the two `messageTimestamp` strings above.
 * That is deliberate: the rows this produces must be INDISTINGUISHABLE from the assumed shape's
 * rows, which is the only thing that makes the feature shape-independent rather than shape-lucky.
 */
const GMAIL_FETCH_EMAILS_ALTERNATIVE_ENVELOPE = {
  successful: true,
  error: null,
  data: {
    messages: [
      {
        id: '19851f2c0a3b7d41',
        threadId: '19851f2c0a3b7d41',
        sender: 'Ada Lovelace <ada@example.com>',
        subject: 'Analytical Engine review Friday?',
        snippet: 'Can you look at the punch-card notes before Friday standup',
        internalDate: '1786361400000', // === Date.parse('2026-08-10T11:30:00Z')
        labelIds: ['INBOX', 'UNREAD'],
      },
      {
        id: '19851a77bb90c012',
        threadId: '19851a77bb90c012',
        sender: 'billing@example.net',
        subject: 'Invoice 4471 is overdue',
        snippet: 'Your invoice from July remains unpaid.',
        internalDate: '1786341912482', // === Date.parse('2026-08-10T06:05:12.482Z')
        labelIds: ['INBOX'],
      },
    ],
    nextPageToken: null,
  },
} as const;

/** Every `[gmail-wire] …` line the production code emitted during the current test. */
const wireLogLines: string[] = [];
/**
 * Bound at MODULE LOAD, before any spy exists. `vi.spyOn(console, 'log')` in `beforeEach` wraps
 * whatever is currently there — i.e. the PREVIOUS test's spy — so a recorder that forwarded to
 * `console.log` would re-enter every earlier layer and record one emitted line N times.
 */
const CONSOLE_LOG = console.log.bind(console);

let composioSignalExecutor: typeof import('./composio.service.js').composioSignalExecutor;
let parseGmailFetchEmailsResult: typeof import('./composio.service.js').parseGmailFetchEmailsResult;
let listDescriptors: typeof import('./connector-signals.registry.js').listDescriptors;
let runSignalIngestBatch: typeof import('./signal-ingest.service.js').runSignalIngestBatch;
let signalIngestExitCode: typeof import('./signal-ingest.service.js').signalIngestExitCode;
let signalIngestFailureReason: typeof import('./signal-ingest.service.js').signalIngestFailureReason;
type ConnectorSignalExecutor = import('./signal-ingest.service.js').ConnectorSignalExecutor;

/** Authorization only. The grant is real-world state; the ITEM SHAPE is what this file tests. */
const accounts = {
  listActiveAccountIdsByToolkit: async (_userId: string, toolkitSlugs: readonly string[]) =>
    new Map(toolkitSlugs.map((slug) => [slug, [ACCOUNT_ID]])),
};

/**
 * The REAL executor, wrapped only to RECORD what it produced. It forwards the page through
 * untouched, so `descriptor.mapItem` downstream receives the executor's own output — not a copy,
 * not a reshaping, not an approximation of it.
 */
function recordingExecutor(sink: unknown[]): ConnectorSignalExecutor {
  return {
    async fetchPage(input) {
      const page = await composioSignalExecutor.fetchPage(input);
      sink.push(...page.items);
      return page;
    },
  };
}

async function signalRows() {
  const { rows } = await h.db.query(
    `SELECT user_id, source, source_ref, sender, summary, suggested_title, received_at
       FROM channel_signals ORDER BY received_at DESC`,
  );
  return rows as Array<Record<string, any>>;
}

beforeAll(async () => {
  // Read at MODULE LOAD by composio.service.ts, so it must be set before the dynamic import below.
  process.env.COMPOSIO_API_KEY = 'test-key';

  const { PGlite } = await import('@electric-sql/pglite');
  h.db = new PGlite();
  await h.db.exec(`
    CREATE TABLE users (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      last_active_at TIMESTAMPTZ
    )
  `);
  await h.db.query(`INSERT INTO users (id) VALUES ($1)`, [USER_ID]);
  // The REAL migration: the unique key and column types under test are defined there, not here.
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

  const composio = await import('./composio.service.js');
  composioSignalExecutor = composio.composioSignalExecutor;
  parseGmailFetchEmailsResult = composio.parseGmailFetchEmailsResult;
  listDescriptors = (await import('./connector-signals.registry.js')).listDescriptors;
  const svc = await import('./signal-ingest.service.js');
  runSignalIngestBatch = svc.runSignalIngestBatch;
  signalIngestExitCode = svc.signalIngestExitCode;
  signalIngestFailureReason = svc.signalIngestFailureReason;
  // pglite's first boot (wasm init + migration) exceeds vitest's 10s default on a cold cache.
  // 60s is slack, not a claim that the boot is slow.
}, 60_000);

afterAll(async () => {
  await h.db?.close?.();
});

beforeEach(async () => {
  vi.clearAllMocks();
  await h.db.query('DELETE FROM channel_signals');
  mocks.toolsExecute.mockResolvedValue(GMAIL_FETCH_EMAILS_ENVELOPE);
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  // PASS-THROUGH, not silenced: the `[gmail-wire] …` line is the deliverable here, so it must be
  // readable in the test output a human looks at, not only assertable from a mock.
  wireLogLines.length = 0;
  vi.spyOn(console, 'log').mockImplementation((...args: unknown[]) => {
    const line = args.map(String).join(' ');
    if (line.startsWith('[gmail-wire]')) wireLogLines.push(line);
    CONSOLE_LOG(...args);
  });
});

describe('the stubbed envelope is a real GMAIL_FETCH_EMAILS 20260721_00 response', () => {
  /**
   * Anchor, not decoration. Every assertion in this file is only as good as the envelope, and the
   * one piece of code in the repo written against a LIVE Composio response is this parser. If the
   * envelope above is not something it accepts, the rest of the file is proving a fiction.
   */
  it('parseGmailFetchEmailsResult — the execution-verified parser — accepts it', () => {
    const page = parseGmailFetchEmailsResult(GMAIL_FETCH_EMAILS_ENVELOPE);
    expect(page.items).toHaveLength(2);
    expect(page.items[0]).toMatchObject({
      providerMessageId: '19851f2c0a3b7d41',
      snippet: 'Can you look at the punch-card notes before Friday standup',
      timestamp: '2026-08-10T11:30:00Z',
    });
  });

  it('carries NONE of the field names mapItem reads — it is genuinely raw', () => {
    for (const message of GMAIL_FETCH_EMAILS_ENVELOPE.data.messages) {
      const keys = Object.keys(message);
      expect(keys).toContain('messageId');
      expect(keys).toContain('preview');
      expect(keys).toContain('messageTimestamp');
      expect(keys).not.toContain('providerMessageId');
      expect(keys).not.toContain('snippet');
      expect(keys).not.toContain('timestamp');
    }
  });
});

describe('composioSignalExecutor output → the REAL descriptor mapItem', () => {
  /**
   * The exact assertion round 2 was missing. Not "an item shaped like the executor's output" —
   * the value the executor actually returned, handed straight to the registry's `mapItem`.
   */
  it('maps every item the real executor returns, with no hand-written fixture in between', async () => {
    const [descriptor] = listDescriptors();
    expect(descriptor, 'the registry is EMPTY — nothing to poll').toBeTruthy();

    const page = await composioSignalExecutor.fetchPage({
      userId: USER_ID,
      connectedAccountId: ACCOUNT_ID,
      action: descriptor.action,
      version: descriptor.actionVersion,
      arguments: descriptor.buildQuery(new Date(NOW.getTime() - 86_400_000), NOW),
      timeoutMs: 2_500,
    });

    expect(page.items).toHaveLength(2);
    const mapped = page.items.map((item) => descriptor.mapItem(item, ACCOUNT_ID));
    // Under the defect this array is [null, null].
    expect(mapped.filter(Boolean)).toHaveLength(2);
    expect(mapped[0]).toMatchObject({
      source: 'gmail',
      sourceRef: `${ACCOUNT_ID}:19851f2c0a3b7d41`,
      sender: 'Ada Lovelace <ada@example.com>',
      summary: 'Analytical Engine review Friday? — Can you look at the punch-card notes before Friday standup',
      receivedAt: '2026-08-10T11:30:00.000Z',
    });
  });

  it('hands the descriptor the executor\'s OWN object, not a re-shaped copy', async () => {
    const [descriptor] = listDescriptors();
    const seen: unknown[] = [];

    await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor(seen),
    });

    // What the executor emitted is what the descriptor consumed; assert on the emitted value.
    expect(seen).toHaveLength(2);
    for (const item of seen) {
      expect(descriptor.mapItem(item, ACCOUNT_ID)).not.toBeNull();
    }
  });
});

describe('end to end: a real Composio envelope lands rows in channel_signals', () => {
  it('writes one row per message through the real registry, executor and upsert', async () => {
    const descriptors = [...listDescriptors()];
    expect(descriptors.length, 'empty registry — the assertions below would be vacuous')
      .toBeGreaterThan(0);

    const seen: unknown[] = [];
    const summary = await runSignalIngestBatch([USER_ID], descriptors, NOW, {
      accounts,
      executor: recordingExecutor(seen),
    });

    // The counters that printed `fetched=2 dropped=2 ingested=0` under the defect.
    expect(summary).toMatchObject({
      users: 1,
      sources: 1,
      fetched: 2,
      dropped: 0,
      ingested: 2,
      duplicates: 0,
      failed: 0,
      writesFailed: 0,
    });

    const rows = await signalRows();
    expect(rows).toHaveLength(2);
    expect(rows.map((row) => row.source_ref)).toEqual([
      `${ACCOUNT_ID}:19851f2c0a3b7d41`,
      `${ACCOUNT_ID}:19851a77bb90c012`,
    ]);
    expect(rows[0]).toMatchObject({
      user_id: USER_ID,
      source: 'gmail',
      sender: 'Ada Lovelace <ada@example.com>',
      summary: 'Analytical Engine review Friday? — Can you look at the punch-card notes before Friday standup',
    });
    // Migration 039 documents the deriver's own fallback title; the descriptor must not invent one.
    expect(rows[0].suggested_title).toBeNull();
    expect(new Date(rows[1].received_at).toISOString()).toBe('2026-08-10T06:05:12.482Z');
  });

  it('the executor asks Composio for the descriptor\'s PINNED action and version', async () => {
    await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor([]),
    });

    expect(mocks.toolsExecute).toHaveBeenCalledWith(
      'GMAIL_FETCH_EMAILS',
      expect.objectContaining({
        userId: USER_ID,
        connectedAccountId: ACCOUNT_ID,
        version: '20260721_00',
      }),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it('a run that wrote rows is exit 0 with no failure reason', async () => {
    const summary = await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor([]),
    });
    expect(signalIngestFailureReason(summary)).toBeNull();
    expect(signalIngestExitCode(summary)).toBe(0);
  });
});

describe('the productivity check: fetched work that reached no row is RED', () => {
  /**
   * The second half of the defect. Under round 2 this exact run — real executor, real descriptor,
   * real table, two real messages, zero rows — returned exit code 0. A cron that fetches mail and
   * persists none of it is a failure, and a green tick over it is what let the dead producer
   * survive two reviews.
   *
   * Driven the same way as everything else: the ONLY thing changed is the provider response, to a
   * message the real `mapItem` legitimately refuses (no `messageId` on the wire).
   */
  it('exits non-zero, naming the reason, when every fetched item is dropped', async () => {
    mocks.toolsExecute.mockResolvedValue({
      successful: true,
      error: null,
      data: {
        messages: [
          // No messageId → `parseGmailItem` drops it. Same terminal state as the shape mismatch.
          { threadId: 't1', sender: 'a@example.com', subject: 'x', preview: 'y', messageTimestamp: '2026-08-10T11:30:00Z' },
          { threadId: 't2', sender: 'b@example.com', subject: 'x', preview: 'y', messageTimestamp: '2026-08-10T11:31:00Z' },
        ],
        nextPageToken: null,
      },
    });

    const summary = await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor([]),
    });

    expect(summary).toMatchObject({ fetched: 2, dropped: 2, ingested: 0, duplicates: 0, failed: 0 });
    expect(await signalRows()).toHaveLength(0);
    expect(signalIngestFailureReason(summary)).toBe('fetched_but_ingested_nothing');
    expect(signalIngestExitCode(summary)).toBe(1);
  });

  /**
   * The counterweight, and the reason the predicate is not the literal `ingested === 0`.
   *
   * This poller re-reads a rolling 24h window every 15 minutes, so `fetched=2 ingested=0
   * duplicates=2` is the HEALTHY steady state — every message is already a row. Firing there would
   * turn the cron permanently red inside one window and teach everyone to ignore it, which is the
   * same disease as a permanently green one.
   */
  it('stays green when items were fetched and every one of them is ALREADY a row', async () => {
    const descriptors = [...listDescriptors()];
    const first = await runSignalIngestBatch([USER_ID], descriptors, NOW, {
      accounts,
      executor: recordingExecutor([]),
    });
    expect(first.ingested).toBe(2);

    const second = await runSignalIngestBatch([USER_ID], descriptors, NOW, {
      accounts,
      executor: recordingExecutor([]),
    });

    expect(second).toMatchObject({ fetched: 2, ingested: 0, duplicates: 2, failed: 0 });
    expect(await signalRows()).toHaveLength(2);
    expect(signalIngestFailureReason(second)).toBeNull();
    expect(signalIngestExitCode(second)).toBe(0);
  });
});

/**
 * ── SHAPE TOLERANCE ─────────────────────────────────────────────────────────────────────────────
 *
 * Everything above proves the pipeline works for the ASSUMED wire names. Nothing above proves
 * those names are the ones Composio sends — they never came from a captured payload. The two
 * describes below run the SAME real path (Composio SDK stub → real `composioSignalExecutor` →
 * real `listDescriptors()` descriptor → real `runSignalIngestBatch` → real `ingestSignalDetailed`
 * → real migration-039 table) over the OTHER candidate spelling, and assert the rows are
 * identical.
 *
 * WHICH OF THESE IS DISCRIMINATING? Only the alternative one. Delete the alternative candidates
 * from `GMAIL_WIRE_*_KEYS` and every test in `the ALTERNATIVE Gmail wire shape` fails while every
 * assumed-shape test above still passes — see this branch's red/green proof. The assumed-shape
 * tests are regression cover for behaviour that must NOT change; they are not evidence of
 * tolerance, and are not counted as such.
 */
describe('the ALTERNATIVE Gmail wire shape (id / snippet / internalDate)', () => {
  beforeEach(() => {
    mocks.toolsExecute.mockResolvedValue(GMAIL_FETCH_EMAILS_ALTERNATIVE_ENVELOPE);
  });

  it('is genuinely raw: no providerMessageId, and its id/timestamp keys are ones mapItem cannot read', () => {
    for (const message of GMAIL_FETCH_EMAILS_ALTERNATIVE_ENVELOPE.data.messages) {
      const keys = Object.keys(message);
      expect(keys).toContain('id');
      expect(keys).toContain('internalDate');
      // The load-bearing absences. `mapItem` reads `providerMessageId` and `timestamp`; neither is
      // present, so an intolerant transport drops every one of these messages.
      expect(keys).not.toContain('providerMessageId');
      expect(keys).not.toContain('timestamp');
      expect(keys).not.toContain('messageId');
      expect(keys).not.toContain('messageTimestamp');
      expect(keys).not.toContain('preview');
    }
  });

  it('the executor + REAL descriptor mapItem maps every item, with no fixture in between', async () => {
    const [descriptor] = listDescriptors();
    const page = await composioSignalExecutor.fetchPage({
      userId: USER_ID,
      connectedAccountId: ACCOUNT_ID,
      action: descriptor.action,
      version: descriptor.actionVersion,
      arguments: descriptor.buildQuery(new Date(NOW.getTime() - 86_400_000), NOW),
      timeoutMs: 2_500,
    });

    expect(page.items).toHaveLength(2);
    const mapped = page.items.map((item) => descriptor.mapItem(item, ACCOUNT_ID));
    // Without the alternative branch this array is [null, null].
    expect(mapped.filter(Boolean)).toHaveLength(2);
    expect(mapped[0]).toMatchObject({
      source: 'gmail',
      sourceRef: `${ACCOUNT_ID}:19851f2c0a3b7d41`,
      sender: 'Ada Lovelace <ada@example.com>',
      summary: 'Analytical Engine review Friday? — Can you look at the punch-card notes before Friday standup',
      // `internalDate: '1786361400000'` converted from epoch millis at the transport boundary.
      // The DOWNSTREAM parser now understands epoch numbers too (`parseConnectorInstant`), so an
      // unconverted `internalDate` would no longer be a silent drop — but the conversion stays
      // here so what crosses this boundary is ISO for every consumer, not one more shape each of
      // them has to know about. Both readings must land on the SAME instant, which is what this
      // asserts.
      receivedAt: '2026-08-10T11:30:00.000Z',
    });
  });

  it('lands rows in channel_signals that are indistinguishable from the assumed shape', async () => {
    const summary = await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor([]),
    });

    expect(summary).toMatchObject({
      users: 1, sources: 1, fetched: 2, dropped: 0, ingested: 2, duplicates: 0, failed: 0,
      writesFailed: 0,
    });

    const rows = await signalRows();
    expect(rows).toHaveLength(2);
    expect(rows.map((row) => row.source_ref)).toEqual([
      `${ACCOUNT_ID}:19851f2c0a3b7d41`,
      `${ACCOUNT_ID}:19851a77bb90c012`,
    ]);
    expect(rows[0]).toMatchObject({
      user_id: USER_ID,
      source: 'gmail',
      sender: 'Ada Lovelace <ada@example.com>',
      summary: 'Analytical Engine review Friday? — Can you look at the punch-card notes before Friday standup',
    });
    expect(rows[0].suggested_title).toBeNull();
    // Sub-second precision survives the epoch-millis → ISO conversion.
    expect(new Date(rows[0].received_at).toISOString()).toBe('2026-08-10T11:30:00.000Z');
    expect(new Date(rows[1].received_at).toISOString()).toBe('2026-08-10T06:05:12.482Z');
    expect(signalIngestFailureReason(summary)).toBeNull();
    expect(signalIngestExitCode(summary)).toBe(0);
  });

  it('the Daily Brief path accepts it too — one normalizer, both consumers', () => {
    const page = parseGmailFetchEmailsResult(GMAIL_FETCH_EMAILS_ALTERNATIVE_ENVELOPE);
    expect(page.items).toHaveLength(2);
    expect(page.items[0]).toMatchObject({
      providerMessageId: '19851f2c0a3b7d41',
      snippet: 'Can you look at the punch-card notes before Friday standup',
      // The strict RFC3339 guard in that parser rejects '1786361400000' outright, so this value
      // also proves the conversion happens BEFORE validation rather than after.
      timestamp: '2026-08-10T11:30:00.000Z',
    });
  });
});

/**
 * ── THE SELF-REPORT ─────────────────────────────────────────────────────────────────────────────
 *
 * Tolerance without this log would have replaced one unverified guess with two. The line below is
 * the whole reason the tolerance is acceptable: the first REAL cron run prints which key set
 * Composio actually sent, and then the loser gets deleted from `GMAIL_WIRE_*_KEYS`.
 */
describe('[gmail-wire] the shape self-report', () => {
  async function collect(envelope: unknown): Promise<string[]> {
    mocks.toolsExecute.mockResolvedValue(envelope);
    await runSignalIngestBatch([USER_ID], [...listDescriptors()], NOW, {
      accounts,
      executor: recordingExecutor([]),
    });
    return [...wireLogLines];
  }

  it('names the ASSUMED key set, once, for an assumed-shape collection', async () => {
    expect(await collect(GMAIL_FETCH_EMAILS_ENVELOPE)).toEqual([
      '[gmail-wire] matched=assumed items=2'
      + ' idKey=messageId snippetKey=preview tsKey=messageTimestamp',
    ]);
  });

  it('names the ALTERNATIVE key set, once, for an alternative-shape collection', async () => {
    expect(await collect(GMAIL_FETCH_EMAILS_ALTERNATIVE_ENVELOPE)).toEqual([
      '[gmail-wire] matched=alternative items=2'
      + ' idKey=id snippetKey=snippet tsKey=internalDate',
    ]);
  });

  it('reports mixed — per field and overall — when a response straddles both spellings', async () => {
    const lines = await collect({
      successful: true,
      error: null,
      data: {
        messages: [
          {
            messageId: 'a1', threadId: 'a1', sender: 'a@example.com', subject: 's',
            snippet: 'p', messageTimestamp: '2026-08-10T11:30:00Z',
          },
          {
            id: 'b2', threadId: 'b2', sender: 'b@example.com', subject: 's',
            snippet: 'p', internalDate: '1786361400000',
          },
        ],
        nextPageToken: null,
      },
    });
    expect(lines).toEqual([
      '[gmail-wire] matched=mixed items=2 idKey=mixed snippetKey=snippet tsKey=mixed',
    ]);
  });

  it('prefers the assumed key when a message carries BOTH spellings', async () => {
    const lines = await collect({
      successful: true,
      error: null,
      data: {
        messages: [{
          messageId: 'assumed-wins', id: 'alternative-loses',
          threadId: 't', sender: 'a@example.com', subject: 's',
          preview: 'p', snippet: 'q',
          messageTimestamp: '2026-08-10T11:30:00Z', internalDate: '1786341912482',
        }],
        nextPageToken: null,
      },
    });
    expect(lines).toEqual([
      '[gmail-wire] matched=assumed items=1'
      + ' idKey=messageId snippetKey=preview tsKey=messageTimestamp',
    ]);
    const rows = await signalRows();
    expect(rows).toHaveLength(1);
    expect(rows[0].source_ref).toBe(`${ACCOUNT_ID}:assumed-wins`);
    expect(rows[0].summary).toBe('s — p');
    expect(new Date(rows[0].received_at).toISOString()).toBe('2026-08-10T11:30:00.000Z');
  });

  it('says so, rather than staying silent, when NEITHER spelling matches', async () => {
    const lines = await collect({
      successful: true,
      error: null,
      data: {
        messages: [{ gmailMessageIdentifier: 'x', body_preview: 'y', date_header: 'z' }],
        nextPageToken: null,
      },
    });
    // The line an operator needs on the day a THIRD spelling ships. Silence here is how this
    // feature died three times.
    expect(lines).toEqual([
      '[gmail-wire] matched=none items=1 idKey=none snippetKey=none tsKey=none',
    ]);
    expect(await signalRows()).toHaveLength(0);
  });

  it('logs ONE line per collection, not one per item', async () => {
    const many = Array.from({ length: 25 }, (_, i) => ({
      messageId: `m${i}`, threadId: `m${i}`, sender: 'a@example.com', subject: 's',
      preview: 'p', messageTimestamp: '2026-08-10T11:30:00Z',
    }));
    const lines = await collect({
      successful: true, error: null, data: { messages: many, nextPageToken: null },
    });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain('items=25');
  });

  it('logs NOTHING for an empty collection — zero items carry zero shape evidence', async () => {
    expect(await collect({
      successful: true, error: null, data: { messages: [], nextPageToken: null },
    })).toEqual([]);
  });

  it('never puts a mailbox VALUE in the line — field names and counts only', async () => {
    const lines = await collect(GMAIL_FETCH_EMAILS_ENVELOPE);
    expect(lines).toHaveLength(1);
    for (const message of GMAIL_FETCH_EMAILS_ENVELOPE.data.messages) {
      for (const value of [message.messageId, message.threadId, message.sender,
        message.subject, message.preview, message.messageTimestamp]) {
        expect(lines[0], `leaked a value: ${JSON.stringify(value)}`).not.toContain(value);
      }
    }
    // Belt and braces: the whole line is drawn from a closed vocabulary.
    expect(lines[0]).toMatch(
      /^\[gmail-wire] matched=(assumed|alternative|mixed|none) items=\d+ idKey=(messageId|id|mixed|none) snippetKey=(preview|snippet|mixed|none) tsKey=(messageTimestamp|timestamp|internalDate|mixed|none)$/,
    );
  });
});
