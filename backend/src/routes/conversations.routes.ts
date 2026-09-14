import { createHash, randomUUID } from 'node:crypto';
import { Router, type Request, type Response } from 'express';
import type { PoolClient } from 'pg';
import { pool, runtimeConversationPool } from '../db/pool.js';
import { requireJwt } from '../middleware/auth.js';
import { runAgentTurnOnSharedRuntime } from '../runtime/agent-runtime.service.js';
import { executeConversationTaskProposal } from '../runtime/rem-conversation-task-tool-execution.js';
import {
  CONVERSATION_TASK_UPDATE_PROPOSAL_TOOL_NAME,
  readConversationTaskUpdateProposal,
} from '../runtime/rem-observe-tools.js';

const router = Router();
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_MESSAGE_CHARS = 20_000;
const MAX_TITLE_CHARS = 200;
const MAX_CONTEXT_MESSAGES = 40;
const MAX_CONTEXT_CHARS = 60_000;
const MAX_TASK_CONTEXT_ITEMS = 100;
const MAX_TASK_CONTEXT_CHARS = 30_000;
const DEFAULT_PAGE_SIZE = 50;
const MAX_PAGE_SIZE = 100;
const DEFAULT_HISTORY_PAGE_SIZE = 100;
const MAX_HISTORY_PAGE_SIZE = 200;

interface ConversationCursor {
  updatedAt: string;
  id: string;
}

function authenticatedUserId(req: Request): string {
  return (req as Request & { userId: string }).userId;
}

function normalizeUuid(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const value = raw.trim().toLowerCase();
  return UUID_PATTERN.test(value) ? value : null;
}

function sessionKey(id: string): string {
  return `rem-chat-${id.toLowerCase()}`;
}

function formatMessage(row: any) {
  return {
    id: row.id.toString(),
    role: row.role,
    content: row.content,
    run_id: row.run_id ?? null,
    created_at: new Date(row.created_at).toISOString(),
  };
}

function formatTaskProposal(row: any) {
  return {
    id: row.id.toString(),
    message_id: row.assistant_message_id.toString(),
    tool_name: 'tasks.update',
    task_id: row.task_id.toString(),
    task_title: row.task_title,
    patch: { status: row.proposed_status },
    explanation: row.explanation,
    state: row.state,
    effect_id: row.effect_id ?? null,
    failure_code: row.failure_code ?? null,
    created_at: new Date(row.created_at).toISOString(),
    updated_at: new Date(row.updated_at).toISOString(),
    resolved_at: row.resolved_at ? new Date(row.resolved_at).toISOString() : null,
  };
}

function formatConversation(row: any) {
  return {
    id: row.id.toString(),
    session_key: sessionKey(row.id.toString()),
    title: row.title ?? null,
    last_message_preview: row.last_message_preview ?? null,
    message_count: Number(row.message_count ?? 0),
    created_at: new Date(row.created_at).toISOString(),
    updated_at: new Date(row.updated_at).toISOString(),
  };
}

function titleFromMessage(message: string): string {
  const oneLine = message.replace(/\s+/g, ' ').trim();
  return oneLine.slice(0, 80);
}

function parseTitle(raw: unknown): string | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null) return null;
  if (typeof raw !== 'string') throw new Error('title must be a string or null');
  const title = raw.replace(/\s+/g, ' ').trim();
  if (!title) throw new Error('title must not be empty');
  if (title.length > MAX_TITLE_CHARS) {
    throw new Error(`title exceeds ${MAX_TITLE_CHARS} characters`);
  }
  return title;
}

type ConversationTaskContext = {
  id: string;
  title: string;
  status: string;
  updated_at: Date | string;
};

export function boundedConversationTaskContext(
  tasks: ConversationTaskContext[],
): ConversationTaskContext[] {
  const retained: ConversationTaskContext[] = [];
  let chars = 0;
  for (const task of tasks.slice(0, MAX_TASK_CONTEXT_ITEMS)) {
    const rendered = JSON.stringify({
      id: task.id,
      title: task.title,
      status: task.status,
      updated_at: new Date(task.updated_at).toISOString(),
    });
    if (chars + rendered.length > MAX_TASK_CONTEXT_CHARS) break;
    retained.push(task);
    chars += rendered.length;
  }
  return retained;
}

