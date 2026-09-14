import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Real-SQL tests for the suggestions service (WS2, doc 38). Runs the ACTUAL migration 038 and
 * the derive/dismiss queries against an in-process pglite Postgres, so a missing column or a
 * broken ON CONFLICT would fail here rather than in prod.
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

let loadScheduleContext: typeof import('./signal-relevance.service.js').loadScheduleContext;
let deriveSuggestions: typeof import('./suggestions.service.js').deriveSuggestions;
let dismissSuggestion: typeof import('./suggestions.service.js').dismissSuggestion;
let ingestSignal: typeof import('./suggestions.service.js').ingestSignal;
let selectMentions: typeof import('./suggestions.service.js').selectMentions;
let signalClusterKey: typeof import('./suggestions.service.js').signalClusterKey;
let shortHash: typeof import('./suggestions.service.js').shortHash;

// A fixed "now" so overdue/lookahead windows are deterministic.
const NOW = new Date('2026-07-20T17:00:00.000Z');

beforeAll(async () => {
  const { PGlite } = await import('@electric-sql/pglite');
  h.db = new PGlite();

  await h.db.exec(`CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())`);
  await h.db.query(`INSERT INTO users (id) VALUES ($1), ($2)`, [USER_ID, OTHER_USER]);

  // Minimal tasks table — the columns deriveSuggestions reads, plus `duration_minutes` for
  // `loadScheduleContext` (whose SQL is exercised here for want of a pglite harness of its own:
  // its catch returns an empty schedule, so an unexecuted query would look like an empty calendar
  // forever).
  await h.db.exec(`
    CREATE TABLE tasks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL,
      title TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'task',
      status TEXT NOT NULL DEFAULT 'pending',
      run_status TEXT,
      start_date TIMESTAMPTZ,
      duration_minutes INTEGER
    )
  `);

  // The real dismissals migration (table + index) — multiple statements → exec().
  const sql = fs.readFileSync(
    path.join(migrationsDir, '038_create_suggestion_dismissals.sql'),
    'utf8',
  );
  await h.db.exec(sql);

  // The real channel_signals migration (tier-2 connected-source signals).
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '039_create_channel_signals.sql'), 'utf8'),
  );

  // The real relevance-verdict migration. Applied here — not stubbed — because the fail-open
  // predicate the deriver now depends on (`relevance_decision IS DISTINCT FROM 'drop'`) is only
  // meaningful against the actual column and its CHECK constraint.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '118_add_signal_relevance.sql'), 'utf8'),
  );

  // The judge's recommended START TIME. Real for the same reason: the deriver SELECTs
  // `relevance_start_at` and the shared upsert clears it on a content change, so a stub of the
  // wrong type would let both go untested.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '122_add_signal_suggested_time.sql'), 'utf8'),
  );

  // The aggregation dispositions. Applied here — not stubbed — because the deriver now excludes
  // 'mention'/'append'/'complete' too, and those values only exist after 123 widens the CHECK.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '123_add_signal_aggregation_dispositions.sql'), 'utf8'),
  );

  // Shared-runtime relevance attempt ownership. Applying the real migration also catches drift
  // between the upsert's reset columns and the production schema.
  await h.db.exec(
    fs.readFileSync(path.join(migrationsDir, '125_create_rem_agent_runs.sql'), 'utf8'),
  );

  loadScheduleContext = (await import('./signal-relevance.service.js')).loadScheduleContext;
  const svc = await import('./suggestions.service.js');
  deriveSuggestions = svc.deriveSuggestions;
  dismissSuggestion = svc.dismissSuggestion;
  ingestSignal = svc.ingestSignal;
  selectMentions = svc.selectMentions;
  signalClusterKey = svc.signalClusterKey;
  shortHash = svc.shortHash;
});

afterAll(async () => {
  await h.db?.close?.();
});

beforeEach(async () => {
  await h.db.query('DELETE FROM tasks');
  await h.db.query('DELETE FROM suggestion_dismissals');
  await h.db.query('DELETE FROM channel_signals');
});

async function insertTask(fields: Record<string, unknown>): Promise<string> {
  const cols = Object.keys(fields);
  const vals = Object.values(fields);
  const placeholders = cols.map((_, i) => `$${i + 1}`).join(', ');
  const { rows } = await h.db.query(
    `INSERT INTO tasks (${cols.join(', ')}) VALUES (${placeholders}) RETURNING id`,
    vals,
  );
  return rows[0].id;
}

/**
 * PURE-LOGIC tests for the clustering primitives. No DB — these pin the conservative heuristic that
 * decides which distinct-but-similar signals collapse into one card. The whole design bias is here:
 * a near-miss must FAIL CLOSED (stay a singleton), never merge two unrelated messages.
 */
