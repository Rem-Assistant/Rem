import { randomUUID } from 'node:crypto';
import { Router, Request, Response } from 'express';
import type { PoolClient } from 'pg';
import { requireJwt } from '../middleware/auth.js';
import { pool } from '../db/pool.js';
import {
  gatewayFailureBody,
  runAgentOnTask,
  type AgentRunResult,
} from '../services/task-agent.service.js';
import { listExistsForUser } from '../services/organization.service.js';
import { taskSessionKey } from '../services/orchestrator-sweep.service.js';
import {
  RESET_STALENESS_SET_CLAUSES,
  resetTaskStaleness,
} from '../services/task-staleness.service.js';
import {
  MAX_USER_DESCRIPTION_CHARS,
  applyAgentTaskContext,
  splitDescription,
  setUserSection,
  stripAgentBlockMarkers,
} from '../services/task-description.service.js';

const router = Router();

// Statuses a comment may propose for its task. Mirrors the CHECK constraint in
// migrations 015_create_task_comments.sql + 021_add_blocked_proposed_status.sql.
// `blocked` = the agent (or user) proposes the task is blocked / needs info before it
// can proceed — a real proposal, not an error (principle 5).
const PROPOSED_STATUSES = new Set(['pending', 'in_progress', 'completed', 'cancelled', 'blocked']);

// Structured run-state on the task (migration 019). Lifecycle: idle/null -> running
// (on dispatch) -> done | review | blocked (terminal, on completion).
type TerminalRunStatus = 'done' | 'review' | 'blocked';

/**
 * Derive the terminal run_status from an agent result — a structured mapping, not a
 * string match on the reply body (principle 5). docs/rebuild/19-TASKS-VS-WORKBOARD.md.
 *   errored               -> blocked (run could not complete)
 *   proposed 'blocked'    -> blocked (agent ran fine but is blocked / needs info)
 *   proposed 'completed'  -> done    (run completed the task)
 *   otherwise             -> review  (run left a comment for the human to review)
 *
 * Both `errored` and a `blocked` proposal land on run_status='blocked' so the
 * daily-brief "blocked/overdue" sweep catches a needs-info task the same as an
 * unreachable-service one — without re-reading the comment prose.
 */
function terminalRunStatus(result: AgentRunResult): TerminalRunStatus {
  if (result.errored) return 'blocked';
  if (result.proposedStatus === 'blocked') return 'blocked';
  if (result.proposedStatus === 'completed') return 'done';
  return 'review';
}

interface CreateTaskRequest {
  id?: string;
  title: string;
  priority?: string;
  status?: string;
  start_date?: string;
  end_date?: string;
  duration_minutes?: number;
  alert_time?: string;
  repeat_frequency?: string;
  list_id?: string | null;
  /** The USER's half of the co-authored description (migration 120). */
  description?: string | null;
}

/**
 * Validate + sanitize the user's half of a description on the way in (migration 120).
 * Returns the text to store, or throws a 400-shaped error.
 *   undefined → caller omits the field    null/'' → clear the user's half
 * Block markers are stripped so pasted text can never forge or truncate the agent's
 * block — user input is data here, never structure.
 */
function resolveUserDescription(raw: unknown): string | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null) return null;
  if (typeof raw !== 'string') {
    const err = new Error('description must be a string or null');
    (err as any).status = 400;
    throw err;
  }
  if (raw.length > MAX_USER_DESCRIPTION_CHARS) {
    const err = new Error(`description exceeds ${MAX_USER_DESCRIPTION_CHARS} characters`);
    (err as any).status = 400;
    throw err;
  }
  const cleaned = stripAgentBlockMarkers(raw).trim();
  return cleaned.length === 0 ? null : cleaned;
}

interface CreateEventRequest {
  id?: string;
  title: string;
  date_time: string;
  duration_minutes: number;
  type: string;
  list_id?: string | null;
}

function formatTask(row: any) {
  // The co-authored description (migration 120). The client gets the canonical stored
  // text AND the two halves already split, so no parser of the block delimiter exists
  // outside task-description.service.ts — a second implementation in Swift is exactly
  // how the two would drift.
  const description = splitDescription(row.description);
  return {
    id: row.id.toString(),
    title: row.title,
    status: row.status ?? null,
    priority: row.priority ?? null,
    start_date: row.start_date ? new Date(row.start_date).toISOString() : null,
    end_date: row.end_date ? new Date(row.end_date).toISOString() : null,
    duration_minutes: row.duration_minutes ?? null,
    alert_time: row.alert_time ? new Date(row.alert_time).toISOString() : null,
    repeat_frequency: row.repeat_frequency ?? null,
    type: row.type ?? 'task',
    // "What I know NOW" (migration 120) — current state, updated in place, as opposed
    // to `task_comments` which logs what happened each run. `description` is the whole
    // stored column (what a model prompt should read); `description_user` is the half a
    // text editor binds to; `description_agent` is the half Rem maintains and the client
    // renders read-only. PATCHing `description` sets the USER's half only.
    description: row.description ?? null,
    description_user: description.user,
    description_agent: description.agent,
    // Organization (migration 021): the List this task belongs to, if any.
    list_id: row.list_id ? row.list_id.toString() : null,
    // The calendar event this task backs, if any (migration 024). Non-null only for a
    // lightweight backing task that carries a calendar event's Activity thread + runs.
    calendar_event_id: row.calendar_event_id ?? null,
    // Structured agent run-state (migration 019) — lets the client show
    // "being worked right now" (TaskRuntimeBadge) without parsing a comment.
    run_status: row.run_status ?? null,
    run_id: row.run_id ?? null,
    session_key: row.session_key ?? null,
    run_started_at: row.run_started_at ? new Date(row.run_started_at).toISOString() : null,
    run_last_heartbeat_at: row.run_last_heartbeat_at
      ? new Date(row.run_last_heartbeat_at).toISOString()
      : null,
    // WHY the last run did not happen, and whose key would have paid (migration 121).
    // `run_status` says a run ended badly; these two say what to DO about it, and they are a
    // closed code + a mode rather than a sentence so the client owns the copy and the call to
    // action (CLAUDE.md principle 5 — see backend/src/services/run-block.ts). Both NULL on a
    // run that was not blocked, and on every run that predates the migration.
    run_block_code: row.run_block_code ?? null,
    run_block_mode: row.run_block_mode ?? null,
    // Staleness (migration 116). NON-NULL ⟺ the brief asked BRIEF_STALE_THRESHOLD times and got no
    // answer, so it stopped asking. ORTHOGONAL to `status`, and serialized ALONGSIDE it — never
    // instead of it, so a task that is blocked AND stale reports both facts truthfully. Any user
    // action clears it (see `resetTaskStaleness`), so the client must mirror nulls too.
    //
    // The client cannot see this without it on the wire, and a stale task the user cannot
    // distinguish from a live one is the whole bug: Rem quietly stopped raising it and nothing said
    // so. `gatherBrief` already derives `is_stale` for the brief surface (brief.service.ts:126);
    // this is the same fact for every other task surface.
    stale_at: row.stale_at ? new Date(row.stale_at).toISOString() : null,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
    updated_at: row.updated_at ? new Date(row.updated_at).toISOString() : null,
  };
}

