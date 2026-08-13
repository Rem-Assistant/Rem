/**
 * Route cloud agent work through the user's OpenClaw GATEWAY (Move-2 / AgentBox-drop).
 *
 * Instead of calling a direct GMI / AgentBox HTTP endpoint, this drives a full agent
 * turn on the user's own gateway via the `chat.send` WS RPC. That gives us ONE runtime
 * and ONE prompt (the user's real Rem agent, with its tools + persona), and — crucially —
 * the turn PERSISTS to `~/.openclaw/agents/main/sessions/<sessionId>.jsonl`, the same
 * sessions the app loads. So a cron/routine run threads into a chat the user can open.
 *
 * Mechanism (verified against openclaw/src/gateway/server-methods/chat.ts):
 *   - `chat.send` acks async as `{ runId, status:"started" }` (chat.ts:2215-2219).
 *   - The final assistant text arrives LATER as a server-pushed `chat` event with
 *     `state:"final"` (broadcastChatFinal, chat.ts:1657-1674). The event payload carries
 *     `{ runId, sessionKey, seq, state, message }`; `message` is a projected display
 *     message with `content:[{type:"text",text}]` (mirrors RemChatTransport.swift:556-588).
 *   - The `chat` broadcast requires `operator.read` scope, which the backend control-ui
 *     connection already holds (server-broadcast.ts EVENT_SCOPE_GUARDS + gateway-pair
 *     connect scopes).
 *
 * Never throws: every failure path (no gateway, wake failed, timeout, gateway error)
 * degrades to a structured `{ ok:false, reason }` so a cron caller can log + fall back
 * without crashing. See lifecycle notes on `runAgentTurnOnGateway`.
 */

import { randomUUID } from 'node:crypto';
import { withGatewayRequester } from './gateway-pair.service.js';

/** Default per-turn budget — matches the iOS app's 120s chat.send window. */
export const DEFAULT_AGENT_TURN_TIMEOUT_MS = 120_000;

/**
 * Larger budget for the FIRST turn on a just-woken (cold) gateway. Waking the Fly machine
 * only reports the HTTP server healthy (`/setup/healthz`) — the agent model is still
 * cold-loaded on the first `chat.send`, which can exceed the 120s warm budget and time out.
 * When `wakeGatewayForUser` reports it actually STARTED the machine (`action:'start'`), we
 * grant this longer window so a cold gateway's first authoring turn completes instead of
 * failing the cron. Tune here.
 */
export const COLD_START_AGENT_TURN_TIMEOUT_MS = 240_000;

/**
 * `yyyymmdd` (UTC) for date-scoping recurring session keys (digest/memory). Keeps a
 * recurring run's session from growing unbounded — the agent would otherwise re-read
 * every prior run as history (token bloat + bias). Callers pass their own `now` so this
 * never reads the clock at import time.
 */
export function utcDateStamp(now: Date): string {
  return now.toISOString().slice(0, 10).replace(/-/g, '');
}

export interface GatewayAgentTurnOptions {
  userId: string;
  /** The full instruction/prompt text for this turn (system framing + context inlined). */
  message: string;
  /** Stable key per task/routine/user so runs thread into ONE loadable chat, not many one-offs. */
  sessionKey: string;
  /** Per-turn budget in ms for the async `chat` final event. Defaults to 120s. */
  timeoutMs?: number;
  /**
   * Per-turn budget in ms to use INSTEAD of `timeoutMs` when the wake actually started a cold
   * gateway (model cold-load can exceed the warm budget). Defaults to
   * `COLD_START_AGENT_TURN_TIMEOUT_MS`. Ignored when the gateway was already warm.
   */
  coldStartTimeoutMs?: number;
  /** Thinking level for the turn. Empty string = gateway default (matches the app). */
  thinking?: string;
}

/** Why the gateway path could not produce a turn (structured — callers branch on it). */
export type GatewayAgentTurnFailureReason =
  | 'no_gateway' // user has no gateway provisioned
  | 'wake_failed' // gateway exists but did not become ready in time
  | 'timeout' // chat.send acked but no final event within timeoutMs
  | 'error'; // gateway rejected chat.send, or an unexpected transport error

