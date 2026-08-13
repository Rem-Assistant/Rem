import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';

/** A raw routine_schedules row as pg would return it. */
function routineRow(overrides: Record<string, unknown> = {}) {
  return {
    id: ROUTINE_ID,
    user_id: USER_ID,
    task_id: TASK_ID,
    cadence: 'daily',
    delivery_hour: 7,
    timezone: 'America/Los_Angeles',
    prompt: 'Summarize my open tasks.',
    autonomy: 1,
    model: null,
    enabled: true,
    last_run_at: null,
    created_at: '2026-06-26T00:00:00.000Z',
    ...overrides,
  };
}

const routinesRoutes = (await import('./routines.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', routinesRoutes);
  return app;
}

beforeEach(() => {
  vi.clearAllMocks();
  delete process.env.GMI_API_KEY;
  delete process.env.GMI_AGENTBOX_URL;
});

describe('routines CRUD routes', () => {
  it('creates a routine', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [routineRow()] });
    const res = await request(testApp())
      .post('/api/v1/routines')
      .send({ taskId: TASK_ID, deliveryHour: 7, timezone: 'America/Los_Angeles' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ id: ROUTINE_ID, taskId: TASK_ID });
    expect(poolMock.query.mock.calls[0][0]).toContain('INSERT INTO routine_schedules');
  });

  it('rejects a create missing taskId with 400', async () => {
    const res = await request(testApp())
      .post('/api/v1/routines')
      .send({ deliveryHour: 7, timezone: 'UTC' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('rejects an out-of-range deliveryHour with 400', async () => {
    const res = await request(testApp())
      .post('/api/v1/routines')
      .send({ taskId: TASK_ID, deliveryHour: 24, timezone: 'UTC' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('lists routines', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [routineRow()] });
    const res = await request(testApp()).get('/api/v1/routines');
    expect(res.status).toBe(200);
    expect(res.body.routines).toHaveLength(1);
  });

  it('returns 404 for a routine not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).get(`/api/v1/routines/${ROUTINE_ID}`);
    expect(res.status).toBe(404);
  });

  it('deletes a routine and returns 204', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: ROUTINE_ID }] });
    const res = await request(testApp()).delete(`/api/v1/routines/${ROUTINE_ID}`);
    expect(res.status).toBe(204);
  });
});

describe('POST /routines/:id/run', () => {
  it('returns 404 when the routine does not exist', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).post(`/api/v1/routines/${ROUTINE_ID}/run`);
    expect(res.status).toBe(404);
  });

  it('runs the routine and returns the RunReport (null-model short-circuit)', async () => {
    poolMock.query
      // getRoutine — a routine with no model selected
      .mockResolvedValueOnce({ rows: [routineRow({ model: null })] })
      // runRoutine writes the surfaced "select a model" comment
      .mockResolvedValueOnce({ rows: [{ id: 'c3333333-0000-4000-8000-000000000004' }] });

    const res = await request(testApp()).post(`/api/v1/routines/${ROUTINE_ID}/run`);
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('needs_model');
    expect(res.body.reason).toBe('select a model');
    expect(res.body.report).toMatchObject({ routineId: ROUTINE_ID, needsReview: true });
  });
});
