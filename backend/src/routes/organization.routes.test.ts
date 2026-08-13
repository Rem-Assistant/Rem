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

const FOLDER_ID = '11111111-1111-4111-8111-111111111111';
const LIST_ID = '22222222-2222-4222-8222-222222222222';

const folderRow = {
  id: FOLDER_ID,
  name: 'Work',
  sort_order: 0,
  created_at: '2026-06-29T13:00:00.000Z',
  updated_at: '2026-06-29T13:00:00.000Z',
};

const listRow = {
  id: LIST_ID,
  name: 'Q3 Launch',
  folder_id: FOLDER_ID,
  sort_order: 0,
  created_at: '2026-06-29T13:00:00.000Z',
  updated_at: '2026-06-29T13:00:00.000Z',
};

const organizationRoutes = (await import('./organization.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', organizationRoutes);
  return app;
}

describe('organization routes — folders', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('lists folders ordered by sort_order', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [folderRow] });
    const res = await request(testApp()).get('/api/v1/folders');
    expect(res.status).toBe(200);
    expect(res.body.folders).toHaveLength(1);
    expect(res.body.folders[0]).toMatchObject({ id: FOLDER_ID, name: 'Work' });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('ORDER BY sort_order ASC');
  });

  it('creates a folder and trims the name', async () => {
    poolMock.query.mockImplementationOnce(async (_sql: string, values: any[]) => ({
      rows: [{ ...folderRow, name: values[1] }],
    }));
    const res = await request(testApp()).post('/api/v1/folders').send({ name: '  Work  ' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ name: 'Work' });
    const insertSql = poolMock.query.mock.calls[0][0] as string;
    expect(insertSql).toContain('INSERT INTO folders');
  });

  it('rejects an empty folder name with 400 (no DB call)', async () => {
    const res = await request(testApp()).post('/api/v1/folders').send({ name: '   ' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('renames a folder and returns the row', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ ...folderRow, name: 'Personal' }] });
    const res = await request(testApp()).patch(`/api/v1/folders/${FOLDER_ID}`).send({ name: 'Personal' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ name: 'Personal' });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('UPDATE folders');
  });

  it('returns 404 renaming a folder not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).patch(`/api/v1/folders/${FOLDER_ID}`).send({ name: 'X' });
    expect(res.status).toBe(404);
  });

  it('deletes a folder and returns 204', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: FOLDER_ID }] });
    const res = await request(testApp()).delete(`/api/v1/folders/${FOLDER_ID}`);
    expect(res.status).toBe(204);
  });

  it('delete of a missing folder returns 404', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).delete(`/api/v1/folders/${FOLDER_ID}`);
    expect(res.status).toBe(404);
  });
});

describe('organization routes — lists', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('lists lists', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [listRow] });
    const res = await request(testApp()).get('/api/v1/lists');
    expect(res.status).toBe(200);
    expect(res.body.lists).toHaveLength(1);
    expect(res.body.lists[0]).toMatchObject({ id: LIST_ID, name: 'Q3 Launch', folder_id: FOLDER_ID });
  });

  it('creates a list inside an owned folder', async () => {
    // 1) ownership check on the folder, 2) the INSERT
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: FOLDER_ID }] })
      .mockResolvedValueOnce({ rows: [listRow] });
    const res = await request(testApp())
      .post('/api/v1/lists')
      .send({ name: 'Q3 Launch', folder_id: FOLDER_ID });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ id: LIST_ID, folder_id: FOLDER_ID });
    const insertSql = poolMock.query.mock.calls[1][0] as string;
    expect(insertSql).toContain('INSERT INTO lists');
  });

  it('creates an ungrouped list (no folder)', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ ...listRow, folder_id: null }] });
    const res = await request(testApp()).post('/api/v1/lists').send({ name: 'Inbox' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ folder_id: null });
    // No ownership pre-check fired (only the INSERT).
    expect(poolMock.query).toHaveBeenCalledTimes(1);
  });

  it('rejects a list whose folder_id is not owned with 400', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] }); // ownership check finds nothing
    const res = await request(testApp())
      .post('/api/v1/lists')
      .send({ name: 'Q3 Launch', folder_id: FOLDER_ID });
    expect(res.status).toBe(400);
  });

  it('rejects an empty list name with 400 (no DB call)', async () => {
    const res = await request(testApp()).post('/api/v1/lists').send({ name: '' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('deletes a list and returns 204', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: LIST_ID }] });
    const res = await request(testApp()).delete(`/api/v1/lists/${LIST_ID}`);
    expect(res.status).toBe(204);
  });

  it('delete of a missing list returns 404', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).delete(`/api/v1/lists/${LIST_ID}`);
    expect(res.status).toBe(404);
  });
});
