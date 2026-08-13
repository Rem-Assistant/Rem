/**
 * Composio connections — OAuth connectors (Gmail, GitHub, Calendar, …) for Rem's agent.
 *
 * ── Why Composio, and why NOT the cloud browser ────────────────────────────────────────────────
 * Composio's OAuth completes on the USER'S OWN DEVICE via a redirect, not in Rem's Fly cloud
 * browser. `authorize(toolkit)` returns a Composio-hosted **Connect Link** (connect.composio.dev/
 * link/…); the app opens it in the system browser via SwiftUI `openURL` (not an in-app web view —
 * there's no cookie-shared sheet to dismiss automatically, so the client polls status after the
 * user returns instead of catching an app-owned redirect callback). The user grants provider
 * consent on their own device (residential IP), and Composio captures the token on its own
 * callback. So the datacenter bot-detection that blocks Discord in the cloud browser does NOT
 * apply, and Rem needs no takeover-auth UX. The agent then USES the connected tools via Composio's
 * per-user hosted **MCP** endpoint, wired into the gateway's MCP config (see getMcpConfig).
 *
 * ⚠️ Reconciled against the REAL @composio/core (0.14.0, the latest published version as of this
 * writing — there is no newer SDK release to upgrade to) — the call sites below match the shipped
 * SDK, not the earlier draft ambient d.ts. Deltas from the draft:
 *   • ConnectionRequest.redirectUrl is `string | null | undefined` (was required string).
 *   • connectedAccounts.get(nanoid) → ConnectedAccountRetrieveResponse { id, status, toolkit.slug }
 *     (no `appName`; status enum INITIALIZING|INITIATED|ACTIVE|FAILED|EXPIRED|INACTIVE|REVOKED).
 *   • MCP is opt-in per session: `composio.create(userId, { mcp: true })`; session.mcp is
 *     { type, url, headers? } with url required (no cast needed).
 *   • getConnectionStatus (#1080): `ConnectionRequest.id` IS a connected-account id — `link()` (see
 *     below) and the legacy `initiate()` both build the `ConnectionRequest` from the same
 *     `response.id`/`response.connected_account_id` that `connectedAccounts.get/retrieve` looks up.
 *     Rather than re-deriving the status-string mapping by hand with a bare `connectedAccounts.get`,
 *     this uses `connectedAccounts.waitForConnection(id, timeout)` — the SDK's purpose-built
 *     primitive for this exact poll — with a short bounded timeout per call (our client already
 *     re-polls on an interval), so a still-pending connection times out into a typed
 *     `ConnectionRequestTimeoutError` instead of an ambiguous "unknown" from a caught error.
 *   • createConnectSession (#1086): originally used `composio.toolkits.authorize(userId,
 *     toolkitSlug)`, a high-level helper that resolves/creates an auth config and then calls
 *     `connectedAccounts.initiate(...)`. Composio has retired that endpoint server-side for
 *     Composio-managed OAuth auth configs — verified live: it 400s with `ConnectedAccount_BadRequest
 *     "Creating connections on this endpoint ... is no longer supported. Use POST
 *     /api/v3/connected_accounts/link instead."` `toolkits.authorize()` isn't overridable (it always
 *     calls `initiate()` internally), so we redo its auth-config resolution ourselves
 *     (`resolveAuthConfigId`, mirroring `Toolkits.authorize()`'s own logic in
 *     @composio/core/src/models/Toolkits.ts) and call `connectedAccounts.link(userId, authConfigId,
 *     opts)` instead — confirmed via @composio/client/resources/link.js that `link.create()` posts
 *     to `/api/v3.1/connected_accounts/link`, the current (non-deprecated) endpoint. Same
 *     `ConnectionRequest` return shape, so nothing downstream (getConnectionStatus, the route) changes.
 *     `link()`'s options also genuinely forward `callbackUrl` (unlike `initiate()`, which had no
 *     per-call callback param) — see `CreateConnectedAccountLinkOptionsSchema`.
 */
import {
  Composio,
  ComposioAuthConfigNotFoundError,
  ComposioConnectedAccountNotFoundError,
  ConnectionRequestFailedError,
  ConnectionRequestTimeoutError,
} from '@composio/core';
import { createHash } from 'node:crypto';
import { withGatewayRequester } from './gateway-pair.service.js';
import { tryWithUserGatewayConfigReconciliationLock } from './gateway-lifecycle-lock.service.js';
import {
  getGatewayCredentialsWithClient,
  getLocalGatewayCredentials,
  getSetupPasswordWithClient,
} from './gateway.service.js';
import { env } from '../config/env.js';
import type { GmailBriefAdapter, GmailBriefPage, GmailBriefRawItem } from './brief-input.service.js';
import { parseEpochInstant } from './connector-signals.registry.js';
import type {
  ActiveConnectorAccountSource,
  ActiveConnectorAccountsByToolkitSource,
  ConnectorSignalExecutor,
} from './signal-ingest.service.js';

const COMPOSIO_API_KEY = process.env.COMPOSIO_API_KEY?.trim();

/**
 * Curated connector catalog (#1069 follow-up) — widely-used toolkits that fit a personal-assistant
 * product, picked from Composio's public catalog (verified live against composio.dev/toolkits/<slug>
 * for every entry below, since the catalog isn't otherwise enumerable without a live API key):
 * Gmail, Google Calendar, Google Drive, Google Docs, Google Sheets, GitHub, Slack, Discord,
 * Discord Bot, WhatsApp Business, Telegram, Notion, Linear, Todoist, Asana.
 *
 * This list is also the MCP session's `toolkits` scope (getMcpConfig, #1099) — widening it here
 * widens both the connect list AND what the agent can call, intentionally.
 *
 * Gmail and Google Calendar already have a Composio-managed OAuth auth config set up in the
 * workspace. The OTHER three Google toolkits (Drive/Docs/Sheets) are new additions here and are
 * NOT guaranteed to auto-provision one: Google gates broader/sensitive scopes behind its own app
 * verification, so `resolveAuthConfigId`'s auto-create call can 400 for them exactly like the
 * "sensitive-scope" case its doc comment already anticipates. If that happens for any of drive/
 * docs/sheets, the fix is the same one-time step called out there — create a Composio-managed OAuth
 * auth config for that toolkit in the Composio dashboard — not a code change.
 */
export const COMPOSIO_TOOLKITS = [
  'gmail',
  'googlecalendar',
  'googledrive',
  'googledocs',
  'googlesheets',
  'github',
  'slack',
  'discord',
  'discordbot',
  'whatsapp',
  'telegram',
  'notion',
  'linear',
  'todoist',
  'asana',
] as const;

// Stored as a non-secret extension field on `mcp.servers.composio`. The pinned OpenClaw MCP server
// schema explicitly preserves unknown per-server keys, while `config.get` redacts every header
// value. Keeping the generation outside `headers` makes it observable without weakening secret
// redaction; adding a toolkit changes this value so wake/load reconciliation rotates stale sessions.
export const COMPOSIO_SCOPE_CONFIG_KEY = 'remComposioScope';
// v3 introduced the managed-header schema. v4 forces one replacement for the newly widened
// `discord` scope so already-wired sessions do not stay pinned to the older `discordbot` catalog.
export const COMPOSIO_SCOPE_VERSION = 'catalog-messaging-v4-discord';
export type ComposioToolkit = (typeof COMPOSIO_TOOLKITS)[number];

export class ComposioNotConfiguredError extends Error {
  readonly status = 503;
  constructor() {
    super('Composio is not configured on this backend (COMPOSIO_API_KEY unset).');
    this.name = 'ComposioNotConfiguredError';
  }
}

export class ComposioToolkitError extends Error {
  readonly status = 400;
  constructor(message: string) {
    super(message);
    this.name = 'ComposioToolkitError';
  }
}

export class ComposioMcpOwnershipConflictError extends Error {
  readonly retryable = false;

  constructor() {
    super('Gateway already has an unowned MCP server named "composio"; refusing to overwrite it.');
    this.name = 'ComposioMcpOwnershipConflictError';
  }
}

/** The catalog is available, but its per-user account truth could not be read. Callers must surface
 * this as a retryable failure instead of treating the absence of statuses as absence of grants. */
export class ComposioStatusUnavailableError extends Error {
  readonly status = 503;
  constructor(options?: ErrorOptions) {
    super("Couldn't verify existing Composio connections. Try again in a moment.", options);
    this.name = 'ComposioStatusUnavailableError';
  }
}

let cached: Composio | null = null;
function client(): Composio {
  if (!COMPOSIO_API_KEY) throw new ComposioNotConfiguredError();
  if (!cached) cached = new Composio({ apiKey: COMPOSIO_API_KEY });
  return cached;
}

export function isComposioConfigured(): boolean {
  return Boolean(COMPOSIO_API_KEY);
}

function assertToolkit(toolkit: string): ComposioToolkit {
  if (!(COMPOSIO_TOOLKITS as readonly string[]).includes(toolkit)) {
    throw new ComposioToolkitError(`Unsupported toolkit "${toolkit}". Supported: ${COMPOSIO_TOOLKITS.join(', ')}.`);
  }
  return toolkit as ComposioToolkit;
}

export interface ConnectSession {
  /** Composio-hosted Connect Link — the app opens this in the system browser via `openURL`. */
  redirectUrl: string;
  /** The connection request id (== the connected-account id, see module doc) — poll getConnectionStatus with it. */
  connectionId: string;
  toolkit: ComposioToolkit;
}

/** Duck-typed 400 check. `@composio/core`'s own `Toolkits.authorize()` checks `error instanceof
 * APIError` from `@composio/client`/`openai`, but that's a transitive dep we don't declare
 * directly — importing its class would be a phantom-dependency risk (breaks silently if hoisting
 * ever changes). A status-code duck-type is more defensive here and the classes aren't ours to
 * keep in sync anyway. */
function isBadRequestStatus(error: unknown, status: number): boolean {
  return Boolean(error && typeof error === 'object' && 'status' in error && (error as { status?: unknown }).status === status);
}

/**
 * Finds (or auto-provisions) the auth config to connect `toolkit` against.
 *
 * This mirrors the auth-config half of `composio.toolkits.authorize()` (see
 * @composio/core/src/models/Toolkits.ts) — list existing auth configs for the toolkit, reuse only
 * one whose scheme and management mode match this product's flow, and otherwise create the
 * required config. We can't just call `toolkits.authorize()` itself
 * because it always finishes with the deprecated `connectedAccounts.initiate()` (see module doc
 * #1086); this redoes just the resolution half so `createConnectSession` can finish with
 * `connectedAccounts.link()` instead.
 *
 * Some toolkits (notably ones needing sensitive-scope review, e.g. Google APIs) don't have a
 * default Composio-managed auth config available to auto-create, and the create call 400s — when
 * that happens this throws `ComposioAuthConfigNotFoundError` with a message pointing at the fix:
 * **create an auth config for that toolkit in the Composio dashboard** (Auth Configs → New → pick
 * the toolkit → Composio-managed OAuth), which only has to be done once per toolkit for the whole
 * project, not per user.
 */
