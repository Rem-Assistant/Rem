/**
 * Gateway management via WebSocket.
 *
 * Provides functions for auto-approving device pairing requests and
 * patching the gateway configuration (e.g., unblocking node commands).
 */

import WebSocket from 'ws';

/**
 * Gateway WS protocol version range this backend advertises at `connect` handshake time.
 *
 * ROOT CAUSE (#1087 live-test failure, "Connect rejected: protocol mismatch"): this used to be a
 * single hardcoded `PROTOCOL_VERSION = 3` sent as BOTH `minProtocol` and `maxProtocol` — a fixed
 * version, not a range. The pinned gateway image (the hosted gateway build, operated
 * separately, at a99c65a973d3bfa2e9f1288d9a25ba3e06b40c03 / 2026.5.10-beta.1)
 * bumped its OWN `PROTOCOL_VERSION` to 4 (openclaw/src/gateway/protocol/version.ts). The gateway's
 * handshake gate (openclaw/src/gateway/server/ws-connection/message-handler.ts
 * `supportsCurrentProtocol`) is `maxProtocol >= <gateway's PROTOCOL_VERSION> && minProtocol <=
 * <gateway's PROTOCOL_VERSION>` — sending a fixed `maxProtocol: 3` against a v4 gateway fails that
 * check (`3 >= 4` is false) and the gateway closes the socket with "protocol mismatch" before ever
 * reaching config.get/config.patch. This affected EVERY WS caller through this file (channels
 * connect, auto-approve, config-patch scripts), not just Composio — the MCP wiring path just
 * happened to be the one freshly exercised against this specific 5.10-beta gateway.
 *
 * FIX (mirrors upstream — principle 1): OpenClaw's own CLI client
 * (openclaw/src/gateway/client.ts, openclaw/src/gateway/call.ts) sends
 * `minProtocol: MIN_CLIENT_PROTOCOL_VERSION (3), maxProtocol: PROTOCOL_VERSION (4)` — a RANGE, so
 * it can speak to a gateway on either v3 or v4. We do the same here instead of a fixed version, so
 * this backend keeps working across a gateway protocol bump without another live break. Bump
 * `GATEWAY_MAX_PROTOCOL_VERSION` (and re-verify `GATEWAY_MIN_PROTOCOL_VERSION`) whenever
 * OPENCLAW_GIT_REF moves and openclaw/src/gateway/protocol/version.ts changes.
 */
const GATEWAY_MIN_PROTOCOL_VERSION = 3;
const GATEWAY_MAX_PROTOCOL_VERSION = 4;

/**
 * Client capabilities advertised at connect. `tool-events` is what makes the gateway stream
 * this connection the agent's live tool lifecycle for a run it started.
 *
 * WHY IT IS NEEDED AND NOT OPTIONAL: `chat.send` registers the CALLING connection as a
 * tool-event recipient only when its connect handshake advertised the capability —
 * openclaw `src/gateway/server-methods/chat.ts:2516-2531`
 * (`wantsToolEvents = hasGatewayClientCap(client?.connect?.caps, GATEWAY_CLIENT_CAPS.TOOL_EVENTS)`
 * guarding `context.registerToolEventRecipient(runId, connId)`). Without it the gateway
 * never sends this socket an `agent`/`stream:"tool"` event, so a run's tool calls — and any
 * machine verdict carried on one (`task-verdict.ts`) — are simply not delivered. The
 * capability is connection-scoped, so it has to be on the connect frame; there is no later
 * subscribe that substitutes for it.
 *
 * Mirrors the iOS operator connection, which advertises the same string for the same reason
 * (`RemClaw/Sources/Gateway/GatewayClient.swift:49`, `caps: ["tool-events"]`). Literal value
 * from upstream `src/gateway/protocol/client-info.ts:48`.
 *
 * Cost of advertising it on every backend connection: the gateway streams tool events to
 * this socket for runs THIS connection starts. Config patches and pairing calls start no
 * run, so they receive nothing extra.
 */
const GATEWAY_CLIENT_CAPS = ['tool-events'] as const;