describe('signalClusterKey (conservative correlation stem)', () => {
  it('MERGES the founder\'s CI emails: same sender + same subject, only a run number differing', () => {
    const a = signalClusterKey('notifications@github.com', '', '[Rem-Assistant/Rem] PR run failed: Build Apple (run 4021)');
    const b = signalClusterKey('notifications@github.com', '', '[Rem-Assistant/Rem] PR run failed: Build Apple (run 4022)');
    expect(a).toBe(b); // identical subject FORMAT, only the volatile run number differs → merge
    expect(a).not.toBe(''); // a confident stem, not the singleton escape hatch
  });

  it('ACCEPTED COST: two different subject FORMATS of the same alert stay separate (no over-merge)', () => {
    // Whole-line comparison is conservative: "#4023" and "(run 4021)" strip to different stems
    // ("…build apple" vs "…build apple run"). We accept this missed merge rather than truncate to a
    // shared prefix and risk merging genuinely different messages (see the over-merge guards below).
    const hashForm = signalClusterKey('notifications@github.com', '', '[Rem-Assistant/Rem] PR run failed: Build Apple #4023');
    const runForm = signalClusterKey('notifications@github.com', '', '[Rem-Assistant/Rem] PR run failed: Build Apple (run 4021)');
    expect(hashForm).not.toBe(runForm);
    expect(hashForm).not.toBe('');
    expect(runForm).not.toBe('');
  });

  it('MERGES the repeated Discover alerts, ignoring the amount', () => {
    const a = signalClusterKey('Discover <no-reply@discover.com>', '', 'A new transaction of $50.00 was charged to your account');
    const b = signalClusterKey('Discover <no-reply@discover.com>', '', 'A new transaction of $128.94 was charged to your account');
    expect(a).toBe(b);
    expect(a).not.toBe('');
  });

  it('does NOT merge across senders — two people saying the same thing stay separate', () => {
    const ada = signalClusterKey('Ada <ada@example.com>', '', 'Are you free to review the visa paperwork this week?');
    const bob = signalClusterKey('Bob <bob@example.com>', '', 'Are you free to review the visa paperwork this week?');
    expect(ada).not.toBe(bob);
  });

  it('does NOT merge genuinely different subjects from the same sender', () => {
    const s = 'Dana <dana@acme.com>';
    const a = signalClusterKey(s, '', 'Are you open to a chat about the Staff Engineer role?');
    const b = signalClusterKey(s, '', 'Following up on the signed offer letter and start date');
    expect(a).not.toBe(b);
  });

  it('treats display-name wobble as the same sender by keying on the address inside <…>', () => {
    const a = signalClusterKey('Deploybot <alerts@example-ci.test>', '', 'Deployment crashed for rem-canary again');
    const b = signalClusterKey('Deploy Bot <alerts@example-ci.test>', '', 'Deployment crashed for rem-canary again');
    expect(a).toBe(b);
  });

  it('is case-insensitive on both sender and subject', () => {
    const a = signalClusterKey('Ada <Ada@Example.com>', '', 'Weekly Metrics Report');
    const b = signalClusterKey('ada <ada@example.com>', '', 'weekly metrics report');
    expect(a).toBe(b);
  });

  it('strips Re:/Fwd: so a reply groups with the message it answers', () => {
    const root = signalClusterKey('Ada <ada@example.com>', '', 'Project kickoff planning notes');
    const reply = signalClusterKey('Ada <ada@example.com>', '', 'Re: Project kickoff planning notes');
    const fwd = signalClusterKey('Ada <ada@example.com>', '', 'Fwd: RE: Project kickoff planning notes');
    expect(reply).toBe(root);
    expect(fwd).toBe(root);
  });

  it('falls back to the summary when there is no title', () => {
    const fromSummary = signalClusterKey('Ada <ada@example.com>', '', 'The quarterly board deck is ready for your review');
    const fromTitle = signalClusterKey('Ada <ada@example.com>', 'The quarterly board deck is ready for your review', 'ignored body text');
    expect(fromSummary).toBe(fromTitle);
    expect(fromSummary).not.toBe('');
  });

  it('CONSERVATIVE GUARD: a too-short/generic stem returns "" so it can never merge', () => {
    // Below MIN_CLUSTER_STEM_LEN (12) after stripping → the singleton escape hatch.
    expect(signalClusterKey('Ada <ada@example.com>', '', 'Hi')).toBe('');
    expect(signalClusterKey('Ada <ada@example.com>', '', 'update')).toBe('');
    expect(signalClusterKey('Ada <ada@example.com>', '', 'ok thanks')).toBe('');
    expect(signalClusterKey('Ada <ada@example.com>', '', '#1234')).toBe(''); // pure volatile → empty
    expect(signalClusterKey('Ada <ada@example.com>', '', '')).toBe('');
  });

  it('CONSERVATIVE GUARD: a shared leading phrase does NOT collapse unrelated mail', () => {
    // The whole line decides, not a prefix — so two "FYI: …" notes stay distinct.
    const a = signalClusterKey('Ada <ada@example.com>', '', 'FYI: the staging deploy finished cleanly');
    const b = signalClusterKey('Ada <ada@example.com>', '', 'FYI: lunch is moved to the third floor');
    expect(a).not.toBe(b);
  });

  // ── OVER-MERGE GUARDS (the reviewer's HIGH finding) ───────────────────────────────────────────
  // These are the cases a prefix-before-separator rule got WRONG: distinct messages that merely
  // share a generic leading phrase must NOT collapse, because hiding a fraud/login alert behind
  // another card's "+N similar" is a real harm. Whole-line comparison keeps each pair distinct.
  it('OVER-MERGE GUARD: "Notification: fraud alert" is NOT merged with "Notification: statement ready"', () => {
    const s = 'Chase <no-reply@chase.com>';
    const fraud = signalClusterKey(s, '', 'Notification: A fraud alert was placed on your card');
    const statement = signalClusterKey(s, '', 'Notification: Your monthly statement is ready');
    expect(fraud).not.toBe(statement);
    expect(fraud).not.toBe(''); // both are confident stems — just DIFFERENT ones
    expect(statement).not.toBe('');
  });

  it('OVER-MERGE GUARD: a "Security alert:" sign-in does NOT swallow a "Security alert:" password change', () => {
    const s = 'Google <no-reply@accounts.google.com>';
    const signin = signalClusterKey(s, '', 'Security alert: New sign-in from Chrome on Mac');
    const passwordChanged = signalClusterKey(s, '', 'Security alert: Your password was changed');
    expect(signin).not.toBe(passwordChanged);
  });

  it('OVER-MERGE GUARD: distinct CI jobs sharing "PR run failed:" stay separate (Build Apple vs Deploy Backend)', () => {
    const s = 'GitHub <notifications@github.com>';
    const apple = signalClusterKey(s, '', '[Rem-Assistant/Rem] PR run failed: Build Apple');
    const backend = signalClusterKey(s, '', '[Rem-Assistant/Rem] PR run failed: Deploy Backend');
    expect(apple).not.toBe(backend);
  });

  it('caps the stem length so a giant subject cannot make an unbounded key', () => {
    const long = 'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar';
    const key = signalClusterKey('Ada <ada@example.com>', '', long);
    // key = "<sender>\u0000<stem>"; the stem portion is capped at 80.
    const stem = key.split('\u0000')[1];
    expect(stem.length).toBeLessThanOrEqual(80);
  });
});

