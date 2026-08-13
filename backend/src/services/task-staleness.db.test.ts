/**
 * Task staleness (migration 116) against a REAL PostgreSQL engine (PGlite), driven through the
 * REAL authoring path — `authorBriefForUser` → `gatherBrief` → the authoring lease →
 * `completeBriefArtifact` → `recordBriefSurfacing`.
 *
 * WHY THE WHOLE PATH AND NOT A UNIT TEST OF THE COUNTER. The counter is trivially correct in
 * isolation; every interesting way this feature can be wrong lives in the wiring:
 *   - counting on a READ (GET /api/v1/brief) instead of on an authored brief, so staleness would
 *     track how often the user opens the app;
 *   - counting more than once per brief, because two workers or a redelivery raced;
 *   - marking a task stale and then still handing it to the model, so the brief keeps repeating
 *     itself anyway — the exact bug being fixed;
 *   - resetting on a machine write, so Rem's own sweep buys a task three more chances to nag.
 * A test that stubbed the DB or called `recordBriefSurfacing` directly would pass with any of those
 * bugs present. So the only things stubbed here are the two NETWORK boundaries (the gateway turn
 * that writes the prose, and the chat injection that delivers it); every SQL statement is the real
 * one, running against a real Postgres.
 *
 * The migrations are applied from the actual .sql files, so a schema change that contradicts the
 * service fails here rather than in production.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// PGlite exposes pg's `query(text, values)` shape, so the production statements run unmodified.
// `connect()` hands back the same single engine with a no-op `release()`: PGlite is one connection,
// and the delivery path only needs a client handle.
const poolMock = vi.hoisted(() => ({
  db: null as any,
  query: (...args: any[]) => poolMock.db.query(...args),
  connect: async () => ({
    query: (...args: any[]) => poolMock.db.query(...args),
    release: () => undefined,
  }),
}));
vi.mock('../db/pool.js', () => ({ pool: poolMock, DatabaseQueryable: null }));

// NETWORK BOUNDARIES ONLY. `runAgentTurnOnGateway` is where the model writes the prose;
// `injectAssistantMessageOnGateway` is the chat delivery. Everything between them is real.
const runAgentTurnOnGateway = vi.hoisted(() => vi.fn());
const injectAssistantMessageOnGateway = vi.hoisted(() => vi.fn());
vi.mock('./gateway-agent.service.js', () => ({
  runAgentTurnOnGateway,
  injectAssistantMessageOnGateway,
}));

const USER_ID = '22222222-2222-4222-8222-222222222222';

// The REAL task routes, so the reset is proven through PATCH /api/v1/tasks/:id rather than through
// a hand-copied UPDATE that could drift from the route without anything failing.
vi.mock('../middleware/auth.js', () => ({
  requireJwt: (
    req: express.Request & { userId?: string },
    _res: express.Response,
    next: express.NextFunction,
  ) => {
    req.userId = USER_ID;
    next();
  },
}));
vi.mock('./organization.service.js', () => ({ listExistsForUser: async () => true }));

const { authorBriefForUser } = await import('./brief-authoring.service.js');
const { BRIEF_STALE_THRESHOLD, resetTaskStaleness } = await import('./task-staleness.service.js');
const tasksRoutes = (await import('../routes/tasks.routes.js')).default;

function taskApi() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', tasksRoutes);
  return app;
}

const IGNORED = '33333333-3333-4333-8333-333333333331';
const TOUCHED = '33333333-3333-4333-8333-333333333332';

// Three consecutive local days, each at 15:00 UTC — the AFTERNOON authoring slot, well past the
// 12:00 start. A different local day each time is what lets three separate briefs be authored:
// the lease dedupes to one artifact per (user, day, slot), which is exactly the fence the counter
// leans on.
const DAYS = [
  new Date('2026-06-30T15:00:00.000Z'),
  new Date('2026-07-01T15:00:00.000Z'),
  new Date('2026-07-02T15:00:00.000Z'),
  new Date('2026-07-03T15:00:00.000Z'),
];

function migration(file: string): string {
  return fs.readFileSync(path.join(__dirname, '..', 'db', 'migrations', file), 'utf8');
}

/** The prose context handed to the model on the most recent authoring turn. */
function lastAuthoringPrompt(): string {
  const calls = runAgentTurnOnGateway.mock.calls;
  return calls.length ? (calls[calls.length - 1][0] as { message: string }).message : '';
}

