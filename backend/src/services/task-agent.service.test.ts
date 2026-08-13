/**
 * `task-agent.service` — the run's own behaviour, with the gateway turn stubbed.
 *
 * The end-to-end proof that a verdict survives the wire lives in
 * `task-verdict.roundtrip.test.ts`, which mocks only the socket. This file covers the
 * decisions this service makes on top of a turn it already has.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const runAgentTurnOnGatewayMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway-agent.service.js', () => ({
  runAgentTurnOnGateway: runAgentTurnOnGatewayMock,
}));

// Only the mode LOOKUP is stubbed; `blockCodeForGatewayFailure` stays real so the mapping this
// service depends on is exercised here, not mocked away.
const resolveModeMock = vi.hoisted(() => vi.fn());
vi.mock('./run-block.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./run-block.js')>()),
  resolveModelRuntimeMode: resolveModeMock,
}));

const { runAgentOnTask, resolveRunVerdict, buildUserPrompt, NO_GATEWAY_BODY } = await import(
  './task-agent.service.js'
);
const { TASK_VERDICT_ENVELOPE_ID, TASK_VERDICT_TOOL_NAME } = await import('./task-verdict.js');

const TASK = {
  id: 'b7f1e2a0-0000-4000-8000-000000000009',
  title: 'Renew the permit',
  status: 'pending',
  priority: 'high',
};
const COMMENTS = [{ author_kind: 'user', author_label: 'Owner', body: 'where are we' }];

beforeEach(() => {
  vi.clearAllMocks();
  resolveModeMock.mockResolvedValue('rem_managed');
  runAgentTurnOnGatewayMock.mockResolvedValue({
    ok: true,
    text: 'Had a look.',
    runId: 'r1',
    sessionKey: 'rem-task-x',
    toolCalls: [],
  });
});

describe('the prompt asks for the verdict, once, in one shared form', () => {
  it('sends the verdict instruction naming both carriers', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });

    const message = runAgentTurnOnGatewayMock.mock.calls[0][0].message as string;
    expect(message).toContain(TASK_VERDICT_TOOL_NAME);
    expect(message).toContain(TASK_VERDICT_ENVELOPE_ID);
    // The retired instruction must not linger beside the new one — two contracts in one
    // prompt is how `proposed_status:` came to mean three different things.
    expect(message).not.toMatch(/end your reply with a line `proposed_status/i);
  });

  it('threads the task title, prior comments and instruction into the prompt', () => {
    const prompt = buildUserPrompt(TASK, COMMENTS, 'chase the office');
    expect(prompt).toContain('Renew the permit');
    expect(prompt).toContain('where are we');
    expect(prompt).toContain('INSTRUCTION: chase the office');
  });
});

describe('runAgentOnTask routes to the owner, or does not run', () => {
  it('uses the caller-supplied session key so runs thread into one chat', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u9', sessionKey: 'rem-task-abc' });
    expect(runAgentTurnOnGatewayMock).toHaveBeenCalledWith(
      expect.objectContaining({ userId: 'u9', sessionKey: 'rem-task-abc' }),
    );
  });

  it('derives a per-task session key when the caller supplied none', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u9' });
    expect(runAgentTurnOnGatewayMock.mock.calls[0][0].sessionKey).toBe(`rem-task-${TASK.id}`);
  });

  it('returns an actionable, errored result — and starts no turn — without a userId', async () => {
    const result = await runAgentOnTask(TASK, COMMENTS);
    expect(result.reply).toBe(NO_GATEWAY_BODY);
    expect(result.errored).toBe(true);
    expect(result.verdictSource).toBe('none');
    expect(runAgentTurnOnGatewayMock).not.toHaveBeenCalled();
  });

  it('IGNORES opts.model, because chat.send has no model parameter', async () => {
    // Documented rather than silently dropped: a caller that still passes a routine's model
    // (#808) must not be able to believe it took effect.
    await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1', model: 'some-model' });
    const sent = runAgentTurnOnGatewayMock.mock.calls[0][0];
    expect(sent).not.toHaveProperty('model');
  });

  it('maps each gateway failure reason to an errored result with no verdict', async () => {
    for (const reason of ['no_gateway', 'wake_failed', 'timeout', 'error'] as const) {
      runAgentTurnOnGatewayMock.mockResolvedValueOnce({ ok: false, reason });
      const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
      expect(result.errored, reason).toBe(true);
      expect(result.proposedStatus, reason).toBeUndefined();
      expect(result.verdictSource, reason).toBe('none');
    }
  });

  it('degrades rather than throwing when the turn helper throws unexpectedly', async () => {
    runAgentTurnOnGatewayMock.mockRejectedValueOnce(new Error('socket exploded'));
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    expect(result.errored).toBe(true);
    expect(result.verdictSource).toBe('none');
  });
});

/**
 * THE CONTRACT THE UI WILL READ. The founder's requirement is that a run which cannot proceed
 * tells the user WHY and WHAT TO DO, in chat and in run history, with different remedies by
 * mode — and that the backend never ships the sentence. So every blocked run must carry a code
 * plus the mode, and a run that succeeded must carry neither.
 */
