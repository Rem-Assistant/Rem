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

const DIGEST_ID = '22222222-2222-4222-8222-222222222222';

const digestRow = {
  id: DIGEST_ID,
  kind: 'morning_brief',
  title: 'Your morning brief',
  body: 'You have 1 high-priority task.',
  source: 'fallback',
  model: null,
  created_at: '2026-06-26T13:00:00.000Z',
};

const digestsRoutes = (await import('./digests.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', digestsRoutes);
  return app;
}

describe('digests routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.GMI_API_KEY;
    delete process.env.GMI_AGENTBOX_URL;
  });

  it('lists digests newest-first', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [digestRow] });
    const res = await request(testApp()).get('/api/v1/digests');
    expect(res.status).toBe(200);
    expect(res.body.digests).toHaveLength(1);
    expect(res.body.digests[0]).toMatchObject({ id: DIGEST_ID, kind: 'morning_brief' });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('ORDER BY created_at DESC');
  });

  it('rejects an invalid kind filter with 400', async () => {
    const res = await request(testApp()).get('/api/v1/digests?kind=bogus');
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('returns 404 for a digest not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).get(`/api/v1/digests/${DIGEST_ID}`);
    expect(res.status).toBe(404);
  });

  it('run generates a fallback digest when no GMI env is set', async () => {
    poolMock.query
      // resolveUserTimezone: createDigestForUser resolves the user's local tz first so the day
      // window is their LOCAL day. It issues TWO reads — `users.timezone` (the device-persisted
      // value, migration 101) and then `user_checkins.timezone` as the fallback — and only the
      // first was mocked here, so every later expectation was off by one and the INSERT ran
      // against `undefined`. This test has been red on `staging` since the timezone persist
      // landed; it is a stale mock, not a route bug (see the query-order comment below).
      .mockResolvedValueOnce({ rows: [] }) // users.timezone → none
      .mockResolvedValueOnce({ rows: [] }) // user_checkins.timezone → none, so UTC
      // gatherDigestContext: events, open tasks, completed, comments
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [{ title: 'Ship digests', status: 'pending', priority: 'high', start_date: null, overdue: false }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      // generateDigest tries the user's gateway first (getGatewayCredentials): no gateway
      // configured → the row lacks gateway_url → runAgentTurnOnGateway returns no_gateway,
      // and (GMI unconfigured) we render the local fallback.
      .mockResolvedValueOnce({ rows: [{}] })
      // INSERT digest
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [
          {
            id: DIGEST_ID,
            kind: values[1],
            title: values[2],
            body: values[3],
            source: values[4],
            model: values[5],
            created_at: '2026-06-26T13:00:00.000Z',
          },
        ],
      }));

    const res = await request(testApp()).post('/api/v1/digests/run').send({ kind: 'morning_brief' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ kind: 'morning_brief', source: 'fallback' });
    expect(res.body.body).toContain('Ship digests');

    // Query order: [0..1] tz resolve, [2..5] gather, [6] gateway-credentials, [7] INSERT.
    const insertSql = poolMock.query.mock.calls[7][0] as string;
    expect(insertSql).toContain('INSERT INTO digests');
  });

  it('run resolves the local tz and buckets the digest by the user LOCAL day', async () => {
    // The user's most-recent check-in tz is Los Angeles. createDigestForUser must resolve it
    // and pass it through so gatherDigestContext scopes the SQL to the LA local day — the
    // regression this PR fixes (a behind-UTC user got the wrong UTC day's digest).
    poolMock.query
      // resolveUserTimezone → LA
      .mockResolvedValueOnce({ rows: [{ timezone: 'America/Los_Angeles' }] })
      // gatherDigestContext (events, open, completed, comments)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [{ title: 'Ship digests', status: 'pending', priority: 'high', start_date: null, overdue: false }] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      // getGatewayCredentials → no gateway → fallback
      .mockResolvedValueOnce({ rows: [{}] })
      // INSERT digest
      .mockResolvedValueOnce({ rows: [digestRow] });

    const res = await request(testApp()).post('/api/v1/digests/run').send({ kind: 'evening_recap' });
    expect(res.status).toBe(201);

    // The events query (calls[1]) must carry LA-local-day bounds, not UTC-day bounds. The exact
    // instants depend on "now", but the window start must be LA local midnight.
    const eventsParams = poolMock.query.mock.calls[1][1] as string[];
    const startLocal = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Los_Angeles', hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(new Date(eventsParams[1]));
    // LA local midnight formats as "00:00" (or "24:00" for midnight on some ICU builds).
    expect(['00:00', '24:00']).toContain(startLocal);
  });

  it('run rejects an invalid kind with 400', async () => {
    const res = await request(testApp()).post('/api/v1/digests/run').send({ kind: 'bogus' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('deletes a digest and returns 204', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: DIGEST_ID }] });
    const res = await request(testApp()).delete(`/api/v1/digests/${DIGEST_ID}`);
    expect(res.status).toBe(204);
  });

  it('delete of a missing digest returns 404', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp()).delete(`/api/v1/digests/${DIGEST_ID}`);
    expect(res.status).toBe(404);
  });
});
