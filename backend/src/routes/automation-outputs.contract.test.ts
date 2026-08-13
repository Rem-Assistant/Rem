import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * OUTPUTS contract test — the wire AND the discrimination.
 *
 * Two things are asserted here, and the second is the one that matters:
 *
 *  1. SHAPE: field names and JSON types, so a rename cannot silently break Swift decoding (the
 *     same failure mode `automation-inputs.contract.test.ts` was written for).
 *
 *  2. DISCRIMINATION: the same producer list must yield a DIFFERENT state when the observed fact
 *     changes. A test that only asserts "the row says Included" would pass just as happily against
 *     the hand-typed literal this route replaces — which is precisely how the old `.planned`
 *     survived a shipped suggestions producer. Every state assertion below is paired with the
 *     opposite fact producing the opposite state.
 */

const briefServiceMock = vi.hoisted(() => ({ gatherBrief: vi.fn() }));
const suggestionsServiceMock = vi.hoisted(() => ({ deriveSuggestions: vi.fn() }));
const briefAuthoringMock = vi.hoisted(() => ({ resolveUserTimezone: vi.fn() }));
const composioServiceMock = vi.hoisted(() => ({ listActiveToolkitSlugs: vi.fn() }));
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
vi.mock('../services/brief.service.js', () => briefServiceMock);
vi.mock('../services/suggestions.service.js', () => suggestionsServiceMock);
vi.mock('../services/brief-authoring.service.js', () => briefAuthoringMock);
vi.mock('../services/composio.service.js', () => composioServiceMock);
vi.mock('../db/pool.js', () => poolMock);

const automationsRoutes = (await import('./automations.routes.js')).default;
const {
  AUTOMATION_OUTPUT_KINDS,
  AUTOMATION_OUTPUT_STATES,
  PRODUCERS,
  deriveAutomationOutputs,
  deriveOutputState,
} = await import('../services/automation-outputs.service.js');

type OutputKind = (typeof AUTOMATION_OUTPUT_KINDS)[number];

function app() {
  const server = express();
  server.use('/api/v1', automationsRoutes);
  return server;
}

/** No authored artifact, nothing blocked/overdue, no suggestions — the "never produced" world. */
function seedEmptyWorld() {
  poolMock.pool.query.mockResolvedValue({ rows: [] });
  briefServiceMock.gatherBrief.mockResolvedValue({
    counts: { blocked: 0, overdue: 0, scheduled_today: 0, completed_today: 0, total: 0, done: 0 },
  });
  suggestionsServiceMock.deriveSuggestions.mockResolvedValue([]);
  briefAuthoringMock.resolveUserTimezone.mockResolvedValue('America/Los_Angeles');
}

async function fetchOutputs() {
  const response = await request(app()).get('/api/v1/automations/daily-brief/outputs');
  expect(response.status).toBe(200);
  return response.body.outputs as Array<Record<string, unknown>>;
}

function row(rows: Array<Record<string, unknown>>, output: OutputKind) {
  const found = rows.find((entry) => entry.output === output);
  expect(found, `no row for ${output}`).toBeDefined();
  return found!;
}

beforeEach(() => {
  vi.clearAllMocks();
  seedEmptyWorld();
});

describe('GET /automations/:kind/outputs — wire shape', () => {
  it('serves every registered output with the pinned field names and JSON types', async () => {
    const rows = await fetchOutputs();

    expect(rows.map((entry) => entry.output)).toEqual(PRODUCERS.map((p) => p.output));

    for (const entry of rows) {
      // `output` and `state` are STRINGS: the Swift models decode them with an
      // `unrecognized(String)` fallback, so a number or nested object breaks decoding outright.
      expect(typeof entry.output).toBe('string');
      expect(typeof entry.state).toBe('string');
      expect(AUTOMATION_OUTPUT_STATES).toContain(entry.state);
      expect(typeof entry.detail).toBe('string');
      expect((entry.detail as string).length).toBeGreaterThan(0);

      // Nullable in Swift → may be null, but never undefined and never the wrong type.
      expect(Object.hasOwn(entry, 'lastProducedAt')).toBe(true);
      expect(entry.lastProducedAt === null || typeof entry.lastProducedAt === 'string').toBe(true);
      expect(Object.hasOwn(entry, 'lastItemCount')).toBe(true);
      expect(entry.lastItemCount === null || typeof entry.lastItemCount === 'number').toBe(true);

      // Guards against a field the Swift model does not know about creeping onto the wire.
      expect(Object.keys(entry).sort()).toEqual(
        ['detail', 'lastItemCount', 'lastProducedAt', 'output', 'state'].sort(),
      );
    }
  });

  it('404s an unknown kind instead of guessing a contract', async () => {
    const response = await request(app()).get('/api/v1/automations/not-a-thing/outputs');
    expect(response.status).toBe(404);
    expect(typeof response.body.error).toBe('string');
  });
});

