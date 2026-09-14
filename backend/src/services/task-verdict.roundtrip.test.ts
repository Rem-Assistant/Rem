/**
 * End-to-end service proof for the task verdict carried by Rem's shared runtime.
 *
 * Only the runtime boundary is mocked. Prompt construction, the reporting-only policy,
 * verdict parsing, and the user-facing reply are production code. This intentionally
 * replaces the former fake-WebSocket test: task runs no longer touch an OpenClaw gateway.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const runSharedMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runSharedMock,
  runAgentTurn: vi.fn(),
}));

const { runAgentOnTask } = await import('./task-agent.service.js');
const { TASK_VERDICT_ENVELOPE_ID, TASK_VERDICT_TOOL_NAME } = await import('./task-verdict.js');

const TASK = {
  id: 'a1b2c3d4-0000-4000-8000-000000000001',
  title: 'File the renewal',
  status: 'pending',
};
const COMMENTS = [{ author_kind: 'user', author_label: 'Owner', body: 'any progress?' }];

function runtimeOpts(userId: string) {
  return {
    userId,
    authority: 'authenticated_user' as const,
    idempotencyKey: `dispatch-${userId}`,
  };
}

function sharedReply(text: string, toolCalls: unknown[] = []) {
  runSharedMock.mockResolvedValueOnce({
    ok: true,
    text,
    runId: 'rem-run-777',
    sessionKey: `rem-task-${TASK.id}`,
    toolCalls,
    provenance: {
      runtimeId: 'rem_shared',
      persistenceKind: 'rem_runtime',
      billingMode: 'rem_managed',
    },
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('task verdict round trip through Rem runtime', () => {
  it('dispatches under the authenticated owner with only the reporting capability', async () => {
    sharedReply('Investigated it.');

    await runAgentOnTask(TASK, COMMENTS, 'chase it', runtimeOpts('owner-42'));

    expect(runSharedMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: 'owner-42', authority: 'authenticated_user' },
      sessionKey: `rem-task-${TASK.id}`,
      idempotencyKey: 'dispatch-owner-42',
      toolPolicy: {
        mode: 'observe',
        allowedTools: [TASK_VERDICT_TOOL_NAME],
        approval: 'none',
      },
    }));
  });

  it('prefers a structured runtime report over the compatibility envelope', async () => {
    sharedReply(
      `Filed the renewal.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"blocked"}`,
      [{
        name: TASK_VERDICT_TOOL_NAME,
        toolCallId: 'call-1',
        args: { status: 'completed', confidence: 0.95 },
      }],
    );

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, runtimeOpts('owner-42'));

    expect(result).toMatchObject({
      reply: 'Filed the renewal.',
      proposedStatus: 'completed',
      confidence: 0.95,
      verdictSource: 'tool_call',
    });
  });

  it('carries the versioned verdict into the validated status and strips the machine line', async () => {
    sharedReply(
      `Filed the renewal.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"completed","confidence":0.95}`,
    );

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, runtimeOpts('owner-42'));

    expect(result).toMatchObject({
      reply: 'Filed the renewal.',
      proposedStatus: 'completed',
      confidence: 0.95,
      verdictSource: 'envelope',
      runtime: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime' },
    });
  });

  it('carries current task context without exposing it in the reply', async () => {
    sharedReply(
      `Waiting on the office.\n${TASK_VERDICT_ENVELOPE_ID} ` +
        '{"status":"in_progress","task_context":"Submitted 3 Aug; awaiting reference."}',
    );

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, runtimeOpts('owner-42'));

    expect(result.taskContext).toBe('Submitted 3 Aug; awaiting reference.');
    expect(result.reply).toBe('Waiting on the office.');
  });

  it('does not infer a verdict from status-like prose', async () => {
    sharedReply('The office said status: completed is not yet confirmed.');

    const result = await runAgentOnTask(TASK, COMMENTS, undefined, runtimeOpts('owner-42'));

    expect(result.proposedStatus).toBeUndefined();
    expect(result.verdictSource).toBe('none');
    expect(result.reply).toContain('status: completed');
  });
});
