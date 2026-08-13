import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { GatewayEventTap, GatewayResponse } from './gateway-pair.service.js';

// ─── Mocks ──────────────────────────────────────────────────────────────────
// gateway.service supplies creds + wake + setup password. Keep it minimal and
// always "ready" so the turn reaches the chat.send / event-capture path we test.
const getGatewayCredentialsMock = vi.hoisted(() => vi.fn());
const getSetupPasswordMock = vi.hoisted(() => vi.fn());
const wakeGatewayForUserMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway.service.js', () => ({
  getGatewayCredentials: getGatewayCredentialsMock,
  getSetupPassword: getSetupPasswordMock,
  wakeGatewayForUser: wakeGatewayForUserMock,
}));

// withGatewayRequester drives the operator socket. We stub it so the test can
// inject arbitrary `chat.send` acks and server-pushed `chat` events without a
// real WebSocket. `emit` lets a test push events AFTER the ack resolves.
type RequestFn = (method: string, params?: Record<string, unknown>) => Promise<GatewayResponse>;
type CallbackFn = (request: RequestFn, events: GatewayEventTap) => Promise<unknown>;

let ackResult: GatewayResponse = { ok: true, result: { runId: 'run-xyz' } };

const withGatewayRequesterMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway-pair.service.js', () => ({
  withGatewayRequester: withGatewayRequesterMock,
}));

const { runAgentTurnOnGateway, injectAssistantMessageOnGateway, readAssistantHistoryOnGateway, bareSessionKey, COLD_START_AGENT_TURN_TIMEOUT_MS, DEFAULT_AGENT_TURN_TIMEOUT_MS } =
  await import('./gateway-agent.service.js');

beforeEach(() => {
  vi.clearAllMocks();
  ackResult = { ok: true, result: { runId: 'run-xyz' } };
  getGatewayCredentialsMock.mockResolvedValue({
    gateway_url: 'https://remclaw-test.fly.dev',
    gateway_token: 'tok',
  });
  getSetupPasswordMock.mockResolvedValue('setup-pass');
  wakeGatewayForUserMock.mockResolvedValue({ gatewayReady: true });

  // Default requester: register the event tap and resolve the ack, but emit no
  // events (each test that needs a final overrides with mockImplementationOnce).
  withGatewayRequesterMock.mockImplementation(
    async (_url: string, _token: string, fn: CallbackFn) => {
      const request: RequestFn = async () => ackResult;
      const events: GatewayEventTap = { onEvent: () => {} };
      return fn(request, events);
    },
  );
});

describe('bareSessionKey', () => {
  it('strips the canonical agent:<id>: prefix', () => {
    expect(bareSessionKey('agent:main:rem-brief-20260704')).toBe('rem-brief-20260704');
    expect(bareSessionKey('agent:main:main')).toBe('main');
    expect(bareSessionKey('agent:custom:task-abc:sub')).toBe('task-abc:sub');
  });
  it('leaves already-bare keys unchanged', () => {
    expect(bareSessionKey('rem-brief-20260704')).toBe('rem-brief-20260704');
    expect(bareSessionKey('main')).toBe('main');
  });
});

describe('readAssistantHistoryOnGateway', () => {
  it('uses stored server-side credentials and returns only projected assistant identity fields', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (url: string, token: string, fn: CallbackFn) => {
        expect(url).toBe('https://remclaw-test.fly.dev');
        expect(token).toBe('tok');
        const request: RequestFn = async (method, params) => {
          expect(method).toBe('chat.history');
          expect(params).toEqual({ sessionKey: 'rem-orchestrator', limit: 500 });
          return {
            ok: true,
            result: {
              messages: [
                { role: 'user', content: [{ type: 'text', text: 'Private user text' }] },
                {
                  __openclaw: { id: 'message-1' },
                  role: 'assistant',
                  timestamp: 1_786_206_600_000,
                  content: [{ type: 'text', text: 'Verified brief prose' }],
                  rawSecret: 'must-not-project',
                },
                {
                  messageId: 'legacy-message-2',
                  role: 'assistant',
                  timestamp: 1_786_206_700_000,
                  content: [{ type: 'text', text: 'Legacy wrapper prose' }],
                },
              ],
            },
          };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(readAssistantHistoryOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
    })).resolves.toEqual({
      ok: true,
      messages: [{
        messageId: 'message-1',
        text: 'Verified brief prose',
        timestamp: 1_786_206_600_000,
      }, {
        messageId: 'legacy-message-2',
        text: 'Legacy wrapper prose',
        timestamp: 1_786_206_700_000,
      }],
    });
    expect(getGatewayCredentialsMock).toHaveBeenCalledWith('u1');
  });
});

