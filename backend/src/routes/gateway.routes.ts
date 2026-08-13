import fs from 'node:fs';
import path from 'node:path';
import { Router, Request, Response } from 'express';
import { env } from '../config/env.js';
import { buildManagedGatewayReconfigurePatch } from '../config/gateway-defaults.js';
import { requireJwt } from '../middleware/auth.js';
import * as gatewayService from '../services/gateway.service.js';
import {
  autoApproveDevices,
  autoApproveDevicesHttp,
  patchGatewayConfigHttp,
  listWorkspaceFilesHttp,
  readWorkspaceFileHttp,
  WorkspaceEndpointsUnavailableError,
  ApprovalCheckTimeoutError,
  ApprovalRetryFailedError,
  NoPendingPairingRequestError,
} from '../services/gateway-pair.service.js';
import { ensureComposioMcpWired, isComposioConfigured } from '../services/composio.service.js';
import {
  reconcileUserTimezoneAfterGatewaySave,
  syncUserTimezoneToGateway,
} from '../services/gateway-user-context.service.js';
import {
  tryWithUserGatewayLifecycleMutationLock,
  withUserGatewayLifecycleLock,
} from '../services/gateway-lifecycle-lock.service.js';
import {
  ensureManagedTalkConfigured,
  inspectManagedTalkTarget,
  tryEnsureManagedTalkConfigured,
} from '../services/managed-talk-configuration.service.js';

const router = Router();

/** Only rewrites loopback (localhost/127.0.0.1) so devices can reach a local gateway. Prod URLs (Fly, Railway, etc.) are returned unchanged. */
function gatewayUrlForRequest(gatewayUrl: string, requestHost: string | undefined): string {
  if (!requestHost) return gatewayUrl;
  try {
    const u = new URL(gatewayUrl);
    const isLoopback = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
    if (!isLoopback) return gatewayUrl; // prod: fly.dev, railway.app, etc.
    const requestHostname = requestHost.split(':')[0];
    u.hostname = requestHostname;
    return u.toString();
  } catch {
    return gatewayUrl;
  }
}

/** Read token: gateway.token (what wrapper passes via --token) first, then openclaw.json, then env. */
function readLocalGatewayToken(): string | null {
  const stateDir = env.LOCAL_GATEWAY_STATE_DIR;
  try {
    const tokenPath = path.join(stateDir, 'gateway.token');
    const content = fs.readFileSync(tokenPath, 'utf8').trim();
    if (content) return content;
  } catch {}
  try {
    const configPath = path.join(stateDir, 'openclaw.json');
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const token = config?.gateway?.auth?.token?.trim();
    if (token) return token;
  } catch {}
  return env.LOCAL_GATEWAY_TOKEN || null;
}

function isControlUiDeviceIdentityFailure(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  const lastError = error instanceof ApprovalRetryFailedError ? error.lastError : undefined;
  return `${message} ${lastError ?? ''}`.toLowerCase().includes('control ui requires device identity');
}

async function getCredentialsWithLocalFallback(userId: string) {
  let creds = await gatewayService.getGatewayCredentials(userId);
  if (!creds && env.LOCAL_GATEWAY_URL) {
    const token = readLocalGatewayToken();
    if (token) {
      creds = {
        gateway_url: env.LOCAL_GATEWAY_URL,
        gateway_token: token,
        hosting_provider: 'local',
      };
    }
  }
  return creds;
}

router.get('/me', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  const me = await gatewayService.getMe(userId);
  if (!me) {
    return res.status(404).json({ error: 'User not found' });
  }
  res.json(me);
});

router.patch('/me/gateway', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  const { gatewayUrl, gatewayToken } = req.body ?? {};
  if (!gatewayUrl || typeof gatewayUrl !== 'string' || !gatewayToken || typeof gatewayToken !== 'string') {
    return res.status(400).json({ error: 'gatewayUrl and gatewayToken required' });
  }
  const hostingProvider = (req.body?.hostingProvider ?? 'railway').toString().trim() || 'railway';
  try {
    const gateway = await withUserGatewayLifecycleLock(userId, (lifecycleClient) =>
      gatewayService.setUserEnteredGatewayForUserWithClient(
        lifecycleClient,
        userId,
        gatewayUrl,
        gatewayToken,
        hostingProvider,
      ),
    );
    void reconcileUserTimezoneAfterGatewaySave(userId).catch((error) => {
      // Credentials are already durable. Manual gateways may be offline or reject the backend's
      // unpaired operator; never turn that best-effort repair into an apparent save failure. The
      // paired client session performs the durable retry when it connects.
      console.error(`[users] post-save gateway timezone sync failed for user ${userId}:`, error);
    });
    return res.json({ gateway });
  } catch (e) {
    return res.status(500).json({ error: 'Failed to save gateway config' });
  }
});