async function staleness(taskId: string) {
  const row = await poolMock.db.query(
    `SELECT brief_surface_count, stale_at, brief_last_surfaced_at, status, title
       FROM tasks WHERE id = $1::uuid`,
    [taskId],
  );
  return row.rows[0];
}

/** Seed two identical, indistinguishable overdue tasks. Only what happens next tells them apart. */
async function seedTasks() {
  await poolMock.db.query(`DELETE FROM tasks WHERE user_id = $1::uuid`, [USER_ID]);
  await poolMock.db.query(`DELETE FROM daily_brief_artifacts WHERE user_id = $1::uuid`, [USER_ID]);
  await poolMock.db.query(`DELETE FROM daily_briefs WHERE user_id = $1::uuid`, [USER_ID]);
  for (const [id, title] of [[IGNORED, 'Renew the domain'], [TOUCHED, 'Book the dentist']]) {
    await poolMock.db.query(
      `INSERT INTO tasks (id, user_id, title, status, priority, type, start_date)
       VALUES ($1::uuid, $2::uuid, $3, 'pending', 'medium', 'task', '2026-06-01T09:00:00Z')`,
      [id, USER_ID, title],
    );
  }
}

describe('task staleness through the real brief-authoring path (migration 116)', () => {
  // PGlite's first cold start (wasm compile + init) can exceed vitest's default 10s hook timeout on
  // a loaded box; 60s is headroom, and a genuine hang still fails rather than hanging the run.
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    poolMock.db = new PGlite();
    await poolMock.db.exec('CREATE TABLE users (id UUID PRIMARY KEY, timezone TEXT)');
    await poolMock.db.query('INSERT INTO users (id, timezone) VALUES ($1::uuid, $2)', [USER_ID, 'UTC']);
    for (const file of [
      '006_create_tasks_table.sql',
      '015_create_task_comments.sql',
      '019_task_run_state.sql',
      // 023/024 add `list_id` / `calendar_event_id`, which the tasks route's RETURNING list and its
      // PATCH handler both reference — without them the real route 500s.
      '023_create_lists_and_folders.sql',
      '024_add_calendar_event_backing.sql',
      '029_add_blocked_task_status.sql',
      '033_create_daily_briefs.sql',
      '034_add_summary_to_daily_briefs.sql',
      '037_add_authoring_slot_and_seed_flag_to_daily_briefs.sql',
      '107_create_daily_brief_artifacts.sql',
      '109_add_daily_brief_artifact_source.sql',
      '114_add_daily_brief_input_provenance.sql',
      '116_add_task_staleness.sql',
      // 120 adds `description`, which the tasks route's RETURNING list and its PATCH
      // handler both reference — without it the real route 500s (same trap as 023/024).
      '120_add_description_to_tasks.sql',
      // 121 adds `run_block_code`/`run_block_mode` to BOTH `tasks` and `task_comments`. The
      // tasks route's RETURNING list, its COMMENT_RETURNING list, and the agent-run write all
      // reference them, so without this the real route 500s — same hand-maintained-list trap as
      // 023/024 and 120 above.
      '121_add_run_block_reason.sql',
      // Replayable: the runner records applied files, but every migration is expected to survive a
      // re-run (a first boot after the tracking table was introduced replays everything).
      '116_add_task_staleness.sql',
      // 119 adds `daily_brief_artifacts.headline`, which `completeBriefArtifact` writes on EVERY
      // authored brief. Without it authoring throws `column "headline" does not exist`, the error
      // is swallowed, and every brief here comes back `skipped_gateway` — the suite fails on
      // staleness assertions that have nothing to do with headlines. Same trap as 023/024 above:
      // this list is hand-maintained, so a migration touching any table the brief-authoring path
      // writes has to be added here even when it is unrelated to staleness.
      '119_add_daily_brief_headline.sql',
      '121_add_run_block_reason.sql',
    ]) {
      await poolMock.db.exec(migration(file));
    }
  }, 60_000);

  afterAll(async () => {
    await poolMock.db?.close?.();
  });

  beforeEach(async () => {
    vi.clearAllMocks();
    runAgentTurnOnGateway.mockResolvedValue({ ok: true, text: 'Here is your day.' });
    injectAssistantMessageOnGateway.mockResolvedValue({ ok: true, messageId: 'msg-1' });
    await seedTasks();
  });

  it('starts every task at "never nagged about"', async () => {
    const row = await staleness(IGNORED);
    expect(row.brief_surface_count).toBe(0);
    expect(row.stale_at).toBeNull();
    expect(row.brief_last_surfaced_at).toBeNull();
  });

  it('goes stale after BRIEF_STALE_THRESHOLD authored briefs with no user action', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
      const result = await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' });
      // Assert the brief was really authored, not skipped. Without this the counter assertions
      // below would still pass on a path that never produced a brief at all.
      expect(result.status).toBe('authored');
    }

    const row = await staleness(IGNORED);
    expect(row.brief_surface_count).toBe(BRIEF_STALE_THRESHOLD);
    expect(row.stale_at).not.toBeNull();
  });

  it('does NOT go stale one brief short of the threshold', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD - 1; day += 1) {
      expect((await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' })).status).toBe('authored');
    }

    const row = await staleness(IGNORED);
    expect(row.brief_surface_count).toBe(BRIEF_STALE_THRESHOLD - 1);
    expect(row.stale_at).toBeNull();
  });

  it('does NOT go stale when the user acts in between — and the counter restarts from zero', async () => {
    // Two briefs ask about both tasks.
    for (let day = 0; day < 2; day += 1) {
      expect((await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' })).status).toBe('authored');
    }
    expect((await staleness(TOUCHED)).brief_surface_count).toBe(2);

    // The user touches ONE of them, through the REAL route the app calls.
    const patched = await request(taskApi())
      .patch(`/api/v1/tasks/${TOUCHED}`)
      .send({ status: 'in_progress' });
    expect(patched.status).toBe(200);

    // A third brief. The ignored task now hits the threshold; the touched one is back at 1.
    expect((await authorBriefForUser(USER_ID, DAYS[2], { timezone: 'UTC' })).status).toBe('authored');

    const ignored = await staleness(IGNORED);
    const touched = await staleness(TOUCHED);
    expect(ignored.brief_surface_count).toBe(3);
    expect(ignored.stale_at).not.toBeNull();
    expect(touched.brief_surface_count).toBe(1);
    expect(touched.stale_at).toBeNull();
  });

  it('stops handing a stale task to the model — the brief actually stops asking', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
      await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' });
    }
    // Up to and including the third brief, Rem was still asking.
    expect(lastAuthoringPrompt()).toContain('Renew the domain');

    // The user finally engages with ONE of the two, so the fourth brief has something left to say.
    // (Without this both tasks are stale and the brief correctly authors nothing at all — which is
    // the right behaviour, but it would not prove the surviving task is still raised.)
    expect(await resetTaskStaleness(USER_ID, TOUCHED, poolMock.db)).toBe(true);

    const fourth = await authorBriefForUser(USER_ID, DAYS[3], { timezone: 'UTC' });
    expect(fourth.status).toBe('authored');

    const prompt = lastAuthoringPrompt();
    expect(prompt).not.toContain('Renew the domain'); // stale — dropped
    expect(prompt).toContain('Book the dentist'); // not stale — still raised
    // The headline counts are recomputed on the filtered view, so the model is never told about a
    // task it cannot see (which is how it would invent one).
    expect(prompt).toContain('1 overdue');
  });

  it('never advances a stale task past the threshold, however long it is ignored', async () => {
    for (const day of DAYS) await authorBriefForUser(USER_ID, day, { timezone: 'UTC' });
    const row = await staleness(IGNORED);
    expect(row.brief_surface_count).toBe(BRIEF_STALE_THRESHOLD);
  });

  it('keeps a stale task readable, un-deleted, and with its real status intact', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
      await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' });
    }

    // The row is still there, still the user's, still 'pending' — "stale" did not overwrite the
    // status column, delete the task, or auto-complete it.
    const row = await staleness(IGNORED);
    expect(row.title).toBe('Renew the domain');
    expect(row.status).toBe('pending');

    // And it is still returned by the query GET /api/v1/tasks runs (no stale filter anywhere).
    const listed = await poolMock.db.query(
      `SELECT id FROM tasks WHERE user_id = $1::uuid ORDER BY created_at DESC`,
      [USER_ID],
    );
    expect(listed.rows.map((r: any) => r.id)).toContain(IGNORED);

    // The deterministic brief buckets still carry it too, flagged rather than hidden.
    const { gatherBrief } = await import('./brief.service.js');
    const brief = await gatherBrief(USER_ID, DAYS[3], 'UTC', poolMock.db);
    const item = brief.overdue.find((i) => i.id === IGNORED);
    expect(item).toBeDefined();
    expect(item!.is_stale).toBe(true);
  });

  // The app cannot render what the API does not send. `gatherBrief` derives `is_stale` for the
  // brief surface, but every OTHER task surface (agenda, inbox, lists, task detail, Mac) is fed by
  // GET /api/v1/tasks — and staleness reached none of them, so a stale task was pixel-identical to
  // a live one. These drive the real route so a regression in `RETURNING` or `formatTask` fails
  // here rather than silently going quiet on the phone.
  describe('GET /api/v1/tasks — the client can SEE staleness', () => {
    async function goStale() {
      for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
        expect((await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' })).status).toBe('authored');
      }
    }

    async function listTasks() {
      const res = await request(taskApi()).get('/api/v1/tasks');
      expect(res.status).toBe(200);
      return res.body.tasks as any[];
    }

    it('still LISTS a stale task — "stop nagging" must never mean "vanish from the app"', async () => {
      await goStale();

      const tasks = await listTasks();
      // The failure this guards is the one a `status = 'stale'` design would have shipped: the row
      // dropping out of the five consumers that filter on `status`. Assert on identity, not on a
      // count — a count passes if the wrong row survived.
      expect(tasks.map((t) => t.id)).toContain(IGNORED);
      const stale = tasks.find((t) => t.id === IGNORED);
      expect(stale.title).toBe('Renew the domain');
      // Its real status is untouched. Staleness did not overwrite it.
      expect(stale.status).toBe('pending');
    });

    it('sends stale_at, so the row can be de-emphasised and labelled', async () => {
      // BEFORE going stale the field is present and null — the client must be able to tell
      // "not stale" from "this backend never told me", and null is the honest answer.
      const fresh = (await listTasks()).find((t) => t.id === IGNORED);
      expect(fresh).toHaveProperty('stale_at');
      expect(fresh.stale_at).toBeNull();

      // Two briefs ask about BOTH tasks; the user then touches one, so only IGNORED reaches the
      // threshold on the third. Both rows come back in the same response, which is what makes this
      // measure staleness rather than "the route now stamps a timestamp on everything".
      for (let day = 0; day < BRIEF_STALE_THRESHOLD - 1; day += 1) {
        expect((await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' })).status).toBe('authored');
      }
      expect((await request(taskApi()).patch(`/api/v1/tasks/${TOUCHED}`).send({ status: 'in_progress' })).status).toBe(200);
      expect((await authorBriefForUser(USER_ID, DAYS[BRIEF_STALE_THRESHOLD - 1], { timezone: 'UTC' })).status).toBe('authored');

      const listed = await listTasks();
      const stale = listed.find((t) => t.id === IGNORED);
      const touched = listed.find((t) => t.id === TOUCHED);

      expect(stale.stale_at).not.toBeNull();
      expect(touched.stale_at).toBeNull();
      // A real ISO-8601 instant the client can parse, not a truthy placeholder. Assert on the
      // value's identity against the stored column, not merely that something non-null arrived.
      const stored = (await staleness(IGNORED)).stale_at;
      expect(new Date(stale.stale_at).toISOString()).toBe(new Date(stored).toISOString());
    });

    it('reports a blocked AND stale task as both — neither fact hides the other', async () => {
      // Blocked is a status; stale is a separate column. They are orthogonal, and the whole reason
      // staleness is not a `status` value is that one must not overwrite the other.
      //
      // HOW THE COMBINATION ACTUALLY ARISES. Not through PATCH: a user setting the status is a user
      // action, and it un-stales the task (proven by the next test). It arises when an AGENT RUN
      // applies `blocked` — `tasks.routes.ts` writes `SET run_status = $1, status = $2, ...` on run
      // completion and deliberately does NOT reset staleness, because a machine must not buy itself
      // three more chances to nag. This UPDATE mirrors that statement.
      await poolMock.db.query(
        `UPDATE tasks SET run_status = 'blocked', status = 'blocked', updated_at = NOW()
          WHERE id = $1::uuid AND user_id = $2::uuid`,
        [IGNORED, USER_ID],
      );
      // The brief still gathers it (`status IN ('pending','in_progress') OR run_status = 'blocked'`,
      // brief.service.ts), so it keeps being surfaced and goes stale for real.
      await goStale();

      const both = (await listTasks()).find((t) => t.id === IGNORED);
      expect(both.status).toBe('blocked'); // the real status survived…
      // …and Rem's "I stopped asking" is reported alongside it.
      //
      // Asserted as "present AND a real instant", NOT as `.not.toBeNull()`. A missing key reads
      // back as `undefined`, and `expect(undefined).not.toBeNull()` passes — so the weaker form
      // stayed green with the serializer deleted, measuring nothing. Checked by deleting it.
      expect(both).toHaveProperty('stale_at');
      expect(Number.isNaN(new Date(both.stale_at).getTime())).toBe(false);
      expect(new Date(both.stale_at).toISOString()).toBe(
        new Date((await staleness(IGNORED)).stale_at).toISOString(),
      );
      // Both facts on one row is the point. A client reading only `status` would render an ordinary
      // blocked task; a client reading only `stale_at` would lose the status the run applied.
      expect(both.run_status).toBe('blocked');
    });

    it('makes an un-staling visible to a delta pull, not just a full one', async () => {
      // `GET /tasks?since=` filters on `updated_at`. Un-staling is a USER-VISIBLE state change —
      // the client drops the dim and the "Stale" badge — so a reset that leaves `updated_at`
      // untouched is permanently invisible to a delta consumer: the row is never re-sent, and the
      // badge never clears. The comment route calls `resetTaskStaleness` bare (the PATCH and
      // agent-run paths write `updated_at` in their own UPDATE), so this is where the trap lives.
      await goStale();
      const before = (await poolMock.db.query(
        `SELECT updated_at FROM tasks WHERE id = $1::uuid`, [IGNORED],
      )).rows[0].updated_at;

      expect(await resetTaskStaleness(USER_ID, IGNORED, poolMock.db)).toBe(true);

      const after = (await poolMock.db.query(
        `SELECT updated_at, stale_at FROM tasks WHERE id = $1::uuid`, [IGNORED],
      )).rows[0];
      expect(after.stale_at).toBeNull();
      // Assert on the timestamp ADVANCING, not merely on it being non-null — it was already
      // non-null before the reset, so a "is set" check would pass without the bump.
      expect(new Date(after.updated_at).getTime()).toBeGreaterThan(new Date(before).getTime());

      // And the row is genuinely re-sent by a `since=` scoped read taken from before the reset.
      const delta = await request(taskApi()).get('/api/v1/tasks').query({ since: new Date(before).toISOString() });
      expect(delta.status).toBe(200);
      expect(delta.body.tasks.map((t: any) => t.id)).toContain(IGNORED);
      expect(delta.body.tasks.find((t: any) => t.id === IGNORED).stale_at).toBeNull();
    });

    it('clears stale_at on the wire the moment the user acts', async () => {
      await goStale();
      expect((await listTasks()).find((t) => t.id === IGNORED).stale_at).not.toBeNull();

      // The PATCH response itself must carry the cleared value: it is the ACK the app applies, and
      // a client that only ever learned about non-null stale_at would leave the row dimmed forever.
      const patched = await request(taskApi())
        .patch(`/api/v1/tasks/${IGNORED}`)
        .send({ start_date: '2026-07-04T09:00:00.000Z' });
      expect(patched.status).toBe(200);
      expect(patched.body).toHaveProperty('stale_at');
      expect(patched.body.stale_at).toBeNull();

      expect((await listTasks()).find((t) => t.id === IGNORED).stale_at).toBeNull();
    });
  });

  it('brings a stale task back the moment the user touches it', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
      await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' });
    }
    expect((await staleness(IGNORED)).stale_at).not.toBeNull();

    // The real reset the comments route calls.
    expect(await resetTaskStaleness(USER_ID, IGNORED, poolMock.db)).toBe(true);

    const row = await staleness(IGNORED);
    expect(row.stale_at).toBeNull();
    expect(row.brief_surface_count).toBe(0);

    const fourth = await authorBriefForUser(USER_ID, DAYS[3], { timezone: 'UTC' });
    expect(fourth.status).toBe('authored');
    expect(lastAuthoringPrompt()).toContain('Renew the domain');
  });

  it('un-stales through PATCH /api/v1/tasks/:id — rescheduling is a user action', async () => {
    for (let day = 0; day < BRIEF_STALE_THRESHOLD; day += 1) {
      await authorBriefForUser(USER_ID, DAYS[day], { timezone: 'UTC' });
    }
    expect((await staleness(IGNORED)).stale_at).not.toBeNull();

    // Rescheduling only — no status change, no completion. Pushing a date out is the founder's own
    // "I'll deal with it later", and it must count as touching the task.
    const patched = await request(taskApi())
      .patch(`/api/v1/tasks/${IGNORED}`)
      .send({ start_date: '2026-07-04T09:00:00.000Z' });
    expect(patched.status).toBe(200);

    const row = await staleness(IGNORED);
    expect(row.stale_at).toBeNull();
    expect(row.brief_surface_count).toBe(0);
    // And the status the user actually set is untouched by any of this.
    expect(row.status).toBe('pending');
  });

  it('does not reset another user\'s task', async () => {
    const OTHER_USER = '44444444-4444-4444-8444-444444444444';
    await poolMock.db.query('INSERT INTO users (id, timezone) VALUES ($1::uuid, $2) ON CONFLICT DO NOTHING', [OTHER_USER, 'UTC']);
    await poolMock.db.query(
      `UPDATE tasks SET brief_surface_count = 3, stale_at = NOW() WHERE id = $1::uuid`,
      [IGNORED],
    );
    expect(await resetTaskStaleness(OTHER_USER, IGNORED, poolMock.db)).toBe(false);
    expect((await staleness(IGNORED)).stale_at).not.toBeNull();
  });

  it('counts an authored brief once, not once per read of it', async () => {
    const { gatherBrief } = await import('./brief.service.js');
    expect((await authorBriefForUser(USER_ID, DAYS[0], { timezone: 'UTC' })).status).toBe('authored');

    // Ten app foregrounds re-reading the brief on the same day.
    for (let i = 0; i < 10; i += 1) await gatherBrief(USER_ID, DAYS[0], 'UTC', poolMock.db);
    // …and the cron ticking again inside the same slot, which the lease must dedupe.
    await authorBriefForUser(USER_ID, DAYS[0], { timezone: 'UTC' });

    expect((await staleness(IGNORED)).brief_surface_count).toBe(1);
  });
});