async function resolveAuthConfigId(composio: Composio, toolkitSlug: ComposioToolkit): Promise<string> {
  const existing = await composio.authConfigs.list({ toolkit: toolkitSlug });

  // Telegram authenticates with a bot token (API_KEY), not OAuth. Create only the credential
  // *schema* here; the credential itself is entered later on Composio's hosted Connect Link and
  // never passes through Rem's client or backend. `credentials: {}` is the SDK's documented shape
  // for an API-key auth config whose per-user value is collected during connected-account setup.
  if (toolkitSlug === 'telegram') {
    // A project may already contain an incompatible managed/OAuth config for the same toolkit.
    // The list response exposes both fields; reuse only the exact schema this flow requires rather
    // than trusting item order and handing `connectedAccounts.link` an unusable config.
    const compatible = existing.items.find(
      config => config.authScheme === 'API_KEY' && config.isComposioManaged === false,
    );
    if (compatible) return compatible.id;

    try {
      const created = await composio.authConfigs.create(toolkitSlug, {
        type: 'use_custom_auth',
        name: 'Telegram Bot Auth Config',
        authScheme: 'API_KEY',
        credentials: {},
      });
      return created.id;
    } catch (error) {
      if (isBadRequestStatus(error, 400)) {
        throw new ComposioAuthConfigNotFoundError(
          'No Telegram bot-token auth config is available. Create an API-key auth config for ' +
            'Telegram in the Composio dashboard first.',
          { meta: { toolkitSlug }, cause: error }
        );
      }
      throw error;
    }
  }

  // Every curated toolkit other than Telegram uses Composio-managed OAuth. A toolkit can have
  // multiple project auth configs (WhatsApp, for example, also supports custom API-key auth), so
  // item order is not a compatibility signal. Reusing a custom/API-key config here would send the
  // user into the wrong hosted flow even though this product promises managed OAuth.
  const compatible = existing.items.find(
    config => config.authScheme === 'OAUTH2' && config.isComposioManaged === true,
  );
  if (compatible) return compatible.id;

  const toolkit = await composio.toolkits.get(toolkitSlug);
  if (!toolkit.authConfigDetails || toolkit.authConfigDetails.length === 0) {
    throw new ComposioAuthConfigNotFoundError(
      `No auth config found for toolkit "${toolkitSlug}". Create one in the Composio dashboard ` +
        `(Auth Configs -> New -> ${toolkit.name}, Composio-managed OAuth) first.`,
      { meta: { toolkitSlug } }
    );
  }
  try {
    const created = await composio.authConfigs.create(toolkitSlug, {
      type: 'use_composio_managed_auth',
      name: `${toolkit.name} Auth Config`,
    });
    return created.id;
  } catch (error) {
    if (isBadRequestStatus(error, 400)) {
      throw new ComposioAuthConfigNotFoundError(
        `No default auth config available for toolkit "${toolkitSlug}". Create one in the Composio ` +
          `dashboard (Auth Configs -> New -> ${toolkit.name}, Composio-managed OAuth) first.`,
        { meta: { toolkitSlug }, cause: error }
      );
    }
    throw error;
  }
}

/**
 * Start an OAuth connect for `toolkit` for our user. The user_id we pass IS Rem's user id, so
 * Composio scopes the connected account to this user. Resolves (or auto-provisions) the toolkit's
 * auth config, then calls `connectedAccounts.link()` — the current connect-link endpoint (#1086;
 * see module doc) — which returns a ConnectionRequest whose `redirectUrl` is the Composio-hosted
 * Connect Link the app opens in the system browser.
 */
export async function createConnectSession(
  userId: string,
  toolkit: string,
  callbackUrl?: string,
): Promise<ConnectSession> {
  const kit = assertToolkit(toolkit);
  const composio = client();
  const authConfigId = await resolveAuthConfigId(composio, kit);
  // connectedAccounts.link() -> POST /api/v3.1/connected_accounts/link (current endpoint; verified
  // in @composio/client/resources/link.js). allowMultiple mirrors the old initiate() call's
  // semantics; callbackUrl is genuinely forwarded here (unlike initiate(), which had no per-call
  // callback param at all).
  const connectionRequest = await composio.connectedAccounts.link(userId, authConfigId, {
    allowMultiple: true,
    ...(callbackUrl ? { callbackUrl } : {}),
  });
  const redirectUrl = connectionRequest.redirectUrl;
  if (!redirectUrl) {
    // A non-redirect auth scheme (e.g. API-key) or an SDK error — surface it rather than returning
    // an empty link the app would silently fail to open.
    throw new ComposioToolkitError(`Composio returned no connect link for "${kit}".`);
  }
  return {
    redirectUrl,
    connectionId: connectionRequest.id,
    toolkit: kit,
  };
}

export type ComposioConnectionStatus = 'pending' | 'connected' | 'failed' | 'unknown';

export interface ConnectionState {
  /** The toolkit this connection is for. `null` when we genuinely can't determine it (a failed/
   * pending poll for which the caller didn't supply the toolkit) — never silently asserted as a
   * default. Prefer Composio's own `account.toolkit.slug`, else the toolkit the caller is polling. */
  toolkit: ComposioToolkit | null;
  status: ComposioConnectionStatus;
  connectedAccountId: string | null;
  /** Whether the just-resolved connection is AVAILABLE to the agent. `waitForConnection` resolves
   * only on an ACTIVE account, so a freshly-connected account is always enabled — the client seeds
   * the row's switch ON from this. `false` for the non-connected outcomes (nothing to enable). */
  enabled: boolean;
}

/** Bounded wait per status poll. The client already re-polls on its own interval (and again on
 * foreground), so this only needs to be long enough to catch "the user just finished OAuth a
 * second ago" in one round trip — not the SDK's 60s default, which would hang the HTTP request. */
const STATUS_POLL_TIMEOUT_MS = 3_000;

/**
 * Status check for a connection request (#1080 fix). The app polls this after opening the Connect
 * Link (Composio's callback captures the token out-of-band).
 *
 * `connectionId` is the `ConnectionRequest.id` from `createConnectSession`, which — per the module
 * doc above — IS a connected-account id. Rather than `connectedAccounts.get(id)` plus hand-rolled
 * status-string mapping (the previous approach, which returned "unknown" forever because a bare
 * `get` throws/behaves differently across SDK states than the purpose-built poller), this uses
 * `connectedAccounts.waitForConnection(id, timeout)`: it resolves on ACTIVE, throws
 * `ConnectionRequestFailedError` for a terminal failed/expired/revoked state, and throws
 * `ConnectionRequestTimeoutError` if still pending after `timeout` — exactly the three outcomes
 * this endpoint needs to report, using the SDK's own state machine instead of ours.
 */
export async function getConnectionStatus(
  userId: string,
  connectionId: string,
  // The toolkit the caller is polling for (the app knows it — it just started this connect). Used
  // so every branch reports the RIGHT toolkit instead of a hardcoded 'gmail'. `null` when unknown.
  toolkit: ComposioToolkit | null = null,
): Promise<ConnectionState> {
  const composio = client();
  try {
    const account = await composio.connectedAccounts.waitForConnection(connectionId, STATUS_POLL_TIMEOUT_MS);
    return {
      // Prefer Composio's own slug; fall back to the toolkit the caller supplied; else unknown.
      toolkit: ((account.toolkit?.slug as ComposioToolkit | undefined) ?? toolkit) ?? null,
      status: 'connected',
      connectedAccountId: account.id ?? connectionId,
      // waitForConnection only resolves on ACTIVE, so a just-connected account is available.
      enabled: true,
    };
  } catch (error) {
    if (error instanceof ConnectionRequestTimeoutError) {
      return { toolkit, status: 'pending', connectedAccountId: null, enabled: false };
    }
    if (error instanceof ConnectionRequestFailedError) {
      return { toolkit, status: 'failed', connectedAccountId: null, enabled: false };
    }
    if (error instanceof ComposioConnectedAccountNotFoundError) {
      console.error(`[composio] status: connected account ${connectionId} not found`, error);
      return { toolkit, status: 'failed', connectedAccountId: null, enabled: false };
    }
    // Unexpected (network blip, SDK/API error) — log so this doesn't silently mask a real bug,
    // but keep the endpoint non-throwing: the client treats "unknown" as "keep polling".
    console.error(`[composio] status check failed for ${connectionId}:`, error);
    return { toolkit, status: 'unknown', connectedAccountId: null, enabled: false };
  }
}

/** Per-toolkit connection state for the toolkits-list screen (#1082) — distinct from
 * `ComposioConnectionStatus` because "never attempted" isn't a poll outcome, it's the absence of
 * any connected-account row. */
export type ComposioToolkitListStatus = ComposioConnectionStatus | 'not_connected';

export interface ComposioToolkitSummary {
  slug: ComposioToolkit;
  /** Branding image URL from Composio's toolkit metadata (#1069). Prefers the toolkit's own
   * `meta.logo`; falls back to Composio's stable logo CDN (`logos.composio.dev/api/<slug>`) so
   * every row still gets a logo even when the per-toolkit `toolkits.get` fetch fails or returns
   * nothing. NOTE: these are SVG — the client renders them via `RemRemoteLogoView`, not AsyncImage. */
  logoUrl?: string;
  status: ComposioToolkitListStatus;
  /** Whether the toolkit is currently AVAILABLE to the agent (at least one ACTIVE account) vs
   * PAUSED (has connected account(s) but all `disable()`d to INACTIVE). Drives the row's on/off
   * switch — the enable/disable pause is distinct from disconnect (revoke). Always `false` for a
   * `not_connected`/`pending`/`failed` toolkit (nothing to pause). See `summarizeToolkit`. */
  enabled: boolean;
}

/** Composio's stable per-toolkit logo CDN. Every curated toolkit resolves here (verified live), and
 * it returns `image/svg+xml`. Used as the fallback when a toolkit's own `meta.logo` is missing so a
 * transient Composio hiccup never blanks a row's branding (#1069). */
export function composioLogoCdnUrl(slug: string): string {
  return `https://logos.composio.dev/api/${slug}`;
}

export interface ComposioToolkitsSummary {
  configured: boolean;
  toolkits: ComposioToolkitSummary[];
}

/** Reduces a user's raw connected-account status rows for one toolkit into (a) a single list-level
 * status and (b) whether the toolkit is currently ENABLED (available to the agent) vs PAUSED.
 *
 * `allowMultiple: true` on link() means a user can end up with more than one row per toolkit
 * (retries, re-connects) — prefer the best outcome rather than an arbitrary one. A `disable()`d
 * account lands in INACTIVE (the SDK's connected-account status for a pause — verified against
 * @composio/core 0.14.0's `ConnectedAccountStatuses`), while `enable()` restores it to ACTIVE.
 *
 * A toolkit still counts as CONNECTED (keeps its switch instead of collapsing back to a "Connect"
 * button) when it has ANY active OR paused account; `enabled` is true iff at least one account is
 * ACTIVE. So: has ACTIVE → connected+enabled; only INACTIVE → connected+paused (enabled:false);
 * only INITIALIZING/INITIATED → pending; only terminal-bad (FAILED/EXPIRED/REVOKED) → failed. */