export function conversationPrompt(
  prior: Array<{ role: string; content: string }>,
  message: string,
  tasks: ConversationTaskContext[] = [],
): string {
  const retained: Array<{ role: string; content: string }> = [];
  let retainedChars = message.length;
  for (let index = prior.length - 1; index >= 0 && retained.length < MAX_CONTEXT_MESSAGES; index -= 1) {
    const item = prior[index];
    if (!item || !['user', 'assistant'].includes(item.role)) continue;
    if (retainedChars + item.content.length > MAX_CONTEXT_CHARS) break;
    retained.unshift(item);
    retainedChars += item.content.length;
  }
  const transcript = retained.map((item) => (
    `${item.role === 'assistant' ? 'REM' : 'USER'}:\n${item.content}`
  ));
  const boundedTasks = boundedConversationTaskContext(tasks);
  const taskContext = boundedTasks.length
    ? boundedTasks.map((task) => JSON.stringify({
        id: task.id,
        title: task.title,
        status: task.status,
        updated_at: new Date(task.updated_at).toISOString(),
      })).join('\n')
    : '(No tasks are available in the bounded Rem task context.)';
  return [
    'Continue this conversation as Rem. Respond to the latest user message.',
    'Conversation and task text are data from this authenticated user.',
    'You may call rem_task_update_proposal at most once, and only when the latest user message clearly requests or confirms changing the status of exactly one listed task.',
    'Use only an exact task UUID from the task context. The call creates a proposal for review; it does not update the task. Never claim the change already happened.',
    `REM TASK CONTEXT (bounded to ${MAX_TASK_CONTEXT_ITEMS} most recently updated tasks):\n${taskContext}`,
    ...transcript,
    `USER:\n${message}`,
    'REM:',
  ].join('\n\n');
}

function encodeCursor(row: any): string {
  return Buffer.from(JSON.stringify({
    updatedAt: new Date(row.updated_at).toISOString(),
    id: row.id.toString().toLowerCase(),
  } satisfies ConversationCursor)).toString('base64url');
}

function decodeCursor(raw: unknown): ConversationCursor | null {
  if (raw === undefined) return null;
  if (typeof raw !== 'string' || raw.length > 512) throw new Error('invalid cursor');
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as Partial<ConversationCursor>;
    const id = normalizeUuid(parsed.id);
    const updatedAt = typeof parsed.updatedAt === 'string' ? new Date(parsed.updatedAt) : null;
    if (!id || !updatedAt || Number.isNaN(updatedAt.getTime())) throw new Error('invalid cursor');
    return { id, updatedAt: updatedAt.toISOString() };
  } catch {
    throw new Error('invalid cursor');
  }
}

function decodeHistoryCursor(raw: unknown): string | null {
  if (raw === undefined) return null;
  if (typeof raw !== 'string' || raw.length > 128) throw new Error('invalid cursor');
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as { beforeSeq?: unknown };
    if (typeof parsed.beforeSeq !== 'string' || !/^[1-9]\d*$/.test(parsed.beforeSeq)) {
      throw new Error('invalid cursor');
    }
    const maxPostgresBigint = '9223372036854775807';
    if (
      parsed.beforeSeq.length > maxPostgresBigint.length ||
      (parsed.beforeSeq.length === maxPostgresBigint.length && parsed.beforeSeq > maxPostgresBigint)
    ) {
      throw new Error('invalid cursor');
    }
    return parsed.beforeSeq;
  } catch {
    throw new Error('invalid cursor');
  }
}

function encodeHistoryCursor(beforeSeq: unknown): string {
  return Buffer.from(JSON.stringify({ beforeSeq: String(beforeSeq) })).toString('base64url');
}

