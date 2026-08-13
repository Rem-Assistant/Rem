import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * CROSS-LAYER CONTRACT TEST — the wire, not the values.
 *
 * A previous multi-lane run shipped a backend serving `{id, ...}` against a client that required a
 * non-optional `provider`. The whole payload failed to decode and the screen never left its error
 * state. Neither side's own tests could see it: both asserted on VALUES, and a rename does not
 * change any value.
 *
 * So this file asserts SHAPE. It drives the real router, the real derivation and the real
 * `res.json` serializer over a mocked DB + Composio, then checks the parsed HTTP body against a
 * declarative table of field NAMES and JSON TYPES. Renaming `source` to `provider`, dropping
 * `connector`, adding a field the Swift model does not know, or widening `state` beyond the four
 * pinned strings all fail here.
 *
 * Swift decoding rules this table encodes:
 *   - `capability` / `state` are STRINGS (decoded with an `unrecognized(String)` fallback), never
 *     numbers and never a nested object — a newer server must not break an older client.
 *   - every field marked `*-or-null` is Optional in Swift; a field NOT marked so must never be null.
 *   - no field is renamed between layers: `source` is `source` in the manifest, in the descriptor,
 *     and on the wire.
 */

const composioServiceMock = vi.hoisted(() => ({
  listActiveToolkitSlugs: vi.fn(),
}));
const poolMock = vi.hoisted(() => ({ pool: { query: vi.fn() } }));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (
    req: express.Request & { userId?: string },
    _res: express.Response,
    next: express.NextFunction,
  ) => {
    req.userId = 'user-1';
    next();
  },
}));
vi.mock('../services/composio.service.js', () => composioServiceMock);
vi.mock('../db/pool.js', () => poolMock);

const automationsRoutes = (await import('./automations.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', automationsRoutes);
  return app;
}

/** The pinned Inputs row. Key set and JSON types are the contract. */
const ROW_CONTRACT = {
  capability: 'string',
  state: 'string',
  detail: 'string',
  connector: 'object-or-null',
  lastCollectedAt: 'string-or-null',
  lastItemCount: 'number-or-null',
  lastUnavailableReason: 'string-or-null',
} as const;

/** The pinned connector attribution object. */
const CONNECTOR_CONTRACT = {
  source: 'string',
  displayName: 'string',
} as const;

const PINNED_STATES = ['included', 'not_connected', 'unavailable', 'coming_soon'];
const PINNED_CAPABILITIES = ['rem_tasks', 'rem_calendar_items', 'connector', 'cloud_browser'];

type FieldKind = 'string' | 'number' | 'object-or-null' | 'string-or-null' | 'number-or-null';

function assertFieldKind(path: string, value: unknown, kind: FieldKind): void {
  const nullable = kind.endsWith('-or-null');
  if (value === null) {
    expect(nullable, `${path} was null but the contract says it is non-optional`).toBe(true);
    return;
  }
  expect(value, `${path} must never be undefined — Swift decodes a missing key as a failure`)
    .not.toBeUndefined();
  const base = kind.replace('-or-null', '');
  expect(typeof value, `${path} must serialize as a JSON ${base}`).toBe(base);
}

function assertExactShape(
  path: string,
  value: unknown,
  contract: Record<string, FieldKind>,
): void {
  expect(typeof value, `${path} must be a JSON object`).toBe('object');
  const record = value as Record<string, unknown>;
  // Exact key set: catches a RENAME (old key gone, new key present), a DROP, and an ADD.
  expect(Object.keys(record).sort(), `${path} key set drifted from the pinned contract`)
    .toEqual(Object.keys(contract).sort());
  for (const [field, kind] of Object.entries(contract)) {
    assertFieldKind(`${path}.${field}`, record[field], kind);
  }
}

/** One artifact manifest row as `readLastCollectFacts` selects it. */
function manifestRow(overrides: Record<string, unknown> = {}) {
  return {
    source: 'gmail',
    availability: 'unavailable',
    unavailable_reason: 'connector_unavailable',
    manifest_captured_at: '2026-08-09T13:00:00Z',
    column_captured_at: null,
    item_count: 0,
    ...overrides,
  };
}

async function getInputs(kind = 'daily-brief') {
  return request(testApp()).get(`/api/v1/automations/${kind}/inputs`);
}

beforeEach(() => {
  vi.clearAllMocks();
  poolMock.pool.query.mockResolvedValue({ rows: [] });
  composioServiceMock.listActiveToolkitSlugs.mockResolvedValue([]);
});