describe('injectAssistantMessageOnGateway', () => {
  it('does not mistake identical prose from a prior artifact for this artifact', async () => {
    const artifactId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    const prepared: number[] = [];
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method, params) => {
          calls.push({ method, params });
          if (method === 'chat.history') {
            return {
              ok: true,
              result: {
                messages: [{
                  role: 'assistant',
                  content: [{ type: 'text', text: 'Prose' }],
                }],
              },
            };
          }
          return { ok: true, result: { messageId: 'new-message' } };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Prose',
      allowNonEmptySession: true,
      artifactId,
      reconciliationBaseline: 1,
      prepareArtifactAttempt: async (baseline) => {
        prepared.push(baseline);
        return true;
      },
    })).resolves.toEqual({ ok: true, messageId: 'new-message' });
    expect(calls.map((call) => call.method)).toEqual(['chat.history', 'chat.inject']);
    expect(prepared).toEqual([1]);
  });

  it('reconciles only when history has a new exact occurrence after the persisted baseline', async () => {
    const calls: string[] = [];
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method) => {
          calls.push(method);
          return {
            ok: true,
            result: {
              messages: [
                { role: 'assistant', content: [{ type: 'text', text: 'Prose' }] },
                { role: 'assistant', content: [{ type: 'text', text: 'Prose' }] },
              ],
            },
          };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Prose',
      allowNonEmptySession: true,
      artifactId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      reconciliationBaseline: 1,
      prepareArtifactAttempt: vi.fn(),
    })).resolves.toEqual({ ok: true, reconciled: true });
    expect(calls).toEqual(['chat.history']);
  });

  it('reconciles after an ambiguous requester failure instead of duplicating the artifact', async () => {
    const artifactId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const prepared: number[] = [];
    withGatewayRequesterMock
      .mockImplementationOnce(async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method) => {
          if (method === 'chat.history') {
            return {
              ok: true,
              result: {
                messages: [{ role: 'assistant', content: [{ type: 'text', text: 'Prose' }] }],
              },
            };
          }
          throw new Error('response lost after commit');
        };
        return fn(request, { onEvent: () => {} });
      })
      .mockImplementationOnce(async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({
          ok: true,
          result: {
            messages: [
              { role: 'assistant', content: [{ type: 'text', text: 'Prose' }] },
              { role: 'assistant', content: [{ type: 'text', text: 'Prose' }] },
            ],
          },
        });
        return fn(request, { onEvent: () => {} });
      });

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Prose',
      allowNonEmptySession: true,
      artifactId,
      prepareArtifactAttempt: async (baseline) => {
        prepared.push(baseline);
        return true;
      },
    })).resolves.toEqual({ ok: true, reconciled: true });
    expect(withGatewayRequesterMock).toHaveBeenCalledTimes(2);
    expect(prepared).toEqual([1]);
  });

  it('does not call chat.inject after the delivery lease is lost', async () => {
    const calls: string[] = [];
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method) => {
          calls.push(method);
          return { ok: true, result: { messages: [] } };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Prose',
      allowNonEmptySession: true,
      artifactId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      prepareArtifactAttempt: async () => false,
    })).resolves.toEqual({ ok: false, reason: 'delivery_lease_lost' });
    expect(calls).toEqual(['chat.history']);
  });

  it('appends a daily artifact to an existing durable session without recreating it', async () => {
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method, params) => {
          calls.push({ method, params });
          if (method === 'chat.history') {
            return { ok: true, result: { messages: [{ role: 'user', content: 'Yesterday' }] } };
          }
          return { ok: true, result: {} };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Today brief',
      allowNonEmptySession: true,
    })).resolves.toEqual({ ok: true });

    expect(calls.map((call) => call.method)).toEqual(['chat.history', 'chat.inject']);
    expect(calls[1]?.params).toEqual({
      sessionKey: 'rem-orchestrator',
      message: 'Today brief',
    });
  });

  it('sends no label or other rendered idempotency preamble for daily artifacts', async () => {
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async (method, params) => {
          calls.push({ method, params });
          if (method === 'chat.history') return { ok: true, result: { messages: [] } };
          return { ok: true, result: { messageId: 'message-1' } };
        };
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'rem-orchestrator',
      message: 'Today brief',
      allowNonEmptySession: true,
      artifactId: 'brief:2026-08-06:morning',
      prepareArtifactAttempt: async () => true,
    })).resolves.toEqual({ ok: true, messageId: 'message-1' });

    expect(calls.map((call) => call.method)).toEqual([
      'chat.history',
      'sessions.create',
      'chat.inject',
    ]);
    expect(calls.at(-1)?.params).toEqual({
      sessionKey: 'rem-orchestrator',
      message: 'Today brief',
    });
  });

  it('keeps the empty-only safety default for non-orchestrator callers', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({
          ok: true,
          result: { messages: [{ role: 'user', content: 'Already engaged' }] },
        });
        return fn(request, { onEvent: () => {} });
      },
    );

    await expect(injectAssistantMessageOnGateway({
      userId: 'u1',
      sessionKey: 'some-session',
      message: 'Do not append',
    })).resolves.toEqual({ ok: false, reason: 'session_not_empty' });
  });
});

