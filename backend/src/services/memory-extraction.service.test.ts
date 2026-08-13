import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

const runAgentTurnMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway-agent.service.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./gateway-agent.service.js')>()),
  runAgentTurnOnGateway: runAgentTurnMock,
}));

import { extractNovelFactsForUser } from './memory-extraction.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-0000000000bb';
const NOW = new Date('2026-06-26T12:00:00.000Z');

/**
 * `gatherActivityContext` runs three SELECTs (open tasks, completed tasks, user comments).
 * Non-empty output is required or the service short-circuits before any runtime is consulted,
 * which would make every assertion below vacuously true.
 */
function mockActivity() {
  poolMock.query
    .mockResolvedValueOnce({
      rows: [{ title: 'Ship the brief', type: 'task', status: 'in_progress', priority: 'high' }],
    })
    .mockResolvedValueOnce({ rows: [] })
    .mockResolvedValueOnce({ rows: [] });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  delete process.env.GMI_API_KEY;
});

describe('extractNovelFactsForUser — one runtime, the user own gateway', () => {
  it('NEVER spends the operator key when the gateway fails, even with GMI configured and healthy', async () => {
    // THE REGRESSION. Extraction used to fall through to `gmiChat` on the org GMI_API_KEY when
    // the user's own gateway could not take the turn. For a user whose runtime is their own,
    // that wrote facts into their DURABLE memory that Rem paid a different provider to infer —
    // silently, on any transient wake failure. BYOK is a global per-user mode; #1327 removed the
    // identical fallback from task runs and this finishes the job.
    //
    // Setup is the friendliest possible case for the old behaviour: org key present, and a GMI
    // call that would have returned a usable fact. Restoring the fallback turns this red twice.
    process.env.GMI_API_KEY = 'k';
    mockActivity();
    runAgentTurnMock.mockResolvedValue({ ok: false, reason: 'wake_failed' });
    const fetchSpy = vi.fn(async () => ({
      ok: true,
      json: async () => ({ choices: [{ message: { content: '- Prefers mornings for deep work' } }] }),
    }));
    vi.stubGlobal('fetch', fetchSpy);

    const facts = await extractNovelFactsForUser(USER_ID, NOW, []);

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(facts).toEqual([]);
  });

  it('extracts nothing rather than throwing when there is no gateway at all', async () => {
    // `extract-memories.ts` counts a throw as a `failed` user and exits non-zero, which marks the
    // whole 15-minute cron run failed. A gateway-less user is not a failure, so this path has to
    // return [] — which is also why the script's GmiEmptyCompletionError branch could be deleted:
    // the condition it classified now resolves inside the service.
    mockActivity();
    runAgentTurnMock.mockResolvedValue({ ok: false, reason: 'no_gateway' });

    await expect(extractNovelFactsForUser(USER_ID, NOW, [])).resolves.toEqual([]);
  });

  it('still extracts from the gateway turn when it succeeds', async () => {
    // Removing the fallback must not remove the feature.
    mockActivity();
    runAgentTurnMock.mockResolvedValue({
      ok: true,
      text: '- Prefers mornings for deep work',
      runId: 'r1',
      sessionKey: 'rem-memory',
      toolCalls: [],
    });

    const facts = await extractNovelFactsForUser(USER_ID, NOW, []);

    expect(facts).toEqual(['Prefers mornings for deep work']);
    expect(runAgentTurnMock).toHaveBeenCalledTimes(1);
  });

  it('treats an empty gateway reply as "no durable facts", not an error', async () => {
    // What #906 bought with a catch clause is now structural: an empty turn parses to [].
    mockActivity();
    runAgentTurnMock.mockResolvedValue({
      ok: true,
      text: '',
      runId: 'r1',
      sessionKey: 'rem-memory',
      toolCalls: [],
    });

    await expect(extractNovelFactsForUser(USER_ID, NOW, [])).resolves.toEqual([]);
  });

  it('consults no runtime at all when there is nothing to summarize', async () => {
    poolMock.query.mockResolvedValue({ rows: [] });
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await expect(extractNovelFactsForUser(USER_ID, NOW, [])).resolves.toEqual([]);

    expect(runAgentTurnMock).not.toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