/**
 * One tool invocation the agent made during a turn, as observed on the gateway's own event
 * stream — NOT scraped from the assistant's prose.
 *
 * This is the structured channel a machine decision belongs on (`task-verdict.ts`). The
 * gateway validates a tool call's arguments against the tool's TypeBox schema before the
 * tool executes, so by the time `args` reaches us it has already been type-checked at the
 * source. Mirrors what the iOS app consumes from the identical event
 * (`RemChatTransport.swift: browserToolActivity`, which reads `data["name"]`,
 * `data["toolCallId"]` and `data["args"]` off the same payload).
 */
export interface ObservedToolCall {
  /** The tool's name, e.g. `browser`, `nodes`, `rem_task_report`. */
  name: string;
  /** The gateway's id for this specific invocation, when it supplied one. */
  toolCallId?: string;
  /** The arguments the model passed — schema-validated by the gateway before execute. */
  args?: unknown;
  /** The tool's own return value, present only once the `end` phase arrives. */
  result?: unknown;
}

export type GatewayAgentTurnResult =
  | {
      ok: true;
      text: string;
      runId: string;
      sessionKey: string;
      /**
       * Tool calls observed during this turn, in invocation order. Empty when the turn used
       * no tools — and ALSO empty if the gateway declined to stream tool events, so an empty
       * array is "nothing observed", never "the agent used no tools". Callers must treat a
       * missing verdict here as no verdict, not as a verdict of "none".
       */
      toolCalls: ObservedToolCall[];
    }
  | { ok: false; reason: GatewayAgentTurnFailureReason; message?: string };

/**
 * Strip the canonical `agent:<agentId>:` prefix the gateway prepends to every
 * custom session key, returning the bare alias callers actually pass
 * (`agent:main:rem-brief-20260704` → `rem-brief-20260704`, `agent:main:main` →
 * `main`). Returns the input unchanged for keys that are already bare.
 *
 * WHY THIS EXISTS: the gateway canonicalizes every custom session key before it
 * persists/broadcasts (openclaw `session-store-key.ts: canonicalizeSessionKeyForAgent`).
 * We send `chat.send` with the BARE key, but the async `chat` final event comes
 * back carrying the CANONICAL key. A raw `payload.sessionKey === opts.sessionKey`
 * compare therefore never matches, so the final event is dropped and the turn
 * times out at 120s even though it completed. The iOS app hit the same wall and
 * solved it the same way (`RemChatTransport.swift: bareSessionKey` /
 * `normalizingCanonicalSessionKey`) — this mirrors that (principle 1).
 */
export function bareSessionKey(key: string): string {
  const parts = key.split(':');
  if (parts.length >= 3 && parts[0] === 'agent') {
    const rest = parts.slice(2).join(':');
    return rest || key;
  }
  return key;
}

/** Extract the assistant's display text from a projected `chat` final message payload. */
function extractAssistantText(message: unknown): string {
  if (!message || typeof message !== 'object') return '';
  const m = message as Record<string, unknown>;
  if (typeof m.text === 'string' && m.text.trim()) return m.text.trim();
  if (Array.isArray(m.content)) {
    const text = m.content
      .map((block) =>
        block && typeof block === 'object' && (block as { type?: unknown }).type === 'text' &&
        typeof (block as { text?: unknown }).text === 'string'
          ? ((block as { text: string }).text)
          : '',
      )
      .filter(Boolean)
      .join('\n\n')
      .trim();
    if (text) return text;
  }
  return '';
}

export interface GatewayAssistantHistoryMessage {
  messageId: string | null;
  text: string;
  timestamp: number | string | null;
}

export type GatewayAssistantHistoryResult =
  | { ok: true; messages: GatewayAssistantHistoryMessage[] }
  | { ok: false; reason: string };

/**
 * Read projected assistant messages from one gateway transcript without exposing credentials.
 *
 * Operator repair jobs pass only a backend user id. Gateway URL/token resolution stays inside
 * the backend process, and the returned shape deliberately excludes every raw envelope field
 * except message identity, timestamp, and display text. Callers must still fail closed when a
 * requested identity is absent or ambiguous.
 */