describe('runAgentTurnOnGateway final-event capture', () => {
  // THE REGRESSION TEST: gateway broadcasts the CANONICAL session key while we
  // sent the bare one. Before the fix, the exact-match filter dropped this and
  // the turn timed out. Now it must resolve ok:true.
  it('captures a final whose sessionKey is canonicalized (agent:main:<key>)', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ackResult;
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        // Emit the canonical-key final on the next tick, after the ack lands.
        queueMicrotask(() => {
          handler?.('chat', {
            runId: 'run-xyz',
            sessionKey: 'agent:main:rem-brief-20260704',
            state: 'final',
            message: { content: [{ type: 'text', text: 'Your brief is ready.' }] },
          });
        });
        return fn(request, events);
      },
    );

    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'author the brief',
      sessionKey: 'rem-brief-20260704',
    });

    expect(result).toEqual({
      ok: true,
      text: 'Your brief is ready.',
      runId: 'run-xyz',
      sessionKey: 'rem-brief-20260704',
      toolCalls: [],
    });
  });

  it('captures a final that matches by runId even if the session key differs', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({ ok: true, result: { runId: 'run-abc' } });
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        queueMicrotask(() => {
          handler?.('chat', {
            runId: 'run-abc',
            sessionKey: 'agent:main:rem-brief-20260704',
            state: 'final',
            message: { text: 'Done via runId.' },
          });
        });
        return fn(request, events);
      },
    );

    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.text).toBe('Done via runId.');
  });

  // CONCURRENCY GUARD: two turns share the IDENTICAL session key (rem-brief-<date>
  // is fired by BOTH the daily cron AND every check-in). A DIFFERENT turn's final,
  // carrying a DIFFERENT runId, arrives BEFORE our chat.send ack resolves our runId.
  // We must NOT settle on it by session-key alone (that would hand a brief a digest's
  // content). We must capture ONLY the final whose runId matches our own ack.
  it('captures only the same-key final whose runId matches its own ack (pre-ack race)', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        let resolveAck: (r: GatewayResponse) => void = () => {};
        // Our chat.send ack is deferred so we control the send→ack window precisely.
        const ackPromise = new Promise<GatewayResponse>((r) => { resolveAck = r; });
        const request: RequestFn = async () => ackPromise;
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };

        queueMicrotask(() => {
          // 1) ANOTHER turn's final on the SAME session key, arriving PRE-ACK. Its
          //    runId is NOT ours — it must be ignored, never settle our turn.
          handler?.('chat', {
            runId: 'run-OTHER',
            sessionKey: 'agent:main:rem-brief-20260704',
            state: 'final',
            message: { text: 'DIGEST CONTENT — not our brief' },
          });
          // 2) OUR final on the same key, also pre-ack (a fast turn). Buffered by runId.
          handler?.('chat', {
            runId: 'run-OURS',
            sessionKey: 'agent:main:rem-brief-20260704',
            state: 'final',
            message: { text: 'Your brief is ready.' },
          });
          // 3) Now the ack lands, revealing OUR runId — the buffered matching final wins.
          resolveAck({ ok: true, result: { runId: 'run-OURS' } });
        });

        return fn(request, events);
      },
    );

    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'author the brief',
      sessionKey: 'rem-brief-20260704',
    });

    expect(result).toEqual({
      ok: true,
      text: 'Your brief is ready.',
      runId: 'run-OURS',
      sessionKey: 'rem-brief-20260704',
      toolCalls: [],
    });
  });

  it('ignores a final for a DIFFERENT session key', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({ ok: true, result: { runId: 'run-xyz' } });
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        queueMicrotask(() => {
          // Wrong runId AND wrong session — must NOT satisfy the turn.
          handler?.('chat', {
            runId: 'run-other',
            sessionKey: 'agent:main:rem-digest-morning-20260704',
            state: 'final',
            message: { text: 'not ours' },
          });
        });
        return fn(request, events);
      },
    );

    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
      timeoutMs: 40,
    });
    expect(result).toEqual({ ok: false, reason: 'timeout' });
  });

  it('surfaces a gateway error state', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({ ok: true, result: { runId: 'run-xyz' } });
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        queueMicrotask(() => {
          handler?.('chat', {
            runId: 'run-xyz',
            sessionKey: 'agent:main:rem-brief-20260704',
            state: 'error',
            errorMessage: 'model exploded',
          });
        });
        return fn(request, events);
      },
    );

    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
    });
    expect(result).toEqual({ ok: false, reason: 'error', message: 'model exploded' });
  });

  it('returns wake_failed when the gateway never becomes ready', async () => {
    wakeGatewayForUserMock.mockResolvedValueOnce({ gatewayReady: false });
    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
    });
    expect(result).toEqual({ ok: false, reason: 'wake_failed' });
  });

  it('returns no_gateway when the user has no gateway', async () => {
    getGatewayCredentialsMock.mockResolvedValueOnce(null);
    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
    });
    expect(result).toEqual({ ok: false, reason: 'no_gateway' });
  });
});