function summarizeToolkit(rawStatuses: string[]): { status: ComposioToolkitListStatus; enabled: boolean } {
  if (rawStatuses.includes('ACTIVE')) return { status: 'connected', enabled: true };
  // Paused: the OAuth token is kept, but every account is disabled so the agent can't use it.
  if (rawStatuses.includes('INACTIVE')) return { status: 'connected', enabled: false };
  if (rawStatuses.some(s => s === 'INITIALIZING' || s === 'INITIATED')) return { status: 'pending', enabled: false };
  if (rawStatuses.length > 0) return { status: 'failed', enabled: false };
  return { status: 'not_connected', enabled: false };
}

/** Defensive bound on connected-account pagination. Hitting it with another cursor is an
 * unavailable status read, never a trustworthy partial snapshot. */
const MAX_ACCOUNT_PAGES = 50;
const COMPOSIO_LOGO_TIMEOUT_MS = process.env.NODE_ENV === 'test' ? 50 : 1_200;
const COMPOSIO_ACCOUNT_STATUS_TIMEOUT_MS = process.env.NODE_ENV === 'test' ? 50 : 4_000;
const COMPOSIO_MUTATION_TIMEOUT_MS = process.env.NODE_ENV === 'test' ? 50 : 20_000;

export class ComposioMutationTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ComposioMutationTimeoutError';
  }
}

/** Pins a late repair to the account identities observed by its original mutation. A generation
 * callback alone has a check/write race once provider I/O starts; intersecting a fresh status list
 * with this captured set makes a replacement OAuth grant permanently ineligible for the repair. */
export type ComposioMutationScope = {
  isCurrent?: () => boolean;
  repairAccountIds?: readonly string[];
  captureRepairAccountIds?: (ids: readonly string[]) => void;
};

async function withComposioProviderDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  label: string,
  timeoutMs: number,
): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      const error = new Error(`${label} timed out`);
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(controller.signal), deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function withComposioMutationDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  label: string,
): Promise<T> {
  const controller = new AbortController();
  let timeoutError: ComposioMutationTimeoutError | undefined;
  const providerOperation = Promise.resolve()
    .then(() => operation(controller.signal))
    .catch(err => {
      // Abort-aware SDKs may reject synchronously from the abort event with a plain AbortError
      // before Promise.race observes the deadline rejection. Once our deadline fired, normalize
      // every such rejection to the typed timeout so route quarantine/repair always runs.
      if (timeoutError) throw timeoutError;
      throw err;
    });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      timeoutError = new ComposioMutationTimeoutError(`${label} timed out`);
      controller.abort(timeoutError);
      reject(timeoutError);
    }, COMPOSIO_MUTATION_TIMEOUT_MS);
  });
  try {
    return await Promise.race([providerOperation, deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

type ConnectedAccountListItem = Awaited<
  ReturnType<Composio['connectedAccounts']['list']>
>['items'][number];

/**
 * Stable, non-secret generation for the account set a Composio session must resolve. Sessions
 * automatically adopt a user's accounts, but OpenClaw caches the MCP runtime per chat session.
 * Including account identity + lifecycle in the gateway-visible generation makes a newly linked,
 * replaced, paused, resumed, or revoked grant change the config patch exactly once. That invokes
 * OpenClaw's `dispose-mcp-runtimes` hot reload so the next turn discovers current connection truth.
 *
 * Only a truncated SHA-256 digest is stored on the gateway; connected-account ids never leave the
 * backend in plaintext. Sorting makes pagination and API ordering irrelevant.
 */
export function buildComposioScopeMarker(
  accounts: Array<{ id?: unknown; status?: unknown; toolkit?: { slug?: unknown } | null }>,
): string {
  const canonical = accounts
    .filter(account => {
      const status = String(account.status ?? '').trim().toUpperCase();
      return status === 'ACTIVE' || status === 'INACTIVE';
    })
    .map(account => [
      String(account.toolkit?.slug ?? '').trim().toLowerCase(),
      String(account.id ?? '').trim(),
      String(account.status ?? '').trim().toUpperCase(),
    ].join('\u{001F}'))
    .filter(Boolean)
    .sort()
    .join('\u{001E}');
  const digest = createHash('sha256').update(canonical).digest('hex').slice(0, 16);
  return `${COMPOSIO_SCOPE_VERSION}:${digest}`;
}

/** Reads every connected-account page for the catalog. Any later-page failure rejects the whole
 * snapshot so callers cannot mistake an incomplete prefix for absence of a live grant. */
async function listAllConnectedAccountsForStatus(
  composio: Composio,
  userId: string,
  signal?: AbortSignal,
): Promise<ConnectedAccountListItem[]> {
  const accounts: ConnectedAccountListItem[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const response = await composio.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [...COMPOSIO_TOOLKITS],
      ...(cursor ? { cursor } : {}),
    }, { signal });
    accounts.push(...response.items);
    if (!response.nextCursor) return accounts;
    cursor = response.nextCursor;
  }
  throw new Error(`Composio connected-account status exceeded ${MAX_ACCOUNT_PAGES} pages`);
}

/**
 * Toolkit list enriched with real branding (#1069) and this user's current connection status per
 * toolkit (#1082), so a relaunch shows "Connected" for toolkits the user already authorized instead
 * of every row resetting to "Not connected". Logos are best-effort because missing branding is
 * harmless. Account status is authoritative lifecycle state: if that read fails, reject the request
 * so the client preserves known rows and offers recovery rather than exposing false Connect actions.
 *
 * The per-toolkit logo fetch is itself `Promise.allSettled` (not `Promise.all`) across
 * `COMPOSIO_TOOLKITS` — with a growing curated catalog a single bad slug (a
 * catalog rename, a toolkit Composio temporarily can't resolve) must only drop THAT toolkit's logo,
 * not `Promise.all`-reject the whole batch and blank out branding for every other toolkit too.
 */
export async function listToolkitsSummary(userId: string): Promise<ComposioToolkitsSummary> {
  if (!isComposioConfigured()) {
    return {
      configured: false,
      toolkits: COMPOSIO_TOOLKITS.map(slug => ({
        slug,
        logoUrl: composioLogoCdnUrl(slug),
        status: 'not_connected' as const,
        enabled: false,
      })),
    };
  }

  const composio = client();
  const logoResultsPromise = withComposioProviderDeadline(
    signal => Promise.allSettled(COMPOSIO_TOOLKITS.map(slug => composio.toolkits.get(slug, { signal }))),
    'Composio toolkit logos',
    COMPOSIO_LOGO_TIMEOUT_MS,
  ).catch(err => {
    console.error('[composio] toolkit logo batch timed out; using CDN fallbacks:', err);
    return [] as PromiseSettledResult<any>[];
  });
  let accounts: ConnectedAccountListItem[];
  try {
    accounts = await withComposioProviderDeadline(
      signal => listAllConnectedAccountsForStatus(composio, userId, signal),
      'Composio connected-account status',
      COMPOSIO_ACCOUNT_STATUS_TIMEOUT_MS,
    );
  } catch (err) {
    console.error(`[composio] bounded toolkit catalog failed for user ${userId}:`, err);
    throw new ComposioStatusUnavailableError({ cause: err });
  }
  const logoResults = await logoResultsPromise;

  const logoBySlug = new Map<string, string>();
  logoResults.forEach((result, index) => {
    const slug = COMPOSIO_TOOLKITS[index];
    if (result.status === 'fulfilled') {
      if (result.value.meta?.logo) logoBySlug.set(slug, result.value.meta.logo);
    } else {
      console.error(`[composio] toolkit logo fetch failed for "${slug}":`, result.reason);
    }
  });

  const rawStatusesBySlug = new Map<string, string[]>();
  for (const account of accounts) {
    const slug = account.toolkit?.slug;
    if (!slug) continue;
    const bucket = rawStatusesBySlug.get(slug) ?? [];
    bucket.push(String(account.status ?? '').toUpperCase());
    rawStatusesBySlug.set(slug, bucket);
  }

  return {
    configured: true,
    toolkits: COMPOSIO_TOOLKITS.map(slug => {
      const { status, enabled } = summarizeToolkit(rawStatusesBySlug.get(slug) ?? []);
      return {
        slug,
        // Prefer the toolkit's own meta.logo; fall back to the stable CDN so a failed logo fetch never
        // leaves a row branding-less (the client can't tell "fetch failed" from "no logo" — both blank).
        logoUrl: logoBySlug.get(slug) ?? composioLogoCdnUrl(slug),
        status,
        enabled,
      };
    }),
  };
}

/**
 * Structural type for the ONE raw-client method we reach through for true revocation. We can't
 * import `@composio/client` (a transitive dep — phantom-dependency risk, see `isBadRequestStatus`),
 * so we type just what we call.
 */
type RevokingConnectedAccountsClient = {
  connectedAccounts: {
    delete(
      nanoid: string,
      params?: { revoke_on_delete?: boolean } | null,
      options?: { signal?: AbortSignal },
    ): Promise<unknown>;
  };
};

/**
 * DELETE a connected account **and revoke the upstream provider grant**.
 *
 * ⚠️ The high-level `composio.connectedAccounts.delete(nanoid)` does NOT revoke: @composio/core's
 * wrapper calls `this.client.connectedAccounts.delete(nanoid, void 0, requestOptions)` — the params
 * arg (which carries `revoke_on_delete`) is hardcoded to `undefined`, so it defaults to `false` and
 * only soft-deletes the Composio record while the Google/Slack grant stays live. Our UI promises to
 * "revoke Rem's access", so we reach the underlying `@composio/client` (`composio.client`, protected
 * on the type but present at runtime) and pass `{ revoke_on_delete: true }`, which starts the
 * server-side revoke job (`ConnectedAccountDeleteResponse.revoke_job_id`).
 */
function revokeConnectedAccount(
  composio: Composio,
  connectedAccountId: string,
  signal?: AbortSignal,
): Promise<unknown> {
  const raw = (composio as unknown as { client: RevokingConnectedAccountsClient }).client;
  return raw.connectedAccounts.delete(connectedAccountId, { revoke_on_delete: true }, { signal });
}

/** The connected-account status literals @composio/core's `ConnectedAccountListParams.statuses`
 * accepts (verified against 0.14.0's `ConnectedAccountListParamsSchema`). Declared locally so the
 * pagination helper is precisely typed without importing the SDK's Zod-inferred type. */
type ConnectedAccountStatusLiteral =
  | 'INITIALIZING'
  | 'INITIATED'
  | 'ACTIVE'
  | 'FAILED'
  | 'EXPIRED'
  | 'INACTIVE'
  | 'REVOKED';

/** Every connected-account id for `userId` + `toolkit` whose status is in `statuses`, following
 * pagination. Scoped to the user by `userIds` (so this can only ever see/return the caller's own
 * accounts) and to the requested `statuses` (with a client-side re-check), so a row in some other
 * state is never touched. Used both by disconnect (ACTIVE → revoke) and enable/disable (ACTIVE →
 * pause, INACTIVE → resume). */
async function listAccountIdsByStatus(
  composio: Composio,
  userId: string,
  toolkit: ComposioToolkit,
  statuses: ConnectedAccountStatusLiteral[],
  signal?: AbortSignal,
): Promise<string[]> {
  const wanted = new Set<string>(statuses);
  const ids: string[] = [];
  let cursor: string | undefined;
  const seenCursors = new Set<string>();
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const res = await composio.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [toolkit],
      statuses,
      ...(cursor ? { cursor } : {}),
    }, { signal });
    for (const account of res.items) {
      if (account.id && wanted.has(String(account.status ?? '').toUpperCase())) {
        ids.push(String(account.id));
      }
    }
    const next = res.nextCursor;
    if (!next) return ids;
    if (seenCursors.has(next)) {
      throw new Error('Composio connected-account mutation pagination repeated a cursor');
    }
    seenCursors.add(next);
    cursor = next;
  }
  throw new Error(`Composio connected-account mutation exceeded ${MAX_ACCOUNT_PAGES} pages`);
}