export async function readAssistantHistoryOnGateway(opts: {
  userId: string;
  sessionKey: string;
  limit?: number;
  timeoutMs?: number;
}): Promise<GatewayAssistantHistoryResult> {
  try {
    const { getGatewayCredentials, getSetupPassword, wakeGatewayForUser } = await import(
      './gateway.service.js'
    );
    const creds = await getGatewayCredentials(opts.userId);
    if (!creds) return { ok: false, reason: 'no_gateway' };

    const wake = await wakeGatewayForUser(opts.userId).catch(() => null);
    if (!wake?.gatewayReady) return { ok: false, reason: 'wake_failed' };

    const setupPassword = await getSetupPassword(opts.userId).catch(() => undefined);
    const history = await withGatewayRequester<unknown>(
      creds.gateway_url,
      creds.gateway_token,
      async (request) => {
        const response = await request('chat.history', {
          sessionKey: opts.sessionKey,
          limit: opts.limit ?? 500,
        });
        if (!response.ok) throw new Error('history_failed');
        return response.result;
      },
      setupPassword,
      opts.timeoutMs ?? 20_000,
    );
    if (!history) return { ok: false, reason: 'history_failed' };

    const raw = history as { messages?: unknown[] } | unknown[];
    const messages = Array.isArray(raw) ? raw : raw.messages;
    if (!Array.isArray(messages)) return { ok: false, reason: 'history_malformed' };

    return {
      ok: true,
      messages: messages.flatMap((entry): GatewayAssistantHistoryMessage[] => {
        if (!entry || typeof entry !== 'object') return [];
        const message = entry as Record<string, unknown>;
        const role = typeof message.role === 'string' ? message.role.trim().toLowerCase() : '';
        if (role !== 'assistant' && role !== 'model') return [];
        const text = extractAssistantText(message);
        if (!text) return [];
        const openClawMetadata = message.__openclaw;
        const nestedId = openClawMetadata && typeof openClawMetadata === 'object'
          ? (openClawMetadata as Record<string, unknown>).id
          : undefined;
        // Persisted chat.history messages project inject identity under __openclaw.id. Retain the
        // older top-level fields for wrapper compatibility, but prefer the canonical nested value.
        const rawId = nestedId ?? message.id ?? message.messageId;
        const timestamp = message.timestamp;
        return [{
          messageId: typeof rawId === 'string' && rawId.trim() ? rawId.trim() : null,
          text,
          timestamp: typeof timestamp === 'number' || typeof timestamp === 'string'
            ? timestamp
            : null,
        }];
      }),
    };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, reason: message === 'history_failed' ? message : 'history_error' };
  }
}

/**
 * `chat.inject` has no idempotency field. Its optional `label` is rendered into message text by
 * upstream (`chat-transcript-inject.ts`), so it cannot carry invisible reconciliation metadata.
 * Reconciliation therefore counts exact assistant-prose occurrences. The delivery row persists
 * the count observed before its first injection attempt; only a later count increase proves this
 * artifact landed. This stays backward-compatible and adds no wire-visible preamble.
 */
function injectedMessageOccurrenceCount(result: unknown, message: string): number {
  const raw = result as { messages?: unknown[] } | unknown[] | undefined;
  const messages = Array.isArray(raw) ? raw : raw?.messages;
  if (!Array.isArray(messages)) return 0;
  const expected = message.trim();
  return messages.filter((entry) => {
    if (!entry || typeof entry !== 'object') return false;
    const role = (entry as { role?: unknown }).role;
    return role === 'assistant' && extractAssistantText(entry) === expected;
  }).length;
}