/**
 * How often the backend sends a WebSocket ping frame to the gateway to keep a
 * long-lived operator socket alive.
 *
 * WHY: a backend-initiated agent turn (`runAgentTurnOnGateway`) can run for up
 * to ~120s with NO application frames flowing FROM the backend while the model
 * thinks. Fly's edge proxy (and the gateway wrapper's http-proxy) drop a socket
 * that looks idle, so the turn's `state:"final"` chat event never arrives and
 * `withGatewayConnection` resolves `undefined` → the caller reports
 * "gateway connection closed before final". TCP keepalive (set on the gateway
 * side, server.js) is not enough — the intermediaries measure application-level
 * activity. A periodic WS ping is a real frame that keeps the path warm, which
 * is exactly what a long-lived operator session (the iOS app) relies on. 25s
 * stays comfortably under the ~60s idle thresholds. Harmless for a genuinely
 * fast request/response call (settles before the first ping ever fires) and
 * actively useful for a SLOW one — `patchGatewayConfig`/`withGatewayRequester`
 * now budget up to `GATEWAY_RPC_TIMEOUT_MS` (120s) precisely because this
 * fleet's gateways can be slow to service an RPC even once "ready" (see that
 * constant's doc), so the heartbeat is what keeps a slow config.patch's socket
 * from being dropped as idle by an intermediary while it waits.
 *
 * Overridable via `GATEWAY_WS_HEARTBEAT_MS` (tests drive it down to assert pings
 * fire without waiting 25s; production leaves it at the default).
 */