// One line, and every consumer's read shape. Two branches added a column here
// independently — `stale_at` (migration 116 surfacing) and `description` (migration 120).
// BOTH must be present: dropping either silently stops the API sending it, with no test
// failure at the line itself.
const RETURNING =
  'id, title, description, priority, status, start_date, end_date, duration_minutes, alert_time, repeat_frequency, type, list_id, calendar_event_id, run_status, run_id, session_key, run_started_at, run_last_heartbeat_at, run_block_code, run_block_mode, stale_at, created_at, updated_at';

/**
 * Validates an optional list_id on a task create/update: a non-null id must
 * reference a List owned by the same user (so a task can't be filed into
 * someone else's List). Returns the validated value, or throws a 400-shaped error.
 *   undefined → caller omits the field   null/'' → unfile   uuid → set
 */
async function resolveListId(userId: string, raw: unknown): Promise<string | null | undefined> {
  if (raw === undefined) return undefined;
  if (raw === null || raw === '') return null;
  if (typeof raw !== 'string' || !(await listExistsForUser(userId, raw))) {
    const err = new Error('list_id does not reference a list you own');
    (err as any).status = 400;
    throw err;
  }
  return raw;
}

function formatComment(row: any) {
  return {
    id: row.id.toString(),
    task_id: row.task_id.toString(),
    author_kind: row.author_kind,
    author_label: row.author_label,
    body: row.body,
    proposed_status: row.proposed_status ?? null,
    // The task status this run CHANGED FROM, when the agent applied a status (migration
    // 028). Non-null = the agent applied `proposed_status` to the task and this is the
    // Undo target; the client renders "Applied: <proposed_status>" + Undo instead of
    // "Proposes: …" + Accept. NULL = nothing was applied (legacy propose/Accept path).
    previous_status: row.previous_status ?? null,
    runtime: row.runtime ?? null,
    // The session/run id this comment executed in (migration 022). Lets the client
    // resolve an activity row back to the agent session/chat that produced it.
    // NULL for human comments and any comment not produced by a run.
    session_id: row.session_id ?? null,
    // The blocked-run reason for THIS run (migration 121). The task row carries only its most
    // recent run's block state; a run history has to render a run that failed three runs ago,
    // which is why the same pair lives on the comment. NULL on every human comment and on
    // every run that actually produced a reply.
    run_block_code: row.run_block_code ?? null,
    run_block_mode: row.run_block_mode ?? null,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
  };
}

const COMMENT_RETURNING =
  'id, task_id, author_kind, author_label, body, proposed_status, previous_status, runtime, session_id, run_block_code, run_block_mode, created_at';

// Replayable task chat transcript (migration 025). A cloud run executes in the GMI
// AgentBox namespace, never on the gateway, so its turns are not retrievable as a
// gateway session — we persist them here keyed by task id + run id and serve them to
// the device via GET /tasks/:id/chat so the task chat opens the REAL conversation
// (the ask + Rem's reply) instead of an empty composer (#869 / #874).
type ChatRole = 'user' | 'assistant' | 'tool';

function formatChatMessage(row: any) {
  return {
    id: row.id.toString(),
    task_id: row.task_id.toString(),
    role: row.role as ChatRole,
    content: row.content,
    run_id: row.run_id ?? null,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
  };
}

const CHAT_MESSAGE_RETURNING = 'id, task_id, role, content, run_id, created_at';

/**
 * Build the user-facing "ask" turn that opened a cloud run, so the persisted
 * transcript reads as a real exchange. Prefers the explicit instruction; otherwise
 * the most recent human comment (the user's own words); otherwise a synthesized ask
 * from the task title (the bare "Run now" case). Never empty — the transcript always
 * has a user turn before Rem's reply.
 */