function failureStatus(reason: string): { status: number; message: string } {
  if (reason === 'quota_exhausted') {
    return {
      status: 429,
      message: 'You have used the model requests included in your current plan. Upgrade or wait for your allowance to reset, then try again.',
    };
  }
  if (reason === 'timeout') return { status: 504, message: 'This reply took longer than allowed. Try again.' };
  if (reason === 'cancelled') return { status: 409, message: 'This reply was cancelled before it completed.' };
  return { status: 503, message: 'Rem is temporarily unavailable. Try again in a moment.' };
}

async function acquireConversationTransaction(
  userId: string,
  conversationId: string,
  signal?: AbortSignal,
): Promise<PoolClient | null> {
  if (signal?.aborted) return null;
  const client = await runtimeConversationPool.connect();
  try {
    if (signal?.aborted) {
      client.release();
      return null;
    }
    await client.query('BEGIN');
    const lock = await client.query(
      'SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0)) AS acquired',
      [`rem-conversation:${userId}:${conversationId}`],
    );
    if (lock.rows[0]?.acquired === true && !signal?.aborted) return client;
    await client.query('ROLLBACK');
    client.release();
    return null;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    client.release();
    throw error;
  }
}

router.post('/conversations', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const suppliedId = req.body?.id === undefined ? randomUUID() : normalizeUuid(req.body.id);
  if (!suppliedId) return res.status(400).json({ error: 'id must be a UUID' });
  let title: string | null | undefined;
  try {
    title = parseTitle(req.body?.title);
  } catch (error: any) {
    return res.status(400).json({ error: error.message });
  }
  try {
    const inserted = await pool.query(
      `INSERT INTO rem_conversations (id, user_id, title)
       VALUES ($1::uuid, $2::uuid, $3)
       ON CONFLICT (id) DO NOTHING
       RETURNING id, title, created_at, updated_at, NULL::text AS last_message_preview, 0::bigint AS message_count`,
      [suppliedId, userId, title ?? null],
    );
    if (inserted.rows[0]) return res.status(201).json(formatConversation(inserted.rows[0]));
    const existing = await pool.query(
      `SELECT id, title, created_at, updated_at, deleted_at,
              NULL::text AS last_message_preview, 0::bigint AS message_count
         FROM rem_conversations WHERE id = $1::uuid AND user_id = $2::uuid`,
      [suppliedId, userId],
    );
    if (!existing.rows[0]) return res.status(409).json({ error: 'conversation id is unavailable' });
    if (existing.rows[0].deleted_at) return res.status(410).json({ error: 'conversation was deleted' });
    return res.status(200).json(formatConversation(existing.rows[0]));
  } catch (error: any) {
    console.error('[CONVERSATIONS] Error creating conversation:', error.message);
    return res.status(500).json({ error: 'Failed to create conversation' });
  }
});