function heartbeatIntervalMs(): number {
  const raw = Number(process.env.GATEWAY_WS_HEARTBEAT_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : 25_000;
}

/**
 * Default budget for a `withGatewayConnection`-based RPC round trip (connect handshake +
 * request/response) — used by `withGatewayRequester`'s default, `patchGatewayConfig`, and
 * `applyGatewayConfig`.
 *
 * ROOT CAUSE (#1087 live-debug, 3rd layer): these all previously hardcoded 15_000ms. That was fine
 * against a fast/idle gateway, but the fleet's shared-cpu-2x Fly machines can take 15-67s to
 * actually SERVICE an RPC even after `/gateway/wake` reports `ready: true` (the machine is
 * listening, but its request pipeline can still be cold/saturated) — see the runtime-bump
 * measurements referenced in this file's heartbeat comment above. A 15s budget for `patchGatewayConfig`
 * specifically has to cover TWO sequential round trips (config.get THEN config.patch) inside one
 * timer, making it even tighter than a single RPC. The live symptom was literally
 * `Error: WebSocket timeout after 15000ms waiting for a response from https://remclaw-...` on the
 * Composio MCP-wiring path (ensureComposioMcpWired), which uses both `withGatewayRequester` (the
 * "already wired" config.get check) and `patchGatewayConfig` (the actual write).
 *
 * FIX: mirror the other "this gateway can be slow" budgets already established in this codebase —
 * `DEFAULT_AGENT_TURN_TIMEOUT_MS` (gateway-agent.service.ts, 120_000) and `pollHealthcheck`'s
 * 120_000 (the managed pre-warm pool pipeline) — rather than inventing a new, smaller number. 120s comfortably covers
 * the cited 15-67s single-RPC worst case even for patchGatewayConfig's two sequential round trips.
 * Bumping this is safe: a longer timeout only makes a genuinely-broken call fail slower, it cannot
 * make a working call behave worse. (Deliberately NOT touched: the legacy WS-only
 * `tryApproveOnce`/`autoApproveDevices` pairing path and the HTTP `AbortSignal.timeout(...)` calls —
 * neither shares this constant or is exercised by the Composio wiring path; out of scope here.)
 */
const GATEWAY_RPC_TIMEOUT_MS = 120_000;

interface PendingDevice {
  requestId: string;
  deviceId: string;
  displayName?: string;
}

export class NoPendingPairingRequestError extends Error {
  approved = 0;

  constructor() {
    super('no pending pairing request found');
    this.name = 'NoPendingPairingRequestError';
  }
}

export class ApprovalCheckTimeoutError extends Error {
  lastError?: string;

  constructor(lastError?: string) {
    const suffix = lastError ? ` Last error: ${lastError}` : '';
    super(`auto-approve timed out before pending devices could be checked.${suffix}`);
    this.name = 'ApprovalCheckTimeoutError';
    this.lastError = lastError;
  }
}

export class ApprovalRetryFailedError extends Error {
  lastError?: string;

  constructor(lastError?: string) {
    const suffix = lastError ? ` Last error: ${lastError}` : '';
    super(`auto-approve failed while checking pending devices.${suffix}`);
    this.name = 'ApprovalRetryFailedError';
    this.lastError = lastError;
  }
}

function isHardApprovalFailure(lastError: string | undefined): boolean {
  if (!lastError) return false;
  return /\bHTTP (400|401|403)\b/i.test(lastError)
    || /connect rejected/i.test(lastError)
    || /unauthori[sz]ed/i.test(lastError)
    || /forbidden/i.test(lastError)
    || /setup auth/i.test(lastError)
    || /bad setup password/i.test(lastError);
}

function buildAutoApproveTimeoutError(observedEmptyPendingList: boolean, lastError: string | undefined): Error {
  if (observedEmptyPendingList) {
    return new NoPendingPairingRequestError();
  }

  if (isHardApprovalFailure(lastError)) {
    return new ApprovalRetryFailedError(lastError);
  }

  return new ApprovalCheckTimeoutError(lastError);
}

/**
 * Old managed gateway wrappers returned only a human-readable HTTP error when
 * their fixed v3 internal client met the pinned v4 OpenClaw runtime. There is no
 * structured code to consume on those already-deployed images, so this exact
 * compatibility signature is the narrow legacy boundary. New wrappers avoid it
 * by advertising the same v3-v4 range as upstream clients.
 */
function isLegacyWrapperProtocolMismatch(error: unknown): boolean {
  return /Connect rejected:\s*protocol mismatch/i.test(error instanceof Error ? error.message : String(error));
}

// ─── Shared WebSocket helper ────────────────────────────────────────────────

/**
 * Opens an authenticated operator WebSocket to the gateway, waits for the
 * connect.challenge handshake, then calls `onConnected` with a `send` helper.
 * Returns whatever the callback resolves to.
 */
function withGatewayConnection<T>(
  gatewayUrl: string,
  gatewayToken: string,
  timeoutMs: number,
  onConnected: (ctx: {
    ws: WebSocket;
    send: (method: string, params?: Record<string, unknown>) => string;
    onMessage: (handler: (frame: any) => void) => void;
  }) => Promise<T>,
  setupPassword?: string,
): Promise<T> {
  const wsUrl = gatewayUrl.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:');
  // When using control-ui client, set Origin to match the gateway host so the
  // dangerouslyAllowHostHeaderOriginFallback check passes.
  const originUrl = gatewayUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');

  return new Promise<T>((resolve, reject) => {
    const ws = new WebSocket(wsUrl, setupPassword ? { headers: { Origin: originUrl } } : undefined);
    let msgId = 0;
    let settled = false;

    // Keep the socket alive across a long (multi-minute) turn so an intermediary
    // (Fly edge / http-proxy) doesn't drop it as idle before the final event.
    // Started once the socket is open; cleared on every settle path below.
    let heartbeat: ReturnType<typeof setInterval> | null = null;
    const stopHeartbeat = () => { if (heartbeat) { clearInterval(heartbeat); heartbeat = null; } };
    ws.on('open', () => {
      heartbeat = setInterval(() => {
        try { if (ws.readyState === WebSocket.OPEN) ws.ping(); } catch { /* best-effort */ }
      }, heartbeatIntervalMs());
      // Node keeps the process alive for an active timer; a heartbeat must never
      // by itself hold the process open past real work.
      if (typeof heartbeat.unref === 'function') heartbeat.unref();
    });

    const timer = setTimeout(() => {
      // Distinguish OUR client-side timer firing (no response arrived in time) from a genuine
      // gateway-side rejection ("Connect rejected: ...", "config.get failed: ...") — those are
      // separate error messages produced elsewhere in this function/callers. Naming the budget and
      // target here means a human reading logs doesn't have to cross-reference code to tell "the
      // gateway was just too slow" from "the gateway explicitly said no" (#1087 live-debug ask).
      if (!settled) {
        settled = true;
        stopHeartbeat();
        ws.close();
        reject(new Error(`WebSocket timeout after ${timeoutMs}ms waiting for a response from ${gatewayUrl}`));
      }
    }, timeoutMs);

    const done = (result: T) => {
      if (!settled) { settled = true; stopHeartbeat(); clearTimeout(timer); ws.close(); resolve(result); }
    };
    const fail = (err: Error) => {
      if (!settled) { settled = true; stopHeartbeat(); clearTimeout(timer); ws.close(); reject(err); }
    };

    const send = (method: string, params: Record<string, unknown> = {}) => {
      const id = String(++msgId);
      ws.send(JSON.stringify({ type: 'req', id, method, params }));
      return id;
    };

    let messageHandler: ((frame: any) => void) | null = null;

    ws.onmessage = (event) => {
      try {
        const frame = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());

        // Wait for challenge before sending connect
        if (frame.type === 'event' && frame.event === 'connect.challenge') {
          // Connect as openclaw-control-ui with setup password so the gateway
          // grants scopes without device identity (dangerouslyDisableDeviceAuth
          // bypass). Falls back to gateway-client when no password available.
          const auth: Record<string, string> = { token: gatewayToken };
          let clientId = 'gateway-client';
          if (setupPassword) {
            auth.password = setupPassword;
            clientId = 'openclaw-control-ui';
          }
          send('connect', {
            minProtocol: GATEWAY_MIN_PROTOCOL_VERSION,
            maxProtocol: GATEWAY_MAX_PROTOCOL_VERSION,
            client: { id: clientId, version: '1.0.0', platform: 'node', mode: 'backend' },
            caps: [...GATEWAY_CLIENT_CAPS],
            auth,
            role: 'operator',
            scopes: ['operator.read', 'operator.write', 'operator.pairing', 'operator.admin'],
          });
          return;
        }

        // Connect response
        if (frame.type === 'res' && msgId === 1) {
          if (!frame.ok) {
            fail(new Error(`Connect rejected: ${frame.error?.message ?? 'unknown'}`));
            return;
          }
          // Connected — hand off to the caller
          onConnected({ ws, send, onMessage: (h) => { messageHandler = h; } })
            .then(done)
            .catch(fail);
          return;
        }

        // Delegate remaining messages
        if (messageHandler) messageHandler(frame);
      } catch {
        // ignore parse errors on event frames
      }
    };

    ws.onerror = (err) => fail(new Error(`WebSocket error: ${String(err)}`));
    ws.onclose = () => {
      stopHeartbeat();
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`Gateway WebSocket closed before the pending operation completed (${gatewayUrl})`));
      }
    };
  });
}

