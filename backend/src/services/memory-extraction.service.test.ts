import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

const runAgentTurnMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runAgentTurnMock,
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

describe('extractNovelFactsForUser — Rem-owned runtime', () => {
  it('does not bypass the Rem runtime with an unmetered direct provider call', async () => {
    process.env.GMI_API_KEY = 'k';
    mockActivity();
    runAgentTurnMock.mockResolvedValue({ ok: false, reason: 'unavailable' });
    const fetchSpy = vi.fn(async () => ({
      ok: true,
      json: async () => ({ choices: [{ message: { content: '- Prefers mornings for deep work' } }] }),
    }));
    vi.stubGlobal('fetch', fetchSpy);

    const facts = await extractNovelFactsForUser(USER_ID, NOW, []);

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(facts).toEqual([]);
  });

  it('extracts nothing rather than throwing when the Rem runtime is unavailable', async () => {
    // `extract-memories.ts` counts a throw as a `failed` user and exits non-zero, which marks the
    // whole 15-minute cron run failed. A gateway-less user is not a failure, so this path has to
    // return [] — which is also why the script's GmiEmptyCompletionError branch could be deleted:
    // the condition it classified now resolves inside the service.
    mockActivity();
    runAgentTurnMock.mockResolvedValue({ ok: false, reason: 'unavailable' });

    await expect(extractNovelFactsForUser(USER_ID, NOW, [])).resolves.toEqual([]);
  });

  it('extracts through a tenant-scoped, tool-free Rem runtime turn', async () => {
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
    expect(runAgentTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: USER_ID, authority: 'internal_service' },
      sessionKey: 'rem-memory-20260626',
      idempotencyKey: expect.stringMatching(/^rem-memory:[a-f0-9-]{36}$/),
      toolPolicy: { mode: 'observe', allowedTools: [], approval: 'none' },
    }));
  });

  it('returns no facts when loading the shared runtime rejects', async () => {
    mockActivity();
    runAgentTurnMock.mockRejectedValue(new Error('module unavailable'));
    await expect(extractNovelFactsForUser(USER_ID, NOW, [])).resolves.toEqual([]);
  });

  it('treats an empty runtime reply as "no durable facts", not an error', async () => {
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