describe('shortHash (stable cluster-key digest)', () => {
  it('is deterministic and 12 hex chars', () => {
    expect(shortHash('abc')).toBe(shortHash('abc'));
    expect(shortHash('abc')).toMatch(/^[0-9a-f]{12}$/);
  });
  it('separates different inputs', () => {
    expect(shortHash('cluster-a')).not.toBe(shortHash('cluster-b'));
  });
});

describe('tier-2 connected-source signals', () => {
  it('turns an ingested Gmail signal into an attributed reply suggestion, leading the list', async () => {
    // A tier-1 overdue task also exists, to prove the connected-source signal SORTS FIRST.
    await insertTask({ user_id: USER_ID, title: 'File visa paperwork', type: 'task', status: 'pending', start_date: new Date('2026-07-17T09:00:00.000Z').toISOString() });
    const id = await ingestSignal(USER_ID, {
      source: 'gmail',
      sourceRef: 'msg-abc',
      sender: 'Ada',
      summary: 'Ada asked if you are free Friday',
      receivedAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1000).toISOString(), // 2h ago
    });

    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    expect(out[0].key).toBe(`gmail:${id}`); // leads
    expect(out[0].source).toBe('gmail');
    expect(out[0].title).toBe('Reply to Ada'); // signal → nameable-outcome task, not the raw event
    expect(out[0].subtitle).toContain('Ada asked if you are free Friday');
    expect(out[0].subtitle).toContain('Gmail');
    expect(out[0].subtitle).toContain('2h ago');
    expect(out[0].action.kind).toBe('createTask');
  });

  /**
   * THE FOUNDER'S DEFECT, at the layer that decides what reaches the phone.
   *
   * "Reply to Deploybot <alerts@example-ci.test>" for a deployment-crash alert. Nobody replies to a
   * robot. These tests pin the two halves of the fix in real SQL: a 'drop' verdict suppresses the
   * row, and an 'act' verdict titles it with the outcome the judge named.
   */
  describe('relevance verdicts decide what becomes a suggestion', () => {
    async function judge(id: string, decision: string, title: string | null) {
      await h.db.query(
        `UPDATE channel_signals SET relevance_decision = $2, relevance_title = $3,
                relevance_policy = 'test' WHERE id = $1`,
        [id, decision, title],
      );
    }

    it("suppresses a 'drop' — the CI alert never becomes 'Reply to Deploybot'", async () => {
      const id = await ingestSignal(USER_ID, {
        source: 'gmail',
        sourceRef: 'deploybot-1',
        sender: 'Deploybot <alerts@example-ci.test>',
        summary: 'Deployment crashed for rem-canary in RemClaw!',
      });
      expect((await deriveSuggestions(USER_ID, NOW, 'UTC'))[0].title)
        .toBe('Reply to Deploybot <alerts@example-ci.test>'); // the defect, before judgment

      await judge(id, 'drop', null);
      expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail'))
        .toEqual([]);
    });

    it("titles an 'act' with the outcome the judge named, over the template", async () => {
      const id = await ingestSignal(USER_ID, {
        source: 'gmail',
        sourceRef: 'rec-1',
        sender: 'Dana at Acme',
        summary: 'Staff Engineer role — are you open to a chat?',
      });
      await judge(id, 'act', 'Reply to the recruiter about the Staff role');
      const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
      expect(out[0].title).toBe('Reply to the recruiter about the Staff role');
    });

    it.each(['mention', 'append', 'complete'])(
      "a '%s' row is NOT a suggestion (aggregation dispositions never surface as cards)",
      async (decision) => {
        const id = await ingestSignal(USER_ID, {
          source: 'gmail', sourceRef: `agg-${decision}`, sender: 'Ada', summary: 'Some update',
        });
        await judge(id, decision, decision === 'mention' ? 'A note' : 'The item');
        expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail'))
          .toEqual([]);
      },
    );

    it('selectMentions returns the prose-routed signals, newest first, and nothing else', async () => {
      const drop = await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'sm-drop', sender: 'Bot', summary: 'noise',
      });
      const mention = await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'sm-mention', sender: 'Apple', summary: 'New device signed in',
      });
      const act = await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'sm-act', sender: 'Dana', summary: 'chat?',
      });
      await judge(drop, 'drop', null);
      await judge(mention, 'mention', 'A new trusted device signed in to your account');
      await judge(act, 'act', 'Reply to Dana');

      const mentions = await selectMentions(USER_ID, 5, h.db as never);
      expect(mentions.map((m) => m.id)).toEqual([mention]);
      expect(mentions[0].note).toBe('A new trusted device signed in to your account');
    });

    /**
     * FAIL-OPEN. The single most important behaviour in this feature: losing a real signal is worse
     * than showing a mediocre one. An unjudged row — the gateway was asleep, the batch came back
     * unparseable, the policy was bumped, the row is brand new — must reach the user anyway.
     *
     * This is why the predicate is `IS DISTINCT FROM 'drop'` and not `= 'act'`. Written the other
     * way, one bad classifier day silently empties the user's suggestions and looks like a quiet
     * inbox.
     */
    it('surfaces an UNJUDGED row, because NULL is not a decision to hide it', async () => {
      await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'unjudged-1', sender: 'Ada', summary: 'Are you free Friday?',
      });
      const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
      expect(out.filter((s) => s.source === 'gmail')).toHaveLength(1);
      // Still the template — that is the honest cost of surfacing something nobody judged.
      expect(out[0].title).toBe('Reply to Ada');
    });

    /**
     * A verdict is about SPECIFIC TEXT. A re-delivery that CHANGES the text must not inherit it,
     * or an edited message keeps a 'drop' decided on its earlier content and is invisible forever.
     * Unchanged content keeps its verdict — that is what makes the 15-minute re-poll cost nothing.
     */
    it('clears the verdict when re-delivery changes the content, and keeps it when it does not', async () => {
      const id = await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'edit-1', sender: 'Ada', summary: 'lunch?',
      });
      await judge(id, 'drop', null);

      await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'edit-1', sender: 'Ada', summary: 'lunch?',
      });
      const same = await h.db.query('SELECT relevance_decision FROM channel_signals WHERE id = $1', [id]);
      expect(same.rows[0].relevance_decision).toBe('drop');
      expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail'))
        .toEqual([]);

      await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'edit-1', sender: 'Ada',
        summary: 'lunch? actually — the visa appointment moved to Tuesday',
      });
      const changed = await h.db.query(
        'SELECT relevance_decision, relevance_policy FROM channel_signals WHERE id = $1', [id],
      );
      expect(changed.rows[0].relevance_decision).toBeNull();
      expect(changed.rows[0].relevance_policy).toBeNull();
      // Cleared → unjudged → SURFACES again, rather than staying hidden on a stale judgment.
      expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail'))
        .toHaveLength(1);
    });
  });

  /**
   * TIMEBLOCKING — "creation on task IS timeblocking, and AI setting the right time for a created
   * task is timeblocking" (the founder). A task's `start_date` IS the block; there is no separate
   * entity. So the whole feature, on this side, is: the judge's recommended time becomes the
   * `startDate` the accepting client already applies, and the card says so.
   *
   * These run against real SQL because the value crosses a `TIMESTAMPTZ` round trip — the failure
   * this catches is a driver handing back a `Date` where the reader expected a string, which no
   * amount of pure unit testing would see.
   */
  describe('the judge recommends a TIME, and accepting lands on it', () => {
    async function judgeWithTime(id: string, title: string, startAt: string | null) {
      await h.db.query(
        `UPDATE channel_signals SET relevance_decision = 'act', relevance_title = $2,
                relevance_policy = 'test', relevance_start_at = $3::timestamptz WHERE id = $1`,
        [id, title, startAt],
      );
    }

    async function gmailSignal(sourceRef: string): Promise<string> {
      return ingestSignal(USER_ID, {
        source: 'gmail',
        sourceRef,
        sender: 'Ada',
        summary: 'Can we talk through the visa timeline?',
        receivedAt: new Date(NOW.getTime() - 60 * 60 * 1000).toISOString(),
      });
    }

    /** NOW is 2026-07-20T17:00Z — a Monday. 2026-07-21T16:00Z is Tuesday 4:00 PM UTC. */
    const RECOMMENDED = '2026-07-21T16:00:00.000Z';

    it('puts the recommended instant on the action, so ONE TAP creates a scheduled task', async () => {
      const id = await gmailSignal('tb-1');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      const [out] = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
      expect(out.action.kind).toBe('createTask');
      expect(out.action.startDate).toBe(RECOMMENDED);
    });

    it('shows the time on the card, first, where a two-line clamp cannot hide it', async () => {
      const id = await gmailSignal('tb-2');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      const [out] = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
      expect(out.subtitle.startsWith('Tomorrow 4:00 PM · ')).toBe(true);
      // The attribution the card already showed is still there — this is a prefix, not a rewrite.
      expect(out.subtitle).toContain('Gmail');
      expect(out.subtitle).toContain('1h ago');
    });

    it('renders the label in the USER\'S zone, not the server\'s', async () => {
      const id = await gmailSignal('tb-3');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      // 16:00Z is 4:00 PM in UTC and 9:00 AM in Los Angeles — same instant, different card.
      const [utc] = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
      const [la] = (await deriveSuggestions(USER_ID, NOW, 'America/Los_Angeles'))
        .filter((s) => s.source === 'gmail');
      expect(utc.subtitle).toContain('Tomorrow 4:00 PM');
      expect(la.subtitle).toContain('Tomorrow 9:00 AM');
      expect(la.action.startDate).toBe(utc.action.startDate); // the INSTANT does not move
    });

    /**
     * THE DEGRADATION, end to end. A row with no recommendation behaves EXACTLY as it did before
     * this feature: `laterToday`, and no time on the card. This is the assertion that makes the
     * whole thing safe to ship — the failure mode is "unchanged", not "wrong".
     */
    it('falls back to later-today, with no label, when the judge named no time', async () => {
      const id = await gmailSignal('tb-4');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', null);

      const [out] = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
      expect(out.action.startDate).toBe(new Date(NOW.getTime() + 60 * 60 * 1000).toISOString());
      expect(out.subtitle.startsWith('Can we talk through')).toBe(true);
      expect(out.subtitle).not.toContain('PM ·');
    });

    /**
     * THE STALENESS CASE, and the reason the reader re-checks rather than trusting the column.
     * The verdict was written at ingest; the user may open the app days later. "Today at 4pm",
     * read tomorrow, would create a task that is already overdue — the exact defect `laterToday`
     * was written to avoid.
     */
    it('ignores a recommendation whose time has passed, rather than creating an overdue task', async () => {
      const id = await gmailSignal('tb-5');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      const twoDaysLater = new Date(NOW.getTime() + 2 * 24 * 60 * 60 * 1000);
      const [out] = (await deriveSuggestions(USER_ID, twoDaysLater, 'UTC'))
        .filter((s) => s.source === 'gmail');
      expect(new Date(out.action.startDate!).getTime()).toBeGreaterThan(twoDaysLater.getTime());
      expect(out.action.startDate).not.toBe(RECOMMENDED);
      expect(out.subtitle).not.toContain('4:00 PM');
    });

    it('ignores a stored time outside waking hours — one tap must never file work at 3am', async () => {
      const id = await gmailSignal('tb-6');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', '2026-07-21T03:00:00.000Z');

      const [out] = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
      expect(out.action.startDate).toBe(new Date(NOW.getTime() + 60 * 60 * 1000).toISOString());
    });

    /**
     * `loadScheduleContext`'s SQL, executed. Its catch returns `[]`, so a query that does not
     * compile degrades to "this person's calendar is empty" — which for most users is
     * indistinguishable from the truth and would let the judge double-book forever with every
     * other test still green. This is the only place the statement actually runs.
     */
    describe('loadScheduleContext runs real SQL', () => {
      it('returns what is booked in the horizon, soonest first, with kind and duration', async () => {
        await insertTask({
          user_id: USER_ID, title: 'Standup', type: 'calendar_event', status: 'pending',
          start_date: new Date(NOW.getTime() + 20 * 60 * 60 * 1000).toISOString(),
          duration_minutes: 30,
        });
        await insertTask({
          user_id: USER_ID, title: 'Draft the visa letter', type: 'task', status: 'in_progress',
          start_date: new Date(NOW.getTime() + 3 * 60 * 60 * 1000).toISOString(),
        });

        const schedule = await loadScheduleContext(USER_ID, NOW, h.db);
        expect(schedule.map((item) => item.title))
          .toEqual(['Draft the visa letter', 'Standup']); // soonest first
        expect(schedule[0]).toMatchObject({ isEvent: false, durationMinutes: null });
        expect(schedule[1]).toMatchObject({ isEvent: true, durationMinutes: 30 });
      });

      it('excludes the past, the far future, other users, and the done', async () => {
        const mine = { user_id: USER_ID, type: 'task', status: 'pending' };
        await insertTask({ ...mine, title: 'Yesterday', start_date: new Date(NOW.getTime() - 86_400_000).toISOString() });
        await insertTask({ ...mine, title: 'Past the horizon', start_date: new Date(NOW.getTime() + 20 * 86_400_000).toISOString() });
        await insertTask({ ...mine, title: 'Undated', start_date: null });
        await insertTask({ user_id: USER_ID, title: 'Finished', type: 'task', status: 'completed', start_date: new Date(NOW.getTime() + 3_600_000).toISOString() });
        await insertTask({ user_id: OTHER_USER, title: 'Not mine', type: 'task', status: 'pending', start_date: new Date(NOW.getTime() + 3_600_000).toISOString() });
        await insertTask({ ...mine, title: 'Keeper', start_date: new Date(NOW.getTime() + 3_600_000).toISOString() });

        expect((await loadScheduleContext(USER_ID, NOW, h.db)).map((i) => i.title))
          .toEqual(['Keeper']);
      });
    });

    /** A time is part of the judgment and decays with it (the migration-118 rule, extended). */
    it('clears the recommended time when re-delivery changes the content', async () => {
      const id = await gmailSignal('tb-7');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: 'tb-7', sender: 'Ada',
        summary: 'actually — can we move the visa call to Friday?',
      });
      const { rows } = await h.db.query(
        'SELECT relevance_start_at FROM channel_signals WHERE id = $1', [id],
      );
      expect(rows[0].relevance_start_at).toBeNull();
    });

    it('keeps the recommended time when re-delivery changes nothing', async () => {
      const id = await gmailSignal('tb-8');
      await judgeWithTime(id, 'Talk through the visa timeline with Ada', RECOMMENDED);

      await gmailSignal('tb-8');
      const { rows } = await h.db.query(
        'SELECT relevance_start_at FROM channel_signals WHERE id = $1', [id],
      );
      expect(new Date(rows[0].relevance_start_at).toISOString()).toBe(RECOMMENDED);
    });
  });

  it('prefers a precomputed suggestedTitle over the "Reply to <sender>" fallback', async () => {
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'm1', sender: 'Ada', summary: 'Invoice overdue', suggestedTitle: 'Pay the Q3 invoice' });
    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    expect(out[0].title).toBe('Pay the Q3 invoice');
  });

  it('ingest is idempotent on (source, sourceRef): re-delivery updates, does not duplicate', async () => {
    const id1 = await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'dupe', sender: 'Ada', summary: 'first' });
    const id2 = await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'dupe', sender: 'Ada', summary: 'second (edited)' });
    expect(id2).toBe(id1);
    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    const gmail = out.filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(1);
    expect(gmail[0].subtitle).toContain('second (edited)');
  });

  it('a dismissed signal never re-derives (durable), keyed <source>:<id>', async () => {
    const id = await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'm1', sender: 'Ada', summary: 'hi' });
    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === `gmail:${id}`)).toBe(true);
    await dismissSuggestion(USER_ID, `gmail:${id}`);
    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === `gmail:${id}`)).toBe(false);
  });

  it('does not leak another user\'s signals', async () => {
    await ingestSignal(OTHER_USER, { source: 'gmail', sourceRef: 'm1', sender: 'Bob', summary: 'secret' });
    expect(await deriveSuggestions(USER_ID, NOW, 'UTC')).toHaveLength(0);
  });
});