/**
 * Backend-owned read path for scheduled connector reads (Daily Brief inputs, tier-2 signal
 * ingest). Returns only ACTIVE, non-disabled grants — never paused rows — because holding an
 * ACTIVE account for a toolkit is what AUTHORIZES the backend to read that source at all.
 *
 * `toolkit` is asserted against the curated catalog: a caller (a signal descriptor, say) naming a
 * toolkit we never offer would otherwise silently return zero accounts and look like "user has not
 * connected it" rather than "we asked for something that cannot exist".
 */
export async function listActiveAccountIdsForToolkit(
  userId: string,
  toolkit: string,
  timeoutMs: number,
): Promise<string[]> {
  const slug = assertToolkit(toolkit);
  const composio = client();
  const deadline = Date.now() + timeoutMs;
  const ids: string[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('timeout');
    const response = await composio.connectedAccounts.list({
      userIds: [userId], toolkitSlugs: [slug], statuses: ['ACTIVE'],
      limit: 100, orderBy: 'created_at', ...(cursor ? { cursor } : {}),
    }, { signal: AbortSignal.timeout(remaining) });
    for (const account of response.items) {
      if (account.id && String(account.status ?? '').toUpperCase() === 'ACTIVE'
        && account.isDisabled !== true) {
        ids.push(String(account.id));
      }
    }
    if (!response.nextCursor) break;
    cursor = response.nextCursor;
  }
  return [...new Set(ids)].sort();
}

/**
 * Same authority as `listActiveAccountIdsForToolkit`, asked for MANY toolkits in ONE round trip —
 * see `ActiveConnectorAccountsByToolkitSource` (connector-signals.runner.ts) for why the tier-2
 * poller needs it and the one-toolkit shape does not scale to a full catalog.
 *
 * Identical rules, deliberately: ACTIVE only (a paused grant is connected but NOT usable, so it
 * must not authorize a read), `isDisabled` respected, same page bound, deduped and sorted.
 *
 * ATTRIBUTION is from the RESPONSE, not from the request. With one slug per call the server-side
 * filter was the attribution; with many, each account must say which toolkit it belongs to, and
 * `toolkit.slug` is a required field of the SDK's parsed item (`listActiveToolkitSlugs` below has
 * read it the same way since it shipped). An account naming a slug we did not ask for is skipped
 * rather than guessed at.
 *
 * THROWS rather than returning a partial answer, for the same reason the single-toolkit version
 * does: "no active account" and "we could not ask" produce opposite behaviour downstream — the
 * first is a silent skip, the second must be a counted, reported failure.
 *
 * `assertToolkit` is applied to every requested slug, so ONE descriptor naming a toolkit outside
 * the curated catalog fails the whole resolution for that tick rather than silently reading as
 * "not connected". That is a wider blast radius than the per-descriptor call had, and it is the
 * right trade: a slug outside the catalog is a code bug in a frozen registry, and this way it
 * reddens the cron (`all_sources_failed`) instead of turning one source permanently, quietly dead.
 */
export async function listActiveAccountIdsByToolkit(
  userId: string,
  toolkitSlugs: readonly string[],
  timeoutMs: number,
): Promise<ReadonlyMap<string, readonly string[]>> {
  const slugs = [...new Set(toolkitSlugs.map(slug => slug.trim().toLowerCase()).filter(Boolean))]
    .map(assertToolkit)
    .sort();
  const byToolkit = new Map<string, string[]>(slugs.map(slug => [slug, []]));
  // No slugs means no question was asked. Returning early keeps the "one call per tick" claim
  // honest: an empty descriptor registry must cost ZERO provider traffic, not one empty query.
  if (slugs.length === 0) return byToolkit;

  const composio = client();
  const deadline = Date.now() + timeoutMs;
  let cursor: string | undefined;
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('timeout');
    const response = await composio.connectedAccounts.list({
      userIds: [userId], toolkitSlugs: slugs, statuses: ['ACTIVE'],
      limit: 100, orderBy: 'created_at', ...(cursor ? { cursor } : {}),
    }, { signal: AbortSignal.timeout(remaining) });
    for (const account of response.items) {
      const slug = String(account.toolkit?.slug ?? '').trim().toLowerCase();
      const ids = byToolkit.get(slug);
      if (!ids || !account.id) continue;
      if (String(account.status ?? '').toUpperCase() !== 'ACTIVE') continue;
      if (account.isDisabled === true) continue;
      ids.push(String(account.id));
    }
    if (!response.nextCursor) break;
    cursor = response.nextCursor;
  }
  for (const [slug, ids] of byToolkit) byToolkit.set(slug, [...new Set(ids)].sort());
  return byToolkit;
}

/**
 * The ONE ACTIVE-account authority for every scheduled connector read — the Daily Brief collector
 * (via the shared runner) and the tier-2 signal poller both bind to this.
 *
 * There is deliberately no `listActiveGmailAccountIds` wrapper any more: a per-toolkit alias is a
 * second place a connector's identity gets typed by hand, and it let the Daily Brief path bind a
 * hardcoded toolkit while claiming to run on a source-generic runner. Callers pass
 * `descriptor.toolkitSlug`.
 *
 * Both shapes hang off ONE object so a caller cannot bind the batched read to a different
 * authority than the single read — the two must always agree about who is connected.
 */
export const composioActiveAccountSource:
  ActiveConnectorAccountSource & ActiveConnectorAccountsByToolkitSource = {
  listActiveAccountIds: listActiveAccountIdsForToolkit,
  listActiveAccountIdsByToolkit,
};

/**
 * Which of `toolkitSlugs` currently have >= 1 ACTIVE connected account for this user.
 *
 * Generalization of `listActiveGmailAccountIds` for the derived automation-inputs contract: that
 * one answers "which Gmail accounts do I collect from", this one answers "is this toolkit live".
 * Same authority rules deliberately — ACTIVE only (a paused/INACTIVE account is connected but
 * NOT usable by the agent, so it must not read as an included input), `isDisabled` respected,
 * same page bound.
 *
 * THROWS rather than returning a partial set. An incomplete page prefix is an unknown answer, and
 * the caller must be able to tell "no active account" from "couldn't ask" — silently returning the
 * prefix would render a Connect call-to-action to an already-connected user.
 */
export async function listActiveToolkitSlugs(
  userId: string,
  toolkitSlugs: readonly string[],
  timeoutMs: number,
): Promise<string[]> {
  const wanted = [...new Set(toolkitSlugs.map(slug => slug.trim().toLowerCase()).filter(Boolean))];
  if (wanted.length === 0) return [];
  const composio = client();
  const deadline = Date.now() + timeoutMs;
  const active = new Set<string>();
  let cursor: string | undefined;
  for (let page = 0; page < MAX_ACCOUNT_PAGES; page++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('timeout');
    const response = await composio.connectedAccounts.list({
      userIds: [userId], toolkitSlugs: wanted, statuses: ['ACTIVE'],
      limit: 100, orderBy: 'created_at', ...(cursor ? { cursor } : {}),
    }, { signal: AbortSignal.timeout(remaining) });
    for (const account of response.items) {
      const slug = String(account.toolkit?.slug ?? '').trim().toLowerCase();
      if (!slug || !wanted.includes(slug)) continue;
      if (String(account.status ?? '').toUpperCase() !== 'ACTIVE') continue;
      if (account.isDisabled === true) continue;
      active.add(slug);
    }
    if (!response.nextCursor) return [...active].sort();
    cursor = response.nextCursor;
  }
  throw new Error(`Composio connected-account status exceeded ${MAX_ACCOUNT_PAGES} pages`);
}

function optionalString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function isStrictRfc3339Instant(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = match[8] === 'Z' ? 0 : Number(match[10]);
  const offsetMinute = match[8] === 'Z' ? 0 : Number(match[11]);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59
    || offsetHour > 23 || offsetMinute > 59) return false;
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
  if (day < 1 || day > daysInMonth) return false;
  return !Number.isNaN(Date.parse(value));
}

/**
 * Gmail's WIRE fields → the one item shape every consumer of this transport reads.
 *
 * THE DEFECT THIS EXISTS TO KILL. `GMAIL_FETCH_EMAILS` puts a message on the wire as
 * `messageId` / `preview` / `messageTimestamp`. Everything downstream — `parseGmailItem` in
 * `connector-signals.registry.ts`, and therefore `gmailSignalDescriptor.mapItem` — reads
 * `providerMessageId` / `snippet` / `timestamp`. The rename used to live INSIDE
 * `parseGmailFetchEmailsResult`, which only the Daily Brief adapter called. The signal executor
 * returned `data.messages` verbatim, so `mapItem` saw `providerMessageId: undefined` on every
 * real message, dropped all of them, and the cron logged
 * `fetched=2 dropped=2 ingested=0 failed=0` — a clean green run over an empty table.
 *
 * So the rename is now ONE function, applied by BOTH adapters on this file's I/O boundary. Adding
 * a third consumer of `GMAIL_FETCH_EMAILS` cannot reintroduce the divergence without deleting this
 * call, and a field renamed here changes for everyone at once.
 *
 * TOTAL, and deliberately so: it renames and coerces, it does not judge. Validation policy is
 * legitimately different per consumer and stays with each consumer — the Daily Brief is
 * all-or-nothing (`parseGmailFetchEmailsResult` throws, because its output is a provenance
 * snapshot that must describe exactly one complete read), while the signal path drops per item and
 * counts the drop. Folding either policy in here would force one of them onto the other.
 *
 * ── WHY IT NOW ACCEPTS TWO SHAPES, REVERSING THIS FILE'S EARLIER RULE ────────────────────────────
 *
 * The rule used to be "do not accept both shapes, it hides the next divergence." That was correct
 * while the goal was to force somebody to go capture a real payload. Nobody has: every occurrence
 * of `messageId` / `preview` / `messageTimestamp` in this repo is hand-authored, `git log -S` on
 * the commit that introduced them (3257f289) carries no captured response and no provenance, the
 * "locally verified" claim in `parseGmailFetchEmailsResult`'s docblock has no artifact behind it,
 * and Composio does not publish this action's response schema. One secondary source uses `id`
 * rather than `messageId`.
 *
 * So the assumed names are a GUESS, and the cost of a wrong guess is not an error — it is
 * `providerMessageId: ''` on every real message, zero rows, and a green suite. That has now
 * happened three times. The alternative to tolerance is not "a real fix"; it is a feature that
 * stays dead indefinitely. Tolerance plus a truthful log is strictly better than a guess:
 * `logGmailWireShape` prints, once per collection, WHICH key set the provider actually sent.
 *
 * THIS IS TEMPORARY AND SELF-RETIRING. The first real run tells us the answer. Once a production
 * log line reports the matched shape, DELETE the loser from `GMAIL_WIRE_*_KEYS` below and this
 * paragraph with it. A tolerant reader is a bridge to the fact, not a substitute for it.
 */