router.get('/me/credentials', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  const creds = await getCredentialsWithLocalFallback(userId);
  if (!creds) {
    console.log('[gateway] GET /me/credentials userId=%s → 404 no gateway', userId);
    return res.status(404).json({ error: 'No gateway configured' });
  }
  const gatewayUrl = gatewayUrlForRequest(creds.gateway_url, req.get('Host'));
  const source = env.LOCAL_GATEWAY_URL ? 'local' : 'db';
  console.log('[gateway] GET /me/credentials userId=%s → 200 gatewayUrl=%s (source=%s)', userId, gatewayUrl, source);
  res.json({
    gatewayUrl,
    gatewayToken: creds.gateway_token,
    hostingProvider: creds.hosting_provider,
  });
});

/**
 * Best-effort, fire-and-forget: sync backend-owned agent context and Composio MCP wiring whenever the app wakes the
 * gateway (every cold launch, RemClawApp.swift `wakeGatewayIfNeeded()`). This is the RELIABLE
 * trigger for #1087 — it does not depend on the app hitting any Composio-specific route (which,
 * per the live-test finding, isn't guaranteed to happen: a toolkit connected before this code
 * shipped, or a client-cached toolkits response, means composio.routes.ts's own triggers never
 * fire again for that user). Runs only once the gateway actually reports ready — attempting the
 * operator WS handshake against a still-sleeping machine would just eat the connect timeout for
 * no reason. Never blocks or fails the wake response.
 */
function syncGatewayDerivedConfigOnWake(userId: string, gatewayReady: boolean): void {
  if (!gatewayReady) return;
  void (async () => {
    // Do this first: both operations use config.get -> config.patch base hashes, so serializing
    // avoids racing two valid patches against the same stale hash.
    try {
      await syncUserTimezoneToGateway(userId);
    } catch (err) {
      console.error(`[users] gateway timezone sync failed on wake for user ${userId}:`, err);
    }

    // Existing managed gateways predate the canonical nested Talk config. Repair only when the
    // active provider/key is absent; avoiding a no-op config.patch also avoids restarting a
    // healthy gateway on every app wake.
    try {
      const outcome = await ensureManagedTalkConfigured(userId);
      console.log(`[talk] managed config sync on gateway wake user=${userId} outcome=${outcome}`);
    } catch (err) {
      console.error(`[talk] managed config sync failed on gateway wake for user ${userId}:`, err);
    }

    if (!isComposioConfigured()) return;
    try {
      const creds = await getCredentialsWithLocalFallback(userId);
      if (!creds) return;
      const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);
      await ensureComposioMcpWired(userId, creds.gateway_url, creds.gateway_token, setupPassword);
    } catch (err) {
      console.error(`[composio] mcp wiring failed on gateway wake for user ${userId}:`, err);
    }
  })();
}

router.post('/gateway/wake', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    const result = await gatewayService.wakeGatewayForUser(userId);
    console.log(
      '[gateway] POST /gateway/wake userId=%s provider=%s action=%s state=%s ready=%s',
      userId,
      result.provider,
      result.action,
      result.machineState,
      result.gatewayReady,
    );
    syncGatewayDerivedConfigOnWake(userId, result.gatewayReady);
    return res.json(result);
  } catch (e: any) {
    console.error(`[gateway] wake error: ${e.message}`);
    return res.status(500).json({ error: e.message || 'Failed to wake gateway' });
  }
});

/**
 * Reconciles canonical Talk provider configuration without returning provider credentials.
 * Managed Fly gateways receive the backend-owned provider reference only for an active
 * entitlement. Self-managed gateways and accounts without managed Voice are routed back to
 * gateway-owned credential setup instead of pretending a device-local key can repair Talk.
 */