/**
 * HEURISTIC CORRELATION ("M") — the founder's real defect: 10+ distinct-but-near-identical CI
 * emails, each its own row with a unique source_ref, each becoming its own card. These aren't
 * duplicate rows (ingest already folds those) — they're distinct real messages that should COLLAPSE
 * into one card with a "+N similar" count. Derive-time grouping only; the rows are untouched.
 */
describe('tier-2 heuristic correlation (clustering)', () => {
  const CI_SENDER = 'GitHub <notifications@github.com>';
  // Distinct subjects that differ ONLY in the volatile run number — the exact founder case.
  const ciSummary = (run: number) => `[Rem-Assistant/Rem] PR run failed: Build Apple (run ${run})`;

  it('(a) collapses N same-sender/same-stem signals into ONE card with "+N-1 similar"', async () => {
    // 10 distinct emails, newest last-ingested. received_at descending so the FIRST (newest) is the
    // representative; its summary is what the card shows.
    for (let i = 0; i < 10; i++) {
      await ingestSignal(USER_ID, {
        source: 'gmail',
        sourceRef: `ci-${i}`,
        sender: CI_SENDER,
        summary: ciSummary(4020 + i),
        receivedAt: new Date(NOW.getTime() - i * 60 * 1000).toISOString(), // i=0 newest
      });
    }

    const gmail = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(1); // ten rows → one card
    expect(gmail[0].subtitle).toContain('+9 similar');
    expect(gmail[0].subtitle).toContain(ciSummary(4020)); // representative = newest (i=0)

    // Stable, group-level dismissal key: `${source}:cluster:${shortHash(clusterKey)}`.
    const stemKey = signalClusterKey(CI_SENDER, '', ciSummary(4020));
    expect(gmail[0].key).toBe(`gmail:cluster:${shortHash(stemKey)}`);
    // actionId is the standard UUID shape, derived from the cluster key.
    expect(gmail[0].actionId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it('(a\') dismissing the CLUSTER key drops the whole group, not just one row', async () => {
    for (let i = 0; i < 4; i++) {
      await ingestSignal(USER_ID, {
        source: 'gmail', sourceRef: `ci2-${i}`, sender: CI_SENDER, summary: ciSummary(5000 + i),
        receivedAt: new Date(NOW.getTime() - i * 60 * 1000).toISOString(),
      });
    }
    const before = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(before).toHaveLength(1);
    const clusterKey = before[0].key;
    expect(clusterKey).toContain(':cluster:');

    await dismissSuggestion(USER_ID, clusterKey);
    const after = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(after).toEqual([]); // all four members gone, as a unit
  });

  it('(a\'\') a dismissed group that shrinks to ONE surviving member stays suppressed (no leak)', async () => {
    // Two members form a cluster; dismiss it; then all but one member disappears (aged out of the
    // fetch window / deleted). The lone survivor still carries the confident stem, so it must remain
    // suppressed for the TTL rather than popping back as a fresh `${source}:${id}` singleton.
    const keepId = await ingestSignal(USER_ID, {
      source: 'gmail', sourceRef: 'shrink-keep', sender: CI_SENDER, summary: ciSummary(6000),
      receivedAt: new Date(NOW.getTime() - 60 * 1000).toISOString(),
    });
    const dropId = await ingestSignal(USER_ID, {
      source: 'gmail', sourceRef: 'shrink-drop', sender: CI_SENDER, summary: ciSummary(6001),
      receivedAt: new Date(NOW.getTime() - 120 * 1000).toISOString(),
    });

    const before = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(before).toHaveLength(1);
    expect(before[0].key).toContain(':cluster:');
    await dismissSuggestion(USER_ID, before[0].key);

    // The other member goes away → only `keepId` remains → count === 1 with a confident stem.
    await h.db.query('DELETE FROM channel_signals WHERE id = $1', [dropId]);
    const after = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(after).toEqual([]); // still suppressed — NOT resurfaced as gmail:${keepId}
    expect(keepId).not.toBe(dropId); // sanity: two distinct rows existed
  });

  it('(b) does NOT over-merge: genuinely different subjects/senders stay separate cards', async () => {
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'd1', sender: 'Ada <ada@x.com>', summary: 'Are you free to review the visa paperwork this week?', receivedAt: new Date(NOW.getTime() - 1_000).toISOString() });
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'd2', sender: 'Bob <bob@y.com>', summary: 'Lunch on Thursday at the new ramen place?', receivedAt: new Date(NOW.getTime() - 2_000).toISOString() });
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'd3', sender: 'Dana <dana@z.com>', summary: 'Following up on the signed offer letter and start date', receivedAt: new Date(NOW.getTime() - 3_000).toISOString() });

    const gmail = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(3);
    // Each is a singleton — today's `${source}:${id}` key, no cluster key, no "+N similar".
    for (const s of gmail) {
      expect(s.key.startsWith('gmail:')).toBe(true);
      expect(s.key).not.toContain(':cluster:');
      expect(s.subtitle).not.toContain('similar');
    }
  });

  it('(c) a singleton is byte-for-byte unchanged: `${source}:${id}` key, no count suffix', async () => {
    const id = await ingestSignal(USER_ID, {
      source: 'gmail', sourceRef: 'solo', sender: CI_SENDER, summary: ciSummary(9001),
      receivedAt: new Date(NOW.getTime() - 60 * 1000).toISOString(),
    });
    const gmail = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(1);
    expect(gmail[0].key).toBe(`gmail:${id}`); // NOT a cluster key — one member is not a cluster
    expect(gmail[0].subtitle).not.toContain('similar');
    expect(gmail[0].subtitle).toContain(ciSummary(9001));
  });

  it('(d) conservative guard: generic short stems each stay their OWN singleton, never merged', async () => {
    // Same sender, sub-threshold stems ("hi", "ok", "yo thanks") → each is its own card.
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'g1', sender: 'Ada <ada@x.com>', summary: 'Hi', receivedAt: new Date(NOW.getTime() - 1_000).toISOString() });
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'g2', sender: 'Ada <ada@x.com>', summary: 'ok', receivedAt: new Date(NOW.getTime() - 2_000).toISOString() });
    await ingestSignal(USER_ID, { source: 'gmail', sourceRef: 'g3', sender: 'Ada <ada@x.com>', summary: 'yo thanks', receivedAt: new Date(NOW.getTime() - 3_000).toISOString() });

    const gmail = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(3); // NOT collapsed — too generic to merge safely
    for (const s of gmail) expect(s.key).not.toContain(':cluster:');
  });

  it('(e) caps tier-2 at MAX_SUGGESTIONS clusters even when many distinct clusters exist', async () => {
    // Seven distinct clusters (distinct sender + subject). The cap counts CLUSTERS, so → 5 cards.
    for (let i = 0; i < 7; i++) {
      await ingestSignal(USER_ID, {
        source: 'gmail',
        sourceRef: `cap-${i}`,
        sender: `Sender${i} <s${i}@example.com>`,
        summary: `Distinct subject number ${['one', 'two', 'three', 'four', 'five', 'six', 'seven'][i]} about project alpha`,
        receivedAt: new Date(NOW.getTime() - i * 60 * 1000).toISOString(),
      });
    }
    const gmail = (await deriveSuggestions(USER_ID, NOW, 'UTC')).filter((s) => s.source === 'gmail');
    expect(gmail).toHaveLength(5);
  });
});