describe('GET /api/v1/automations/:kind/inputs — wire contract', () => {
  it('returns an { inputs: [...] } envelope and nothing else', async () => {
    const response = await getInputs();
    expect(response.status).toBe(200);
    expect(Object.keys(response.body)).toEqual(['inputs']);
    expect(Array.isArray(response.body.inputs)).toBe(true);
    expect(response.body.inputs.length).toBeGreaterThan(0);
  });

  it('gives every row the exact pinned key set and JSON types', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    poolMock.pool.query.mockResolvedValue({ rows: [manifestRow()] });
    const response = await getInputs();
    response.body.inputs.forEach((row: unknown, index: number) => {
      assertExactShape(`inputs[${index}]`, row, ROW_CONTRACT);
    });
  });

  it('gives every connector object the exact pinned key set and JSON types', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    const response = await getInputs();
    const connectors = response.body.inputs.filter(
      (row: { connector: unknown }) => row.connector !== null,
    );
    expect(connectors.length).toBeGreaterThan(0);
    connectors.forEach((row: { connector: unknown }, index: number) => {
      assertExactShape(`inputs[${index}].connector`, row.connector, CONNECTOR_CONTRACT);
    });
  });

  it('serializes capability and state as strings drawn from the pinned vocabularies', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    poolMock.pool.query.mockResolvedValue({ rows: [manifestRow()] });
    const response = await getInputs();
    for (const row of response.body.inputs as Array<{ capability: string; state: string }>) {
      expect(typeof row.state).toBe('string');
      expect(typeof row.capability).toBe('string');
      expect(PINNED_STATES).toContain(row.state);
      expect(PINNED_CAPABILITIES).toContain(row.capability);
    }
  });

  it('never renames `source` between the manifest, the descriptor and the wire', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    poolMock.pool.query.mockResolvedValue({ rows: [manifestRow({ source: 'gmail' })] });
    const response = await getInputs();
    const row = (response.body.inputs as Array<{ connector: { source?: string } | null }>)
      .find((candidate) => candidate.connector !== null);
    expect(row?.connector?.source).toBe('gmail');
    // The rename that broke the last run: `source` reappearing as `provider` / `id` / `slug`.
    expect(row?.connector).not.toHaveProperty('provider');
    expect(row?.connector).not.toHaveProperty('id');
    expect(row?.connector).not.toHaveProperty('slug');
  });

  it('emits lastCollectedAt as an ISO 8601 instant a Swift decoder can parse', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    // Non-fractional seconds in, canonical ISO out — both forms must survive the round trip.
    poolMock.pool.query.mockResolvedValue({
      rows: [manifestRow({ manifest_captured_at: '2026-08-09T13:00:00Z' })],
    });
    const response = await getInputs();
    const row = (response.body.inputs as Array<{ connector: unknown; lastCollectedAt: string | null }>)
      .find((candidate) => candidate.connector !== null);
    expect(row?.lastCollectedAt).toBe('2026-08-09T13:00:00.000Z');
    expect(Number.isNaN(Date.parse(row?.lastCollectedAt ?? ''))).toBe(false);
  });

  it('keeps the nullable fields null rather than omitting them', async () => {
    const response = await getInputs();
    const remTasks = (response.body.inputs as Array<Record<string, unknown>>)
      .find((row) => row.capability === 'rem_tasks');
    // Present-and-null, not absent: an absent key is a decode failure for a non-optional Swift
    // property and indistinguishable from a rename for everything else.
    expect(remTasks).toHaveProperty('connector', null);
    expect(remTasks).toHaveProperty('lastCollectedAt', null);
    expect(remTasks).toHaveProperty('lastItemCount', null);
    expect(remTasks).toHaveProperty('lastUnavailableReason', null);
  });
});

describe('GET /api/v1/automations/:kind/inputs — behavior', () => {
  it('derives state from the observed facts rather than a stored value', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockResolvedValue(['gmail']);
    poolMock.pool.query.mockResolvedValue({ rows: [manifestRow()] });
    const unavailable = await getInputs();
    expect(
      (unavailable.body.inputs as Array<{ capability: string; state: string }>)
        .find((row) => row.capability === 'connector')?.state,
    ).toBe('unavailable');

    // Same user, same code path — only the observed facts change.
    poolMock.pool.query.mockResolvedValue({ rows: [] });
    const included = await getInputs();
    expect(
      (included.body.inputs as Array<{ capability: string; state: string }>)
        .find((row) => row.capability === 'connector')?.state,
    ).toBe('included');
  });

  it('scopes the read to the authenticated caller', async () => {
    await getInputs();
    expect(poolMock.pool.query.mock.calls[0][1][0]).toBe('user-1');
    expect(composioServiceMock.listActiveToolkitSlugs.mock.calls[0][0]).toBe('user-1');
  });

  it('404s an unknown kind instead of guessing a contract', async () => {
    const response = await getInputs('weekly-digest');
    expect(response.status).toBe(404);
    expect(response.body.inputs).toBeUndefined();
    expect(poolMock.pool.query).not.toHaveBeenCalled();
  });

  it('still answers when the connection authority is unreachable', async () => {
    composioServiceMock.listActiveToolkitSlugs.mockRejectedValue(new Error('composio down'));
    const response = await getInputs();
    expect(response.status).toBe(200);
    // A failed lookup is `unavailable` — "we could not check" — never `not_connected`, which is a
    // positive claim about the user's setup that we have no evidence for.
    expect(
      (response.body.inputs as Array<{ capability: string; state: string }>)
        .find((row) => row.capability === 'connector')?.state,
    ).toBe('unavailable');
  });

  it('500s without leaking internals when provenance cannot be read', async () => {
    poolMock.pool.query.mockRejectedValue(new Error('connection terminated: host=db-primary'));
    const response = await getInputs();
    expect(response.status).toBe(500);
    expect(response.body).toEqual({ error: 'failed to load automation inputs' });
  });
});