function deriveRunAsk(
  task: { title?: string | null },
  comments: Array<{ author_kind?: string; body?: string }>,
  instruction?: string,
): string {
  if (instruction && instruction.trim()) return instruction.trim();
  for (let i = comments.length - 1; i >= 0; i--) {
    const c = comments[i];
    if (c.author_kind === 'user' && c.body && c.body.trim()) return c.body.trim();
  }
  const title = task.title?.trim();
  return title ? `Let's work on "${title}".` : "Let's work on this task.";
}

/**
 * Persist a cloud run's conversation turns as a replayable transcript (migration
 * 025): the user ask + Rem's reply, stamped with the run id. Best-effort — wrapped so
 * a transcript-write failure never fails the agent-run response (same demo-safe
 * philosophy as the rest of this route).
 */
async function persistRunTranscript(
  taskId: string,
  userId: string,
  runId: string,
  ask: string,
  reply: string,
): Promise<void> {
  try {
    await pool.query(
      `INSERT INTO task_chat_messages (task_id, user_id, role, content, run_id)
       VALUES ($1::uuid, $2::uuid, 'user', $3, $4),
              ($1::uuid, $2::uuid, 'assistant', $5, $4)`,
      [taskId, userId, ask, runId, reply],
    );
  } catch (error: any) {
    // Non-fatal: the comment + run-state already persisted; the transcript is a
    // continuation aid, not the source of truth. Log and move on.
    console.error('[TASKS] persistRunTranscript failed:', error?.message);
  }
}

/**
 * POST /api/v1/tasks — create a task or calendar event
 */
router.post('/tasks', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const body = req.body;

    if (body.type === 'calendar_event') {
      const ev = body as CreateEventRequest;
      if (!ev.title || !ev.date_time || !ev.duration_minutes) {
        return res.status(400).json({ error: 'Missing required fields: title, date_time, duration_minutes' });
      }
      const hasClientId = ev.id && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ev.id);
      const listId = await resolveListId(userId, ev.list_id);
      let result = await pool.query(
        hasClientId
          ? `INSERT INTO tasks (id, user_id, title, start_date, duration_minutes, type, list_id, created_at, updated_at)
             VALUES ($1::uuid, $2, $3, $4::timestamptz, $5, 'calendar_event', $6::uuid, NOW(), NOW())
             ON CONFLICT (id) DO NOTHING
             RETURNING ${RETURNING}`
          : `INSERT INTO tasks (user_id, title, start_date, duration_minutes, type, list_id, created_at, updated_at)
             VALUES ($1, $2, $3::timestamptz, $4, 'calendar_event', $5::uuid, NOW(), NOW())
             RETURNING ${RETURNING}`,
        hasClientId
          ? [ev.id, userId, ev.title, ev.date_time, ev.duration_minutes, listId ?? null]
          : [userId, ev.title, ev.date_time, ev.duration_minutes, listId ?? null],
      );
      // Calendar-event retries use the same client-owned UUID contract as tasks. Scope the
      // duplicate lookup to the authenticated user; the client reapplies its immutable snapshot
      // with PATCH before retiring the queued intent.
      if (hasClientId && result.rows.length === 0) {
        result = await pool.query(
          `SELECT ${RETURNING} FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid LIMIT 1`,
          [ev.id, userId],
        );
      }
      if (result.rows.length === 0) return res.status(500).json({ error: 'Failed to create event' });
      const row = result.rows[0];
      const endDate =
        row.start_date && row.duration_minutes
          ? new Date(new Date(row.start_date).getTime() + row.duration_minutes * 60_000)
          : null;
      return res.status(201).json({ ...formatTask(row), end_date: endDate ? endDate.toISOString() : null });
    }

    // It's a task
    const task = body as CreateTaskRequest;
    if (!task.title) return res.status(400).json({ error: 'Missing required field: title' });

    const hasClientId = task.id && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(task.id);
    const fields: string[] = hasClientId
      ? ['id', 'user_id', 'title', 'priority', 'status', 'type']
      : ['user_id', 'title', 'priority', 'status', 'type'];
    const values: any[] = hasClientId
      ? [task.id, userId, task.title, task.priority ?? 'medium', task.status ?? 'pending', 'task']
      : [userId, task.title, task.priority ?? 'medium', task.status ?? 'pending', 'task'];
    const timestampFields = new Set(['start_date', 'end_date', 'alert_time']);

    for (const [key, val] of Object.entries(task)) {
      if (['id', 'title', 'priority', 'status'].includes(key) || val === undefined) continue;
      if (['start_date', 'end_date', 'alert_time', 'duration_minutes', 'repeat_frequency'].includes(key)) {
        fields.push(key);
        values.push(val);
      }
    }

    // Organization (migration 021): optionally file the task into a List the user owns.
    const listId = await resolveListId(userId, body.list_id);
    if (listId !== undefined && listId !== null) {
      fields.push('list_id');
      values.push(listId);
    }

    // The co-authored description (migration 120). On create there is no agent block to
    // preserve yet, so this is a plain sanitized write — but it still goes through the
    // same validation, so a create can no more forge a block than a PATCH can.
    const description = resolveUserDescription(task.description);
    if (description !== undefined && description !== null) {
      fields.push('description');
      values.push(description);
    }

    fields.push('created_at', 'updated_at');

    const placeholders = fields.map((f, i) => {
      if (f === 'created_at' || f === 'updated_at') return 'NOW()';
      if (f === 'id' || f === 'list_id') return `$${i + 1}::uuid`;
      if (timestampFields.has(f)) return `$${i + 1}::timestamptz`;
      return `$${i + 1}`;
    });

    let result = await pool.query(
      `INSERT INTO tasks (${fields.join(', ')}) VALUES (${placeholders.join(', ')})${
        hasClientId ? ' ON CONFLICT (id) DO NOTHING' : ''
      } RETURNING ${RETURNING}`,
      values,
    );
    // Offline and suggestion acceptance retries reuse a client-owned UUID. A committed create with
    // that exact authenticated identity is success, not a duplicate task or a permanent retry-loop.
    if (hasClientId && result.rows.length === 0) {
      result = await pool.query(
        `SELECT ${RETURNING} FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid LIMIT 1`,
        [task.id, userId],
      );
    }
    if (result.rows.length === 0) return res.status(500).json({ error: 'Failed to create task' });
    return res.status(201).json(formatTask(result.rows[0]));
  } catch (error: any) {
    if (error.status === 400) return res.status(400).json({ error: error.message });
    if (error.code === 'P0001' && error.message === 'task id was previously deleted') {
      return res.status(410).json({ error: error.message });
    }
    console.error('[TASKS] Error creating task/event:', error.message);
    res.status(500).json({ error: error.message || 'Failed to create task/event' });
  }
});