describe('runBlock — the structured reason a run did not happen', () => {
  it('carries a code AND the mode on every gateway failure reason', async () => {
    const expected = {
      no_gateway: 'runtime_unavailable',
      wake_failed: 'runtime_unavailable',
      timeout: 'runtime_timeout',
      error: 'runtime_error',
    } as const;
    for (const [reason, code] of Object.entries(expected)) {
      runAgentTurnOnGatewayMock.mockResolvedValueOnce({ ok: false, reason });
      const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
      expect(result.runBlock, reason).toEqual({ code, mode: 'rem_managed' });
    }
  });

  it('reports the BYOK mode so the client can say "fix your key", not "upgrade"', async () => {
    // The reason the mode travels WITH the code. `runtime_unavailable` on a Rem-managed account
    // and on a self-hosted one are the same failure with different owners; only the mode tells
    // the client which screen to send the user to.
    resolveModeMock.mockResolvedValue('byok');
    runAgentTurnOnGatewayMock.mockResolvedValueOnce({ ok: false, reason: 'wake_failed' });
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    expect(result.runBlock).toEqual({ code: 'runtime_unavailable', mode: 'byok' });
  });

  it('is ABSENT on a successful run, so "blocked" is never inferred from a stale field', async () => {
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    expect(result.errored).toBeFalsy();
    expect(result.runBlock).toBeUndefined();
  });

  it('reports mode unknown when there is no user to resolve a runtime for', async () => {
    // Without a userId there is no gateway record and nothing to assert. `unknown` is the
    // honest answer; claiming `rem_managed` here would tell a self-hosted user to buy Pro.
    const result = await runAgentOnTask(TASK, COMMENTS);
    expect(result.runBlock).toEqual({ code: 'runtime_unavailable', mode: 'unknown' });
    expect(resolveModeMock).not.toHaveBeenCalled();
  });

  it('still produces a block when the turn helper throws', async () => {
    runAgentTurnOnGatewayMock.mockRejectedValueOnce(new Error('socket exploded'));
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    expect(result.runBlock).toEqual({ code: 'runtime_error', mode: 'rem_managed' });
  });

  it('keeps the CODE when the mode resolves to unknown, rather than dropping the reason', async () => {
    // A degraded mode must not cost the client the diagnosis too. `resolveModelRuntimeMode`
    // returns `unknown` both for "no gateway on record" and for a lookup that failed (it never
    // throws), and in either case the code still has to arrive — otherwise a DB hiccup during a
    // timeout would surface as a blocked run with no reason at all.
    resolveModeMock.mockResolvedValue('unknown');
    runAgentTurnOnGatewayMock.mockResolvedValueOnce({ ok: false, reason: 'timeout' });
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' });
    expect(result.runBlock).toEqual({ code: 'runtime_timeout', mode: 'unknown' });
  });

  it('does not let a THROWN mode lookup take the run down with it', async () => {
    // The version of the above that actually fails the lookup. `runAgentOnTask` awaits the
    // resolver inside its own error path, so a rejection here would escape as an unhandled
    // rejection from a route that is contractually never-throws.
    resolveModeMock.mockRejectedValue(new Error('pool exhausted'));
    runAgentTurnOnGatewayMock.mockResolvedValueOnce({ ok: false, reason: 'timeout' });
    await expect(runAgentOnTask(TASK, COMMENTS, undefined, { userId: 'u1' })).resolves.toMatchObject({
      errored: true,
    });
  });
});

describe('resolveRunVerdict precedence', () => {
  it('lets the schema-validated tool call beat a disagreeing envelope', () => {
    const resolved = resolveRunVerdict({
      text: `Done.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"blocked"}`,
      toolCalls: [{ name: TASK_VERDICT_TOOL_NAME, args: { status: 'completed' } }],
    });
    expect(resolved.proposedStatus).toBe('completed');
    expect(resolved.verdictSource).toBe('tool_call');
  });

  it('falls back to the envelope when no tool call carried a verdict', () => {
    const resolved = resolveRunVerdict({
      text: `Done.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"blocked"}`,
      toolCalls: [{ name: 'web_search', args: { q: 'x' } }],
    });
    expect(resolved.proposedStatus).toBe('blocked');
    expect(resolved.verdictSource).toBe('envelope');
  });

  it('reports `none` — not a default status — when neither carrier spoke', () => {
    const resolved = resolveRunVerdict({ text: 'Looked into it.', toolCalls: [] });
    expect(resolved.proposedStatus).toBeUndefined();
    expect(resolved.verdictSource).toBe('none');
  });

  it('still honours the legacy task_context: marker line', () => {
    const resolved = resolveRunVerdict({
      text: 'Chased it.\ntask_context: Waiting on the reference number.',
      toolCalls: [],
    });
    expect(resolved.taskContext).toBe('Waiting on the reference number.');
    expect(resolved.reply).toBe('Chased it.');
  });

  it('never returns a body that is nothing but machine lines', () => {
    const resolved = resolveRunVerdict({
      text: `${TASK_VERDICT_ENVELOPE_ID} {"status":"completed"}`,
      toolCalls: [],
    });
    expect(resolved.reply.trim()).not.toBe('');
    expect(resolved.reply).not.toContain(TASK_VERDICT_ENVELOPE_ID);
  });
});