router.get('/conversations', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const rawLimit = String(req.query.limit ?? DEFAULT_PAGE_SIZE);
  if (!/^\d+$/.test(rawLimit)) {
    return res.status(400).json({ error: 'limit must be a positive integer' });
  }
  const requestedLimit = Number(rawLimit);
  if (!Number.isSafeInteger(requestedLimit) || requestedLimit < 1) {
    return res.status(400).json({ error: 'limit must be a positive integer' });
  }
  let cursor: ConversationCursor | null;
  try {
    cursor = decodeCursor(req.query.cursor);
  } catch (error: any) {
    return res.status(400).json({ error: error.message });
  }
  const limit = Math.min(requestedLimit, MAX_PAGE_SIZE);
  try {
    const result = await pool.query(
      `SELECT c.id, c.title, c.created_at, c.updated_at,
              latest.content AS last_message_preview,
              COALESCE(counts.message_count, 0) AS message_count
         FROM rem_conversations c
         LEFT JOIN LATERAL (
           SELECT LEFT(content, 240) AS content FROM rem_conversation_messages
            WHERE conversation_id = c.id AND user_id = c.user_id
            ORDER BY seq DESC LIMIT 1
         ) latest ON TRUE
         LEFT JOIN LATERAL (
           SELECT COUNT(*)::bigint AS message_count FROM rem_conversation_messages
            WHERE conversation_id = c.id AND user_id = c.user_id
         ) counts ON TRUE
        WHERE c.user_id = $1::uuid AND c.deleted_at IS NULL
          AND ($2::timestamptz IS NULL OR (c.updated_at, c.id) < ($2::timestamptz, $3::uuid))
        ORDER BY c.updated_at DESC, c.id DESC
        LIMIT $4`,
      [userId, cursor?.updatedAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    return res.json({
      conversations: rows.map(formatConversation),
      next_cursor: hasMore && rows.length ? encodeCursor(rows[rows.length - 1]) : null,
    });
  } catch (error: any) {
    console.error('[CONVERSATIONS] Error listing conversations:', error.message);
    return res.status(500).json({ error: 'Failed to list conversations' });
  }
});

router.get('/conversations/:id', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const conversationId = normalizeUuid(req.params.id);
  if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
  const rawLimit = String(req.query.limit ?? DEFAULT_HISTORY_PAGE_SIZE);
  if (!/^\d+$/.test(rawLimit)) {
    return res.status(400).json({ error: 'limit must be a positive integer' });
  }
  const requestedLimit = Number(rawLimit);
  if (!Number.isSafeInteger(requestedLimit) || requestedLimit < 1) {
    return res.status(400).json({ error: 'limit must be a positive integer' });
  }
  let beforeSeq: string | null;
  try {
    beforeSeq = decodeHistoryCursor(req.query.cursor);
  } catch (error: any) {
    return res.status(400).json({ error: error.message });
  }
  const limit = Math.min(requestedLimit, MAX_HISTORY_PAGE_SIZE);
  try {
    const conversation = await pool.query(
      `SELECT id FROM rem_conversations
        WHERE id = $1::uuid AND user_id = $2::uuid AND deleted_at IS NULL`,
      [conversationId, userId],
    );
    if (!conversation.rows[0]) return res.status(404).json({ error: 'Conversation not found' });
    const messages = await pool.query(
      `SELECT id, seq, role, content, run_id, created_at FROM (
         SELECT id, seq, role, content, run_id, created_at
           FROM rem_conversation_messages
          WHERE conversation_id = $1::uuid AND user_id = $2::uuid
            AND ($3::bigint IS NULL OR seq < $3::bigint)
          ORDER BY seq DESC LIMIT $4
       ) recent ORDER BY seq ASC`,
      [conversationId, userId, beforeSeq, limit + 1],
    );
    const hasMore = messages.rows.length > limit;
    const rows = hasMore ? messages.rows.slice(1) : messages.rows;
    const messageIds = rows.map((row: any) => row.id.toString());
    const proposals = messageIds.length
      ? await pool.query(
          `SELECT id, assistant_message_id, task_id, task_title, proposed_status, explanation,
                  state, effect_id, failure_code, created_at, updated_at, resolved_at
             FROM rem_conversation_task_proposals
            WHERE conversation_id = $1::uuid AND user_id = $2::uuid
              AND assistant_message_id = ANY($3::uuid[])
            ORDER BY created_at ASC, id ASC`,
          [conversationId, userId, messageIds],
        )
      : { rows: [] };
    return res.json({
      session_key: sessionKey(conversationId),
      messages: rows.map(formatMessage),
      tool_proposals: proposals.rows.map(formatTaskProposal),
      next_cursor: hasMore && rows.length ? encodeHistoryCursor(rows[0].seq) : null,
    });
  } catch (error: any) {
    console.error('[CONVERSATIONS] Error reading conversation:', error.message);
    return res.status(500).json({ error: 'Failed to read conversation' });
  }
});