// ─── Generic request/response helper ────────────────────────────────────────

/** A resolved gateway RPC response: `{ ok, result }` on success or `{ ok:false, error }`. */
export interface GatewayResponse {
  ok: boolean;
  result?: any;
  error?: { code?: string; message?: string };
}

/**
 * Server-pushed event surface handed to `withGatewayRequester` callers that need
 * to observe async gateway events (e.g. the `chat` event that carries a chat.send
 * run's final assistant text). Opt-in: callers that only do request/response
 * (config.patch, pairing) never register a handler and are unaffected.
 */
export interface GatewayEventTap {
  /** Register a handler for server-pushed `type:'event'` frames. Last registration wins. */
  onEvent: (handler: (event: string, payload: any) => void) => void;
}

/**
 * Opens one authenticated operator connection and hands `fn` a `request` helper
 * that sends an RPC and resolves with its matching response. Multiple requests
 * reuse the single connection (responses are dispatched by frame id), so a
 * caller can do e.g. `cron.list` then `cron.add` over one socket. The connection
 * closes when `fn` resolves. Built on `withGatewayConnection` so it inherits the
 * control-ui setup-password handshake used by the other helpers in this file.
 *
 * `fn` also receives a `GatewayEventTap` so it can additionally observe async
 * server-pushed events (e.g. `chat` finals). This is additive — existing callers
 * that ignore the second arg keep the exact request/response behavior they had.
 */
export async function withGatewayRequester<T>(
  gatewayUrl: string,
  gatewayToken: string,
  fn: (
    request: (method: string, params?: Record<string, unknown>) => Promise<GatewayResponse>,
    events: GatewayEventTap,
  ) => Promise<T>,
  setupPassword?: string,
  timeoutMs = GATEWAY_RPC_TIMEOUT_MS,
): Promise<T> {
  return withGatewayConnection(
    gatewayUrl,
    gatewayToken,
    timeoutMs,
    async ({ send, onMessage }) => {
      const pending = new Map<string, (res: GatewayResponse) => void>();
      let eventHandler: ((event: string, payload: any) => void) | null = null;
      onMessage((frame: any) => {
        // Surface server-pushed events (chat finals, etc.) to an opt-in handler.
        if (frame?.type === 'event') {
          if (eventHandler && typeof frame.event === 'string') {
            eventHandler(frame.event, frame.payload);
          }
          return;
        }
        if (frame?.type !== 'res') return;
        const resolve = pending.get(String(frame.id));
        if (!resolve) return;
        pending.delete(String(frame.id));
        // The gateway returns success payloads under `result` or `payload`.
        resolve({ ok: !!frame.ok, result: frame.result ?? frame.payload, error: frame.error });
      });
      const request = (method: string, params: Record<string, unknown> = {}) =>
        new Promise<GatewayResponse>((resolve) => {
          const id = send(method, params);
          pending.set(id, resolve);
        });
      return fn(request, { onEvent: (h) => { eventHandler = h; } });
    },
    setupPassword,
  );
}