describe('cold-start turn budget', () => {
  /** Capture the `timeoutMs` sent on chat.send, emit an immediate final so the turn resolves. */
  function captureChatSendTimeout(): { get: () => number | undefined } {
    let captured: number | undefined;
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const request: RequestFn = async (_method, params) => {
          captured = params?.timeoutMs as number | undefined;
          queueMicrotask(() => {
            handler?.('chat', {
              runId: 'run-xyz',
              sessionKey: 'agent:main:rem-brief-20260704',
              state: 'final',
              message: { text: 'ok' },
            });
          });
          return ackResult;
        };
        const events: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        return fn(request, events);
      },
    );
    return { get: () => captured };
  }

  it('uses the larger COLD budget when the wake actually STARTED the machine', async () => {
    wakeGatewayForUserMock.mockResolvedValueOnce({ gatewayReady: true, action: 'start' });
    const cap = captureChatSendTimeout();
    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-brief-20260704' });
    expect(result.ok).toBe(true);
    expect(cap.get()).toBe(COLD_START_AGENT_TURN_TIMEOUT_MS);
  });

  it('uses the normal WARM budget when the gateway was already up (noop)', async () => {
    wakeGatewayForUserMock.mockResolvedValueOnce({ gatewayReady: true, action: 'noop' });
    const cap = captureChatSendTimeout();
    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-brief-20260704' });
    expect(result.ok).toBe(true);
    expect(cap.get()).toBe(DEFAULT_AGENT_TURN_TIMEOUT_MS);
  });

  it('honours an explicit coldStartTimeoutMs override on a cold wake', async () => {
    wakeGatewayForUserMock.mockResolvedValueOnce({ gatewayReady: true, action: 'start' });
    const cap = captureChatSendTimeout();
    const result = await runAgentTurnOnGateway({
      userId: 'u1',
      message: 'x',
      sessionKey: 'rem-brief-20260704',
      coldStartTimeoutMs: 200_000,
    });
    expect(result.ok).toBe(true);
    expect(cap.get()).toBe(200_000);
  });
});

/**
 * Tool-event capture. This is the transport half of the verdict contract
 * (`task-verdict.ts`): the gateway delivers a run's tool calls as `agent` events with
 * `stream:"tool"`, and those arguments were schema-validated by the gateway before the tool
 * ran. What the reader does with them is tested in `task-verdict.test.ts`; what is tested
 * here is that the right calls, and ONLY the right calls, reach it.
 */
