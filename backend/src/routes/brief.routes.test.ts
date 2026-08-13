import express from 'express';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const atomicClientMock = vi.hoisted(() => ({ query: vi.fn(), release: vi.fn() }));
const poolMock = vi.hoisted(() => ({ query: vi.fn(), connect: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

const briefRoutes = (await import('./brief.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', briefRoutes);
  return app;
}

// Legacy reads resolve the user's timezone FIRST (users.timezone, then most-recent check-in fallback)
// live buckets are scoped to the user's LOCAL day, then gatherBrief issues up to four queries
// in order: active tasks, today's events, completed today, then (only when there are surfaced
// items) latest-activity comments. `tz` defaults to a row-less result → UTC fallback, which
// keeps the UTC day-window the fixed-clock assertions below were written against.
function mockQueries(
  active: any[],
  events: any[],
  completed: any[],
  activity: any[] = [],
  tz: any[] = [],
) {
  const queue = poolMock.query.mockResolvedValueOnce({ rows: tz }); // users.timezone
  if (tz.length === 0) queue.mockResolvedValueOnce({ rows: [] }); // check-in fallback
  queue
    .mockResolvedValueOnce({ rows: active })
    .mockResolvedValueOnce({ rows: events })
    .mockResolvedValueOnce({ rows: completed })
    .mockResolvedValueOnce({ rows: activity });
}

// Fixed clock so overdue/today bucketing is deterministic regardless of when tests run.
const NOW = new Date('2026-06-30T15:00:00.000Z');
const todayStart = '2026-06-30T00:00:00.000Z';
const yesterday = '2026-06-29T09:00:00.000Z';
const laterToday = '2026-06-30T18:00:00.000Z';

beforeEach(() => {
  vi.clearAllMocks();
  poolMock.connect.mockResolvedValue(atomicClientMock);
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
});

afterEach(() => {
  // Restore real timers so the fake clock never leaks into other test files.
  vi.useRealTimers();
});

describe('GET /api/v1/brief', () => {
  it('returns one revision-bound atomic suggestion contract only when negotiated', async () => {
    poolMock.query.mockResolvedValue({ rows: [] });
    atomicClientMock.query.mockResolvedValue({ rows: [] });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Suggestion-Contract', 'atomic-v1');

    expect(res.status).toBe(200);
    expect(res.body.brief_revision).toMatch(/^deterministic:[0-9a-f]{64}$/);
    expect(res.body.suggestion_snapshot_id).toMatch(/^[0-9a-f]{64}$/);
    expect(res.body.suggestions).toEqual([]);
    expect(atomicClientMock.query.mock.calls[0][0]).toBe(
      'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY',
    );
    expect(atomicClientMock.query.mock.calls[1][0]).toContain('SELECT timezone FROM users');
    expect(poolMock.query).not.toHaveBeenCalled();
    expect(atomicClientMock.query.mock.calls.at(-1)?.[0]).toBe('COMMIT');
    expect(atomicClientMock.release).toHaveBeenCalledOnce();
  });

  it('returns revision-bound connected-source suggestions without fabricating brief prose', async () => {
    atomicClientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('FROM channel_signals')) {
        return { rows: [{
          id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          source: 'gmail',
          sender: 'Ada',
          summary: 'Ada asked for a reply',
          suggested_title: null,
          received_at: '2026-06-30T14:00:00.000Z',
        }] };
      }
      return { rows: [] };
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Suggestion-Contract', 'atomic-v1');

    expect(res.status).toBe(200);
    expect(res.body.markdown).toBe('');
    expect(res.body.summary).toBe('Rem noticed a few suggested next steps.');
    expect(res.body.suggestions.map((item: any) => item.key)).toEqual([
      'gmail:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    ]);
    expect(res.body.brief_revision).toMatch(/^deterministic:/);
    expect(res.body.suggestion_snapshot_id).toMatch(/^[0-9a-f]{64}$/);
  });

  it('routes timezone, brief, and suggestion reads through the checked-out atomic client', async () => {
    const task = {
      id: '11111111-1111-4111-8111-111111111111',
      title: 'Captured overdue task',
      status: 'pending',
      priority: 'medium',
      run_status: null,
      start_date: yesterday,
      type: 'task',
    };
    atomicClientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes("AND type = 'task'")
          && sql.includes("status IN ('pending', 'in_progress')")
          && sql.includes('LIMIT 200')) {
        return { rows: [task] };
      }
      if (sql.includes('FROM tasks') && sql.includes("status IN ('pending', 'in_progress')")) {
        return { rows: [task] };
      }
      return { rows: [] };
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Suggestion-Contract', 'atomic-v1');

    expect(res.status).toBe(200);
    expect(res.body.overdue.map((item: any) => item.id)).toEqual([task.id]);
    expect(res.body.suggestions.map((item: any) => item.key)).toEqual([`overdue:${task.id}`]);
    const stateReads = atomicClientMock.query.mock.calls
      .map((call) => call[0] as string)
      .filter((sql) => sql.includes('FROM tasks'));
    expect(stateReads.length).toBeGreaterThan(1);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('buckets blocked / overdue / scheduled_today and computes counts', async () => {
    mockQueries(
      [
        { id: 'b1', title: 'Blocked task', status: 'in_progress', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
        { id: 'o1', title: 'Overdue task', status: 'pending', priority: 'medium', run_status: null, start_date: yesterday, type: 'task' },
        { id: 't1', title: 'Today task', status: 'pending', priority: 'low', run_status: null, start_date: laterToday, type: 'task' },
        { id: 'u1', title: 'Unscheduled inbox', status: 'pending', priority: 'low', run_status: null, start_date: null, type: 'task' },
      ],
      [
        { id: 'e1', title: 'Standup', status: null, priority: null, run_status: null, start_date: laterToday, type: 'calendar_event' },
      ],
      [
        { id: 'd1', title: 'Done task', status: 'completed', priority: 'medium', run_status: 'done', start_date: todayStart, type: 'task' },
      ],
    );

    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.blocked.map((i: any) => i.id)).toEqual(['b1']);
    expect(res.body.overdue.map((i: any) => i.id)).toEqual(['o1']);
    // task today + event today, unscheduled excluded
    expect(res.body.scheduled_today.map((i: any) => i.id).sort()).toEqual(['e1', 't1']);
    expect(res.body.completed_today.map((i: any) => i.id)).toEqual(['d1']);
    expect(res.body.counts).toMatchObject({
      blocked: 1,
      overdue: 1,
      scheduled_today: 2,
      completed_today: 1,
      total: 3, // scheduled_today (2) + completed_today (1)
      done: 1,
    });
    // every item is tagged with its bucket
    expect(res.body.blocked[0].bucket).toBe('blocked');
    // #916: prose brief is composed from the same buckets — headings + item titles.
    expect(res.body.markdown).toContain('## Needs a decision');
    expect(res.body.markdown).toContain('Blocked task');
    expect(res.body.markdown).toContain('## Overdue');
    expect(res.body.summary).toContain('need attention');
    expect(res.body.summary).toContain('1 of 3 done');
  });

  it('folds the latest blocked activity into the prose "needs a decision" bullet', async () => {
    mockQueries(
      [
        { id: 'b1', title: 'Book the flight', status: 'in_progress', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
      ],
      [],
      [],
      [
        { task_id: 'b1', author_kind: 'cloud_agent', author_label: 'Rem', body: 'Tried to book\nbut need your card', created_at: '2026-06-30T14:00:00.000Z' },
      ],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.markdown).toContain('**Book the flight** — Tried to book');
  });

  it('sanitizes free-text titles so a multi-line / heading-shaped title cannot break or inject into the prose', async () => {
    // Real tasks.title is user/AI free text — a title with a newline + a markdown heading
    // would otherwise split the bullet and inject a `## ` heading the client would render.
    mockQueries(
      [
        { id: 'o1', title: 'Deploy backend\n## Injected heading', status: 'pending', priority: 'high', run_status: null, start_date: yesterday, type: 'task' },
      ],
      [],
      [],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    // Collapsed to one line inside a single bullet — heading folded into the text, not a heading.
    expect(res.body.markdown).toContain('- **Deploy backend ## Injected heading**');
    // The only real headings in the doc are the ones we emit (## Overdue here) — no injected one.
    const injectedAsHeading = res.body.markdown
      .split('\n')
      .some((l: string) => l.trimStart().startsWith('## Injected heading'));
    expect(injectedAsHeading).toBe(false);
  });

  it('counts a task due earlier today but past its time as overdue, not scheduled_today', async () => {
    // Regression for the founder's "2 overdue but there are 3": at 15:00 a task due
    // 09:00 *today* is past its time. Start-of-today bucketing sent it to
    // scheduled_today and undercounted overdue; it must bucket as overdue (start < now),
    // matching the Agenda. `laterToday` (18:00) is still upcoming → scheduled_today.
    const earlierToday = '2026-06-30T09:00:00.000Z';
    mockQueries(
      [
        { id: 'o1', title: 'Overdue yesterday', status: 'pending', priority: 'medium', run_status: null, start_date: yesterday, type: 'task' },
        { id: 'o2', title: 'Overdue earlier today', status: 'pending', priority: 'high', run_status: null, start_date: earlierToday, type: 'task' },
        { id: 'o3', title: 'In-progress earlier today', status: 'in_progress', priority: 'low', run_status: null, start_date: earlierToday, type: 'task' },
        { id: 't1', title: 'Later today', status: 'pending', priority: 'low', run_status: null, start_date: laterToday, type: 'task' },
      ],
      [],
      [],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.overdue.map((i: any) => i.id).sort()).toEqual(['o1', 'o2', 'o3']);
    expect(res.body.scheduled_today.map((i: any) => i.id)).toEqual(['t1']);
    expect(res.body.counts).toMatchObject({ overdue: 3, scheduled_today: 1 });
  });

  it('a blocked task that is also past due is counted only as blocked', async () => {
    mockQueries(
      [
        { id: 'b1', title: 'Blocked + overdue', status: 'pending', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
      ],
      [],
      [],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.counts.blocked).toBe(1);
    expect(res.body.counts.overdue).toBe(0);
  });

  it('attaches the latest non-user comment as each item latest_activity', async () => {
    mockQueries(
      [
        { id: 'b1', title: 'Blocked task', status: 'in_progress', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
        { id: 'o1', title: 'Overdue task', status: 'pending', priority: 'medium', run_status: null, start_date: yesterday, type: 'task' },
      ],
      [],
      [],
      [
        { task_id: 'b1', author_kind: 'cloud_agent', author_label: 'Rem', body: 'Tried to book the flight\nbut need your card', created_at: '2026-06-30T14:00:00.000Z' },
      ],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.blocked[0].latest_activity).toMatchObject({
      author_label: 'Rem',
      author_kind: 'cloud_agent',
      summary: 'Tried to book the flight', // first non-empty line only
    });
    // No comment for the overdue item → null, not undefined.
    expect(res.body.overdue[0].latest_activity).toBeNull();
  });

  it('excludes a completed+blocked task from the blocked bucket (mutual exclusivity)', async () => {
    mockQueries(
      [
        { id: 'x1', title: 'Done but flagged', status: 'completed', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
      ],
      [],
      [
        { id: 'x1', title: 'Done but flagged', status: 'completed', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' },
      ],
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.counts.blocked).toBe(0);
    expect(res.body.completed_today.map((i: any) => i.id)).toEqual(['x1']);
  });

  it('returns empty buckets when there is nothing to report', async () => {
    mockQueries([], [], []);
    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');
    expect(res.status).toBe(200);
    expect(res.body.counts).toMatchObject({ blocked: 0, overdue: 0, scheduled_today: 0, completed_today: 0, total: 0, done: 0 });
    expect(res.body.blocked).toEqual([]);
    // #916: an all-clear day still returns prose (card + full brief share the same line).
    expect(res.body.markdown).toContain("You're all clear");
    expect(res.body.summary).toContain("You're all clear");
    // No transcript is authoritative until today's exact artifact is delivered.
    expect(res.body.brief_session_key).toBeUndefined();
  });

  it('does not advertise a per-day route to old clients until it is populated', async () => {
    mockQueries([], [], []);
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.brief_session_key).toBeUndefined();
  });

  it('overrides markdown + summary and exposes brief_session_key when authoring is enabled', async () => {
    // Flag ON → after gatherBrief's queries, the route reads today's cached authored card
    // and replaces `markdown` (the card) + `summary` (the chat's latest-message summary),
    // and exposes the brief chat session key. Counts/buckets stay live/deterministic.
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      // Reset the once-queue so a prior test's unconsumed mock can't shift our queries.
      poolMock.query.mockReset();
      // resolveUserTimezone (UTC) runs FIRST, then gatherBrief's 4 queries, then readAuthoredBrief.
      mockQueries(
        [{ id: 'b1', title: 'Blocked task', status: 'in_progress', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' }],
        [],
        [],
        [],
        [{ timezone: 'UTC' }],
      );
      poolMock.query.mockResolvedValueOnce({ rows: [{ markdown: '# Morning\nRem wrote this.', summary: 'Rem wrote this.', delivered: true, source: 'gateway' }] });

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');
      expect(res.status).toBe(200);
      expect(res.body.markdown).toBe('# Morning\nRem wrote this.'); // authored card, not the template
      expect(res.body.summary).toBe('Rem wrote this.'); // latest-message summary, not the counts line
      // brief_session_key is now the persistent CONVERSATION session the user replies into.
      expect(res.body.brief_session_key).toBe('rem-orchestrator');
      expect(res.body.counts.blocked).toBe(1); // counts stay live
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('serves the artifact HEADLINE so the card and the chat title show one string', async () => {
    // #headline: the Agenda card used to synthesize "Good morning" from the clock while the
    // orchestrator chat showed the brief's own "The Day". The route now hands both surfaces the
    // artifact's stored headline.
    poolMock.query.mockReset();
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ timezone: 'UTC' }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });
    poolMock.query.mockResolvedValueOnce({
      rows: [{
        markdown: '## The Day\n\nFour items need you today.',
        summary: 'Four items need you today.',
        headline: 'The Day',
        delivered: true,
        source: 'gateway',
        revision: '11111111-1111-4111-8111-111111111111',
        authored_slot: 'morning',
      }],
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.headline).toBe('The Day');
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
  });

  it('omits a headline for a delivered artifact that has none, leaving client fallbacks intact', async () => {
    poolMock.query.mockReset();
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ timezone: 'UTC' }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });
    poolMock.query.mockResolvedValueOnce({
      rows: [{
        markdown: 'Four items need you today.',
        summary: 'Four items need you today.',
        headline: null,
        delivered: true,
        source: 'gateway',
        revision: '11111111-1111-4111-8111-111111111111',
        authored_slot: 'morning',
      }],
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.headline ?? null).toBeNull();
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
  });

  it('derives the summary from delivered markdown instead of leaking the all-clear fallback', async () => {
    poolMock.query.mockReset();
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ timezone: 'UTC' }] })
      .mockResolvedValueOnce({ rows: [] }) // active tasks
      .mockResolvedValueOnce({ rows: [] }) // events
      .mockResolvedValueOnce({ rows: [] }); // completed tasks
    poolMock.query.mockResolvedValueOnce({
      rows: [{
        markdown: '# Morning\nA connector follow-up needs your review.',
        summary: null,
        delivered: true,
        source: 'gateway',
        revision: '11111111-1111-4111-8111-111111111111',
        authored_slot: 'morning',
      }],
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.counts.total).toBe(0);
    expect(res.body.markdown).toBe('# Morning\nA connector follow-up needs your review.');
    expect(res.body.summary).toBe('A connector follow-up needs your review.');
    expect(res.body.summary).not.toContain("You're all clear");
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
  });

  it('clears the deterministic summary when delivered markdown has no derivable lead', async () => {
    poolMock.query.mockReset();
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ timezone: 'UTC' }] })
      .mockResolvedValueOnce({ rows: [] }) // active tasks
      .mockResolvedValueOnce({ rows: [] }) // events
      .mockResolvedValueOnce({ rows: [] }); // completed tasks
    poolMock.query.mockResolvedValueOnce({
      rows: [{
        markdown: '# Morning\n- Connector follow-up',
        summary: null,
        delivered: true,
        source: 'gateway',
        revision: '11111111-1111-4111-8111-111111111111',
        authored_slot: 'morning',
      }],
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.markdown).toBe('# Morning\n- Connector follow-up');
    expect(res.body.summary).toBe('');
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
  });

  it('keeps an already-delivered brief readable when future authoring is disabled', async () => {
    delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    poolMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('FROM daily_briefs b')) {
        return { rows: [{
          markdown: '# Morning\nPersisted canonical prose.',
          summary: 'Persisted canonical prose.',
          delivered: true,
          source: 'gateway',
          revision: '11111111-1111-4111-8111-111111111111',
          authored_slot: 'morning',
        }] };
      }
      return { rows: [] };
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.markdown).toBe('# Morning\nPersisted canonical prose.');
    expect(res.body.summary).toBe('Persisted canonical prose.');
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
  });

  it('keeps deterministic prose unauthorized when authoring is off and nothing was delivered', async () => {
    delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    poolMock.query.mockResolvedValue({ rows: [] });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

    expect(res.status).toBe(200);
    expect(res.body.markdown).toContain("You're all clear");
    expect(res.body.brief_session_key).toBeUndefined();
    expect(poolMock.query.mock.calls.some(([sql]) =>
      String(sql).includes('FROM daily_briefs b'))).toBe(true);
  });

  it('uses a delivered revision for the atomic snapshot when future authoring is disabled', async () => {
    delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    const revision = '22222222-2222-4222-8222-222222222222';
    atomicClientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('FROM daily_briefs b')) {
        return { rows: [{
          markdown: '# Morning\nAtomic canonical prose.',
          summary: 'Atomic canonical prose.',
          delivered: true,
          source: 'gateway',
          revision,
          authored_slot: 'morning',
        }] };
      }
      return { rows: [] };
    });

    const res = await request(testApp())
      .get('/api/v1/brief')
      .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1')
      .set('X-Rem-Suggestion-Contract', 'atomic-v1');

    expect(res.status).toBe(200);
    expect(res.body.markdown).toBe('# Morning\nAtomic canonical prose.');
    expect(res.body.brief_session_key).toBe('rem-orchestrator');
    expect(res.body.brief_revision).toBe(revision);
    expect(res.body.suggestion_snapshot_id).toMatch(/^[0-9a-f]{64}$/);
  });

  it('advertises the delivered per-day transcript to legacy clients during rollout', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      mockQueries(
        [{ id: 'b1', title: 'Blocked task', status: 'pending', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' }],
        [],
        [],
        [],
        [{ timezone: 'UTC' }],
      );
      poolMock.query.mockResolvedValueOnce({
        rows: [{ markdown: 'Legacy-visible prose.', summary: 'Legacy-visible prose.', delivered: true, source: 'gateway' }],
      });

      const res = await request(testApp()).get('/api/v1/brief');

      expect(res.status).toBe(200);
      expect(res.body.brief_session_key).toBe('rem-today-20260630');
      const deliveryQuery = poolMock.query.mock.calls.at(-1);
      expect(deliveryQuery?.[1]?.[2]).toBe('rem-today-20260630');
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('keeps the deterministic prose when authoring is enabled but no row is cached yet', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      mockQueries(
        [{ id: 'b1', title: 'Blocked task', status: 'in_progress', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' }],
        [],
        [],
        [],
        [{ timezone: 'UTC' }], // resolveUserTimezone
      );
      poolMock.query.mockResolvedValueOnce({ rows: [] }); // no authored row

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');
      expect(res.status).toBe(200);
      expect(res.body.markdown).toContain('## Needs a decision'); // deterministic fallback
      expect(res.body.summary).toContain('need'); // deterministic summary
      expect(res.body.brief_session_key).toBeUndefined();
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('withholds pending authored prose because only verified delivery is canonical', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      mockQueries(
        [{ id: 'b1', title: 'Blocked task', status: 'pending', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' }],
        [],
        [],
        [],
        [{ timezone: 'UTC' }],
      );
      // The canonical read joins only state=delivered, so a pending row is absent.
      poolMock.query.mockResolvedValueOnce({ rows: [] });

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

      expect(res.status).toBe(200);
      expect(res.body.markdown).toContain('## Needs a decision');
      expect(res.body.brief_session_key).toBeUndefined();
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('does not let a same-slot all-clear artifact overwrite newly non-empty live truth', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      mockQueries(
        [{ id: 'b1', title: 'New blocked task', status: 'pending', priority: 'high', run_status: 'blocked', start_date: yesterday, type: 'task' }],
        [],
        [],
        [],
        [{ timezone: 'UTC' }],
      );
      // The service query excludes source=fallback, so a database containing only that legacy
      // row returns no canonical artifact to the route.
      poolMock.query.mockResolvedValueOnce({ rows: [] });

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

      expect(res.status).toBe(200);
      expect(res.body.markdown).toContain('## Needs a decision');
      expect(res.body.summary).toContain('need');
      expect(res.body.brief_session_key).toBeUndefined();
      expect(poolMock.query.mock.calls.at(-1)?.[0]).toContain("a.source = 'gateway'");
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('keeps counts live while delivered canonical gateway prose remains authoritative on an empty task snapshot', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      poolMock.query
        .mockResolvedValueOnce({ rows: [{ timezone: 'UTC' }] })
        .mockResolvedValueOnce({ rows: [] }) // active tasks
        .mockResolvedValueOnce({ rows: [] }) // events
        .mockResolvedValueOnce({ rows: [] }); // completed tasks
      poolMock.query.mockResolvedValueOnce({
        rows: [{
          markdown: 'One task still needs you.',
          summary: 'One task still needs you.',
          delivered: true,
          source: 'gateway',
        }],
      });

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

      expect(res.status).toBe(200);
      expect(res.body.counts).toMatchObject({
        blocked: 0,
        overdue: 0,
        scheduled_today: 0,
        completed_today: 0,
      });
      expect(res.body.markdown).toBe('One task still needs you.');
      expect(res.body.summary).toBe('One task still needs you.');
      expect(res.body.brief_session_key).toBe('rem-orchestrator');
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('excludes legacy fallback artifacts from prose authority', async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    try {
      poolMock.query.mockReset();
      mockQueries([], [], [], [], [{ timezone: 'UTC' }]);
      poolMock.query.mockResolvedValueOnce({ rows: [] });

      const res = await request(testApp())
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1');

      expect(res.status).toBe(200);
      expect(res.body.markdown).toContain("You're all clear");
      expect(res.body.brief_session_key).toBeUndefined();
      const artifactRead = poolMock.query.mock.calls.at(-1)?.[0] as string;
      expect(artifactRead).toContain("a.source = 'gateway'");
      expect(artifactRead).toContain("b.source = 'gateway'");
      expect(artifactRead).toContain("d.state = 'delivered'");
    } finally {
      delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    }
  });

  it('scopes the day-window buckets to the user LOCAL timezone (bug 1: date + buckets agree)', async () => {
    // NOW = 15:00Z = 08:00 PT, so the user's LOCAL day is Jun 30 → window [Jun30 07:00Z, Jul1 07:00Z).
    // A calendar event at 2026-07-01T02:00Z is Jun 30 19:00 PT — TODAY locally, but TOMORROW in
    // UTC. With the tz threaded through gatherBrief it must land in scheduled_today; a UTC window
    // would have excluded it (the card would be dated "the 30th" but its agenda would miss it).
    const tonightLocalTomorrowUtc = '2026-07-01T02:00:00.000Z';
    mockQueries(
      [], // no active tasks
      [
        { id: 'e1', title: 'Evening event', status: null, priority: null, run_status: null, start_date: tonightLocalTomorrowUtc, type: 'calendar_event' },
      ],
      [],
      [],
      [{ timezone: 'America/Los_Angeles' }], // resolveUserTimezone → Pacific
    );
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(200);
    expect(res.body.scheduled_today.map((i: any) => i.id)).toEqual(['e1']);
    // The window itself is the LOCAL Jun-30 day, not the UTC day.
    expect(res.body.window_start).toBe('2026-06-30T07:00:00.000Z');
    expect(res.body.window_end).toBe('2026-07-01T07:00:00.000Z');
  });

  it('500s when the database query fails', async () => {
    poolMock.query.mockRejectedValueOnce(new Error('db down'));
    const res = await request(testApp()).get('/api/v1/brief');
    expect(res.status).toBe(500);
    expect(res.body.error).toBeTruthy();
  });
});