describe('state is derived from the observed fact, not written down', () => {
  /**
   * THE test. `task_suggestions` was hand-typed `.planned` in Swift while `deriveSuggestions`
   * was already producing tier-1 and tier-2 suggestions. A literal cannot move; this must.
   */
  it('flips task_suggestions between idle and included as the producer output changes', async () => {
    const idle = row(await fetchOutputs(), 'task_suggestions');
    expect(idle.state).toBe('idle');
    expect(idle.lastItemCount).toBe(0);

    suggestionsServiceMock.deriveSuggestions.mockResolvedValue([
      { key: 'gmail:1' },
      { key: 'overdue:2' },
    ]);

    const included = row(await fetchOutputs(), 'task_suggestions');
    expect(included.state).toBe('included');
    expect(included.lastItemCount).toBe(2);
    // The copy has to move with the state, or the row would contradict its own label.
    expect(included.detail).not.toBe(idle.detail);
  });

  it('flips attention_triage with the brief producer’s own blocked/overdue counts', async () => {
    expect(row(await fetchOutputs(), 'attention_triage').state).toBe('idle');

    briefServiceMock.gatherBrief.mockResolvedValue({
      counts: { blocked: 1, overdue: 2, scheduled_today: 0, completed_today: 0, total: 0, done: 0 },
    });

    const included = row(await fetchOutputs(), 'attention_triage');
    expect(included.state).toBe('included');
    expect(included.lastItemCount).toBe(3);
  });

  it('flips daily_orientation on the presence of a real authored artifact row', async () => {
    const never = row(await fetchOutputs(), 'daily_orientation');
    expect(never.state).toBe('idle');
    expect(never.lastProducedAt).toBeNull();

    poolMock.pool.query.mockResolvedValue({
      rows: [{ produced_at: new Date('2026-08-10T15:15:00.250Z') }],
    });

    const produced = row(await fetchOutputs(), 'daily_orientation');
    expect(produced.state).toBe('included');
    expect(produced.lastProducedAt).toBe('2026-08-10T15:15:00.250Z');
  });

  it('reads the brief timezone through the same chain the brief itself uses', async () => {
    await fetchOutputs();
    expect(briefServiceMock.gatherBrief).toHaveBeenCalledWith(
      'user-1',
      expect.any(Date),
      'America/Los_Angeles',
    );
    expect(suggestionsServiceMock.deriveSuggestions).toHaveBeenCalledWith(
      'user-1',
      expect.any(Date),
      'America/Los_Angeles',
    );
  });
});

describe('an unobservable producer degrades to idle, never to included', () => {
  it('reports idle when the suggestions producer throws', async () => {
    suggestionsServiceMock.deriveSuggestions.mockRejectedValue(new Error('db down'));

    const entry = row(await fetchOutputs(), 'task_suggestions');
    expect(entry.state).toBe('idle');
    expect(entry.lastItemCount).toBeNull();
  });

  it('keeps the other rows truthful when one producer fails', async () => {
    briefServiceMock.gatherBrief.mockRejectedValue(new Error('timeout'));
    suggestionsServiceMock.deriveSuggestions.mockResolvedValue([{ key: 'gmail:1' }]);

    const rows = await fetchOutputs();
    expect(row(rows, 'attention_triage').state).toBe('idle');
    expect(row(rows, 'task_suggestions').state).toBe('included');
  });
});

describe('pure derivation', () => {
  it('treats a real zero as a real answer and a missing record as never-produced', () => {
    expect(deriveOutputState({ output: 'task_suggestions', producedAt: null, itemCount: 3 }))
      .toBe('included');
    expect(deriveOutputState({ output: 'task_suggestions', producedAt: null, itemCount: 0 }))
      .toBe('idle');
    // No count to speak of → existence of a production record is the evidence.
    expect(deriveOutputState({ output: 'daily_orientation', producedAt: '2026-08-10T00:00:00Z', itemCount: null }))
      .toBe('included');
    expect(deriveOutputState({ output: 'daily_orientation', producedAt: null, itemCount: null }))
      .toBe('idle');
    expect(deriveOutputState(undefined)).toBe('idle');
  });

  it('derives coming_soon from ABSENCE from the producer list, and drops it when one registers', () => {
    const planned = [{ output: 'task_suggestions' as OutputKind, detail: 'Not wired yet.' }];
    const facts = new Map();

    const withoutProducer = deriveAutomationOutputs({ producers: [], factsByOutput: facts, planned });
    expect(withoutProducer).toHaveLength(1);
    expect(withoutProducer[0].state).toBe('coming_soon');

    const producer = PRODUCERS.find((p) => p.output === 'task_suggestions')!;
    const withProducer = deriveAutomationOutputs({
      producers: [producer],
      factsByOutput: facts,
      planned,
    });
    // Exactly one row — the roadmap entry must not double up with the derived one, which is how
    // the same surface could have shown a capability twice and disagreed with itself.
    expect(withProducer).toHaveLength(1);
    expect(withProducer[0].state).not.toBe('coming_soon');
  });

  it('never emits a state outside the pinned wire set', () => {
    for (const producer of PRODUCERS) {
      for (const fact of [
        undefined,
        { output: producer.output, producedAt: null, itemCount: 0 },
        { output: producer.output, producedAt: '2026-08-10T00:00:00Z', itemCount: 5 },
      ]) {
        const facts = new Map(fact ? [[producer.output, fact]] : []);
        const [entry] = deriveAutomationOutputs({ producers: [producer], factsByOutput: facts });
        expect(AUTOMATION_OUTPUT_STATES).toContain(entry.state);
      }
    }
  });
});