describe('runAgentTurnOnGateway tool-event capture', () => {
  /** Drive a scripted sequence of server events over the real event tap. */
  function withEvents(events: Array<{ event: string; payload: Record<string, unknown> }>) {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const tap: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        const request: RequestFn = async () => {
          queueMicrotask(() => {
            for (const e of events) handler?.(e.event, e.payload);
          });
          return { ok: true, result: { runId: 'run-xyz' } };
        };
        return fn(request, tap);
      },
    );
  }

  const final = (runId = 'run-xyz') => ({
    event: 'chat',
    payload: {
      runId,
      sessionKey: 'agent:main:rem-task-1',
      state: 'final',
      message: { content: [{ type: 'text', text: 'done' }] },
    },
  });

  const tool = (data: Record<string, unknown>, runId = 'run-xyz') => ({
    event: 'agent',
    payload: { runId, stream: 'tool', sessionKey: 'agent:main:rem-task-1', data },
  });

  it("merges a tool call's start (args) and end (result) into ONE observed call", async () => {
    withEvents([
      tool({ phase: 'start', name: 'rem_task_report', toolCallId: 'c1', args: { status: 'completed' } }),
      tool({ phase: 'end', name: 'rem_task_report', toolCallId: 'c1', result: { ok: true } }),
      final(),
    ]);

    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-task-1' });

    expect(result.ok).toBe(true);
    expect(result.ok && result.toolCalls).toEqual([
      { name: 'rem_task_report', toolCallId: 'c1', args: { status: 'completed' }, result: { ok: true } },
    ]);
  });

  it('keeps invocation order across several tools', async () => {
    withEvents([
      tool({ phase: 'start', name: 'web_search', toolCallId: 'c1', args: { q: 'a' } }),
      tool({ phase: 'start', name: 'rem_task_report', toolCallId: 'c2', args: { status: 'blocked' } }),
      final(),
    ]);

    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-task-1' });
    expect(result.ok && result.toolCalls.map((c) => c.name)).toEqual(['web_search', 'rem_task_report']);
  });

  it('adopts tool events that arrived BEFORE the ack revealed our runId', async () => {
    // A tool call can be dispatched inside the send-to-ack window. Dropping those would lose
    // a verdict that did arrive - indistinguishable from an agent that never reported one.
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const tap: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        const request: RequestFn = () =>
          new Promise<GatewayResponse>((resolve) => {
            queueMicrotask(() => {
              handler?.('agent', {
                runId: 'run-OURS',
                stream: 'tool',
                sessionKey: 'agent:main:rem-task-1',
                data: { phase: 'start', name: 'rem_task_report', toolCallId: 'c1', args: { status: 'completed' } },
              });
              resolve({ ok: true, result: { runId: 'run-OURS' } });
              queueMicrotask(() => {
                handler?.('chat', {
                  runId: 'run-OURS',
                  sessionKey: 'agent:main:rem-task-1',
                  state: 'final',
                  message: { content: [{ type: 'text', text: 'done' }] },
                });
              });
            });
          });
        return fn(request, tap);
      },
    );

    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-task-1' });
    expect(result.ok && result.toolCalls).toEqual([
      { name: 'rem_task_report', toolCallId: 'c1', args: { status: 'completed' } },
    ]);
  });

  it('does NOT adopt a pre-ack tool event belonging to a different run', async () => {
    withGatewayRequesterMock.mockImplementationOnce(
      async (_url: string, _token: string, fn: CallbackFn) => {
        let handler: ((event: string, payload: unknown) => void) | null = null;
        const tap: GatewayEventTap = { onEvent: (h) => { handler = h; } };
        const request: RequestFn = () =>
          new Promise<GatewayResponse>((resolve) => {
            queueMicrotask(() => {
              handler?.('agent', {
                runId: 'run-THEIRS',
                stream: 'tool',
                sessionKey: 'agent:main:rem-task-1',
                data: { phase: 'start', name: 'rem_task_report', toolCallId: 'c1', args: { status: 'completed' } },
              });
              resolve({ ok: true, result: { runId: 'run-OURS' } });
              queueMicrotask(() => {
                handler?.('chat', {
                  runId: 'run-OURS',
                  sessionKey: 'agent:main:rem-task-1',
                  state: 'final',
                  message: { content: [{ type: 'text', text: 'done' }] },
                });
              });
            });
          });
        return fn(request, tap);
      },
    );

    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-task-1' });
    expect(result.ok && result.toolCalls).toEqual([]);
  });

  it('ignores non-tool agent streams', async () => {
    withEvents([
      {
        event: 'agent',
        payload: {
          runId: 'run-xyz',
          stream: 'lifecycle',
          sessionKey: 'agent:main:rem-task-1',
          data: { phase: 'start', name: 'x' },
        },
      },
      final(),
    ]);
    const result = await runAgentTurnOnGateway({ userId: 'u1', message: 'x', sessionKey: 'rem-task-1' });
    expect(result.ok && result.toolCalls).toEqual([]);
  });
});