/**
 * Logs a channel account out through OpenClaw's live gateway runtime.
 *
 * This deliberately mirrors upstream's `channels.logout` path instead of deleting a guessed
 * credential directory from the Railway backend. The gateway resolves the configured account,
 * stops its runtime, and lets the channel plugin perform its own guarded credential cleanup
 * (`logoutWeb` for WhatsApp). Upstream reports `ok: true` even when guarded credential cleanup
 * returns `cleared: false`, so transport success is not a logout postcondition. We follow the
 * logout with `channels.status` and only return after the exact account reports `linked: false`.
 * That keeps an already-cleared account idempotent while refusing to erase RemClaw's database
 * record when credentials remain (for example, an auth directory outside OpenClaw's ownership).
 */
export async function logoutGatewayChannel(
  gatewayUrl: string,
  gatewayToken: string,
  channel: string,
  setupPassword?: string,
): Promise<void> {
  await withGatewayRequester(
    gatewayUrl,
    gatewayToken,
    async (request) => {
      const response = await request('channels.logout', { channel });
      if (!response.ok) {
        throw new Error(
          `channels.logout failed (${channel}): ${response.error?.message ?? 'unknown error'}`,
        );
      }

      const accountId = typeof response.result?.accountId === 'string'
        ? response.result.accountId
        : null;
      if (!accountId) {
        throw new Error(`channels.logout returned no account identifier (${channel})`);
      }

      const status = await request('channels.status', { probe: false });
      if (!status.ok) {
        throw new Error(
          `channels.status failed after logout (${channel}): ${status.error?.message ?? 'unknown error'}`,
        );
      }

      const channelAccounts = status.result?.channelAccounts?.[channel];
      const account = Array.isArray(channelAccounts)
        ? channelAccounts.find((candidate: any) => candidate?.accountId === accountId)
        : null;
      if (account?.linked !== false) {
        throw new Error(
          `Channel credentials remain linked after logout (${channel}:${accountId})`,
        );
      }
    },
    setupPassword,
  );
}

// ─── Config patch ───────────────────────────────────────────────────────────

/**
 * Patches the gateway config via WebSocket (config.get → config.patch).
 * Used after onboarding to unblock node commands that RemClaw needs.
 */
export async function patchGatewayConfig(
  gatewayUrl: string,
  gatewayToken: string,
  configPatch: Record<string, unknown>,
  setupPassword?: string,
): Promise<void> {
  await withGatewayConnection(gatewayUrl, gatewayToken, GATEWAY_RPC_TIMEOUT_MS, async ({ send, onMessage }) => {
    // Step 1: get current config hash
    const getId = send('config.get', {});

    const hash = await new Promise<string>((resolve, reject) => {
      onMessage((frame: any) => {
        if (frame.type !== 'res' || frame.id !== getId) return;
        if (!frame.ok) { reject(new Error(`config.get failed: ${frame.error?.message}`)); return; }
        const payload = frame.result ?? frame.payload;
        resolve(payload?.hash ?? '');
      });
    });

    // Step 2: apply the patch
    const patchId = send('config.patch', {
      raw: JSON.stringify(configPatch),
      baseHash: hash,
      note: 'RemClaw deploy: unblock iOS node commands',
    });

    await new Promise<void>((resolve, reject) => {
      onMessage((frame: any) => {
        if (frame.type !== 'res' || frame.id !== patchId) return;
        if (!frame.ok) { reject(new Error(`config.patch failed: ${frame.error?.message}`)); return; }
        resolve();
      });
    });
  }, setupPassword);
}

/**
 * Sends a `config.apply` command via WebSocket to trigger a gateway restart.
 * This causes the gateway to reload hooks with the updated config (e.g., after
 * enabling `hooks.internal.enabled` via config.patch).
 */