/**
 * GET /api/v1/tasks — list tasks for the authenticated user (with pagination)
 *   ?limit=50&offset=0  — pagination (defaults: limit=50, offset=0)
 *   ?status=pending      — optional filter by status
 *   ?type=task           — optional filter by type (task | calendar_event)
 *   ?since=<ISO8601>     — optional: only tasks updated after this timestamp
 */
router.get('/tasks', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const limit = Math.min(Math.max(parseInt(req.query.limit as string, 10) || 50, 1), 200);
    const offset = Math.max(parseInt(req.query.offset as string, 10) || 0, 0);

    const conditions: string[] = ['user_id = $1'];
    const values: any[] = [userId];
    let paramIdx = 2;

    if (req.query.status) {
      conditions.push(`status = $${paramIdx}`);
      values.push(req.query.status);
      paramIdx++;
    }

    if (req.query.type) {
      conditions.push(`type = $${paramIdx}`);
      values.push(req.query.type);
      paramIdx++;
    }

    if (req.query.since) {
      conditions.push(`updated_at > $${paramIdx}::timestamptz`);
      values.push(req.query.since);
      paramIdx++;
    }

    const where = conditions.join(' AND ');

    // Get total count for pagination metadata
    const countResult = await pool.query(
      `SELECT COUNT(*) FROM tasks WHERE ${where}`,
      values,
    );
    const total = parseInt(countResult.rows[0].count, 10);

    values.push(limit, offset);
    const result = await pool.query(
      `SELECT ${RETURNING} FROM tasks WHERE ${where} ORDER BY created_at DESC LIMIT $${paramIdx} OFFSET $${paramIdx + 1}`,
      values,
    );

    return res.json({
      tasks: result.rows.map(formatTask),
      pagination: { total, limit, offset, hasMore: offset + limit < total },
    });
  } catch (error: any) {
    console.error('[TASKS] Error fetching tasks:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch tasks' });
  }
});

/**
 * GET /api/v1/tasks/deletions — explicit deletion tombstones for cross-device sync.
 * Kept separate from the mutable paginated task list so absence is never interpreted
 * as deletion. The user_id comes only from the verified JWT.
 */
router.get('/tasks/deletions', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const result = await pool.query(
      `SELECT task_id, deleted_at
       FROM task_deletions
       WHERE user_id = $1::uuid
       ORDER BY deleted_at ASC`,
      [userId],
    );
    return res.json({
      deletions: result.rows.map((row) => ({
        task_id: row.task_id.toString(),
        deleted_at: new Date(row.deleted_at).toISOString(),
      })),
    });
  } catch (error: any) {
    console.error('[TASKS] Error fetching task deletions:', error.message);
    return res.status(500).json({ error: error.message || 'Failed to fetch task deletions' });
  }
});

/**
 * GET /api/v1/tasks/:id — get a single task
 */
router.get('/tasks/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const result = await pool.query(
      `SELECT ${RETURNING} FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid`,
      [req.params.id, userId],
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Task not found' });
    return res.json(formatTask(result.rows[0]));
  } catch (error: any) {
    console.error('[TASKS] Error fetching task:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch task' });
  }
});

/**
 * PATCH /api/v1/tasks/:id — update a task
 *
 * `description` is CO-AUTHORED (migration 120): the value in the body replaces the
 * USER's half only, and Rem's `<!-- rem:agent-context -->` block is carried through
 * untouched. The user cannot clobber the agent here and the agent cannot clobber the
 * user in its own write — see task-description.service.ts for why that is the design.
 * Because the merge is read-modify-write, a body carrying `description` runs the whole
 * PATCH in a transaction and takes the row lock the agent's writer takes, so the two
 * writers serialize instead of overwriting each other with stale halves.
 */
