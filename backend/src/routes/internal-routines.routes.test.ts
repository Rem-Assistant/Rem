import express from 'express';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const getRoutineByIdMock = vi.hoisted(() => vi.fn());
const runRoutineMock = vi.hoisted(() => vi.fn());

vi.mock('../services/routine-schedule.service.js', () => ({
  getRoutineById: getRoutineByIdMock,
}));
vi.mock('../services/routine-runner.service.js', () => ({
  runRoutine: runRoutineMock,
}));

const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';
const SECRET = 'super-secret-webhook-token';
const RUN_PATH = `/api/v1/internal/routines/${ROUTINE_ID}/run`;

function routine(overrides: Record<string, unknown> = {}) {
  return {
    id: ROUTINE_ID,
    userId: USER_ID,
    taskId: TASK_ID,
    cadence: 'daily',
    deliveryHour: 7,
    timezone: 'America/Los_Angeles',
    prompt: 'Summarize my open tasks.',
    autonomy: 3,
    model: 'gpt-4o',
    enabled: true,
    lastRunAt: null,
    createdAt: '2026-06-26T00:00:00.000Z',
    ...overrides,
  };
}

function runResult() {
  return {
    status: 'executed',
    report: {
      routineId: ROUTINE_ID,
      timestamp: '2026-06-29T15:00:00.000Z',
      sources: ['task'],
      writes: ['task_comment'],
      confidence: 'medium',
      needsReview: false,
    },
    commentId: 'c3333333-0000-4000-8000-000000000004',
    reason: null,
  };
}

const internalRoutinesRoutes = (await import('./internal-routines.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', internalRoutinesRoutes);
  return app;
}

beforeEach(() => {
  vi.clearAllMocks();
  process.env.ROUTINE_WEBHOOK_SECRET = SECRET;
});

afterEach(() => {
  delete process.env.ROUTINE_WEBHOOK_SECRET;
});

describe('inbound routine cron webhook', () => {
  describe('auth rejection', () => {
    it('rejects when no secret is presented (401) and never runs the routine', async () => {
      const res = await request(testApp()).post(RUN_PATH).send({});
      expect(res.status).toBe(401);
      expect(getRoutineByIdMock).not.toHaveBeenCalled();
      expect(runRoutineMock).not.toHaveBeenCalled();
    });

    it('rejects a wrong bearer token (401)', async () => {
      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', 'Bearer wrong-token')
        .send({});
      expect(res.status).toBe(401);
      expect(runRoutineMock).not.toHaveBeenCalled();
    });

    it('rejects a wrong x-routine-webhook-secret header (401)', async () => {
      const res = await request(testApp())
        .post(RUN_PATH)
        .set('x-routine-webhook-secret', 'nope')
        .send({});
      expect(res.status).toBe(401);
      expect(runRoutineMock).not.toHaveBeenCalled();
    });

    it('fails closed when ROUTINE_WEBHOOK_SECRET is unset (401), even with a bearer token', async () => {
      delete process.env.ROUTINE_WEBHOOK_SECRET;
      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', `Bearer ${SECRET}`)
        .send({});
      expect(res.status).toBe(401);
      expect(getRoutineByIdMock).not.toHaveBeenCalled();
      expect(runRoutineMock).not.toHaveBeenCalled();
    });
  });

  describe('happy path', () => {
    it('invokes runRoutine and returns the RunReport on a valid bearer token', async () => {
      getRoutineByIdMock.mockResolvedValueOnce(routine());
      runRoutineMock.mockResolvedValueOnce(runResult());

      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', `Bearer ${SECRET}`)
        .send({});

      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ status: 'executed', report: { routineId: ROUTINE_ID } });
      expect(getRoutineByIdMock).toHaveBeenCalledWith(ROUTINE_ID);
      expect(runRoutineMock).toHaveBeenCalledTimes(1);
      expect(runRoutineMock.mock.calls[0][0]).toMatchObject({ id: ROUTINE_ID, userId: USER_ID });
    });

    it('accepts the secret via the x-routine-webhook-secret header too', async () => {
      getRoutineByIdMock.mockResolvedValueOnce(routine());
      runRoutineMock.mockResolvedValueOnce(runResult());

      const res = await request(testApp())
        .post(RUN_PATH)
        .set('x-routine-webhook-secret', SECRET)
        .send({});

      expect(res.status).toBe(200);
      expect(runRoutineMock).toHaveBeenCalledTimes(1);
    });

    it('no-ops a paused routine (enabled:false): does not run, comment, or stamp', async () => {
      getRoutineByIdMock.mockResolvedValueOnce(routine({ enabled: false }));

      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', `Bearer ${SECRET}`)
        .send({});

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ skipped: 'disabled', routineId: ROUTINE_ID });
      // The whole run+comment+stamp path lives behind runRoutine — never reached when paused.
      expect(runRoutineMock).not.toHaveBeenCalled();
    });

    it('returns 404 for an unknown routine without running it', async () => {
      getRoutineByIdMock.mockResolvedValueOnce(null);

      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', `Bearer ${SECRET}`)
        .send({});

      expect(res.status).toBe(404);
      expect(runRoutineMock).not.toHaveBeenCalled();
    });

    it('returns 500 when the runner throws', async () => {
      getRoutineByIdMock.mockResolvedValueOnce(routine());
      runRoutineMock.mockRejectedValueOnce(new Error('boom'));

      const res = await request(testApp())
        .post(RUN_PATH)
        .set('Authorization', `Bearer ${SECRET}`)
        .send({});

      expect(res.status).toBe(500);
    });
  });
});