export function normalizeGmailWireMessage(raw: unknown): GmailBriefRawItem {
  return normalizeGmailWireItem(raw).item;
}

/**
 * Candidate wire keys per field, in PREFERENCE order: index 0 is the long-assumed name, the rest
 * are the plausible Gmail-API alternatives. Preferring index 0 keeps the assumed shape's behaviour
 * bit-identical when both names are present, so tolerance cannot silently change today's reading.
 *
 * `threadId` is not listed because both candidate shapes spell it the same.
 */
const GMAIL_WIRE_ID_KEYS = ['messageId', 'id'] as const;
// `snippetKey=none` on the first real run: neither `preview` nor `snippet` matched, so signals
// landed with only a subject. These are Gmail's own documented spellings for the body preview
// plus the shapes Composio has used elsewhere. The verdict line now names any field it did
// not see, so the next run says which of these (if any) is real.
const GMAIL_WIRE_SNIPPET_KEYS = [
  'preview', 'snippet', 'messageText', 'body', 'bodyPreview', 'messageSnippet', 'text',
] as const;
/** `internalDate` is Gmail's own field and needs a UNIT conversion — see `gmailWireInstant`. */
const GMAIL_WIRE_TIMESTAMP_KEYS = ['messageTimestamp', 'timestamp', 'internalDate'] as const;

/** Which wire key actually carried each field on one item. `null` = the field was absent. */
interface GmailWireKeyMatch {
  idKey: string | null;
  snippetKey: string | null;
  tsKey: string | null;
}

/** First candidate present as a non-empty string (or, for `internalDate`, a finite number). */
function pickGmailWireKey(
  message: Record<string, unknown>,
  candidates: readonly string[],
): string | null {
  for (const key of candidates) {
    const value = message[key];
    if (typeof value === 'string' && value.trim() !== '') return key;
    if (key === 'internalDate' && typeof value === 'number' && Number.isFinite(value)) return key;
  }
  return null;
}

/**
 * `internalDate` is EPOCH MILLISECONDS AS A STRING (`"1786620600000"`), not ISO-8601 — Gmail's
 * documented type for it is `string (int64 format)`. `isStrictRfc3339Instant` on the brief path
 * REFUSES a numeric string, so accepting this key without converting it would reproduce the exact
 * failure this change exists to end: silent per-item drops.
 *
 * The unit conversion itself is NOT written here. `parseEpochInstant`
 * (connector-signals.registry.ts) owns the seconds-vs-milliseconds rule for every connector, and
 * this used to be a second, Gmail-only copy of it — two implementations that could disagree about
 * what a number means, which is precisely the class of divergence `normalizeGmailWireMessage`
 * exists to prevent. One rule, documented once, tested once.
 *
 * Returns '' — the same "absent" value as a missing key — for anything the shared rule refuses, so
 * a surprise here drops one item and is counted rather than inventing a date.
 */
function gmailWireInstant(key: string, value: unknown): string {
  if (key !== 'internalDate') return optionalString(value);
  const digits = (typeof value === 'number' ? String(value) : optionalString(value)).trim();
  return parseEpochInstant(digits)?.toISOString() ?? '';
}

/** The rename itself, plus the record of which key set it read. */
function normalizeGmailWireItem(raw: unknown): { item: GmailBriefRawItem; keys: GmailWireKeyMatch } {
  const message = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const idKey = pickGmailWireKey(message, GMAIL_WIRE_ID_KEYS);
  const snippetKey = pickGmailWireKey(message, GMAIL_WIRE_SNIPPET_KEYS);
  const tsKey = pickGmailWireKey(message, GMAIL_WIRE_TIMESTAMP_KEYS);
  return {
    item: {
      providerMessageId: idKey ? optionalString(message[idKey]).trim() : '',
      providerThreadId: optionalString(message.threadId) || null,
      sender: optionalString(message.sender),
      subject: optionalString(message.subject),
      snippet: snippetKey ? optionalString(message[snippetKey]) : '',
      timestamp: tsKey ? gmailWireInstant(tsKey, message[tsKey]) : '',
    },
    keys: { idKey, snippetKey, tsKey },
  };
}

/** One key across a whole collection: the key itself, `none` if never seen, `mixed` if it varied. */
function collapseObservedKey(observed: Set<string>): string {
  if (observed.size === 0) return 'none';
  if (observed.size === 1) return [...observed][0];
  return 'mixed';
}

/**
 * ONE structured line per collection naming the key set the provider actually sent. This is the
 * point of the tolerance above: without it we would have swapped one unverified guess for two, and
 * still not know which is real.
 *
 * PRIVACY: field NAMES and counts only. No id, sender, subject, snippet, token, or any other
 * mailbox value is ever formatted into this line — read `collapseObservedKey`'s inputs, which are
 * sets of key names taken from `GMAIL_WIRE_*_KEYS`, never from message content.
 *
 * ONE LINE PER COLLECTION, not per item: this poller re-reads a rolling 24h window every 15
 * minutes, so per-item logging would bury the answer in its own volume. An EMPTY collection logs
 * nothing — zero items carry zero evidence about shape, and the ingest summary already reports
 * emptiness through `fetched`.
 */
function logGmailWireShape(
  items: number,
  observed: { id: Set<string>; snippet: Set<string>; ts: Set<string> },
): void {
  const matchedKeys = [...observed.id, ...observed.snippet, ...observed.ts];
  const assumed = new Set<string>([
    GMAIL_WIRE_ID_KEYS[0], GMAIL_WIRE_SNIPPET_KEYS[0], GMAIL_WIRE_TIMESTAMP_KEYS[0],
  ]);
  // THE ID FIELD VETOES THE VERDICT. It used to drop out of the vote when it matched no
  // candidate, so a payload spelling the id a THIRD way while keeping the other two names logged
  // `matched=assumed` on a run that produced ids of ["", ""] and wrote zero rows. Observed against
  // the production normalizer with {gmailMsgId, preview, messageTimestamp}:
  //
  //   [gmail-wire] matched=assumed items=2 idKey=none snippetKey=preview tsKey=messageTimestamp
  //
  // That line is the ENTIRE justification for accepting two spellings — the docblock on
  // GMAIL_WIRE_ID_KEYS tells an operator to read the first real production line and delete the
  // loser. Acting on a false `assumed` deletes the tolerance and entrenches a dead producer,
  // which is the exact failure the tolerance exists to end.
  // ANY unmatched field qualifies the verdict, not just the id. The first real production run
  // printed `matched=assumed items=1 idKey=messageId snippetKey=none tsKey=messageTimestamp` —
  // confidently "assumed" while the snippet field matched NO candidate, so every signal landed
  // with a subject and no body preview. An operator following the retirement instruction on
  // GMAIL_WIRE_ID_KEYS would read "assumed" and delete the alternatives, entrenching that gap.
  // A verdict may only claim to have identified the shape when it actually saw all three fields.
  const unseen = [
    observed.id.size === 0 ? 'id' : null,
    observed.snippet.size === 0 ? 'snippet' : null,
    observed.ts.size === 0 ? 'ts' : null,
  ].filter((f): f is string => f !== null);
  const matched = unseen.length > 0
    ? (matchedKeys.length === 0 ? 'none' : `partial-missing:${unseen.join('+')}`)
    : matchedKeys.every(key => assumed.has(key))
      ? 'assumed'
      : matchedKeys.every(key => !assumed.has(key))
        ? 'alternative'
        : 'mixed';
  console.log(
    `[gmail-wire] matched=${matched} items=${items}`
    + ` idKey=${collapseObservedKey(observed.id)}`
    + ` snippetKey=${collapseObservedKey(observed.snippet)}`
    + ` tsKey=${collapseObservedKey(observed.ts)}`,
  );
}

/**
 * Normalize one PAGE of wire messages and report its shape exactly once.
 *
 * Collection-scoped on purpose: the shape question is about a response, not about a message, and
 * the log line has to be answerable from one grep of one cron run.
 */
export function normalizeGmailWireCollection(rawItems: readonly unknown[]): GmailBriefRawItem[] {
  const observed = { id: new Set<string>(), snippet: new Set<string>(), ts: new Set<string>() };
  const items = rawItems.map(raw => {
    const { item, keys } = normalizeGmailWireItem(raw);
    if (keys.idKey) observed.id.add(keys.idKey);
    if (keys.snippetKey) observed.snippet.add(keys.snippetKey);
    if (keys.tsKey) observed.ts.add(keys.tsKey);
    return item;
  });
  if (items.length > 0) logGmailWireShape(items.length, observed);
  return items;
}

/**
 * Strict parser for the GMAIL_FETCH_EMAILS 20260721_00 envelope.
 *
 * The envelope KEYS (`data.messages`, `data.nextPageToken`) are what this parser was written
 * against; the per-message field names are NOT verified — see `normalizeGmailWireMessage`, which
 * now reads either candidate shape and logs which one arrived.
 */
