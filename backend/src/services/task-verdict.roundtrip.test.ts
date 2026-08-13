/**
 * THE ROUND TRIP. Does a run's status verdict actually survive the trip from the gateway
 * to the value the route applies?
 *
 * MOCKED HERE: only the network boundary — `gateway-pair.service` (the WebSocket) and
 * `gateway.service` (credentials + wake). Everything between the wire and the verdict is the
 * REAL code: the real `runAgentTurnOnGateway` event tap, the real tool-event correlation, the
 * real `runAgentOnTask`, the real `task-verdict` readers. A test that mocked
 * `runAgentTurnOnGateway` would prove that a mock returns what it was told to return.
 *
 * The assertions are on IDENTITY, not on shape: a specific status that is NOT the task's
 * current status, arriving on a specific carrier, from a specific runId. "A verdict came
 * back" is exactly the kind of green signal that stays green while the verdict is being
 * dropped — so nothing here asserts merely that a field is defined.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { GatewayEventTap, GatewayResponse } from './gateway-pair.service.js';

const getGatewayCredentialsMock = vi.hoisted(() => vi.fn());
const getSetupPasswordMock = vi.hoisted(() => vi.fn());
const wakeGatewayForUserMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway.service.js', () => ({
  getGatewayCredentials: getGatewayCredentialsMock,
  getSetupPassword: getSetupPasswordMock,
  wakeGatewayForUser: wakeGatewayForUserMock,
}));

const withGatewayRequesterMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway-pair.service.js', () => ({
  withGatewayRequester: withGatewayRequesterMock,
}));

const { runAgentOnTask } = await import('./task-agent.service.js');
const { TASK_VERDICT_ENVELOPE_ID, TASK_VERDICT_TOOL_NAME } = await import('./task-verdict.js');

type RequestFn = (method: string, params?: Record<string, unknown>) => Promise<GatewayResponse>;
type CallbackFn = (request: RequestFn, events: GatewayEventTap) => Promise<unknown>;

const TASK = { id: 'a1b2c3d4-0000-4000-8000-000000000001', title: 'File the renewal', status: 'pending' };
const COMMENTS = [{ author_kind: 'user', author_label: 'Owner', body: 'any progress?' }];
const RUN_ID = 'run-777';

/**
 * Stand up a fake gateway that acks `chat.send` and then pushes the given server events, in
 * order, on the SAME tap the production code registers. `emit` runs after the ack resolves,
 * which is the ordering a real turn has.
 */
function fakeGateway(events: Array<{ event: string; payload: Record<string, unknown> }>) {
  withGatewayRequesterMock.mockImplementation(
    async (_url: string, _token: string, fn: CallbackFn) => {
      let push: ((event: string, payload: unknown) => void) | null = null;
      const tap: GatewayEventTap = { onEvent: (h) => { push = h; } };
      const request: RequestFn = async (method) => {
        if (method !== 'chat.send') return { ok: true, result: {} };
        // Deliver the events on the next tick, after chat.send's ack has resolved.
        queueMicrotask(() => {
          for (const e of events) push?.(e.event, e.payload);
        });
        return { ok: true, result: { runId: RUN_ID } };
      };
      return fn(request, tap);
    },
  );
}

function toolEvent(name: string, args: unknown, runId = RUN_ID) {
  return {
    event: 'agent',
    payload: {
      runId,
      stream: 'tool',
      sessionKey: `agent:main:rem-task-${TASK.id}`,
      seq: 1,
      data: { phase: 'start', name, toolCallId: 'call-1', args },
    },
  };
}

function finalEvent(text: string, runId = RUN_ID) {
  return {
    event: 'chat',
    payload: {
      runId,
      sessionKey: `agent:main:rem-task-${TASK.id}`,
      seq: 2,
      state: 'final',
      message: { role: 'assistant', content: [{ type: 'text', text }] },
    },
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  getGatewayCredentialsMock.mockResolvedValue({
    gateway_url: 'https://remclaw-test.fly.dev',
    gateway_token: 'tok',
  });
  getSetupPasswordMock.mockResolvedValue('setup-pass');
  wakeGatewayForUserMock.mockResolvedValue({ gatewayReady: true, action: 'noop' });
});

