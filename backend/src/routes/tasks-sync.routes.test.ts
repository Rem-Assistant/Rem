import express from 'express';
import { readFileSync } from 'node:fs';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const clientMock = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
}));
const poolMock = vi.hoisted(() => ({
  query: vi.fn(),
  connect: vi.fn(async () => clientMock),
}));

vi.mock('../db/pool.js', () => ({ pool: poolMock }));
vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

const TASK_ID = '11111111-1111-4111-8111-111111111111';
const LIST_ID = '22222222-2222-4222-8222-222222222222';
const MIXED_CASE_TASK_ID = 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF';
const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const tasksRoutes = (await import('./tasks.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', tasksRoutes);
  return app;
}

describe('task sync tombstones', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    poolMock.connect.mockResolvedValue(clientMock);
  });

  it('lists only the authenticated user deletion tombstones', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ task_id: TASK_ID, deleted_at: '2026-08-04T12:00:00.000Z' }],
    });

    const response = await request(testApp()).get('/api/v1/tasks/deletions');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      deletions: [{ task_id: TASK_ID, deleted_at: '2026-08-04T12:00:00.000Z' }],
    });
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID]);
  });

  it('records a tombstone in the same transaction as deletion', async () => {
    clientMock.query.mockResolvedValue({ rows: [] });

    const response = await request(testApp()).delete(`/api/v1/tasks/${TASK_ID}`);

    expect(response.status).toBe(204);
    expect(clientMock.query.mock.calls.map((call) => call[0])).toEqual([
      'BEGIN',
      expect.stringContaining('pg_advisory_xact_lock'),
      expect.stringContaining('DELETE FROM tasks'),
      expect.stringContaining('INSERT INTO task_deletions'),
      'COMMIT',
    ]);
    expect(clientMock.query.mock.calls[1][1]).toEqual([USER_ID, TASK_ID]);
    expect(clientMock.query.mock.calls[2][1]).toEqual([TASK_ID, USER_ID]);
    expect(clientMock.query.mock.calls[3][1]).toEqual([USER_ID, TASK_ID]);
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('normalizes UUID text before taking the delete advisory lock', async () => {
    clientMock.query.mockResolvedValue({ rows: [] });

    const response = await request(testApp()).delete(`/api/v1/tasks/${MIXED_CASE_TASK_ID}`);

    expect(response.status).toBe(204);
    expect(clientMock.query.mock.calls[1][0]).toContain(
      "hashtextextended($1::uuid::text || ':' || $2::uuid::text, 0)",
    );
    expect(clientMock.query.mock.calls[1][1]).toEqual([USER_ID, MIXED_CASE_TASK_ID]);
  });

  it('rolls back when tombstone persistence fails', async () => {
    clientMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      .mockRejectedValueOnce(new Error('disk full'))
      .mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp()).delete(`/api/v1/tasks/${TASK_ID}`);

    expect(response.status).toBe(500);
    expect(clientMock.query).toHaveBeenLastCalledWith('ROLLBACK');
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('uses the same advisory key in the insert trigger so delete wins create races', () => {
    const migration = readFileSync(
      new URL('../db/migrations/103_create_task_deletions.sql', import.meta.url),
      'utf8',
    );

    expect(migration).toContain('BEFORE INSERT ON tasks');
    expect(migration).toContain("NEW.user_id::text || ':' || NEW.id::text");
    expect(migration).toContain('task id was previously deleted');
  });

  it('returns gone when a delayed create loses to a committed tombstone', async () => {
    const tombstoneError = Object.assign(new Error('task id was previously deleted'), {
      code: 'P0001',
    });
    poolMock.query.mockRejectedValueOnce(tombstoneError);

    const response = await request(testApp())
      .post('/api/v1/tasks')
      .send({ id: TASK_ID, title: 'Late create retry' });

    expect(response.status).toBe(410);
    expect(response.body).toEqual({ error: 'task id was previously deleted' });
  });

  it('returns the existing authenticated task for a repeated client-owned create id', async () => {
    const existing = {
      id: TASK_ID,
      title: 'Stable suggestion task',
      type: 'task',
      status: 'pending',
      priority: 'medium',
      start_date: '2026-08-16T13:00:00.000Z',
    };
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [existing] });

    const response = await request(testApp())
      .post('/api/v1/tasks')
      .send({ id: TASK_ID, title: 'Stable suggestion task', start_date: '2026-08-16T14:00:00.000Z' });

    expect(response.status).toBe(201);
    expect(response.body.id).toBe(TASK_ID);
    expect(poolMock.query.mock.calls[0][0]).toContain('ON CONFLICT (id) DO NOTHING');
    expect(poolMock.query.mock.calls[1][1]).toEqual([TASK_ID, USER_ID]);
  });
});

describe('task organization writes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('creates a calendar event with its validated list in the same insert', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: LIST_ID }] })
      .mockResolvedValueOnce({
        rows: [{
          id: TASK_ID,
          title: 'Launch review',
          status: 'pending',
          priority: 'medium',
          start_date: '2026-08-08T20:00:00.000Z',
          end_date: null,
          duration_minutes: 30,
          alert_time: null,
          repeat_frequency: null,
          type: 'calendar_event',
          list_id: LIST_ID,
          calendar_event_id: null,
          run_status: null,
          run_id: null,
          session_key: null,
          run_started_at: null,
          run_last_heartbeat_at: null,
          created_at: '2026-08-08T19:00:00.000Z',
          updated_at: '2026-08-08T19:00:00.000Z',
        }],
      });

    const response = await request(testApp()).post('/api/v1/tasks').send({
      id: TASK_ID,
      title: 'Launch review',
      type: 'calendar_event',
      date_time: '2026-08-08T20:00:00.000Z',
      duration_minutes: 30,
      list_id: LIST_ID,
    });

    expect(response.status).toBe(201);
    expect(response.body.list_id).toBe(LIST_ID);
    expect(poolMock.query.mock.calls[1][0]).toContain('type, list_id, created_at');
    expect(poolMock.query.mock.calls[1][1]).toEqual([
      TASK_ID,
      USER_ID,
      'Launch review',
      '2026-08-08T20:00:00.000Z',
      30,
      LIST_ID,
    ]);
  });

  it('returns the existing authenticated event for a repeated client-owned create id', async () => {
    const existing = {
      id: TASK_ID,
      title: 'Older committed event',
      status: 'pending',
      priority: 'medium',
      start_date: '2026-08-08T20:00:00.000Z',
      duration_minutes: 30,
      type: 'calendar_event',
      list_id: null,
    };
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: LIST_ID }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [existing] });

    const response = await request(testApp()).post('/api/v1/tasks').send({
      id: TASK_ID,
      title: 'Newer queued event',
      type: 'calendar_event',
      date_time: '2026-08-09T21:00:00.000Z',
      duration_minutes: 45,
      list_id: LIST_ID,
    });

    expect(response.status).toBe(201);
    expect(response.body.title).toBe(existing.title);
    expect(poolMock.query.mock.calls[1][0]).toContain('ON CONFLICT (id) DO NOTHING');
    expect(poolMock.query.mock.calls[2][1]).toEqual([TASK_ID, USER_ID]);
  });
});