router.post('/gateway/voice/reconcile', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    // Validate the stored target before wake performs any network request, then validate it again
    // under the fail-fast mutation lock. The second check closes the
    // repoint/delete race between wake and config mutation.
    const inspection = await tryWithUserGatewayLifecycleMutationLock(userId, (lifecycleClient) =>
      inspectManagedTalkTarget(userId, lifecycleClient));
    if (!inspection.acquired) {
      return res.status(409).json({ error: 'Gateway lifecycle work is already in progress. Try again shortly.' });
    }
    if (typeof inspection.value === 'string') return res.json({ outcome: inspection.value });
    const wake = await gatewayService.wakeGatewayForUser(userId);
    if (!wake.gatewayReady) {
      return res.status(503).json({ error: 'Gateway is still waking. Try again shortly.' });
    }
    const reconciliation = await tryEnsureManagedTalkConfigured(userId, { requireActivated: true });
    if (!reconciliation.acquired) {
      return res.status(409).json({ error: 'Gateway lifecycle work is already in progress. Try again shortly.' });
    }
    return res.json({ outcome: reconciliation.value });
  } catch (error) {
    console.error(`[talk] interactive managed config repair failed user=${userId}:`, error);
    return res.status(500).json({ error: 'Voice configuration repair failed' });
  }
});

router.get('/gateway/update-readiness', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    const readiness = await gatewayService.getGatewayUpdateReadinessForUser(userId);
    return res.json({ readiness });
  } catch (e: any) {
    console.error(`[gateway] update-readiness error: ${e.message}`);
    return res.status(500).json({ error: e.message || 'Failed to check gateway update readiness' });
  }
});

router.post('/approve-device', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    const creds = await getCredentialsWithLocalFallback(userId);
    if (!creds) {
      return res.status(400).json({
        ok: false,
        status: 'no_gateway_configured',
        approved: 0,
        error: 'No gateway configured for this user',
        message: 'No gateway is configured for this account.',
      });
    }

    // Read setup password from Fly machine env so we can connect as control-ui
    const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);

    // Use HTTP endpoint (bypasses WebSocket secure-context), falls back to WebSocket
    console.log(`[gateway] approve-device: starting for user ${userId}, gateway ${creds.gateway_url}, hasSetupPw=${!!setupPassword}`);
    let approved: number;
    try {
      approved = await autoApproveDevicesHttp(creds.gateway_url, creds.gateway_token, setupPassword, 30_000, 3_000);
    } catch (approvalError) {
      if (!setupPassword || !isControlUiDeviceIdentityFailure(approvalError)) {
        throw approvalError;
      }

      console.warn('[gateway] approve-device: patching stale control UI config before retrying approval for user %s', userId);
      // Approval repair owns only the control-UI posture. Talk provider, credential, and voice/model
      // selections are independently owned and must never ride along with this broad repair.
      await patchGatewayConfigHttp(
        creds.gateway_url,
        creds.gateway_token,
        buildManagedGatewayReconfigurePatch(),
        setupPassword,
      );
      approved = await autoApproveDevicesHttp(creds.gateway_url, creds.gateway_token, setupPassword, 30_000, 3_000);
    }

    return res.json({
      ok: true,
      status: 'approved',
      approved,
      message: `Auto-approved ${approved} pending device(s)`,
    });
  } catch (e: any) {
    if (e instanceof NoPendingPairingRequestError) {
      return res.status(409).json({
        ok: false,
        status: 'no_pending_device',
        approved: e.approved,
        error: e.message,
        message: 'No pending device approval request was found on the gateway',
      });
    }
    if (e instanceof ApprovalCheckTimeoutError) {
      return res.status(504).json({
        ok: false,
        status: 'approval_still_pending',
        approved: 0,
        error: e.message,
        message: 'Rem could not confirm pending device approvals before the check timed out.',
        lastError: e.lastError,
      });
    }
    if (e instanceof ApprovalRetryFailedError) {
      return res.status(502).json({
        ok: false,
        status: 'approval_retry_failed',
        approved: 0,
        error: e.message,
        message: 'Rem could not retry gateway approval. Check gateway setup, then try again.',
        lastError: e.lastError,
      });
    }
    console.error(`[gateway] approve-device error: ${e.message}`);
    return res.status(500).json({
      ok: false,
      status: 'approval_retry_failed',
      approved: 0,
      error: e.message || 'Failed to approve device',
      message: 'Rem could not retry gateway approval.',
    });
  }
});