router.patch('/tasks/:id', requireJwt, async (req: Request, res: Response) => {
  let client: PoolClient | undefined;
  try {
    const userId = (req as Request & { userId: string }).userId;
    const body = req.body;
    const timestampFields = new Set(['start_date', 'end_date', 'alert_time']);
    const allowed = ['title', 'priority', 'status', 'start_date', 'end_date', 'duration_minutes', 'alert_time', 'repeat_frequency'];

    // Validate + sanitize BEFORE opening a transaction, so a 400 never holds a row lock.
    const userDescription = resolveUserDescription(body.description);

    const setClauses: string[] = [];
    const values: any[] = [];
    let i = 1;

    for (const key of allowed) {
      if (body[key] !== undefined) {
        const cast = timestampFields.has(key) ? '::timestamptz' : '';
        setClauses.push(`${key} = $${i}${cast}`);
        values.push(body[key]);
        i++;
      }
    }

    // Organization (migration 021): move the task between Lists (or null to unfile).
    const listId = await resolveListId(userId, body.list_id);
    if (listId !== undefined) {
      setClauses.push(`list_id = $${i}::uuid`);
      values.push(listId);
      i++;
    }

    // Co-authored description: read the CURRENT stored value under a row lock, replace
    // only the user's half, and let the merged text ride the same UPDATE as everything
    // else — so the staleness reset below still covers it and cannot be forgotten.
    if (userDescription !== undefined) {
      client = await pool.connect();
      await client.query('BEGIN');
      const current = await client.query(
        `SELECT description FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid FOR UPDATE`,
        [req.params.id, userId],
      );
      if (current.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Task not found' });
      }
      setClauses.push(`description = $${i}`);
      values.push(setUserSection(current.rows[0].description, userDescription));
      i++;
    }

    if (setClauses.length === 0) {
      if (client) await client.query('ROLLBACK');
      return res.status(400).json({ error: 'No fields to update' });
    }
    setClauses.push('updated_at = NOW()');
    // THE USER TOUCHED THIS TASK, so it is not stale — clear the brief's nag counter and any
    // `stale_at` marker (migration 116). Every user-facing task mutation funnels through this one
    // route: retitling, re-prioritising, RESCHEDULING (start_date/end_date/alert_time), COMPLETING
    // (status), changing the repeat rule, and re-filing into a list. Folding the reset into the
    // SAME UPDATE, rather than issuing a second statement, means it is atomic with the edit and
    // cannot be forgotten when a new patchable field is added to `allowed` above.
    //
    // A stale task the user edits therefore comes straight back into the brief on the next slot —
    // "stale" is a pause on nagging, not a one-way door.
    setClauses.push(...RESET_STALENESS_SET_CLAUSES);
    values.push(req.params.id, userId);

    const result = await (client ?? pool).query(
      `UPDATE tasks SET ${setClauses.join(', ')} WHERE id = $${i}::uuid AND user_id = $${i + 1}::uuid RETURNING ${RETURNING}`,
      values,
    );
    if (result.rows.length === 0) {
      if (client) await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Task not found' });
    }
    if (client) await client.query('COMMIT');
    return res.json(formatTask(result.rows[0]));
  } catch (error: any) {
    await client?.query('ROLLBACK').catch(() => {});
    if (error.status === 400) return res.status(400).json({ error: error.message });
    console.error('[TASKS] Error updating task:', error.message);
    res.status(500).json({ error: error.message || 'Failed to update task' });
  } finally {
    client?.release();
  }
});

/**
 * DELETE /api/v1/tasks/:id — delete a task
 */
router.delete('/tasks/:id', requireJwt, async (req: Request, res: Response) => {
  let client: PoolClient | undefined;
  try {
    client = await pool.connect();
    const userId = (req as Request & { userId: string }).userId;
    await client.query('BEGIN');
    await client.query(
      `SELECT pg_advisory_xact_lock(
         hashtextextended($1::uuid::text || ':' || $2::uuid::text, 0)
       )`,
      [userId, req.params.id],
    );
    await client.query(
      `DELETE FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid`,
      [req.params.id, userId],
    );
    await client.query(
      `INSERT INTO task_deletions (user_id, task_id, deleted_at)
       VALUES ($1::uuid, $2::uuid, NOW())
       ON CONFLICT (user_id, task_id)
       DO UPDATE SET deleted_at = EXCLUDED.deleted_at`,
      [userId, req.params.id],
    );
    await client.query('COMMIT');
    return res.status(204).send();
  } catch (error: any) {
    await client?.query('ROLLBACK').catch(() => {});
    console.error('[TASKS] Error deleting task:', error.message);
    return res.status(500).json({ error: error.message || 'Failed to delete task' });
  } finally {
    client?.release();
  }
});

/**
 * POST /api/v1/tasks/event-backing — find-or-create the lightweight backing task that
 * lets a CALENDAR EVENT carry an Activity thread (task_comments) + agent runs. The
 * client calls this the first time the user "works" an event (Run now / "Let Rem work
 * this"); the returned task id is then used unchanged against `/tasks/:id/comments`
 * and `/tasks/:id/agent-run`.
 *
 * Idempotent: keyed on (user_id, calendar_event_id) via migration 024's partial unique
 * index, so repeated Run-now on the same event reuses one row (one thread) instead of
 * forking a new one. App-side only — this never mutates the underlying calendar event.
 *
 * Body: { calendar_event_id (required), title?, start_date?, duration_minutes?, list_id? }.
 * Returns 200 with the backing task (formatTask shape). See migration 024 +
 * docs/rebuild/19-TASKS-VS-WORKBOARD.md. Relative-time triggers + richer event/task
 * unification are explicit follow-ups, out of scope here.
 */