export function parseGmailFetchEmailsResult(result: unknown): GmailBriefPage {
  if (!result || typeof result !== 'object') throw new Error('invalid_gmail_result');
  const envelope = result as Record<string, unknown>;
  if (envelope.successful !== true || envelope.error != null) throw new Error('gmail_action_failed');
  const data = envelope.data;
  if (!data || typeof data !== 'object') throw new Error('invalid_gmail_data');
  const record = data as Record<string, unknown>;
  if (record.messages !== undefined && !Array.isArray(record.messages)) {
    throw new Error('invalid_gmail_messages');
  }
  const rawMessages = record.messages as unknown[] | undefined ?? [];
  for (const raw of rawMessages) {
    if (!raw || typeof raw !== 'object') throw new Error('invalid_gmail_message');
  }
  // Same ONE normalizer the signal executor uses, and the same single shape log line.
  const items = normalizeGmailWireCollection(rawMessages);
  for (const item of items) {
    // Timestamp representation is not execution-proved. Accept only explicit RFC3339 strings;
    // never infer locale-formatted values or numeric units. `internalDate` is converted from
    // epoch millis to ISO by the normalizer, so it reaches here already RFC3339.
    if (!item.providerMessageId || !isStrictRfc3339Instant(item.timestamp)) {
      throw new Error('invalid_gmail_message');
    }
  }
  const nextPageToken = record.nextPageToken;
  if (nextPageToken !== undefined && nextPageToken !== null && typeof nextPageToken !== 'string') {
    throw new Error('invalid_gmail_page_token');
  }
  return { items, nextPageToken: nextPageToken as string | null | undefined ?? null };
}

export const composioGmailBriefAdapter: GmailBriefAdapter = {
  async fetchPage(input) {
    const result = await client().tools.execute(
      input.action,
      {
        userId: input.userId,
        connectedAccountId: input.connectedAccountId,
        version: input.version,
        arguments: {
          verbose: false,
          include_payload: false,
          ids_only: false,
          include_spam_trash: false,
          max_results: input.maxResults,
          query: input.query,
          ...(input.pageToken ? { page_token: input.pageToken } : {}),
        },
      },
      { signal: AbortSignal.timeout(input.timeoutMs) },
    );
    return parseGmailFetchEmailsResult(result);
  },
};

/**
 * Where a Composio action's items and page cursor live, and how one item is renamed onto the shape
 * descriptors read — PER ACTION.
 *
 * There is no cross-action convention to infer: `data.messages` / `data.nextPageToken` /
 * `page_token` are Gmail's, verified against a live GMAIL_FETCH_EMAILS 20260721_00 response (the
 * same envelope `parseGmailFetchEmailsResult` parses for the Daily Brief). Guessing these keys for
 * an unverified action yields an empty item array and a job that reports a clean run having read
 * nothing — the exact failure mode this workflow exists to remove. So an unlisted action throws.
 * Adding a second signal descriptor REQUIRES adding a verified entry here.
 *
 * `normalizeItems` is REQUIRED, not optional, and that is the load-bearing part. Its absence was
 * the whole bug: this executor used to hand `record[itemsKey]` to `descriptor.mapItem` verbatim,
 * in the provider's wire naming, while the descriptor had only ever been written against the
 * renamed shape the brief adapter produces. A required field means a new action cannot be
 * registered here without someone answering "what does one of its items look like to a
 * descriptor?" — the question this defect skipped twice.
 *
 * COLLECTION-scoped rather than item-scoped so the normalizer can emit its one shape log line per
 * response (`[gmail-wire] matched=…`). That line is how the two candidate wire shapes stop being
 * two guesses and become one fact.
 */
const COMPOSIO_SIGNAL_ENVELOPES: Record<
  string,
  {
    itemsKey: string;
    nextPageTokenKey: string;
    pageTokenArgument: string;
    /** Wire page → the shape `descriptor.mapItem` reads. Same function the brief path applies. */
    normalizeItems: (raw: readonly unknown[]) => unknown[];
  }
> = {
  GMAIL_FETCH_EMAILS: {
    itemsKey: 'messages',
    nextPageTokenKey: 'nextPageToken',
    pageTokenArgument: 'page_token',
    normalizeItems: normalizeGmailWireCollection,
  },
};

/**
 * Provider transport for the scheduled signal poller. Returns items in the SAME normalized shape
 * `composioGmailBriefAdapter` returns — one rename, one function
 * (`COMPOSIO_SIGNAL_ENVELOPES[action].normalizeItem`), both consumers.
 *
 * It does NOT judge the items. Deciding that an item is unusable — no message id, an unparseable
 * timestamp — is `descriptor.mapItem`'s call, and the ingest loop counts each refusal as a
 * `dropped`. Filtering here instead would make a malformed message vanish from `fetched` too, and
 * "we never saw it" would become indistinguishable from "we saw it and threw it away".
 *
 * Envelope validation stays as strict as the brief path's: a Composio result that is not
 * explicitly `successful` is an error, never an empty page.
 */
export const composioSignalExecutor: ConnectorSignalExecutor = {
  async fetchPage(input) {
    const envelope = COMPOSIO_SIGNAL_ENVELOPES[input.action];
    if (!envelope) throw new Error('unsupported_signal_action');
    const result = await client().tools.execute(
      input.action,
      {
        userId: input.userId,
        connectedAccountId: input.connectedAccountId,
        version: input.version,
        arguments: {
          ...input.arguments,
          ...(input.pageToken ? { [envelope.pageTokenArgument]: input.pageToken } : {}),
        },
      },
      { signal: AbortSignal.timeout(input.timeoutMs) },
    );
    if (!result || typeof result !== 'object') throw new Error('invalid_signal_result');
    const outer = result as Record<string, unknown>;
    if (outer.successful !== true || outer.error != null) throw new Error('signal_action_failed');
    const data = outer.data;
    if (!data || typeof data !== 'object') throw new Error('invalid_signal_data');
    const record = data as Record<string, unknown>;
    const items = record[envelope.itemsKey];
    if (items !== undefined && !Array.isArray(items)) throw new Error('invalid_signal_items');
    const nextPageToken = record[envelope.nextPageTokenKey];
    if (nextPageToken !== undefined && nextPageToken !== null && typeof nextPageToken !== 'string') {
      throw new Error('invalid_signal_page_token');
    }
    return {
      items: envelope.normalizeItems((items as unknown[] | undefined) ?? []),
      nextPageToken: (nextPageToken as string | null | undefined) ?? null,
    };
  },
};

/** Every LIVE connected-account id for `userId` + `toolkit` — the revoke target set. Covers BOTH
 * `ACTIVE` and `INACTIVE`: a **paused** connector's accounts are `INACTIVE` (see `setToolkitEnabled`),
 * yet its row is still `isConnected` and its manage sheet still offers Disconnect. Revoking only
 * `ACTIVE` would make disconnecting a paused connector a silent `{ deleted: 0 }` no-op — the OAuth
 * grant would survive and the row would reappear as "Connected • Paused" on the next reload. The raw
 * `revokeConnectedAccount` delete works on an INACTIVE account too, so it's just a wider filter. */
function listRevocableAccountIds(
  composio: Composio,
  userId: string,
  toolkit: ComposioToolkit,
  signal?: AbortSignal,
): Promise<string[]> {
  return listAccountIdsByStatus(composio, userId, toolkit, ['ACTIVE', 'INACTIVE'], signal);
}

/**
 * Disconnect (revoke) a toolkit for `userId` — deletes+revokes EVERY LIVE connected account for
 * that toolkit (both `ACTIVE` and paused/`INACTIVE`), not just the first. `createConnectSession`
 * passes `allowMultiple: true`, so a user can hold >1 row per toolkit (retries, re-connects);
 * revoking only one would leave the agent still connected. Idempotent: zero live accounts returns
 * `{ deleted: 0 }` (already disconnected) rather than erroring, so the row can safely flip to
 * not-connected.
 *
 * Covers `INACTIVE` too (see `listRevocableAccountIds`): a **paused** connector's row is still
 * `isConnected` and still offers Disconnect, but its accounts are `INACTIVE` — an `ACTIVE`-only
 * revoke would be a silent `{ deleted: 0 }` no-op that leaves the OAuth grant live. Disconnect must
 * fully revoke regardless of the pause state.
 *
 * Inherently user-scoped — `listRevocableAccountIds` only ever lists `userIds:[userId]`, so there is
 * no cross-user id to guess and no separate ownership check to get wrong (the old id-based path had
 * both problems: a first-page-only ownership scan, and a single-id delete).
 *
 * `mcp.servers.composio` remains one per-user endpoint rather than one server per account. The HTTP
 * route follows this mutation with `ensureComposioMcpWired`, whose account-set generation hot-
 * reloads OpenClaw's cached MCP runtime; the service itself only revokes the requested accounts.
 */
export async function disconnectToolkit(
  userId: string,
  toolkit: string,
  scope?: ComposioMutationScope,
): Promise<{ deleted: number }> {
  const kit = assertToolkit(toolkit);
  const composio = client();
  return withComposioMutationDeadline(async signal => {
    const listedIds = await listRevocableAccountIds(composio, userId, kit, signal);
    const repairIds = scope?.repairAccountIds
      ? new Set(scope.repairAccountIds)
      : undefined;
    const ids = repairIds ? listedIds.filter(id => repairIds.has(id)) : listedIds;
    scope?.captureRepairAccountIds?.(ids);
    let deleted = 0;
    for (const id of ids) {
      if (scope?.isCurrent && !scope.isCurrent()) break;
      await revokeConnectedAccount(composio, id, signal);
      deleted += 1;
    }
    return { deleted };
  }, `Composio ${kit} revoke`);
}

/**
 * Enable (resume) or disable (PAUSE) a toolkit for `userId` — the NON-destructive counterpart to
 * `disconnectToolkit`. Unlike disconnect (which deletes+revokes the OAuth grant), this only flips
 * the connected account's status: `disable()` → INACTIVE (token KEPT, agent can't use it),
 * `enable()` → ACTIVE (instantly usable again, no re-auth). Applies to EVERY matching account for
 * the toolkit, mirroring disconnect's multi-account handling (`allowMultiple: true` means a user can
 * hold >1 row per toolkit). Idempotent: already in the desired state → nothing to list →
 * `{ updated: 0 }`. Inherently user-scoped via `listAccountIdsByStatus(userIds:[userId])`.
 *
 * Unlike `revokeConnectedAccount` (which needs the raw @composio/client for `revoke_on_delete`),
 * `enable`/`disable` are correctly forwarded by @composio/core's high-level `connectedAccounts`
 * wrapper, so we call them directly.
 *
 * ── Does "Paused" actually block the agent's MCP tools? (VERIFIED, not assumed) ─────────────────
 * YES — a disabled account cannot be used by the agent. The Composio MCP endpoint remains a single
 * per-user server spanning all toolkits, while the HTTP route follows this mutation with
 * `ensureComposioMcpWired`. Its account-set generation changes on ACTIVE/INACTIVE and drives
 * OpenClaw's `dispose-mcp-runtimes` hot reload, so a long-lived chat cannot retain a stale tool
 * catalog or connection view after the switch changes.
 */