router.post('/patch-config', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    const creds = await getCredentialsWithLocalFallback(userId);
    if (!creds) {
      return res.status(400).json({ error: 'No gateway configured for this user' });
    }
    const configPatch = req.body?.config;
    if (!configPatch || typeof configPatch !== 'object') {
      return res.status(400).json({ error: 'config object required in body' });
    }
    const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);
    const result = await patchGatewayConfigHttp(
      creds.gateway_url,
      creds.gateway_token,
      configPatch,
      setupPassword,
      { requireActivated: true, timeoutMs: 120_000 },
    );
    return res.json({ ok: true, activated: result.activated });
  } catch (e: any) {
    console.error(`[gateway] patch-config error: ${e.message}`);
    return res.status(500).json({ error: e.message || 'Failed to patch config' });
  }
});

// ─── Read-only workspace/memory files ───────────────────────────────────────
//
// Surfaces the agent's identity/memory workspace (IDENTITY.md / USER.md /
// MEMORY.md / memory/*.md on the gateway's /data/workspace) so the app's
// Settings → Memory screen can show the real files the runtime uses to
// understand the user. These live on the persistent Fly volume and survive
// image patching (the managed deploy pipeline reconfigures rather than re-onboards).
//
// Reading requires the setup password (the wrapper's workspace endpoints use
// Basic auth). If it's unavailable (e.g. local gateway), we return 200 with an
// empty list + `available:false` so the app can show a graceful empty state
// rather than an error.

router.get('/gateway/workspace/files', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  try {
    const creds = await getCredentialsWithLocalFallback(userId);
    if (!creds) {
      return res.status(400).json({ error: 'No gateway configured for this user' });
    }
    const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);
    if (!setupPassword) {
      return res.json({ available: false, files: [] });
    }
    const files = await listWorkspaceFilesHttp(creds.gateway_url, setupPassword);
    return res.json({ available: true, files });
  } catch (e: any) {
    if (e instanceof WorkspaceEndpointsUnavailableError) {
      // Stale wrapper image (predates /setup/api/workspace/*): not an error the
      // user can act on from the app — show the graceful "not available yet"
      // state and let ops roll the gateway image (deploy runbook §4).
      console.warn(`[gateway] workspace/files unavailable (stale wrapper): ${e.message}`);
      return res.json({ available: false, files: [], reason: 'gateway-update-required' });
    }
    console.error(`[gateway] workspace/files error: ${e.message}`);
    return res.status(502).json({ error: 'Couldn’t reach your gateway to load memory files. Try again in a moment.' });
  }
});

router.get('/gateway/workspace/file', requireJwt, async (req: Request, res: Response) => {
  const userId = (req as Request & { userId: string }).userId;
  const relPath = typeof req.query.path === 'string' ? req.query.path : '';
  if (!relPath) {
    return res.status(400).json({ error: 'path query parameter required' });
  }
  try {
    const creds = await getCredentialsWithLocalFallback(userId);
    if (!creds) {
      return res.status(400).json({ error: 'No gateway configured for this user' });
    }
    const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);
    if (!setupPassword) {
      return res.status(404).json({ error: 'Workspace file access unavailable for this gateway' });
    }
    const file = await readWorkspaceFileHttp(creds.gateway_url, setupPassword, relPath);
    return res.json(file);
  } catch (e: any) {
    if (e instanceof WorkspaceEndpointsUnavailableError) {
      console.warn(`[gateway] workspace/file unavailable (stale wrapper): ${e.message}`);
      return res.status(503).json({ error: 'Your gateway needs an update before memory files can be read.' });
    }
    console.error(`[gateway] workspace/file error: ${e.message}`);
    return res.status(502).json({ error: 'Couldn’t reach your gateway to read this file. Try again in a moment.' });
  }
});

export default router;