router.post('/tasks/event-backing', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;

    const calendarEventId =
      typeof req.body?.calendar_event_id === 'string' ? req.body.calendar_event_id.trim() : '';
    if (!calendarEventId) {
      return res.status(400).json({ error: 'Missing required field: calendar_event_id' });
    }

    const title =
      typeof req.body?.title === 'string' && req.body.title.trim()
        ? req.body.title.trim()
        : 'Calendar event';
    const startDate = typeof req.body?.start_date === 'string' ? req.body.start_date : null;
    const durationMinutes =
      typeof req.body?.duration_minutes === 'number' && Number.isFinite(req.body.duration_minutes)
        ? req.body.duration_minutes
        : null;

    // Organization (migration 021): optionally file the backing into a List the user owns.
    const listId = await resolveListId(userId, req.body?.list_id);

    // Find-or-create keyed on (user_id, calendar_event_id). On conflict we only touch
    // updated_at — title/schedule/list of an existing backing are not clobbered by a
    // later Run-now (those are managed via the normal PATCH /tasks/:id path).
    const result = await pool.query(
      `INSERT INTO tasks (user_id, title, start_date, duration_minutes, type, calendar_event_id, list_id, status, created_at, updated_at)
       VALUES ($1::uuid, $2, $3::timestamptz, $4, 'calendar_event', $5, $6::uuid, 'pending', NOW(), NOW())
       ON CONFLICT (user_id, calendar_event_id) WHERE calendar_event_id IS NOT NULL
       DO UPDATE SET updated_at = NOW()
       RETURNING ${RETURNING}`,
      [userId, title, startDate, durationMinutes, calendarEventId, listId ?? null],
    );
    if (result.rows.length === 0) {
      return res.status(500).json({ error: 'Failed to create event backing' });
    }
    return res.status(200).json(formatTask(result.rows[0]));
  } catch (error: any) {
    if (error.status === 400) return res.status(400).json({ error: error.message });
    console.error('[TASKS] Error creating event backing:', error.message);
    res.status(500).json({ error: error.message || 'Failed to create event backing' });
  }
});

/**
 * Loads a task scoped to the authed user. Returns the row, or null if not found.
 */
async function loadOwnedTask(taskId: string, userId: string): Promise<any | null> {
  const result = await pool.query(
    `SELECT ${RETURNING} FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid`,
    [taskId, userId],
  );
  return result.rows.length === 0 ? null : result.rows[0];
}

/**
 * GET /api/v1/tasks/:id/comments — list comments on a task (oldest first).
 * See docs/agentbox/CONTRACT.md §4.
 */
router.get('/tasks/:id/comments', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const task = await loadOwnedTask(req.params.id, userId);
    if (!task) return res.status(404).json({ error: 'Task not found' });

    const result = await pool.query(
      `SELECT ${COMMENT_RETURNING} FROM task_comments WHERE task_id = $1::uuid ORDER BY created_at ASC`,
      [req.params.id],
    );
    return res.json({ comments: result.rows.map(formatComment) });
  } catch (error: any) {
    console.error('[TASKS] Error fetching comments:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch comments' });
  }
});

/**
 * GET /api/v1/tasks/:id/chat — the replayable cloud-run transcript for a task
 * (migration 025), oldest first. The device renders these as the REAL prior messages
 * in the task-scoped continuation chat so opening it continues the actual
 * conversation (ask + Rem's reply) rather than landing in an empty composer (#869).
 * User-scoped via loadOwnedTask; returns `{ messages: [...] }`.
 */
router.get('/tasks/:id/chat', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const task = await loadOwnedTask(req.params.id, userId);
    if (!task) return res.status(404).json({ error: 'Task not found' });

    const result = await pool.query(
      `SELECT ${CHAT_MESSAGE_RETURNING} FROM task_chat_messages
        WHERE task_id = $1::uuid ORDER BY seq ASC`,
      [req.params.id],
    );
    return res.json({ messages: result.rows.map(formatChatMessage) });
  } catch (error: any) {
    console.error('[TASKS] Error fetching task chat:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch task chat' });
  }
});

/**
 * POST /api/v1/tasks/:id/comments — add a human comment to a task.
 * Body: { body, proposed_status? }. See docs/agentbox/CONTRACT.md §4.
 */
router.post('/tasks/:id/comments', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const task = await loadOwnedTask(req.params.id, userId);
    if (!task) return res.status(404).json({ error: 'Task not found' });

    const body = typeof req.body?.body === 'string' ? req.body.body.trim() : '';
    if (!body) return res.status(400).json({ error: 'Missing required field: body' });

    const proposedStatus = req.body?.proposed_status ?? null;
    if (proposedStatus !== null && !PROPOSED_STATUSES.has(proposedStatus)) {
      return res.status(400).json({
        error: `Invalid proposed_status. Must be one of: ${Array.from(PROPOSED_STATUSES).join(', ')}`,
      });
    }

    const result = await pool.query(
      `INSERT INTO task_comments (task_id, user_id, author_kind, author_label, body, proposed_status)
       VALUES ($1::uuid, $2::uuid, 'user', 'You', $3, $4)
       RETURNING ${COMMENT_RETURNING}`,
      [req.params.id, userId, body, proposedStatus],
    );
    // Writing about a task is acting on it, so it is not stale (migration 116). This is the only
    // route that inserts a comment with author_kind='user'; the agent's own comments are written by
    // the agent-run route and by the sweep, and those must NOT reset — Rem replying to itself
    // cannot be what earns a task three more chances to nag.
    await resetTaskStaleness(userId, req.params.id);
    return res.status(201).json(formatComment(result.rows[0]));
  } catch (error: any) {
    console.error('[TASKS] Error creating comment:', error.message);
    res.status(500).json({ error: error.message || 'Failed to create comment' });
  }
});

