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

const MEMORY_ID = '33333333-3333-4333-8333-333333333333';

const memoryRow = {
  id: MEMORY_ID,
  fact: 'Prefers morning workouts',
  source: null,
  created_at: '2026-06-26T13:00:00.000Z',
  updated_at: '2026-06-26T13:00:00.000Z',
};

const userMemoryRoutes = (await import('./user-memory.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', userMemoryRoutes);
  return app;
}

describe('user-memory routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('lists memories newest-first with last-refreshed stamps', async () => {
    // GET fires listMemories then getMemoryFreshness (Promise.all, list query first).
    poolMock.query
      .mockResolvedValueOnce({ rows: [memoryRow] })
      .mockResolvedValueOnce({
        rows: [
          {
            last_updated_at: '2026-06-29T09:00:00.000Z',
            last_auto_extracted_at: '2026-06-29T08:00:00.000Z',
          },
        ],
      });
    const res = await request(testApp()).get('/api/v1/memory');
    expect(res.status).toBe(200);
    expect(res.body.memories).toHaveLength(1);
    expect(res.body.memories[0]).toMatchObject({ id: MEMORY_ID, fact: 'Prefers morning workouts' });
    expect(res.body.lastUpdatedAt).toBe('2026-06-29T09:00:00.000Z');
    expect(res.body.lastAutoExtractedAt).toBe('2026-06-29T08:00:00.000Z');
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('ORDER BY created_at DESC');
  });

  it('adds a memory and returns 201', async () => {
    poolMock.query.mockImplementationOnce(async (_sql: string, values: any[]) => ({
      rows: [{ ...memoryRow, fact: values[1], source: values[2] }],
    }));
    const res = await request(testApp()).post('/api/v1/memory').send({ fact: '  Has two cats  ' });
    expect(res.status).toBe(201);
    // fact is trimmed before insert
    expect(res.body).toMatchObject({ fact: 'Has two cats', source: null });
    const insertSql = poolMock.query.mock.calls[0][0] as string;
    expect(insertSql).toContain('INSERT INTO user_memory');
  });

  it('rejects an empty fact with 400 (no DB call)', async () => {
    const res = await request(testApp()).post('/api/v1/memory').send({ fact: '   ' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('rejects a missing fact with 400', async () => {
    const res = await request(testApp()).post('/api/v1/memory').send({});
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('updates a memory and returns the row', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ ...memoryRow, fact: 'Prefers evening workouts' }] });
    const res = await request(testApp())
      .patch(`/api/v1/memory/${MEMORY_ID}`)
      .send({ fact: 'Prefers evening workouts' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ id: MEMORY_ID, fact: 'Prefers evening workouts' });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('UPDATE user_memory');
  });

  it('returns 404 updating a memory not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp())
      .patch(`/api/v1/memory/${MEMORY_ID}`)
      .send({ fact: 'whatever' });
    expect(res.status).toBe(404);
  });

  it('rejects an empty fact on update with 400 (no DB call)', async () => {
    const res = await request(testApp()).patch(`/api/v1/memory/${MEMORY_ID}`).send({ fact: '' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('deletes a memory and returns 204', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: MEMORY_ID }] });
    const res = await request(testApp()).delete(`/api/v1/memory/${MEMORY_ID}`);
    expect(res.status).toBe(204);
  });

  it('delete of a missing memory returns 404', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).delete(`/api/v1/memory/${MEMORY_ID}`);
    expect(res.status).toBe(404);
  });
});