export async function applyGatewayConfig(
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
): Promise<void> {
  await withGatewayConnection(gatewayUrl, gatewayToken, GATEWAY_RPC_TIMEOUT_MS, async ({ send, onMessage }) => {
    const applyId = send('config.apply', {});

    await new Promise<void>((resolve, reject) => {
      onMessage((frame: any) => {
        if (frame.type !== 'res' || frame.id !== applyId) return;
        if (!frame.ok) { reject(new Error(`config.apply failed: ${frame.error?.message}`)); return; }
        resolve();
      });
    });
  }, setupPassword);
}

/**
 * Polls the gateway for pending pairing requests and approves them.
 * Retries every `intervalMs` for up to `timeoutMs`.
 */
export async function autoApproveDevices(
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
  timeoutMs = 60_000,
  intervalMs = 5_000
): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  let observedEmptyPendingList = false;
  let lastError: string | undefined;

  while (Date.now() < deadline) {
    try {
      const approved = await tryApproveOnce(gatewayUrl, gatewayToken, setupPassword);
      if (approved > 0) {
        console.log(`[pair] auto-approved ${approved} device(s)`);
        return approved;
      }
      observedEmptyPendingList = true;
    } catch (err: any) {
      lastError = err.message;
      console.warn(`[pair] attempt failed: ${lastError}`);
    }
    await new Promise(r => setTimeout(r, intervalMs));
  }
  throw buildAutoApproveTimeoutError(observedEmptyPendingList, lastError);
}

// ─── HTTP-based alternatives (bypass WebSocket secure-context requirement) ──

function setupAuthHeader(setupPassword: string): string {
  return `Basic ${Buffer.from(`admin:${setupPassword}`).toString('base64')}`;
}

/**
 * Patches gateway config via the wrapper's HTTP endpoint (file-based merge + restart).
 * Falls back to WebSocket config.patch if setupPassword is not available.
 */
export async function patchGatewayConfigHttp(
  gatewayUrl: string,
  gatewayToken: string,
  configPatch: Record<string, unknown>,
  setupPassword?: string,
  options?: { requireActivated?: boolean; timeoutMs?: number },
): Promise<{ activated: boolean }> {
  if (!setupPassword) {
    if (options?.requireActivated) {
      // Interactive policy saves must be all-or-nothing. Reject before opening
      // the legacy WebSocket transport, which cannot prove restart/readback.
      throw new Error('config-patch activation cannot be confirmed without gateway setup access');
    }
    // Non-interactive repair callers retain the legacy best-effort fallback.
    await patchGatewayConfig(gatewayUrl, gatewayToken, configPatch, setupPassword);
    return { activated: false };
  }

  const res = await fetch(`${gatewayUrl}/setup/api/config-patch`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': setupAuthHeader(setupPassword),
    },
    body: JSON.stringify({ config: configPatch }),
    signal: AbortSignal.timeout(options?.timeoutMs ?? 30_000),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`config-patch HTTP ${res.status}: ${text}`);
  }

  const body = await res.json() as { ok: boolean; activated?: boolean; error?: string };
  if (!body.ok) {
    throw new Error(`config-patch failed: ${body.error ?? 'unknown'}`);
  }
  if (options?.requireActivated && body.activated !== true) {
    throw new Error('config-patch was accepted but activation was not confirmed');
  }
  return { activated: body.activated === true };
}

/**
 * Auto-approves all pending device pairing requests via the wrapper's HTTP endpoint.
 * Falls back to WebSocket method if setupPassword is not available.
 */