/**
 * Remove a gateway conversation session from the session list.
 *
 * ⚠️ THIS DOES NOT ERASE THE TRANSCRIPT, AND AN EARLIER VERSION OF THIS DOCBLOCK CLAIMED IT DID.
 * Upstream's `sessions.delete` ARCHIVES: `archiveFileOnDisk` (`session-transcript-files.fs.ts:127`)
 * renames the file to `<sessionId>.jsonl.<reason>.<ts>` and then calls
 * `emitSessionTranscriptUpdate` with the new path. The content therefore stays on the Fly volume
 * and is announced to the memory-index subscribers. There is no erase RPC at the pinned runtime.
 *
 * So the honest scope: this makes the session unreachable from the app's session list and from
 * `sessions.list`. It is NOT a data-erasure guarantee, and nobody should tell a user their mail
 * content was deleted on the strength of it. Scrubbing the archives needs its own mechanism.
 *
 * Exists for BACKGROUND turns whose transcript is a byproduct, not a product. `chat.send` persists
 * — on this path it creates the session implicitly, no `sessions.create` involved — so a background
 * classifier running per tick leaves one openable chat per tick, each holding whatever context the
 * prompt inlined. A fresh per-run key does NOT avoid this; it multiplies it.
 *
 * NO EXPLICIT WAKE, which is not the same as no wake. Callers invoke this straight after a turn,
 * when the gateway is warm, so `wakeGatewayForUser` is skipped. But `fly.toml` sets
 * `auto_start_machines` with `min_machines_running = 0`, so merely opening the socket resumes a
 * suspended machine through the Fly proxy. That is why callers must not call this when no session
 * was created — see the guard in `signal-relevance.service.ts`.
 *
 * Never throws — cleanup failure must not fail the caller's real work.
 *
 * Returns the gateway's OWN `deleted` field, not the envelope's `ok`. Upstream answers
 * `{ok, key, deleted, archived}` (`server-methods/sessions.ts`) where `deleted` is FALSE when the
 * store held no matching entry. Reading `response.ok` reported success for a delete that removed
 * nothing — the one structured signal proving this works, discarded in favour of the envelope.
 */
export async function deleteSessionOnGateway(opts: {
  userId: string;
  sessionKey: string;
  timeoutMs?: number;
}): Promise<boolean> {
  try {
    const { getGatewayCredentials, getSetupPassword } = await import('./gateway.service.js');
    const creds = await getGatewayCredentials(opts.userId);
    if (!creds) return false;

    const setupPassword = await getSetupPassword(opts.userId).catch(() => undefined);
    const deleted = await withGatewayRequester<boolean>(
      creds.gateway_url,
      creds.gateway_token,
      async (request) => {
        const response = await request('sessions.delete', { key: opts.sessionKey });
        if (!response.ok) return false;
        const result = response.result as { deleted?: unknown } | undefined;
        return result?.deleted === true;
      },
      setupPassword,
      opts.timeoutMs ?? 15_000,
    );
    return deleted === true;
  } catch {
    return false;
  }
}

/**
 * Inject a single assistant-authored message into a gateway conversation session, making it the
 * VISIBLE opener the app loads via `chat.history` — with NO model turn and NO leaked prompt.
 *
 * This is how the daily brief becomes "the chat's first message" (WS2 doc 38 §5). The spike
 * proved `chat.inject` appends exactly the text passed, as `role:"assistant"`, no turn (see the
 * `project_brief_shape_spike` note). It is the clean counterpart to the #985 leak: `chat.send`
 * runs a full turn (persisting the internal prompt + an ack); `chat.inject` writes only this text.
 *
 * Safety: we only seed an EMPTY (or missing) session — never inject into a conversation the user
 * has already started, which would drop a brief into the middle of their chat. `chat.inject` also
 * 404s on an unknown session, so we `sessions.create` first (agentId 'main' → the app's
 * `agent:main:<key>` conversation).
 *
 * Scope: `chat.inject` requires `operator.admin`; the backend already connects with it
 * (`gateway-pair.service` withGatewayConnection). Never throws; returns a structured result.
 */
