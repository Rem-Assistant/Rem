/**
 * `task-agent.service` — the run's own behaviour, with the Rem runtime stubbed.
 *
 * The end-to-end proof that a verdict survives the wire lives in
 * `task-verdict.roundtrip.test.ts`, which mocks only the socket. This file covers the
 * decisions this service makes on top of a turn it already has.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const runAgentTurnMock = vi.hoisted(() => vi.fn());
const runLegacyTurnMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runAgentTurnMock,
  runAgentTurn: runLegacyTurnMock,
}));

const { runAgentOnTask, resolveRunVerdict, buildUserPrompt, runtimeFailureBody, NO_RUNTIME_BODY } = await import(
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
  runAgentTurnMock.mockResolvedValue({
    ok: true,
    text: 'Had a look.',
    runId: 'r1',
    sessionKey: 'rem-task-x',
    toolCalls: [],
    provenance: provenance(),
  });
  runLegacyTurnMock.mockResolvedValue({
    ok: true,
    text: 'Legacy BYOK result.',
    runId: 'legacy-1',
    sessionKey: 'rem-task-x',
    toolCalls: [],
    provenance: {
      runtimeId: 'openclaw_gateway',
      persistenceKind: 'gateway',
      billingMode: 'byok',
    },
  });
});

function provenance(billingMode: 'rem_managed' | 'byok' | 'unknown' = 'rem_managed') {
  return {
    runtimeId: 'rem_shared' as const,
    persistenceKind: 'rem_runtime' as const,
    billingMode,
  };
}

function authorizedOpts(userId: string, extra: Record<string, unknown> = {}) {
  return {
    userId,
    authority: 'authenticated_user' as const,
    idempotencyKey: `dispatch-${userId}`,
    ...extra,
  };
}

describe('the prompt asks for the verdict, once, in one shared form', () => {
  it('sends the verdict instruction naming both carriers', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));

    const message = runAgentTurnMock.mock.calls[0][0].message as string;
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
  it('forwards caller-established authority and idempotency with a reporting-only policy', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, {
      userId: 'u9',
      authority: 'authenticated_user',
      idempotencyKey: 'dispatch-9',
    });
    expect(runAgentTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: 'u9', authority: 'authenticated_user' },
      idempotencyKey: 'dispatch-9',
      toolPolicy: {
        mode: 'observe',
        allowedTools: [TASK_VERDICT_TOOL_NAME],
        approval: 'none',
      },
    }));
  });

  it('keeps an explicitly tool-bearing transitional caller on its existing adapter', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, {
      ...authorizedOpts('u9'),
      authority: 'trusted_automation',
      toolPolicy: { mode: 'act', allowedTools: ['*'], approval: 'automation_policy' },
    });

    expect(runAgentTurnMock).not.toHaveBeenCalled();
    expect(runLegacyTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: 'u9', authority: 'trusted_automation' },
      toolPolicy: { mode: 'act', allowedTools: ['*'], approval: 'automation_policy' },
    }));
  });

  it('uses the caller-supplied session key so runs thread into one chat', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u9', { sessionKey: 'rem-task-abc' }));
    expect(runAgentTurnMock).toHaveBeenCalledWith(
      expect.objectContaining({
        principal: { userId: 'u9', authority: 'authenticated_user' },
        sessionKey: 'rem-task-abc',
      }),
    );
  });

  it('derives a per-task session key when the caller supplied none', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u9'));
    expect(runAgentTurnMock.mock.calls[0][0].sessionKey).toBe(`rem-task-${TASK.id}`);
  });

  it('returns an actionable, errored result — and starts no turn — without a userId', async () => {
    const result = await runAgentOnTask(TASK, COMMENTS);
    expect(result.reply).toBe(NO_RUNTIME_BODY);
    expect(result.errored).toBe(true);
    expect(result.verdictSource).toBe('none');
    expect(runAgentTurnMock).not.toHaveBeenCalled();
  });

  it('forwards model selection to the Rem-owned boundary', async () => {
    await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1', { model: 'some-model' }));
    const sent = runAgentTurnMock.mock.calls[0][0];
    expect(sent.model).toBe('some-model');
  });

  it('retains exact Rem report identity for the audited task-update proposal', async () => {
    runAgentTurnMock.mockResolvedValueOnce({
      ok: true,
      text: '',
      runId: 'runtime-run-1',
      sessionKey: `rem-task-${TASK.id}`,
      toolCalls: [{
        name: TASK_VERDICT_TOOL_NAME,
        toolCallId: 'report-call-1',
        args: { status: 'completed', comment: 'The permit is renewed.' },
      }],
      provenance: provenance(),
    });

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));

    expect(result.taskUpdateProposal).toEqual({
      runtimeRunId: 'runtime-run-1', toolCallId: 'report-call-1',
    });
    expect(result.proposedStatus).toBe('completed');
  });

  it('does not turn a text envelope into Rem tool execution authority', async () => {
    runAgentTurnMock.mockResolvedValueOnce({
      ok: true,
      text: `Done.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"completed"}`,
      runId: 'runtime-run-1',
      sessionKey: `rem-task-${TASK.id}`,
      toolCalls: [],
      provenance: provenance(),
    });

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));

    expect(result.proposedStatus).toBe('completed');
    expect(result.taskUpdateProposal).toBeUndefined();
  });

  it('falls back to the transitional adapter only for a proven BYOK account', async () => {
    runAgentTurnMock.mockResolvedValueOnce({
      ok: false,
      reason: 'unavailable',
      provenance: provenance('byok'),
    });

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1', {
      allowLegacyByokFallback: true,
      legacyByokFallbackSessionKey: 'openclaw-manual-task-abc',
    }));

    expect(runLegacyTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: 'u1', authority: 'authenticated_user' },
      sessionKey: 'openclaw-manual-task-abc',
      toolPolicy: { mode: 'act', allowedTools: ['*'], approval: 'interactive_user' },
    }));
    expect(result.runtime?.persistenceKind).toBe('gateway');
  });

  it('does not enter the acting BYOK adapter unless the caller explicitly allows it', async () => {
    runAgentTurnMock.mockResolvedValueOnce({
      ok: false,
      reason: 'unavailable',
      provenance: provenance('byok'),
    });

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1', {
      allowLegacyByokFallback: false,
    }));

    expect(runLegacyTurnMock).not.toHaveBeenCalled();
    expect(result).toMatchObject({
      errored: true,
      runBlock: { code: 'runtime_unavailable', mode: 'byok' },
    });
  });

  it('maps each runtime failure reason to an errored result with no verdict', async () => {
    for (const reason of [
      'unavailable',
      'startup_failed',
      'quota_exhausted',
      'credential_rejected',
      'timeout',
      'cancelled',
      'error',
    ] as const) {
      runAgentTurnMock.mockResolvedValueOnce({ ok: false, reason, provenance: provenance() });
      const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
      expect(result.errored, reason).toBe(true);
      expect(result.proposedStatus, reason).toBeUndefined();
      expect(result.verdictSource, reason).toBe('none');
    }
  });

  it('degrades rather than throwing when the turn helper throws unexpectedly', async () => {
    runAgentTurnMock.mockRejectedValueOnce(new Error('socket exploded'));
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
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
  it('carries a code AND the mode on every runtime failure reason', async () => {
    const expected = {
      unavailable: 'runtime_unavailable',
      startup_failed: 'runtime_unavailable',
      quota_exhausted: 'quota_exhausted',
      credential_rejected: 'credential_rejected',
      timeout: 'runtime_timeout',
      cancelled: 'runtime_error',
      error: 'runtime_error',
    } as const;
    for (const [reason, code] of Object.entries(expected)) {
      runAgentTurnMock.mockResolvedValueOnce({ ok: false, reason, provenance: provenance() });
      const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
      expect(result.runBlock, reason).toEqual({ code, mode: 'rem_managed' });
    }
  });

  it('gives current clients actionable quota and credential recovery prose', () => {
    expect(runtimeFailureBody('quota_exhausted')).toContain('Upgrade or wait');
    expect(runtimeFailureBody('credential_rejected')).toContain('Rem’s model provider credential');
    expect(runtimeFailureBody('credential_rejected')).not.toContain('Settings');
  });

  it('reports the BYOK mode so the client can say "fix your key", not "upgrade"', async () => {
    // The reason the mode travels WITH the code. `runtime_unavailable` on a Rem-managed account
    // and on a self-hosted one are the same failure with different owners; only the mode tells
    // the client which screen to send the user to.
    runAgentTurnMock.mockResolvedValueOnce({
      ok: false,
      reason: 'startup_failed',
      provenance: provenance('byok'),
    });
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
    expect(result.runBlock).toEqual({ code: 'runtime_unavailable', mode: 'byok' });
  });

  it('is ABSENT on a successful run, so "blocked" is never inferred from a stale field', async () => {
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
    expect(result.errored).toBeFalsy();
    expect(result.runBlock).toBeUndefined();
  });

  it('reports mode unknown when there is no user to resolve a runtime for', async () => {
    // Without a userId there is no authenticated runtime principal. `unknown` is the
    // honest answer; claiming `rem_managed` here would tell a self-hosted user to buy Pro.
    const result = await runAgentOnTask(TASK, COMMENTS);
    expect(result.runBlock).toEqual({ code: 'runtime_unavailable', mode: 'unknown' });
  });

  it('still produces a block when the turn helper throws', async () => {
    runAgentTurnMock.mockRejectedValueOnce(new Error('socket exploded'));
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
    expect(result.runBlock).toEqual({ code: 'runtime_error', mode: 'unknown' });
  });

  it('keeps the CODE when the mode resolves to unknown, rather than dropping the reason', async () => {
    // A degraded mode must not cost the client the diagnosis too. `resolveModelRuntimeMode`
    // returns `unknown` when payer ownership cannot be resolved (it never
    // throws), and in either case the code still has to arrive — otherwise a DB hiccup during a
    // timeout would surface as a blocked run with no reason at all.
    runAgentTurnMock.mockResolvedValueOnce({
      ok: false,
      reason: 'timeout',
      provenance: provenance('unknown'),
    });
    const result = await runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'));
    expect(result.runBlock).toEqual({ code: 'runtime_timeout', mode: 'unknown' });
  });

  it('uses the runtime result as the single source of billing mode', async () => {
    runAgentTurnMock.mockResolvedValueOnce({
      ok: false,
      reason: 'timeout',
      provenance: provenance('unknown'),
    });
    await expect(runAgentOnTask(TASK, COMMENTS, undefined, authorizedOpts('u1'))).resolves.toMatchObject({
      runBlock: { code: 'runtime_timeout', mode: 'unknown' },
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

  it('uses the report comment for a tool-only actionable reply', () => {
    const resolved = resolveRunVerdict({
      text: '',
      toolCalls: [{
        name: TASK_VERDICT_TOOL_NAME,
        args: { status: 'completed', comment: 'The permit is renewed.' },
      }],
    });
    expect(resolved.reply).toBe('The permit is renewed.');
    expect(resolved.proposedStatus).toBe('completed');
    expect(resolved.verdictSource).toBe('tool_call');
  });

  it('strips a conflicting machine marker embedded in the report comment', () => {
    const resolved = resolveRunVerdict({
      text: '',
      toolCalls: [{
        name: TASK_VERDICT_TOOL_NAME,
        args: {
          status: 'completed',
          comment: `The permit is renewed.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"blocked"}`,
        },
      }],
    });
    expect(resolved.reply).toBe('The permit is renewed.');
    expect(resolved.reply).not.toContain(TASK_VERDICT_ENVELOPE_ID);
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