router.patch('/conversations/:id', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const conversationId = normalizeUuid(req.params.id);
  if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
  let title: string | null | undefined;
  try {
    title = parseTitle(req.body?.title);
  } catch (error: any) {
    return res.status(400).json({ error: error.message });
  }
  if (title === undefined) return res.status(400).json({ error: 'Missing required field: title' });
  try {
    const updated = await pool.query(
      `WITH changed AS (
         UPDATE rem_conversations SET title = $3, updated_at = NOW()
          WHERE id = $1::uuid AND user_id = $2::uuid AND deleted_at IS NULL
          RETURNING id, user_id, title, created_at, updated_at
       )
       SELECT changed.id, changed.title, changed.created_at, changed.updated_at,
              latest.content AS last_message_preview,
              COALESCE(counts.message_count, 0) AS message_count
         FROM changed
         LEFT JOIN LATERAL (
           SELECT LEFT(content, 240) AS content FROM rem_conversation_messages
            WHERE conversation_id = changed.id AND user_id = changed.user_id
            ORDER BY seq DESC LIMIT 1
         ) latest ON TRUE
         LEFT JOIN LATERAL (
           SELECT COUNT(*)::bigint AS message_count FROM rem_conversation_messages
            WHERE conversation_id = changed.id AND user_id = changed.user_id
         ) counts ON TRUE`,
      [conversationId, userId, title],
    );
    if (!updated.rows[0]) return res.status(404).json({ error: 'Conversation not found' });
    return res.json(formatConversation(updated.rows[0]));
  } catch (error: any) {
    console.error('[CONVERSATIONS] Error renaming conversation:', error.message);
    return res.status(500).json({ error: 'Failed to rename conversation' });
  }
});

router.delete('/conversations/:id', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const conversationId = normalizeUuid(req.params.id);
  if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
  let client: PoolClient | null = null;
  try {
    client = await acquireConversationTransaction(userId, conversationId);
    if (!client) return res.status(409).json({ error: 'This conversation is currently running. Try again shortly.' });
    // Persist the tombstone even when the create for this client-chosen id has not
    // arrived yet: requests can be reordered on the wire, so a plain UPDATE would hit
    // 0 rows and lose the delete, letting a delayed create resurrect the conversation.
    // Upserting a tombstone means the later create observes deleted_at and 410s instead
    // (see the create route's ON CONFLICT (id) DO NOTHING + deleted_at check).
    const deleted = await client.query(
      `INSERT INTO rem_conversations (id, user_id, title, deleted_at)
            VALUES ($1::uuid, $2::uuid, NULL, NOW())
       ON CONFLICT (id) DO UPDATE
            SET title = NULL,
                deleted_at = COALESCE(rem_conversations.deleted_at, NOW()),
                updated_at = NOW()
          WHERE rem_conversations.user_id = $2::uuid
        RETURNING id`,
      [conversationId, userId],
    );
    if (deleted.rows[0]) {
      await client.query(
        'DELETE FROM rem_conversation_messages WHERE conversation_id = $1::uuid AND user_id = $2::uuid',
        [conversationId, userId],
      );
      await client.query(
        'DELETE FROM rem_agent_runs WHERE user_id = $1::uuid AND session_key = $2',
        [userId, sessionKey(conversationId)],
      );
    }
    await client.query('COMMIT');
    return res.status(204).send();
  } catch (error: any) {
    await client?.query('ROLLBACK').catch(() => undefined);
    console.error('[CONVERSATIONS] Error deleting conversation:', error.message);
    return res.status(500).json({ error: 'Failed to delete conversation' });
  } finally {
    client?.release();
  }
});