describe('deriveSuggestions', () => {
  it('turns an overdue task into a reschedule suggestion, attributed', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'File visa paperwork',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-17T09:00:00.000Z').toISOString(), // 3 days before NOW
    });

    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    const s = out.find((x) => x.key === `overdue:${id}`);
    expect(s).toBeDefined();
    expect(s!.source).toBe('overdue');
    expect(s!.action.kind).toBe('rescheduleTask');
    expect(s!.action.targetTaskId).toBe(id);
    // "overdue 3d" — assert the actual computed count, not just a substring of the title.
    expect(s!.subtitle).toContain('File visa paperwork');
    expect(s!.subtitle).toContain('overdue 3d');
    // Reschedules to a FUTURE time today — never back into the past, or it's instantly
    // overdue again (the overdue signal is `start_date < now`).
    const rescheduledTo = new Date(s!.action.startDate!).getTime();
    expect(rescheduledTo).toBeGreaterThan(NOW.getTime());
    // …but still today (not spilled into tomorrow).
    expect(rescheduledTo).toBeLessThan(new Date('2026-07-21T00:00:00.000Z').getTime());
  });

  it('suppresses today actions when no future instant remains in the local day', async () => {
    await insertTask({
      user_id: USER_ID,
      title: 'Last-minute overdue task',
      type: 'task',
      status: 'pending',
      start_date: '2026-07-20T20:00:00.000Z',
    });

    const finalMinute = new Date('2026-07-20T23:59:30.000Z');
    expect(await deriveSuggestions(USER_ID, finalMinute, 'UTC')).toEqual([]);
  });

  it('keeps the backend action identity stable when a later refresh moves the proposed schedule', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'File visa paperwork',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-17T09:00:00.000Z').toISOString(),
    });
    const first = (await deriveSuggestions(USER_ID, NOW, 'UTC')).find((x) => x.key === `overdue:${id}`)!;
    const later = (await deriveSuggestions(
      USER_ID,
      new Date(NOW.getTime() + 10 * 60_000),
      'UTC',
    )).find((x) => x.key === `overdue:${id}`)!;

    expect(first.action.startDate).not.toBe(later.action.startDate);
    expect(first.actionId).toBe(later.actionId);
    expect(first.actionId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  // #1094: a task due EARLIER TODAY (past its time) is an intraday overdue — it must read a
  // plain "overdue", never "overdue 1d". NOW is 2026-07-20T17:00Z; due 2026-07-20T11:44Z is
  // the same UTC day, ~5h earlier.
  it('labels a task due earlier the SAME day as plain "overdue", not "overdue 1d"', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'Same-day task',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-20T11:44:00.000Z').toISOString(),
    });

    const s = (await deriveSuggestions(USER_ID, NOW, 'UTC')).find((x) => x.key === `overdue:${id}`);
    expect(s).toBeDefined();
    expect(s!.subtitle).toContain('overdue');
    expect(s!.subtitle).not.toContain('1d');
    expect(s!.subtitle).not.toContain('overdue 0d');
    expect(s!.subtitle).toBe("'Same-day task' · overdue");
  });

  // A task due LATER today is not past its time → not overdue at all (no suggestion).
  it('does not surface a task due later today as overdue', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'Later today',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-20T22:00:00.000Z').toISOString(), // 5h AFTER NOW
    });

    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    expect(out.some((x) => x.key === `overdue:${id}`)).toBe(false);
  });

  // Exactly one calendar day ago (yesterday) → "overdue 1d", even though only ~17h elapsed.
  it('labels a task due yesterday as "overdue 1d" (floors by calendar day, not 24h)', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'Yesterday task',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-19T23:30:00.000Z').toISOString(), // 17.5h before NOW, prev day
    });

    const s = (await deriveSuggestions(USER_ID, NOW, 'UTC')).find((x) => x.key === `overdue:${id}`);
    expect(s).toBeDefined();
    expect(s!.subtitle).toBe("'Yesterday task' · overdue 1d");
  });

  // Two calendar days ago → "overdue 2d" even though <48h of wall-clock has elapsed.
  it('labels a task due two local days ago as "overdue 2d"', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'Two days',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-18T23:00:00.000Z').toISOString(), // ~42h before NOW, 2 days back
    });

    const s = (await deriveSuggestions(USER_ID, NOW, 'UTC')).find((x) => x.key === `overdue:${id}`);
    expect(s).toBeDefined();
    expect(s!.subtitle).toBe("'Two days' · overdue 2d");
  });

  // Timezone boundary: due 2026-07-20T05:00Z is "yesterday" (Jul 19) in a UTC-8 zone but the SAME
  // day (Jul 20) in UTC. With now=17:00Z, the UTC-8 local day is Jul 20 09:00 → same local day as
  // the due date's local day (Jul 19 21:00)… so it's the PREVIOUS local day → "overdue 1d".
  it('counts overdue days by the user LOCAL calendar day across a TZ boundary', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'TZ task',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-20T05:00:00.000Z').toISOString(),
    });

    // In America/Los_Angeles (UTC-7 in July): due = Jul 19 22:00 local; now = Jul 20 10:00 local
    // → one local day earlier → "overdue 1d".
    const local = (await deriveSuggestions(USER_ID, NOW, 'America/Los_Angeles')).find(
      (x) => x.key === `overdue:${id}`,
    );
    expect(local).toBeDefined();
    expect(local!.subtitle).toBe("'TZ task' · overdue 1d");

    // In UTC the same instant is Jul 20 05:00 — same day as now (Jul 20) → intraday "overdue".
    const utc = (await deriveSuggestions(USER_ID, NOW, 'UTC')).find((x) => x.key === `overdue:${id}`);
    expect(utc).toBeDefined();
    expect(utc!.subtitle).toBe("'TZ task' · overdue");
  });

  it('turns an upcoming calendar event into a prep suggestion that CREATES a task', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'Standup',
      type: 'calendar_event',
      status: 'pending',
      start_date: new Date('2026-07-21T09:00:00.000Z').toISOString(), // ~16h ahead
    });

    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    const s = out.find((x) => x.key === `cal:${id}`);
    expect(s).toBeDefined();
    expect(s!.source).toBe('calendar');
    expect(s!.title).toBe('Prep for Standup');
    expect(s!.action.kind).toBe('createTask');
    expect(s!.action.taskTitle).toBe('Prep for Standup');
    expect(s!.subtitle).toContain('Calendar');
  });

  it('does NOT re-suggest an event that already has a "Prep for X" task (server-side dedup)', async () => {
    const eventId = await insertTask({ user_id: USER_ID, title: 'Standup', type: 'calendar_event', status: 'pending', start_date: new Date('2026-07-21T09:00:00Z').toISOString() });
    // Before the prep task exists → suggested.
    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === `cal:${eventId}`)).toBe(true);
    // Once a matching prep task exists (even without any dismissal) → gone. This is the durable
    // dedup that survives a dropped client dismiss.
    await insertTask({ user_id: USER_ID, title: 'Prep for Standup', type: 'task', status: 'pending', start_date: new Date('2026-07-21T20:00:00Z').toISOString() });
    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === `cal:${eventId}`)).toBe(false);
  });

  it('does NOT suggest an empty-title task/event', async () => {
    await insertTask({ user_id: USER_ID, title: '   ', type: 'task', status: 'pending', start_date: new Date('2026-07-17T00:00:00Z').toISOString() });
    await insertTask({ user_id: USER_ID, title: '', type: 'calendar_event', status: 'pending', start_date: new Date('2026-07-21T09:00:00Z').toISOString() });
    expect(await deriveSuggestions(USER_ID, NOW, 'UTC')).toHaveLength(0);
  });

  it('does NOT suggest blocked, unscheduled, other-user, or far-future items', async () => {
    await insertTask({ user_id: USER_ID, title: 'Blocked', type: 'task', status: 'pending', run_status: 'blocked', start_date: new Date('2026-07-10T00:00:00Z').toISOString() });
    await insertTask({ user_id: USER_ID, title: 'Inbox', type: 'task', status: 'pending', start_date: null });
    await insertTask({ user_id: USER_ID, title: 'Done', type: 'task', status: 'completed', start_date: new Date('2026-07-10T00:00:00Z').toISOString() });
    await insertTask({ user_id: OTHER_USER, title: 'NotMine', type: 'task', status: 'pending', start_date: new Date('2026-07-10T00:00:00Z').toISOString() });
    await insertTask({ user_id: USER_ID, title: 'FarEvent', type: 'calendar_event', status: 'pending', start_date: new Date('2026-07-25T09:00:00Z').toISOString() }); // >36h out

    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    expect(out).toHaveLength(0);
  });

  it('caps at 5 suggestions', async () => {
    for (let i = 0; i < 8; i++) {
      await insertTask({ user_id: USER_ID, title: `Overdue ${i}`, type: 'task', status: 'pending', start_date: new Date(`2026-07-1${i}T00:00:00Z`).toISOString() });
    }
    const out = await deriveSuggestions(USER_ID, NOW, 'UTC');
    expect(out.length).toBeLessThanOrEqual(5);
  });
});