export async function injectAssistantMessageOnGateway(opts: {
  userId: string;
  sessionKey: string;
  message: string;
  timeoutMs?: number;
  /** Append to an existing transcript. Reserved for idempotent, persisted daily artifacts. */
  allowNonEmptySession?: boolean;
  /** Stable persisted identity. Enables occurrence-count reconciliation without visible markers. */
  artifactId?: string;
  /** Exact-prose count persisted before this artifact's first injection attempt. */
  reconciliationBaseline?: number | null;
  /** Persist the first baseline and heartbeat/revalidate the delivery lease before side effect. */
  prepareArtifactAttempt?: (baselineOccurrenceCount: number) => Promise<boolean>;
}): Promise<{ ok: boolean; reason?: string; messageId?: string; reconciled?: boolean }> {
  try {
    const { getGatewayCredentials, getSetupPassword, wakeGatewayForUser } = await import(
      './gateway.service.js'
    );
    const creds = await getGatewayCredentials(opts.userId);
    if (!creds) return { ok: false, reason: 'no_gateway' };

    const wake = await wakeGatewayForUser(opts.userId).catch(() => null);
    if (!wake || !wake.gatewayReady) return { ok: false, reason: 'wake_failed' };

    const setupPassword = await getSetupPassword(opts.userId).catch(() => undefined);
    const timeoutMs = opts.timeoutMs ?? 20_000;
    let reconciliationBaseline = opts.reconciliationBaseline ?? null;

    const reconcile = async (): Promise<boolean> => {
      if (!opts.artifactId || reconciliationBaseline === null) return false;
      const found = await withGatewayRequester<boolean>(
        creds.gateway_url,
        creds.gateway_token,
        async (request) => {
          const history = await request('chat.history', {
            sessionKey: opts.sessionKey,
            limit: 200,
          });
          return history.ok &&
            injectedMessageOccurrenceCount(history.result, opts.message) > reconciliationBaseline!;
        },
        setupPassword,
        timeoutMs,
      );
      return found === true;
    };

    let result: {
      ok: boolean;
      reason?: string;
      messageId?: string;
      reconciled?: boolean;
    } | null;
    try {
      result = await withGatewayRequester<{
        ok: boolean;
        reason?: string;
        messageId?: string;
        reconciled?: boolean;
      }>(
        creds.gateway_url,
        creds.gateway_token,
        async (request) => {
          // Never seed a session the user has already engaged. A missing session returns
          // ok:true with messages:[] (an errored read is also treated as empty) → safe to
          // create + inject; a non-empty history means the user is mid-conversation → skip.
          const hist = await request('chat.history', {
            sessionKey: opts.sessionKey,
            limit: opts.artifactId ? 200 : 1,
          });
          if (opts.artifactId) {
            if (!hist.ok) return { ok: false, reason: 'history_failed' };
            const occurrenceCount = injectedMessageOccurrenceCount(hist.result, opts.message);
            if (reconciliationBaseline !== null && occurrenceCount > reconciliationBaseline) {
              return { ok: true, reconciled: true };
            }
            const baseline = reconciliationBaseline ?? occurrenceCount;
            if (!opts.prepareArtifactAttempt || !(await opts.prepareArtifactAttempt(baseline))) {
              return { ok: false, reason: 'delivery_lease_lost' };
            }
            reconciliationBaseline = baseline;
          }
          const raw = hist.ok
            ? ((hist.result as { messages?: unknown[] } | unknown[] | undefined) ?? [])
            : [];
          const msgs = Array.isArray(raw) ? raw : ((raw as { messages?: unknown[] }).messages ?? []);
          if (!opts.allowNonEmptySession && Array.isArray(msgs) && msgs.length > 0) {
            return { ok: false, reason: 'session_not_empty' };
          }

          // A transcript with messages is already backed by a real session. Only create the empty /
          // missing case; this avoids asking `sessions.create` to recreate the durable orchestrator
          // on every new day's append.
          if (!Array.isArray(msgs) || msgs.length === 0) {
            await request('sessions.create', { key: opts.sessionKey, agentId: 'main' });
          }
          const injected = await request('chat.inject', {
            sessionKey: opts.sessionKey,
            message: opts.message,
          });
          if (!injected.ok) {
            return { ok: false, reason: injected.error?.message ?? 'chat.inject rejected' };
          }
          const messageId = (injected.result as { messageId?: unknown } | undefined)?.messageId;
          return {
            ok: true,
            ...(typeof messageId === 'string' ? { messageId } : {}),
          };
        },
        setupPassword,
        timeoutMs,
      );
    } catch {
      result = null;
    }
    if (result?.ok) return result;
    // `chat.inject` may have committed even when its response was lost. Re-open the gateway and
    // reconcile the stable transcript marker before allowing the database lease to retry.
    if (await reconcile()) return { ok: true, reconciled: true };
    return result ?? { ok: false, reason: 'connection_closed' };
  } catch (err: unknown) {
    return { ok: false, reason: err instanceof Error ? err.message : String(err) };
  }
}