export async function autoApproveDevicesHttp(
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
  timeoutMs = 60_000,
  intervalMs = 5_000,
): Promise<number> {
  if (!setupPassword) {
    // Fall back to WebSocket method
    return autoApproveDevices(gatewayUrl, gatewayToken, setupPassword, timeoutMs, intervalMs);
  }

  const deadline = Date.now() + timeoutMs;
  let observedEmptyPendingList = false;
  let lastError: string | undefined;

  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${gatewayUrl}/setup/api/approve-all`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': setupAuthHeader(setupPassword),
        },
        signal: AbortSignal.timeout(15_000),
      });

      if (res.ok) {
        const body = await res.json() as { ok: boolean; approved: number; output?: string; error?: string };
        if (body.ok && body.approved > 0) {
          console.log(`[pair-http] auto-approved ${body.approved} device(s)`);
          return body.approved;
        }
        if (body.ok) {
          observedEmptyPendingList = true;
        } else {
          throw new Error(`approve-all failed: ${body.error ?? body.output ?? 'unknown error'}`);
        }
      } else {
        const body = await res.text();
        throw new Error(`approve-all HTTP ${res.status}: ${body}`);
      }
    } catch (err: any) {
      lastError = err.message;
      console.warn(`[pair-http] attempt failed: ${lastError}`);
      if (isLegacyWrapperProtocolMismatch(err)) {
        // Existing user gateways cannot receive the wrapper fix until their
        // image is rolled. Fall back to the backend's direct operator client,
        // which already mirrors OpenClaw's v3-v4 negotiation range. This makes
        // Finish Connection repair the current fleet without requiring a
        // destructive per-user gateway reset.
        const remainingMs = Math.max(1, deadline - Date.now());
        console.warn('[pair-http] stale wrapper protocol; falling back to direct gateway approval');
        return autoApproveDevices(gatewayUrl, gatewayToken, setupPassword, remainingMs, intervalMs);
      }
    }
    await new Promise(r => setTimeout(r, intervalMs));
  }
  throw buildAutoApproveTimeoutError(observedEmptyPendingList, lastError);
}

async function tryApproveOnce(gatewayUrl: string, gatewayToken: string, setupPassword?: string): Promise<number> {
  const wsUrl = gatewayUrl.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:');
  const originUrl = gatewayUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');

  return new Promise<number>((resolve, reject) => {
    const ws = new WebSocket(wsUrl, setupPassword ? { headers: { Origin: originUrl } } : undefined);
    let msgId = 0;
    const nextId = () => String(++msgId);
    let connected = false;
    let settled = false;
    let connectRequestId: string | null = null;
    let listRequestId: string | null = null;
    const approvalRequestIds = new Set<string>();
    let approvedCount = 0;

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        ws.close();
        reject(new Error('WebSocket timeout'));
      }
    }, 15_000);

    const send = (method: string, params: Record<string, unknown> = {}) => {
      const id = nextId();
      ws.send(JSON.stringify({ type: 'req', id, method, params }));
      return id;
    };

    // The gateway sends a connect.challenge event before accepting connect requests.
    // We must wait for it before sending our connect frame.
    ws.onmessage = async (event) => {
      try {
        const frame = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());

        // Handle challenge event — send connect after receiving it.
        // Use openclaw-control-ui + setup password so the gateway grants
        // scopes without device identity (dangerouslyDisableDeviceAuth bypass).
        if (frame.type === 'event' && frame.event === 'connect.challenge') {
          const auth: Record<string, string> = { token: gatewayToken };
          let clientId = 'gateway-client';
          if (setupPassword) {
            auth.password = setupPassword;
            clientId = 'openclaw-control-ui';
          }
          connectRequestId = send('connect', {
            minProtocol: GATEWAY_MIN_PROTOCOL_VERSION,
            maxProtocol: GATEWAY_MAX_PROTOCOL_VERSION,
            client: {
              id: clientId,
              version: '1.0.0',
              platform: 'node',
              mode: 'backend',
            },
            caps: [...GATEWAY_CLIENT_CAPS],
            auth,
            role: 'operator',
            scopes: ['operator.read', 'operator.write', 'operator.pairing', 'operator.admin'],
          });
          return;
        }

        if (frame.type !== 'res') return;

        if (frame.id === connectRequestId) {
          // This is the connect response
          if (!frame.ok) {
            settled = true;
            clearTimeout(timeout);
            ws.close();
            reject(new Error(`Connect rejected: ${frame.error?.message ?? 'unknown'}`));
            return;
          }
          connected = true;
          // List pending pairing requests
          listRequestId = send('device.pair.list', {});
          return;
        }

        // Handle device.pair.list response (gateway uses "payload" not "result")
        const resultData = frame.result ?? frame.payload;
        if (frame.id === listRequestId && resultData?.pending !== undefined) {
          const pending: PendingDevice[] = resultData.pending ?? [];
          if (pending.length === 0) {
            settled = true;
            clearTimeout(timeout);
            ws.close();
            resolve(0);
            return;
          }

          // Approve each pending device
          for (const device of pending) {
            approvalRequestIds.add(send('device.pair.approve', { requestId: device.requestId }));
          }
          return;
        }

        if (approvalRequestIds.has(frame.id)) {
          approvalRequestIds.delete(frame.id);
          if (!frame.ok) {
            settled = true;
            clearTimeout(timeout);
            ws.close();
            reject(new Error(`Approval rejected: ${frame.error?.message ?? 'unknown'}`));
            return;
          }
          approvedCount++;
          if (approvalRequestIds.size === 0) {
            settled = true;
            clearTimeout(timeout);
            ws.close();
            resolve(approvedCount);
          }
        }
      } catch {
        // Ignore parse errors for event frames etc.
      }
    };

    ws.onerror = (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        reject(new Error(`WebSocket error: ${String(err)}`));
      }
    };

    ws.onclose = () => {
      clearTimeout(timeout);
      if (!settled) {
        settled = true;
        resolve(0);
      }
    };
  });
}

// ─── Read-only workspace/memory file access (HTTP) ─────────────────────────
//
// Mirrors patchGatewayConfigHttp: talks to the gateway wrapper's setup API using
// the setup password (Basic auth). Surfaces the agent's identity/memory workspace
// (IDENTITY.md / USER.md / MEMORY.md / memory/*.md on /data/workspace) for the
// app's Settings → Memory screen. Read-only by design.

export interface WorkspaceFileEntry {
  path: string;
  size: number;
  mtime: string | null;
}

export interface WorkspaceFileContent {
  path: string;
  content: string;
  size: number;
  truncated: boolean;
}

/**
 * The gateway answered, but its wrapper image predates the workspace endpoints
 * (`/setup/api/workspace/*`, added alongside the Settings → Memory screen).
 * Old wrappers fall through to the control-ui SPA and return 200 `text/html`
 * for these paths — so a non-JSON "success" body means "this gateway needs an
 * image update", not "the request failed". Routes map this to a graceful
 * `available: false` instead of a 502 (see gateway.routes.ts).
 */
export class WorkspaceEndpointsUnavailableError extends Error {
  constructor(detail: string) {
    super(`Gateway wrapper does not expose workspace endpoints (image update required): ${detail}`);
    this.name = 'WorkspaceEndpointsUnavailableError';
  }
}

/**
 * Parses a wrapper setup-API response body as JSON. A 2xx non-JSON body (the
 * control-ui SPA's index.html) is the stale-wrapper signature → typed error.
 */
function parseWrapperJson(endpoint: string, status: number, ok: boolean, text: string): any {
  try {
    return JSON.parse(text);
  } catch {
    const preview = text.slice(0, 120).replace(/\s+/g, ' ');
    if (ok) {
      throw new WorkspaceEndpointsUnavailableError(`${endpoint} returned non-JSON (HTTP ${status}): ${preview}`);
    }
    throw new Error(`${endpoint} HTTP ${status}: ${preview}`);
  }
}

/** Lists the agent workspace files via the wrapper's HTTP endpoint. Requires setupPassword. */
export async function listWorkspaceFilesHttp(
  gatewayUrl: string,
  setupPassword: string,
): Promise<WorkspaceFileEntry[]> {
  const res = await fetch(`${gatewayUrl}/setup/api/workspace/list`, {
    method: 'GET',
    headers: { Authorization: setupAuthHeader(setupPassword) },
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  const body = parseWrapperJson('workspace/list', res.status, res.ok, text) as
    { ok: boolean; files?: WorkspaceFileEntry[]; error?: string };
  if (!res.ok) throw new Error(`workspace/list HTTP ${res.status}: ${body.error ?? text.slice(0, 200)}`);
  if (!body.ok) throw new Error(`workspace/list failed: ${body.error ?? 'unknown'}`);
  return body.files ?? [];
}

/** Reads a single workspace file via the wrapper's HTTP endpoint. Requires setupPassword. */
export async function readWorkspaceFileHttp(
  gatewayUrl: string,
  setupPassword: string,
  relPath: string,
): Promise<WorkspaceFileContent> {
  const res = await fetch(`${gatewayUrl}/setup/api/workspace/file?path=${encodeURIComponent(relPath)}`, {
    method: 'GET',
    headers: { Authorization: setupAuthHeader(setupPassword) },
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  const body = parseWrapperJson('workspace/file', res.status, res.ok, text) as
    ({ ok: boolean; error?: string } & Partial<WorkspaceFileContent>);
  if (!res.ok) throw new Error(`workspace/file HTTP ${res.status}: ${body.error ?? text.slice(0, 200)}`);
  if (!body.ok) throw new Error(`workspace/file failed: ${body.error ?? 'unknown'}`);
  return {
    path: body.path ?? relPath,
    content: body.content ?? '',
    size: body.size ?? 0,
    truncated: body.truncated ?? false,
  };
}