/**
 * POST /api/v1/tasks/:id/agent-run — run the GMI AgentBox cloud agent against the
 * task + its comment thread, then persist the agent's reply as a cloud_agent comment.
 * Body: { instruction?, runtime? }. Always returns 201 with a comment — on service
 * failure it persists a clearly-labelled stub so the demo never hard-fails.
 *
 * Structured run-state (migration 019): stamps run_status='running' + a generated
 * run_id BEFORE dispatch, then a terminal run_status (done/review/blocked) on
 * completion — so "this task is being worked right now" is state ON the task, not
 * just a comment. The response is `{ ...comment, task_run }` so the client gets the
 * new run-state without a follow-up GET. docs/rebuild/19-TASKS-VS-WORKBOARD.md.
 *
 * AI autonomy: the agent APPLIES the status it decides on directly to `tasks.status`
 * (not just proposing it). The comment records `previous_status` (migration 028) as the
 * Undo target, so the client shows "Applied: <status>" + Undo instead of Accept.
 *
 * Event-aware: a calendar-event-backed task (type 'calendar_event') has no
 * "in progress" phase, so an in_progress proposal on one is suppressed (no apply, no
 * chip) — "in progress" on a birthday is nonsense; blocked / completed stay valid.
 * See docs/agentbox/CONTRACT.md §4 and §5.
 */