export async function setToolkitEnabled(
  userId: string,
  toolkit: string,
  enabled: boolean,
  scope?: ComposioMutationScope,
): Promise<{ updated: number }> {
  const kit = assertToolkit(toolkit);
  const composio = client();
  // enable → resume the PAUSED (INACTIVE) accounts; disable → pause the ACTIVE ones.
  const sourceStatuses: ConnectedAccountStatusLiteral[] = enabled ? ['INACTIVE'] : ['ACTIVE'];
  return withComposioMutationDeadline(async signal => {
    const listedIds = await listAccountIdsByStatus(composio, userId, kit, sourceStatuses, signal);
    const repairIds = scope?.repairAccountIds
      ? new Set(scope.repairAccountIds)
      : undefined;
    const ids = repairIds ? listedIds.filter(id => repairIds.has(id)) : listedIds;
    scope?.captureRepairAccountIds?.(ids);
    let updated = 0;
    for (const id of ids) {
      if (scope?.isCurrent && !scope.isCurrent()) break;
      if (enabled) {
        await composio.connectedAccounts.enable(id, { signal });
      } else {
        await composio.connectedAccounts.disable(id, { signal });
      }
      updated += 1;
    }
    return { updated };
  }, `Composio ${kit} ${enabled ? 'resume' : 'pause'}`);
}

/**
 * The gateway's `mcp.servers.<name>.transport` literal (see Shared/Models/McpServerModels.swift
 * `McpServerTransport` / openclaw/src/config/types.mcp.ts). Composio's SDK reports its own
 * `session.mcp.type` as `'http' | 'sse'` (@composio/core 0.14.0 `Session.mcp`) — 'http' names the
 * MCP spec's Streamable HTTP transport, which the gateway schema spells `'streamable-http'`. Kept
 * as an explicit map (not a raw pass-through) so an unrecognized future `type` is caught in
 * `mapComposioTransport` rather than silently writing an invalid transport string into the gateway
 * config.
 */
export type GatewayMcpTransport = 'sse' | 'streamable-http';

function mapComposioTransport(type: string): GatewayMcpTransport {
  if (type === 'sse') return 'sse';
  if (type === 'http') return 'streamable-http';
  // Unknown future SDK value — default to the modern spec transport rather than throw, since a
  // wrong-but-plausible guess here just means an MCP connect error surfaced later on the gateway,
  // not a crash-loop (transport is never omitted/null — see ComposioMcpConfig doc).
  console.warn(`[composio] unrecognized session.mcp.type "${type}", defaulting to streamable-http`);
  return 'streamable-http';
}

export interface ComposioMcpConfig {
  /** Per-user Composio MCP endpoint the gateway adds to `mcp.servers.composio`. */
  url: string;
  /** Auth headers the gateway sends on the MCP connection (never surfaced to the client/agent chat). */
  headers: Record<string, string>;
  /** Gateway-schema transport literal, mapped from Composio's `session.mcp.type`. */
  transport: GatewayMcpTransport;
}

/**
 * The per-user Composio hosted-MCP config to wire into the user's gateway (mcp.servers.composio via
 * the same config.patch path SharedMcpServersView uses — the base-hash fix, PR #1035, is merged to
 * staging). The agent then calls the user's connected tools through it. Returns null when no MCP
 * session is available yet (e.g. no connected accounts).
 *
 * NOTE: `composio.sessions.create` (aliased as `composio.create`) mints a NEW tool-router session
 * every call — it is NOT idempotent/cached per userId. Callers should call this at most once per
 * gateway-wiring attempt (see `ensureComposioMcpWired`'s already-wired short-circuit below), not on
 * every status poll, or they'll churn orphaned Composio sessions and rewrite a still-valid gateway
 * config with a different (but equally valid) URL for no reason.
 *
 * `toolkits: [...COMPOSIO_TOOLKITS]` (#1099 fix): explicitly scopes the session to the toolkits Rem
 * actually offers, mirroring Composio's own documented usage (`sessions.mdx`'s canonical example:
 * `composio.sessions.create('user_123', { toolkits: ['gmail'], manageConnections: true })`). Without
 * this the session was created with `toolkits` entirely unset — the live symptom was the agent
 * finding and calling a Gmail tool through the session, but the tool call reporting "No active Gmail
 * connection found" even though `connectedAccounts.list({ userIds: [userId] })` (what
 * `listToolkitsSummary` uses for the Settings screen) shows an ACTIVE gmail account for the exact
 * same `userId`. `ToolRouterCreateSessionConfig.toolkits` (`@composio/core/src/types/
 * toolRouter.types.ts`) is the field that scopes which toolkits the session resolves *connections*
 * for, not just which tool schemas it exposes — a toolkit whose tools got exposed some other way
 * (e.g. a project-wide default) without being in this list is exactly the shape of bug where the
 * tool is callable but reports no active connection. This does not change `createConnectSession`'s
 * `connectedAccounts.link(userId, authConfigId, ...)` call (unaffected, already scoped by the exact
 * same `userId` + resolved auth config) — only the SESSION's own toolkit scope was the gap.
 */
export async function getMcpConfig(userId: string): Promise<ComposioMcpConfig | null> {
  const composio = client();
  // MCP is opt-in per session in 0.14.0 — `{ mcp: true }` makes session.mcp a usable endpoint.
  const session = await composio.create(userId, { mcp: true, toolkits: [...COMPOSIO_TOOLKITS] });
  const mcp = session.mcp;
  if (!mcp?.url) return null;
  return { url: mcp.url, headers: mcp.headers ?? {}, transport: mapComposioTransport(mcp.type) };
}

/**
 * Builds the `mcp.servers.composio` merge-patch — the SAME shape `SharedMcpServersView`'s "Add
 * Custom MCP Server" sheet writes (Shared/Views/Skills/SharedMcpServersView.swift `addServer`):
 * `{ mcp: { servers: { composio: { url, transport, headers } } } }`. Desired fields are concrete;
 * keys present in the inspected managed record but absent from the desired record are explicitly
 * `null` so RFC 7396 cannot preserve stale transport or header state. The no-retained-grant path
 * deliberately sends the separate exact deletion patch `{ mcp: { servers: { composio: null } } }`.
 * `headers` carries the
 * Composio-issued auth token; it is written straight into the gateway's own config file over the
 * operator WebSocket and is never returned to any HTTP route or the app.
 */
export function buildComposioMcpConfigPatch(
  mcp: ComposioMcpConfig,
  scopeMarker = COMPOSIO_SCOPE_VERSION,
  currentServer?: Record<string, unknown>,
): Record<string, unknown> {
  const desiredHeaders: Record<string, string | null> = { ...mcp.headers };
  const currentHeaders = currentServer?.headers;
  if (currentHeaders && typeof currentHeaders === 'object' && !Array.isArray(currentHeaders)) {
    for (const key of Object.keys(currentHeaders)) {
      if (!(key in desiredHeaders)) desiredHeaders[key] = null;
    }
  }

  const desiredServer: Record<string, unknown> = {
    url: mcp.url,
    transport: mcp.transport,
    [COMPOSIO_SCOPE_CONFIG_KEY]: scopeMarker,
    headers: desiredHeaders,
  };
  if (currentServer) {
    for (const key of Object.keys(currentServer)) {
      if (!(key in desiredServer)) desiredServer[key] = null;
    }
  }

  return {
    mcp: {
      servers: {
        composio: desiredServer,
      },
    },
  };
}

function isRemOwnedComposioServer(server: Record<string, unknown>): boolean {
  if (typeof server[COMPOSIO_SCOPE_CONFIG_KEY] === 'string') return true;
  if (typeof server.url !== 'string') return false;
  try {
    return new URL(server.url).hostname.toLowerCase() === 'mcp.composio.dev';
  } catch {
    return false;
  }
}

function hasStaleComposioTopLevelKeys(server: Record<string, unknown>): boolean {
  const managedKeys = new Set(['url', 'transport', COMPOSIO_SCOPE_CONFIG_KEY, 'headers']);
  return Object.keys(server).some(key => !managedKeys.has(key));
}

function hasLegacyComposioHeaders(server: Record<string, unknown>): boolean {
  const headers = server.headers;
  if (!headers || typeof headers !== 'object' || Array.isArray(headers)) return false;
  // Older RemClaw builds persisted the scope generation in a header. config.get redacts values but
  // preserves keys, so the visible legacy key is sufficient to force one replacement that removes
  // it; arbitrary Composio-issued headers remain valid and do not cause perpetual reminting.
  return Object.keys(headers).some(key => key.toLowerCase() === 'x-rem-composio-scope');
}

export interface ComposioMcpWireResult {
  wired: boolean;
  reason?: 'already_wired' | 'no_mcp_session' | 'no_gateway' | 'busy';
}

/**
 * Idempotently wires this user's per-user Composio hosted-MCP endpoint into `mcp.servers.composio`
 * on their gateway, via the WS `config.patch` hot-reload path (`withGatewayRequester`,
 * gateway-pair.service.ts) — the SAME protocol `SharedMcpServersView` uses for custom MCP
 * servers: a merge-patch, no gateway restart.
 *
 * VERIFIED (not assumed) that `mcp.*` config changes do NOT require a gateway restart, against the
 * exact pinned OpenClaw commit this fleet runs (a99c65a973d3bfa2e9f1288d9a25ba3e06b40c03,
 * openclaw/src/gateway/config-reload-plan.ts): `{ prefix: "mcp", kind: "hot", actions:
 * ["dispose-mcp-runtimes"] }` — a HOT rule, not a restart rule, and `resolveGatewayReloadSettings`
 * defaults `gateway.reload.mode` to `"hybrid"` (we never set it), which takes the hot path for any
 * plan that doesn't set `restartGateway`. `dispose-mcp-runtimes` calls
 * `disposeAllSessionMcpRuntimes()` (openclaw/src/gateway/server-reload-handlers.ts), which evicts
 * the cached per-session MCP runtime (openclaw/src/agents/pi-bundle-mcp-runtime.ts
 * `SessionMcpRuntimeManager`) so the NEXT agent turn on that session re-fetches the tool catalog
 * from the config as it stands then — including our newly-added `composio` server — with no
 * process restart. This is why we push via the WS `config.patch` path and never via the wrapper's
 * HTTP `config-patch` (file-merge + full `restartGateway()`, which drops the app's live WebSocket,
 * #953) — that heavier path was never needed for `mcp.*` at this pinned ref.
 *
 * Checks the GATEWAY'S OWN config first — principle 3, gateway is the source of truth — rather than
 * a backend-side "did we already wire this" flag that could drift from what's actually on the
 * gateway. A harmless Rem-owned server extension records which curated catalog minted the session;
 * it cannot live in headers because `config.get` correctly redacts every header value.
 * Matching sessions remain a cheap `config.get` no-op; missing/older scope rotates exactly once.
 *
 * Called from multiple, INDEPENDENT trigger points on purpose (#1087 fix-up) — no single one is
 * trusted to always fire: composio.routes.ts right after a connection is observed `connected` and
 * whenever the toolkits list loads; gateway.routes.ts `/gateway/wake` on every app cold launch; and
 * the one-shot `sync-composio-mcp-all-gateways.ts` script for an immediate manual reconcile that
 * doesn't depend on the app doing anything at all. Every call logs a DEFINITIVE outcome
 * (`mcp already wired` / `mcp wired` / `mcp NOT wired`) so a human can confirm from backend logs
 * alone whether this ran, rather than inferring it from silence.
 *
 * BOUNDED RETRY (#1087 3rd layer): the live symptom after the protocol-version fix was
 * `Error: WebSocket timeout after 15000ms ...` — `/gateway/wake` had already reported the gateway
 * `ready: true`, but this fleet's shared-cpu-2x Fly machines can still take 15-67s to actually
 * SERVICE an RPC even once listening (see `GATEWAY_RPC_TIMEOUT_MS` in gateway-pair.service.ts,
 * which this fix also bumped from 15s to 120s). A single still-slow attempt right at the moment the
 * gateway just woke up is exactly the kind of transient condition worth one retry for, rather than
 * silently giving up until the NEXT cold launch. `MAX_WIRE_ATTEMPTS = 2` (one retry) with a short
 * fixed delay — bounded, not a backoff loop, because every call site here already gets a natural
 * retry on its own cadence (the next `/gateway/wake`, the next toolkits-screen load, re-running the
 * sync script) if this still fails after 2 attempts.
 *
 * `opts.force` remains an operator repair escape hatch that always re-mints. Ordinary catalog
 * evolution no longer needs a fleet script because the stored scope version is self-healing.
 */