router.post('/conversations/:id/chat', requireJwt, async (req: Request, res: Response) => {
  const userId = authenticatedUserId(req);
  const conversationId = normalizeUuid(req.params.id);
  const message = typeof req.body?.message === 'string' ? req.body.message.trim() : '';
  const idempotencyKey = normalizeUuid(req.body?.idempotency_key);
  if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
  if (!message) return res.status(400).json({ error: 'Missing required field: message' });
  if (message.length > MAX_MESSAGE_CHARS) {
    return res.status(400).json({ error: `message exceeds ${MAX_MESSAGE_CHARS} characters` });
  }
  if (!idempotencyKey) return res.status(400).json({ error: 'idempotency_key must be a UUID' });

  const abortController = new AbortController();
  const abortIfDisconnected = () => {
    if (!res.writableEnded) abortController.abort();
  };
  res.once('close', abortIfDisconnected);
  let client: PoolClient | null = null;
  try {
    client = await acquireConversationTransaction(userId, conversationId, abortController.signal);
    if (!client) {
      if (abortController.signal.aborted) return;
      return res.status(409).json({ error: 'This conversation is already running. Try again shortly.' });
    }
    const conversation = await client.query(
      `SELECT id FROM rem_conversations
        WHERE id = $1::uuid AND user_id = $2::uuid AND deleted_at IS NULL`,
      [conversationId, userId],
    );
    if (!conversation.rows[0]) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Conversation not found' });
    }
    const existing = await client.query(
      `SELECT id, conversation_id, role, content, run_id, created_at
         FROM rem_conversation_messages
        WHERE user_id = $1::uuid AND run_id = $2::uuid
          AND role IN ('user', 'assistant') ORDER BY seq ASC`,
      [userId, idempotencyKey],
    );
    if (existing.rows.some((row: any) => row.conversation_id.toString().toLowerCase() !== conversationId)) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'idempotency_key belongs to another conversation' });
    }
    const existingUser = existing.rows.find((row: any) => row.role === 'user');
    const existingAssistant = existing.rows.find((row: any) => row.role === 'assistant');
    if (existingUser && existingUser.content !== message) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'idempotency_key was reused for a different message' });
    }
    if (existingAssistant) {
      if (!existingUser) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'idempotency_key was reused for a different message' });
      }
      const proposals = await client.query(
        `SELECT id, assistant_message_id, task_id, task_title, proposed_status, explanation,
                state, effect_id, failure_code, created_at, updated_at, resolved_at
           FROM rem_conversation_task_proposals
          WHERE conversation_id = $1::uuid AND user_id = $2::uuid
            AND assistant_message_id = $3::uuid`,
        [conversationId, userId, existingAssistant.id],
      );
      await client.query('COMMIT');
      return res.json({
        run_id: idempotencyKey,
        session_key: sessionKey(conversationId),
        status: 'completed',
        message: formatMessage(existingAssistant),
        tool_proposals: proposals.rows.map(formatTaskProposal),
      });
    }
    const transcript = await client.query(
      `SELECT role, content FROM (
         SELECT seq, role, content FROM rem_conversation_messages
          WHERE conversation_id = $1::uuid AND user_id = $2::uuid
          ORDER BY seq DESC LIMIT $3
       ) recent ORDER BY seq ASC`,
      [conversationId, userId, MAX_CONTEXT_MESSAGES],
    );
    const taskContext = await client.query(
      `SELECT id::text, title, status, updated_at
         FROM tasks
        WHERE user_id = $1::uuid
        ORDER BY updated_at DESC, id DESC
        LIMIT $2`,
      [userId, MAX_TASK_CONTEXT_ITEMS],
    );
    const promptTasks = boundedConversationTaskContext(taskContext.rows);
    const result = await runAgentTurnOnSharedRuntime({
      principal: { userId, authority: 'authenticated_user' },
      message: conversationPrompt(transcript.rows, message, promptTasks),
      requestIdentity: `conversation:${conversationId}:${createHash('sha256').update(message).digest('hex')}`,
      sessionKey: sessionKey(conversationId),
      idempotencyKey,
      toolPolicy: {
        mode: 'observe',
        allowedTools: [CONVERSATION_TASK_UPDATE_PROPOSAL_TOOL_NAME],
        approval: 'none',
      },
      signal: abortController.signal,
    });
    if (!result.ok) {
      await client.query('ROLLBACK');
      const failure = failureStatus(result.reason);
      return res.status(failure.status).json({ error: failure.message, reason: result.reason });
    }
    const reportedProposal = readConversationTaskUpdateProposal(result.toolCalls);
    const proposedTask = reportedProposal
      ? promptTasks.find((task: any) => (
          task.id.toString().toLowerCase() === reportedProposal.proposal.taskId
        ))
      : undefined;
    const proposal = reportedProposal && proposedTask
      && reportedProposal.proposal.patch.status !== proposedTask.status
      ? { ...reportedProposal, task: proposedTask }
      : null;
    const proposedTaskTitle = proposal?.task.title.replace(/\s+/g, ' ').trim();
    // The model may emit a proposal tool call that yields no stored proposal — an unlisted
    // task id, a no-op status, or more than one call. In those cases result.text can still
    // read as if Rem acted, so fall back to deterministic copy that never claims a change.
    const attemptedTaskProposal = Array.isArray(result.toolCalls)
      && result.toolCalls.some((call: any) => call?.name === CONVERSATION_TASK_UPDATE_PROPOSAL_TOOL_NAME);
    const assistantText = proposal
      ? `I can update “${proposedTaskTitle}” to ${proposal.proposal.patch.status.replace('_', ' ')}. Review the proposal to approve it.`
      : attemptedTaskProposal
        ? 'I can only propose a status change for a task shown in this conversation, and I haven’t changed anything. Tell me which of your tasks you mean and I’ll prepare a proposal for you to approve.'
        : result.text;
    const inserted = await client.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1::uuid, $2::uuid, 'user', $3, $4::uuid),
              ($1::uuid, $2::uuid, 'assistant', $5, $4::uuid)
       ON CONFLICT (user_id, run_id, role)
         WHERE run_id IS NOT NULL AND role IN ('user', 'assistant') DO NOTHING
       RETURNING id, role, content, run_id, created_at`,
      [conversationId, userId, message, idempotencyKey, assistantText],
    );
    const assistant = inserted.rows.find((row: any) => row.role === 'assistant');
    if (!assistant) throw new Error('Conversation continuation did not persist an assistant turn');
    let storedProposals: any[] = [];
    if (proposal) {
      const stored = await client.query(
        `INSERT INTO rem_conversation_task_proposals
           (conversation_id, user_id, assistant_message_id, proposal_run_id, tool_call_id,
            task_id, task_title, proposed_status, expected_task_status,
            expected_task_updated_at, explanation)
         VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5,
                 $6::uuid, $7, $8, $9, $10::timestamptz, $11)
         ON CONFLICT (assistant_message_id) DO NOTHING
         RETURNING id, assistant_message_id, task_id, task_title, proposed_status, explanation,
                   state, effect_id, failure_code, created_at, updated_at, resolved_at`,
        [
          conversationId,
          userId,
          assistant.id,
          result.runId,
          proposal.toolCallId,
          proposal.proposal.taskId,
          proposedTaskTitle,
          proposal.proposal.patch.status,
          proposal.task.status,
          proposal.task.updated_at,
          proposal.proposal.comment,
        ],
      );
      storedProposals = stored.rows;
      if (!storedProposals[0]) {
        const replay = await client.query(
          `SELECT id, assistant_message_id, task_id, task_title, proposed_status, explanation,
                  state, effect_id, failure_code, created_at, updated_at, resolved_at
             FROM rem_conversation_task_proposals
            WHERE conversation_id = $1::uuid AND user_id = $2::uuid
              AND assistant_message_id = $3::uuid`,
          [conversationId, userId, assistant.id],
        );
        storedProposals = replay.rows;
      }
    }
    await client.query(
      `UPDATE rem_conversations
          SET title = COALESCE(title, $3), updated_at = NOW()
        WHERE id = $1::uuid AND user_id = $2::uuid AND deleted_at IS NULL`,
      [conversationId, userId, titleFromMessage(message)],
    );
    await client.query('COMMIT');
    return res.status(201).json({
      run_id: idempotencyKey,
      session_key: sessionKey(conversationId),
      status: 'completed',
      message: formatMessage(assistant),
      tool_proposals: storedProposals.map(formatTaskProposal),
    });
  } catch (error: any) {
    await client?.query('ROLLBACK').catch(() => undefined);
    console.error('[CONVERSATIONS] Error continuing conversation:', error.message);
    return res.status(500).json({ error: 'Failed to continue conversation' });
  } finally {
    res.off('close', abortIfDisconnected);
    client?.release();
  }
});

router.post(
  '/conversations/:id/task-proposals/:proposalId/approve',
  requireJwt,
  async (req: Request, res: Response) => {
    const userId = authenticatedUserId(req);
    const conversationId = normalizeUuid(req.params.id);
    const proposalId = normalizeUuid(req.params.proposalId);
    if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
    if (!proposalId) return res.status(400).json({ error: 'proposal id must be a UUID' });
    let client: PoolClient | null = null;
    try {
      client = await acquireConversationTransaction(userId, conversationId);
      if (!client) {
        return res.status(409).json({ error: 'This conversation is currently changing. Try again shortly.' });
      }
      const result = await executeConversationTaskProposal({ userId, conversationId, proposalId });
      await client.query('COMMIT');
      if (result.kind === 'succeeded') {
        return res.json({
          status: 'succeeded',
          task: result.task,
          effect_id: result.effectId,
          replayed: result.replayed,
        });
      }
      if (result.reason === 'proposal_not_found' || result.reason === 'conversation_not_found') {
        return res.status(404).json({ error: 'Task proposal not found', reason: result.reason });
      }
      if (result.reason === 'execution_unavailable') {
        return res.status(503).json({ error: 'Task proposal execution is temporarily unavailable', reason: result.reason });
      }
      if (result.reason === 'execution_pending') {
        return res.status(409).json({ error: 'Task proposal execution is still being reconciled', reason: result.reason });
      }
      return res.status(409).json({
        error: result.reason === 'task_changed'
          ? 'The task changed after this proposal was created. Ask Rem to make a fresh proposal.'
          : 'This task proposal can no longer be applied.',
        reason: result.reason,
        ...(result.failureCode ? { failure_code: result.failureCode } : {}),
      });
    } catch (error: any) {
      await client?.query('ROLLBACK').catch(() => undefined);
      console.error('[CONVERSATIONS] Error approving task proposal:', error.message);
      return res.status(503).json({ error: 'Task proposal execution is temporarily unavailable' });
    } finally {
      client?.release();
    }
  },
);

router.post(
  '/conversations/:id/task-proposals/:proposalId/dismiss',
  requireJwt,
  async (req: Request, res: Response) => {
    const userId = authenticatedUserId(req);
    const conversationId = normalizeUuid(req.params.id);
    const proposalId = normalizeUuid(req.params.proposalId);
    if (!conversationId) return res.status(400).json({ error: 'conversation id must be a UUID' });
    if (!proposalId) return res.status(400).json({ error: 'proposal id must be a UUID' });
    let client: PoolClient | null = null;
    try {
      client = await acquireConversationTransaction(userId, conversationId);
      if (!client) {
        return res.status(409).json({ error: 'This conversation is currently changing. Try again shortly.' });
      }
      const dismissed = await client.query(
        `UPDATE rem_conversation_task_proposals proposal
            SET state = 'dismissed', resolved_at = NOW(), updated_at = NOW()
           FROM rem_conversations conversation
          WHERE proposal.id = $1::uuid
            AND proposal.conversation_id = $2::uuid
            AND proposal.user_id = $3::uuid
            AND proposal.state = 'pending'
            AND conversation.id = proposal.conversation_id
            AND conversation.user_id = proposal.user_id
            AND conversation.deleted_at IS NULL
          RETURNING proposal.id`,
        [proposalId, conversationId, userId],
      );
      if (dismissed.rows[0]) {
        await client.query('COMMIT');
        return res.status(204).send();
      }
      const existing = await client.query(
        `SELECT proposal.state
           FROM rem_conversation_task_proposals proposal
           JOIN rem_conversations conversation
             ON conversation.id = proposal.conversation_id
            AND conversation.user_id = proposal.user_id
          WHERE proposal.id = $1::uuid
            AND proposal.conversation_id = $2::uuid
            AND proposal.user_id = $3::uuid
            AND conversation.deleted_at IS NULL`,
        [proposalId, conversationId, userId],
      );
      await client.query('COMMIT');
      if (!existing.rows[0]) return res.status(404).json({ error: 'Task proposal not found' });
      if (existing.rows[0].state === 'dismissed') return res.status(204).send();
      return res.status(409).json({ error: 'A resolved task proposal cannot be dismissed' });
    } catch (error: any) {
      await client?.query('ROLLBACK').catch(() => undefined);
      console.error('[CONVERSATIONS] Error dismissing task proposal:', error.message);
      return res.status(500).json({ error: 'Failed to dismiss task proposal' });
    } finally {
      client?.release();
    }
  },
);

export default router;