describe('dismissSuggestion', () => {
  it('durably hides a suggestion and is idempotent', async () => {
    const id = await insertTask({
      user_id: USER_ID,
      title: 'File visa paperwork',
      type: 'task',
      status: 'pending',
      start_date: new Date('2026-07-17T09:00:00.000Z').toISOString(),
    });
    const key = `overdue:${id}`;

    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === key)).toBe(true);

    await dismissSuggestion(USER_ID, key);
    expect((await deriveSuggestions(USER_ID, NOW, 'UTC')).some((s) => s.key === key)).toBe(false);

    // Idempotent — re-dismissing the same key must not throw (ON CONFLICT DO NOTHING).
    await expect(dismissSuggestion(USER_ID, key)).resolves.toBeUndefined();
    const { rows } = await h.db.query(
      'SELECT COUNT(*)::int AS n FROM suggestion_dismissals WHERE user_id = $1 AND suggestion_key = $2',
      [USER_ID, key],
    );
    expect(rows[0].n).toBe(1);
  });

  it("does not leak one user's dismissal to another", async () => {
    const id = await insertTask({ user_id: USER_ID, title: 'Shared-shape', type: 'task', status: 'pending', start_date: new Date('2026-07-17T00:00:00Z').toISOString() });
    const otherId = await insertTask({ user_id: OTHER_USER, title: 'Shared-shape', type: 'task', status: 'pending', start_date: new Date('2026-07-17T00:00:00Z').toISOString() });
    await dismissSuggestion(USER_ID, `overdue:${id}`);
    // OTHER_USER's own suggestion is unaffected.
    expect((await deriveSuggestions(OTHER_USER, NOW, 'UTC')).some((s) => s.key === `overdue:${otherId}`)).toBe(true);
  });
});