const MAX_WIRE_ATTEMPTS = 2;
const WIRE_RETRY_DELAY_MS = 5_000;
interface ComposioWireRequest {
  gatewayUrl: string;
  gatewayToken: string;
  setupPassword?: string;
  opts?: { force?: boolean };
}
interface ComposioWireFlight {
  dirty: boolean;
  phase: 'leading' | 'trailing';
  latest: ComposioWireRequest;
  promise: Promise<ComposioMcpWireResult>;
}
const composioWireByUser = new Map<string, ComposioWireFlight>();

export async function ensureComposioMcpWired(
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
  opts?: { force?: boolean },
): Promise<ComposioMcpWireResult> {
  const request = { gatewayUrl, gatewayToken, setupPassword, opts };
  const existing = composioWireByUser.get(userId);
  if (existing) {
    if (existing.phase === 'trailing') {
      // The bounded trailing pass already captured its request. A later arrival must retry instead
      // of being falsely acknowledged or extending an unbounded promise chain.
      return { wired: false, reason: 'busy' };
    }
    // Collapse any leading-pass burst into one trailing pass using the newest arguments. Calls
    // arriving once that trailing snapshot is fixed receive retryable busy above.
    existing.latest = request;
    existing.dirty = true;
    return existing.promise;
  }

  const flight = {} as ComposioWireFlight;
  flight.dirty = false;
  flight.phase = 'leading';
  flight.latest = request;
  flight.promise = (async () => {
    let result: ComposioMcpWireResult | undefined;
    let leadingError: unknown;
    try {
      result = await runComposioMcpReconciliation(userId, flight.latest);
    } catch (error) {
      leadingError = error;
    }
    if (result?.reason === 'busy') {
      // Preserve a lone trigger through one bounded delayed retry without waiting in either lock
      // limiter. Natural route/wake triggers remain the longer-term retry mechanism.
      flight.dirty = true;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    if (flight.dirty) {
      flight.dirty = false;
      flight.phase = 'trailing';
      return runComposioMcpReconciliation(userId, flight.latest);
    }
    if (leadingError !== undefined) throw leadingError;
    return result as ComposioMcpWireResult;
  })();
  composioWireByUser.set(userId, flight);
  try {
    return await flight.promise;
  } finally {
    if (composioWireByUser.get(userId) === flight) composioWireByUser.delete(userId);
  }
}

async function runComposioMcpReconciliation(
  userId: string,
  request: ComposioWireRequest,
): Promise<ComposioMcpWireResult> {
  const attempt = await tryWithUserGatewayConfigReconciliationLock(userId, async (lifecycleClient) => {
    // Callers commonly fetched credentials before waiting for this lock. A gateway migration or
    // manual repoint can complete while they wait, so the lifecycle-session read is authoritative.
    const lockedTarget = await getGatewayCredentialsWithClient(lifecycleClient, userId);
    const localGatewayUrl = env.LOCAL_GATEWAY_URL?.trim();
    const target = lockedTarget ?? (localGatewayUrl && request.gatewayUrl.trim() === localGatewayUrl
      ? getLocalGatewayCredentials() ?? undefined
      : undefined);
    if (!target) return { wired: false, reason: 'no_gateway' as const };
    const targetChanged = target.gateway_url !== request.gatewayUrl || target.gateway_token !== request.gatewayToken;
    if (targetChanged) {
      console.warn(`[composio] gateway target changed while reconciliation waited for user ${userId}; using locked target`);
    }
    // URL/token equality does not prove the managed Machine metadata stayed unchanged while this
    // caller waited. Always take setup auth from the same locked snapshot; local targets never
    // consult Fly metadata.
    const authoritativeSetupPassword = target.hosting_provider === 'local'
      ? undefined
      : await getSetupPasswordWithClient(lifecycleClient, userId).catch(() => undefined);
    return ensureComposioMcpWiredWithRetry(
      userId,
      target.gateway_url,
      target.gateway_token,
      authoritativeSetupPassword,
      request.opts,
    );
  });
  return attempt.acquired ? attempt.value : { wired: false, reason: 'busy' };
}

async function ensureComposioMcpWiredWithRetry(
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
  opts?: { force?: boolean },
): Promise<ComposioMcpWireResult> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= MAX_WIRE_ATTEMPTS; attempt++) {
    try {
      return await attemptEnsureComposioMcpWired(userId, gatewayUrl, gatewayToken, setupPassword, opts);
    } catch (err) {
      lastError = err;
      const message = err instanceof Error ? err.message : String(err);
      if (err instanceof ComposioMcpOwnershipConflictError) {
        console.error(`[composio] mcp ownership conflict for user ${userId}: ${message}`);
        throw err;
      }
      if (attempt < MAX_WIRE_ATTEMPTS) {
        console.warn(
          `[composio] mcp wiring attempt ${attempt}/${MAX_WIRE_ATTEMPTS} failed for user ${userId} (${message}) — retrying in ${WIRE_RETRY_DELAY_MS}ms`,
        );
        await new Promise((resolve) => setTimeout(resolve, WIRE_RETRY_DELAY_MS));
      }
    }
  }
  const finalMessage = lastError instanceof Error ? lastError.message : String(lastError);
  console.error(`[composio] mcp NOT wired for user ${userId} after ${MAX_WIRE_ATTEMPTS} attempts: ${finalMessage}`);
  throw lastError;
}

/** One wiring attempt — see `ensureComposioMcpWired` for the retry wrapper around this. */
async function attemptEnsureComposioMcpWired(
  userId: string,
  gatewayUrl: string,
  gatewayToken: string,
  setupPassword?: string,
  opts?: { force?: boolean },
): Promise<ComposioMcpWireResult> {
  const composio = client();
  const accounts = await listAllConnectedAccountsForStatus(composio, userId);
  const accountScopeMarker = buildComposioScopeMarker(accounts);
  const hasRetainedGrant = accounts.some(account => {
    const status = String(account.status ?? '').trim().toUpperCase();
    return status === 'ACTIVE' || status === 'INACTIVE';
  });
  return withGatewayRequester(
    gatewayUrl,
    gatewayToken,
    async (request) => {
      const snapshot = await request('config.get', {});
      if (!snapshot.ok) {
        throw new Error(`config.get failed: ${snapshot.error?.message ?? 'unknown error'}`);
      }
      const payload = snapshot.result as {
        hash?: unknown;
        config?: { mcp?: { servers?: Record<string, unknown> } };
      } | undefined;
      const hash = typeof payload?.hash === 'string' ? payload.hash : '';
      if (!hash) throw new Error('config.get returned no base hash');
      const rawServer = payload?.config?.mcp?.servers?.composio;
      const composioServer = rawServer && typeof rawServer === 'object' && !Array.isArray(rawServer)
        ? rawServer as Record<string, unknown>
        : undefined;
      if (composioServer && !isRemOwnedComposioServer(composioServer)) {
        throw new ComposioMcpOwnershipConflictError();
      }

      const alreadyWired = opts?.force
        ? false
        : hasRetainedGrant
          ? Boolean(composioServer)
            && composioServer?.[COMPOSIO_SCOPE_CONFIG_KEY] === accountScopeMarker
            && !hasStaleComposioTopLevelKeys(composioServer)
            && !hasLegacyComposioHeaders(composioServer)
          : !composioServer;
      if (alreadyWired) {
        console.log(`[composio] mcp already reconciled for user ${userId} (account scope current)`);
        return { wired: true, reason: 'already_wired' };
      }

      if (!opts?.force) {
        console.log(`[composio] mcp scope stale for user ${userId}; refreshing session and runtime cache`);
      } else {
        console.log(`[composio] mcp force re-wire for user ${userId}: minting a fresh session regardless of existing config`);
      }

      let patch: Record<string, unknown>;
      let mcpConfig: ComposioMcpConfig | null = null;
      if (!hasRetainedGrant) {
        patch = { mcp: { servers: { composio: null } } };
      } else {
        mcpConfig = await getMcpConfig(userId);
        if (!mcpConfig) {
          console.warn(`[composio] mcp NOT wired for user ${userId}: no_mcp_session (Composio returned no usable mcp endpoint)`);
          return { wired: false, reason: 'no_mcp_session' };
        }

        // Account OAuth state can change while Composio mints the hosted session. Never publish a
        // marker for a snapshot that is no longer current; the retry takes a fresh lock/snapshot.
        patch = buildComposioMcpConfigPatch(mcpConfig, accountScopeMarker, composioServer);
      }

      // Recheck before both replacement and deletion. A final account can reconnect while a
      // config read is in flight; publishing either stale direction would otherwise win last.
      const latestAccountScopeMarker = buildComposioScopeMarker(
        await listAllConnectedAccountsForStatus(composio, userId),
      );
      if (latestAccountScopeMarker !== accountScopeMarker) {
        throw new Error('Composio account scope changed while refreshing the MCP session');
      }

      const patched = await request('config.patch', {
        raw: JSON.stringify(patch),
        baseHash: hash,
        note: 'RemClaw: reconcile Composio MCP runtime',
      });
      if (!patched.ok) {
        throw new Error(`config.patch failed: ${patched.error?.message ?? 'unknown error'}`);
      }

      if (!hasRetainedGrant) {
        console.log(`[composio] mcp removed for user ${userId} (no retained connected accounts)`);
      } else if (mcpConfig) {
        const host = safeUrlHost(mcpConfig.url);
        console.log(`[composio] mcp wired for user ${userId} -> mcp.servers.composio (${mcpConfig.transport}, host=${host})`);
      }
      return { wired: true };
    },
    setupPassword,
  );
}

function safeUrlHost(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return 'unparseable-url';
  }
}