router.post('/tasks/:id/agent-run', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const task = await loadOwnedTask(req.params.id, userId);
    if (!task) return res.status(404).json({ error: 'Task not found' });

    const instruction =
      typeof req.body?.instruction === 'string' && req.body.instruction.trim()
        ? req.body.instruction.trim()
        : undefined;

    const commentsResult = await pool.query(
      `SELECT ${COMMENT_RETURNING} FROM task_comments WHERE task_id = $1::uuid ORDER BY created_at ASC`,
      [req.params.id],
    );
    const comments = commentsResult.rows.map(formatComment);

    // Mark the task as actively being worked BEFORE dispatch. The generated run_id
    // correlates this run with the comment it produces (and a later, newer run).
    const runId = randomUUID();
    // Stamp the STABLE per-task session key (`rem-task-<taskId>`) so the client's
    // "Open conversation" jump (P2) has a handle to route to. Unlike run_id (which
    // changes every run), session_key is stable across runs — the same helper the
    // orchestrator sweep uses (taskSessionKey), so a manual run and a swept run land
    // on the same continuation chat for a task. Stamping it at run START (not
    // completion) means a run that fails mid-flight still leaves the key populated,
    // so a partially-run task isn't confusingly missing its conversation handle;
    // being stable, re-running never orphans a prior key. Idempotent on re-run.
    const sessionKey = taskSessionKey(req.params.id);
    // Dispatching a run is a USER action on this specific task (migration 116): the work is Rem's,
    // but the tap is the person's, and it is as clear a signal that the task is still real as
    // editing it would be — so clear the brief's nag counter and any `stale_at` marker. Folded into
    // the dispatch stamp rather than issued as its own statement so it is atomic with the run start
    // and costs no extra round-trip; stamping it at START (not completion) means a run that dies
    // mid-flight still leaves the task un-stale.
    //
    // The autonomous `orchestrator-sweep` path deliberately does NOT do this. It dispatches runs
    // nobody asked for, so it must not be able to revive a task the user has been ignoring.
    await pool.query(
      `UPDATE tasks
          SET run_status = 'running', run_id = $1, session_key = $2, run_started_at = NOW(),
              run_last_heartbeat_at = NOW(), updated_at = NOW(),
              ${RESET_STALENESS_SET_CLAUSES.join(', ')}
        WHERE id = $3::uuid AND user_id = $4::uuid`,
      [runId, sessionKey, req.params.id, userId],
    );

    let agentResult: AgentRunResult;
    try {
      // Run-now runs on the OWNER'S GATEWAY, like every other agent turn in this backend.
      //
      // This call previously withheld `userId` on purpose, under a comment claiming the
      // AgentBox JSON path was "the only consumer of the structured `proposed_status`
      // contract". That was checked and it was not so: `GMI_AGENTBOX_URL` is set nowhere in
      // this repo's deploy, and the observed failure is a GMI 429 — i.e. the run was on
      // `runViaGmiMaaS`, whose status signal was a regex over the model's prose. Withholding
      // `userId` therefore protected nothing and billed the operator's shared org key for
      // work metered to nobody. `task-verdict.ts` is the contract that actually replaces it.
      agentResult = await runAgentOnTask(formatTask(task), comments, instruction, {
        userId,
        sessionKey,
      });
    } catch (serviceError: any) {
      // runAgentOnTask is designed never to throw, but guard anyway so we always
      // persist a comment rather than 500 the run.
      console.error('[TASKS] agent-run service threw:', serviceError?.message);
      agentResult = {
        reply: gatewayFailureBody('error'),
        errored: true,
        verdictSource: 'none',
        // Mode `unknown` deliberately: this catch fires when runAgentOnTask itself broke, so we
        // have no evidence about the runtime and must not assert one. Guessing `rem_managed`
        // here would tell a BYOK user to upgrade a plan that is not their problem.
        runBlock: { code: 'runtime_error', mode: 'unknown' },
      };
    }

    let proposedStatus =
      agentResult.proposedStatus && PROPOSED_STATUSES.has(agentResult.proposedStatus)
        ? agentResult.proposedStatus
        : null;

    // Event-aware lifecycle: a calendar event has no "in progress" phase — an event is
    // scheduled, then it happens (or is blocked / done). "In progress" on a birthday is
    // nonsense, so suppress that one proposal for event-backed tasks (type
    // 'calendar_event'). blocked / completed / cancelled / pending stay meaningful, so
    // they pass through unchanged. Suppressing here (vs. in the agent) keeps the rule in
    // one place and event-agnostic for the model.
    const isEvent = (task.type ?? 'task') === 'calendar_event';
    if (isEvent && proposedStatus === 'in_progress') {
      proposedStatus = null;
    }

    // AI autonomy: the agent APPLIES the status it decided on to the task's `status`
    // column directly, rather than only proposing it for the human to Accept. We record
    // the prior value (`previousStatus`) on the comment so the client can offer a
    // one-tap Undo. We only apply (and only stamp previous_status) when the proposal is
    // an actual change — re-affirming the current status is a no-op, not an "apply".
    const previousStatus: string | null = task.status ?? null;
    const willApply = proposedStatus !== null && proposedStatus !== previousStatus;
    const appliedStatus = willApply ? proposedStatus : null;
    const commentPreviousStatus = willApply ? previousStatus : null;

    // Terminal run-state from a structured mapping (not a string match on the reply).
    // Derive it from the post-suppression status so an event whose in_progress was
    // dropped doesn't land on a status it can't hold.
    const runStatus = terminalRunStatus({
      ...agentResult,
      proposedStatus: proposedStatus ?? undefined,
    });
    // WHY THE RUN DID NOT HAPPEN, persisted (migration 121). Written on EVERY terminal write,
    // including the success path where both values are NULL — a run that succeeds must clear a
    // previous run's block, or the task keeps advertising a stale "your key was refused" long
    // after the user fixed it. Nulling is the whole reason this is unconditional rather than
    // tacked onto the error branch.
    const runBlockCode = agentResult.runBlock?.code ?? null;
    const runBlockMode = agentResult.runBlock?.mode ?? null;
    const taskRunResult = await pool.query(
      appliedStatus
        ? `UPDATE tasks
              SET run_status = $1, status = $2, run_block_code = $3, run_block_mode = $4,
                  run_last_heartbeat_at = NOW(), updated_at = NOW()
            WHERE id = $5::uuid AND user_id = $6::uuid
            RETURNING ${RETURNING}`
        : `UPDATE tasks
              SET run_status = $1, run_block_code = $2, run_block_mode = $3,
                  run_last_heartbeat_at = NOW(), updated_at = NOW()
            WHERE id = $4::uuid AND user_id = $5::uuid
            RETURNING ${RETURNING}`,
      appliedStatus
        ? [runStatus, appliedStatus, runBlockCode, runBlockMode, req.params.id, userId]
        : [runStatus, runBlockCode, runBlockMode, req.params.id, userId],
    );

    // The terminal comment is stamped now (created_at DEFAULT NOW()) — i.e. today.
    // Stamp the comment with the run id it executed in (migration 022) — the same
    // run_id stamped on the task above. This is the handle the client uses to open
    // the session/chat that produced this activity row.
    //
    // ATTRIBUTION FOLLOWS THE RUNTIME THAT ACTUALLY RAN. This used to record
    // `runtime='agentbox'` / "Rem Cloud (AgentBox)"; the run now happens on the user's own
    // gateway, so it records what the orchestrator sweep already records for the same
    // runtime: `'gateway'` (migration 031 added it to the CHECK constraint for exactly this
    // reason). Leaving the old value would make every future consumer read a wrong stored
    // fact about which runtime did the work — the same failure CLAUDE.md documents for
    // `clientId`. Decodable on the client today: `TaskRuntimeKind.gateway`
    // (Shared/Models/TaskCollaboration.swift:25) is `isCloud` and displays as "Rem".
    const result = await pool.query(
      `INSERT INTO task_comments (task_id, user_id, author_kind, author_label, body, proposed_status, previous_status, runtime, session_id, run_block_code, run_block_mode)
       VALUES ($1::uuid, $2::uuid, 'cloud_agent', 'Rem Cloud', $3, $4, $5, 'gateway', $6, $7, $8)
       RETURNING ${COMMENT_RETURNING}`,
      [
        req.params.id,
        userId,
        agentResult.reply,
        proposedStatus,
        commentPreviousStatus,
        runId,
        runBlockCode,
        runBlockMode,
      ],
    );
    // THE RUN WRITES WHAT IT LEARNED (migration 120). The comment above is the
    // append-only "what happened this run"; this is the in-place "what I know NOW", so
    // the NEXT run opens with this run's state instead of starting from zero. Only the
    // agent's delimited block is rewritten — anything the user typed here survives
    // byte-for-byte, and a run that returned no summary is a no-op rather than an
    // erasure. Runs after the comment INSERT and is best-effort: the comment is the
    // durable record of the run, and losing the bookkeeping write must not 500 a run
    // that actually succeeded.
    const storedDescription = await applyAgentTaskContext(
      req.params.id,
      userId,
      agentResult.taskContext,
    );

    // Persist the run's conversation turns (the ask + Rem's reply) as a replayable
    // transcript (migration 025), keyed by the same run_id stamped on the comment.
    // This is what makes opening the task chat continue the REAL conversation rather
    // than a prefilled-but-empty composer (#869). Best-effort: never fails the run.
    const ask = deriveRunAsk(task, comments, instruction);
    await persistRunTranscript(req.params.id, userId, runId, ask, agentResult.reply);

    // Reflect the description the run just wrote in the returned task_run, so the client
    // shows Rem's new context without a follow-up GET (same reason run-state is echoed).
    const taskRunRow = taskRunResult.rows[0]
      ? { ...taskRunResult.rows[0], ...(storedDescription !== null ? { description: storedDescription } : {}) }
      : null;
    const taskRun = taskRunRow ? formatTask(taskRunRow) : null;
    return res.status(201).json({ ...formatComment(result.rows[0]), task_run: taskRun });
  } catch (error: any) {
    console.error('[TASKS] Error running agent:', error.message);
    res.status(500).json({ error: error.message || 'Failed to run agent' });
  }
});

export default router;