/**
 * Run a single agent turn on the user's gateway and return the final assistant text.
 *
 * Lifecycle (each degrades gracefully, never throws):
 *   - gateway asleep  → `wakeGatewayForUser` starts the Fly machine and waits for health;
 *                        if it never reports ready, returns `{ ok:false, reason:'wake_failed' }`.
 *   - no gateway      → returns `{ ok:false, reason:'no_gateway' }` (user never deployed one,
 *                        or non-Fly stub). Caller falls back to GMI or skips.
 *   - turn times out  → chat.send acked but no `state:"final"` chat event within timeoutMs →
 *                        `{ ok:false, reason:'timeout' }`.
 *   - gateway error   → chat.send rejected / `state:"error"` / transport error →
 *                        `{ ok:false, reason:'error', message }`.
 */
export async function runAgentTurnOnGateway(
  opts: GatewayAgentTurnOptions,
): Promise<GatewayAgentTurnResult> {
  const warmTimeoutMs = opts.timeoutMs ?? DEFAULT_AGENT_TURN_TIMEOUT_MS;
  const coldTimeoutMs = opts.coldStartTimeoutMs ?? COLD_START_AGENT_TURN_TIMEOUT_MS;

  try {
    // Dynamic import so a module-load of this service (and its caller chain) never eagerly
    // pulls db/pool + required env.
    const { getGatewayCredentials, getSetupPassword, wakeGatewayForUser } = await import(
      './gateway.service.js'
    );

    const creds = await getGatewayCredentials(opts.userId);
    if (!creds) return { ok: false, reason: 'no_gateway' };

    // Wake the (possibly sleeping) gateway before opening the operator socket. For Fly
    // gateways this starts the machine + waits for health; for others it's a noop that
    // reports ready. A provisioned-but-unreachable gateway → wake_failed.
    const wake = await wakeGatewayForUser(opts.userId).catch(() => null);
    if (!wake || !wake.gatewayReady) {
      return { ok: false, reason: 'wake_failed' };
    }

    // COLD-START: if the wake actually STARTED the machine, the model is still cold-loading
    // on this first turn — grant the larger budget so it doesn't time out at the warm 120s.
    // A warm ('noop') gateway keeps the normal budget.
    const timeoutMs = wake.action === 'start' ? coldTimeoutMs : warmTimeoutMs;

    const setupPassword = await getSetupPassword(opts.userId).catch(() => undefined);
    const idempotencyKey = randomUUID();

    // Give the socket headroom beyond the turn budget for the connect handshake +
    // wake slack; the inner event-wait timer is the real bound and fires first.
    const connectionTimeoutMs = timeoutMs + 20_000;

    // withGatewayConnection resolves `undefined` when the socket closes before `fn`
    // settles (gateway-pair.service.ts ws.onclose) — realistic when a sleeping gateway
    // drops mid-turn. Coerce that to a structured failure so callers never see an
    // undefined that would blow past their `.ok` check (and their try/catch fallback).
    const result = await withGatewayRequester<GatewayAgentTurnResult>(
      creds.gateway_url,
      creds.gateway_token,
      (request, { onEvent }) =>
        new Promise<GatewayAgentTurnResult>((resolve) => {
          let runId: string | null = null;
          let settled = false;

          const finish = (result: GatewayAgentTurnResult) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve(result);
          };

          const timer = setTimeout(
            () => finish({ ok: false, reason: 'timeout' }),
            timeoutMs,
          );

          // ── Correlating a `chat` final/error to OUR turn ─────────────────────
          // The gateway ALWAYS stamps `runId` on the broadcast final/error
          // (openclaw broadcastChatFinal, chat.ts:1657-1674 — `runId: params.runId`,
          // and clientRunId === our idempotencyKey, chat.ts:2025). That runId is
          // the authoritative correlator: it is unique per turn, so it disambiguates
          // even when TWO turns share the IDENTICAL session key (rem-brief-<date> is
          // fired by BOTH the daily cron AND every check-in; digest/memory/routine/
          // canary keys are stable and re-firable). The session key alone CANNOT.
          //
          // The subtle race: the async final can arrive BEFORE our own `chat.send`
          // ack resolves `runId` (a fast turn). If we settled a pre-ack final by
          // session-key alone, a *different* concurrent turn on the same key could
          // hand us ITS text (a brief showing a digest's content). So instead we
          // BUFFER any pre-ack event keyed by its runId and settle nothing until the
          // ack lands; once `runId` is known we correlate STRICTLY by runId, checking
          // the buffered pre-ack events first and every subsequent event after.
          //
          // Bare-key matching survives only as a genuine last resort: a final that
          // arrives with NO runId at all. Upstream always sets it today, so this path
          // is effectively dead — kept defensively in case a future/old gateway drops
          // the field, and never used to disambiguate between concurrent same-key runs.
          const wantSessionKey = bareSessionKey(opts.sessionKey);

          // ── Tool calls observed on this run ──────────────────────────────────
          // Keyed by toolCallId so the `end` phase (which carries `result`) lands on the
          // same entry the `start` phase (which carries `args`) created, rather than
          // appearing as a second, argument-less call. A Map also preserves insertion
          // order, which is invocation order.
          const observedToolCalls = new Map<string, ObservedToolCall>();
          const toolCallsInOrder = () => Array.from(observedToolCalls.values());

          const toResult = (payload: Record<string, unknown>): GatewayAgentTurnResult | null => {
            if (payload.state === 'final') {
              return {
                ok: true,
                text: extractAssistantText(payload.message),
                runId: typeof payload.runId === 'string' ? payload.runId : (runId ?? ''),
                sessionKey: opts.sessionKey,
                toolCalls: toolCallsInOrder(),
              };
            }
            if (payload.state === 'error') {
              return {
                ok: false,
                reason: 'error',
                message: typeof payload.errorMessage === 'string' ? payload.errorMessage : undefined,
              };
            }
            return null;
          };

          // Pre-ack finals/errors we can't yet attribute (runId still unknown), keyed
          // by the event's own runId so a runId-carrying event is settled ONLY if that
          // runId turns out to be ours once the ack lands.
          const bufferedByRunId = new Map<string, Record<string, unknown>>();
          // Same treatment for tool events that arrive before the ack: a tool call can be
          // dispatched inside the send→ack window, and attributing one by session key alone
          // would let a concurrent turn on the SAME key donate us its tool calls — which,
          // for a verdict-carrying tool, means applying another run's decision to this task.
          const bufferedToolEvents = new Map<string, Record<string, unknown>[]>();

          /**
           * Fold one `agent`/`stream:"tool"` payload into `observedToolCalls`.
           *
           * Shape per openclaw `src/gateway/server-chat.ts:648-665`: the payload is the raw
           * `AgentEventPayload` plus a `sessionKey`, and `data` carries `{ phase, name,
           * toolCallId, args, result }`. Control-UI recipients receive `result` in full —
           * the verbose-level stripping at `server-chat.ts:620-628` applies only to the
           * channel/node copy of the payload, not to ours.
           */
          const recordToolEvent = (payload: Record<string, unknown>) => {
            const data = payload.data;
            if (!data || typeof data !== 'object') return;
            const d = data as Record<string, unknown>;
            const name = typeof d.name === 'string' ? d.name : undefined;
            if (!name) return;
            // No toolCallId (older gateway, or an event that omits it) still has to be
            // recorded, so key on a synthetic id rather than dropping the call.
            const toolCallId =
              typeof d.toolCallId === 'string' && d.toolCallId
                ? d.toolCallId
                : `${name}:${observedToolCalls.size}`;
            const existing = observedToolCalls.get(toolCallId);
            const merged: ObservedToolCall = {
              name,
              ...(typeof d.toolCallId === 'string' && d.toolCallId ? { toolCallId: d.toolCallId } : {}),
              // `start` carries args, `end` carries result. Never let a later phase blank a
              // field an earlier one populated.
              ...(d.args !== undefined ? { args: d.args } : existing?.args !== undefined ? { args: existing.args } : {}),
              ...(d.result !== undefined
                ? { result: d.result }
                : existing?.result !== undefined
                  ? { result: existing.result }
                  : {}),
            };
            observedToolCalls.set(toolCallId, merged);
          };

          onEvent((event, payload) => {
            if (event === 'agent' && payload && typeof payload === 'object') {
              if (payload.stream !== 'tool') return;
              const eventRunId = typeof payload.runId === 'string' ? payload.runId : undefined;
              const eventSessionKey =
                typeof payload.sessionKey === 'string'
                  ? bareSessionKey(payload.sessionKey)
                  : undefined;
              if (runId) {
                if (eventRunId === runId || (!eventRunId && eventSessionKey === wantSessionKey)) {
                  recordToolEvent(payload);
                }
                return;
              }
              if (eventRunId) {
                if (eventSessionKey === wantSessionKey) {
                  const queue = bufferedToolEvents.get(eventRunId) ?? [];
                  queue.push(payload);
                  bufferedToolEvents.set(eventRunId, queue);
                }
                return;
              }
              if (eventSessionKey === wantSessionKey) recordToolEvent(payload);
              return;
            }
            if (event !== 'chat' || !payload || typeof payload !== 'object') return;
            if (payload.state !== 'final' && payload.state !== 'error') return;
            const eventRunId = typeof payload.runId === 'string' ? payload.runId : undefined;
            const eventSessionKey =
              typeof payload.sessionKey === 'string' ? bareSessionKey(payload.sessionKey) : undefined;

            if (runId) {
              // Ack has landed: correlate STRICTLY by runId. A same-key final from
              // another turn carries a different runId and is ignored.
              if (eventRunId === runId) {
                const result = toResult(payload);
                if (result) finish(result);
              }
              return;
            }

            // Pre-ack: we don't yet know our runId.
            if (eventRunId) {
              // Buffer by runId — DON'T settle by session key alone (that is the
              // concurrency bug: another turn on the same key could win the race).
              // When the ack lands we replay the buffered event whose runId matches.
              if (eventSessionKey === wantSessionKey) bufferedByRunId.set(eventRunId, payload);
              return;
            }

            // Genuinely no runId on the event (defensive last resort, see note above):
            // fall back to bare-key match. Nothing else can disambiguate it.
            if (eventSessionKey === wantSessionKey) {
              const result = toResult(payload);
              if (result) finish(result);
            }
          });

          request('chat.send', {
            sessionKey: opts.sessionKey,
            message: opts.message,
            thinking: opts.thinking ?? '',
            idempotencyKey,
            timeoutMs,
          })
            .then((ack) => {
              if (!ack.ok) {
                finish({ ok: false, reason: 'error', message: ack.error?.message ?? 'chat.send rejected' });
                return;
              }
              const ackRunId = ack.result?.runId;
              if (typeof ackRunId === 'string' && ackRunId) {
                runId = ackRunId;
                // Adopt pre-ack TOOL events before replaying the final, or a fast turn
                // whose final was also buffered would resolve with an empty toolCalls list
                // and silently drop a verdict that did arrive.
                for (const buffered of bufferedToolEvents.get(ackRunId) ?? []) {
                  recordToolEvent(buffered);
                }
                bufferedToolEvents.clear();
                // Replay any pre-ack final/error that turned out to be OURS. A fast
                // turn can emit its final inside the send→ack window; this makes sure
                // that legitimately-buffered final is still captured.
                const buffered = bufferedByRunId.get(ackRunId);
                if (buffered) {
                  const result = toResult(buffered);
                  if (result) finish(result);
                }
                bufferedByRunId.clear();
              }
            })
            .catch((err: unknown) => {
              finish({
                ok: false,
                reason: 'error',
                message: err instanceof Error ? err.message : String(err),
              });
            });
        }),
      setupPassword,
      connectionTimeoutMs,
    );
    return result ?? { ok: false, reason: 'error', message: 'gateway connection closed before final' };
  } catch (err: unknown) {
    return {
      ok: false,
      reason: 'error',
      message: err instanceof Error ? err.message : String(err),
    };
  }
}