describe('verdict round trip — tool call (the structured carrier)', () => {
  it('carries a status the prose never mentions, from the tool call to proposedStatus', async () => {
    // The prose deliberately contains NO status word at all. If this test passes, the value
    // came off the tool call and nowhere else.
    fakeGateway([
      toolEvent(TASK_VERDICT_TOOL_NAME, { status: 'blocked', confidence: 0.8 }),
      finalEvent('I could not go further without the reference number.'),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, {
      userId: 'u1',
      sessionKey: `rem-task-${TASK.id}`,
    });

    expect(result.proposedStatus).toBe('blocked');
    expect(result.confidence).toBe(0.8);
    expect(result.verdictSource).toBe('tool_call');
    expect(result.errored).toBeUndefined();
    expect(result.reply).toBe('I could not go further without the reference number.');
  });

  it('prefers the tool call over an envelope that disagrees with it', async () => {
    // Both carriers present, DIFFERENT statuses. Asserting the winner by identity is the
    // only way this test can tell the precedence rule is real.
    fakeGateway([
      toolEvent(TASK_VERDICT_TOOL_NAME, { status: 'completed' }),
      finalEvent(`Done.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"in_progress"}`),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.proposedStatus).toBe('completed');
    expect(result.verdictSource).toBe('tool_call');
    // The losing envelope line is still removed from what the user reads.
    expect(result.reply).toBe('Done.');
  });

  it('ignores a tool call belonging to a DIFFERENT run on the same session key', async () => {
    // Two turns can share a session key (`rem-task-<id>` is stable across runs). A verdict
    // donated by someone else's run would be applied to this user's task.
    fakeGateway([
      toolEvent(TASK_VERDICT_TOOL_NAME, { status: 'completed' }, 'run-SOMEONE-ELSE'),
      finalEvent('Looked into it, nothing to change yet.'),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
  });

  it('ignores a tool call that is not the verdict tool', async () => {
    fakeGateway([
      toolEvent('web_search', { status: 'completed', query: 'renewal deadline' }),
      finalEvent('Searched for the deadline.'),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
  });
});

describe('verdict round trip — envelope (the carrier that is live today)', () => {
  it('carries the status off the machine line and strips the line from the comment', async () => {
    fakeGateway([
      finalEvent(
        `Renewal filed and confirmed.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"completed","confidence":0.95}`,
      ),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.proposedStatus).toBe('completed');
    expect(result.confidence).toBe(0.95);
    expect(result.verdictSource).toBe('envelope');
    expect(result.reply).toBe('Renewal filed and confirmed.');
    // The machine line must never reach the activity feed.
    expect(result.reply).not.toContain(TASK_VERDICT_ENVELOPE_ID);
  });

  it('does NOT treat prose that discusses a status as a verdict', async () => {
    // This is the exact input the deleted `parseProposedStatusFromText` regex read as a
    // decision: it matched `status:` followed by a keyword ANYWHERE in the prose.
    fakeGateway([
      finalEvent('I asked them whether the status: completed flag was ever set, still waiting.'),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
    // …and the sentence survives intact, because it is prose, not a marker.
    expect(result.reply).toContain('status: completed');
  });

  it('carries task_context off the verdict so the next run does not start from zero', async () => {
    fakeGateway([
      finalEvent(
        `Chased it up.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"in_progress","task_context":"Form submitted 3 Aug; awaiting a reference number."}`,
      ),
    ]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.taskContext).toBe('Form submitted 3 Aug; awaiting a reference number.');
    expect(result.proposedStatus).toBe('in_progress');
  });
});

describe('verdict round trip — the dispatch itself', () => {
  it('runs the turn on the OWNER\'S gateway, under the task\'s stable session key', async () => {
    // The whole point of the change: the run is billed to the user whose task it is.
    fakeGateway([finalEvent('Had a look.')]);

    await runAgentOnTask(TASK, COMMENTS, 'chase it', {
      userId: 'owner-42',
      sessionKey: `rem-task-${TASK.id}`,
    });

    expect(getGatewayCredentialsMock).toHaveBeenCalledWith('owner-42');
    const sent = withGatewayRequesterMock.mock.calls[0];
    expect(sent[0]).toBe('https://remclaw-test.fly.dev');
  });

  it('refuses to run — and charges nobody — when the user has no gateway', async () => {
    getGatewayCredentialsMock.mockResolvedValue(null);
    fakeGateway([finalEvent('unreachable')]);

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    expect(result.errored).toBe(true);
    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
    expect(withGatewayRequesterMock).not.toHaveBeenCalled();
  });

  it('never falls back to a shared key: no userId means no run at all', async () => {
    const result = await runAgentOnTask(TASK, COMMENTS);

    expect(result.errored).toBe(true);
    expect(result.verdictSource).toBe('none');
    expect(getGatewayCredentialsMock).not.toHaveBeenCalled();
    expect(withGatewayRequesterMock).not.toHaveBeenCalled();
  });

  it('reports a timed-out turn as errored with no verdict', async () => {
    // Ack, but no final event ever arrives.
    withGatewayRequesterMock.mockImplementation(
      async (_url: string, _token: string, fn: CallbackFn) => {
        const request: RequestFn = async () => ({ ok: true, result: { runId: RUN_ID } });
        return fn(request, { onEvent: () => {} });
      },
    );
    vi.useFakeTimers();
    const pending = runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    await vi.advanceTimersByTimeAsync(130_000);
    const result = await pending;
    vi.useRealTimers();

    expect(result.errored).toBe(true);
    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
  });
});
