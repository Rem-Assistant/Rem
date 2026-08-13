import crypto from 'node:crypto';
import { buildGatewayConfigPatch, DEFAULT_TALK_PROVIDER_ID } from '../config/gateway-defaults.js';
import { env } from '../config/env.js';
import { getHostedGatewayProvisioning } from './gateway/hosted-provisioning.js';
import { assertManagedGatewayOwnership } from './gateway-environment-ownership.service.js';
import {
  tryWithUserGatewayLifecycleMutationLock,
  withUserGatewayLifecycleLock,
  type GatewayLifecycleDatabaseClient,
} from './gateway-lifecycle-lock.service.js';
import {
  patchGatewayConfig,
  patchGatewayConfigHttp,
  withGatewayRequester,
} from './gateway-pair.service.js';
import * as gatewayService from './gateway.service.js';
import { getEntitlementProvider } from './entitlement/entitlement-provider.js';

export type ManagedTalkConfigurationOutcome =
  | 'already_configured'
  | 'repaired'
  | 'subscription_required'
  | 'user_credentials_required';

export interface ManagedTalkInitialInstall {
  talk: Record<string, unknown>;
  credentialFingerprint: string;
  credentialGeneration: number;
}

export function managedTalkCredentialGeneration(): number {
  const raw = process.env.ELEVENLABS_API_KEY_GENERATION?.trim() || '1';
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new Error('ELEVENLABS_API_KEY_GENERATION must be a positive integer');
  }
  return parsed;
}

/**
 * Phase-two rollout gate for mutations that legacy replicas can undo.
 *
 * The pre-fence wake writer treats a missing managed key as damage and restores its environment
 * key without reading entitlement or generation state. Revocation and rotation therefore stay
 * pending until operators have drained every legacy writer. This must be an explicit opt-in: an
 * absent or misspelled value fails closed.
 */
export function managedTalkFencedWriterRolloutComplete(): boolean {
  return process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE?.trim().toLowerCase() === 'true';
}

/**
 * Returns the only Talk branch a fresh managed gateway may receive. Free/inactive accounts and
 * backends without a managed provider key get no Talk patch at all, so the organization credential
 * cannot exist on the gateway before the post-save ownership reconciliation runs.
 */
export function managedTalkInitialInstallForEntitlement(
  entitlementIsActive: boolean,
): ManagedTalkInitialInstall | null {
  const managedKey = process.env.ELEVENLABS_API_KEY?.trim();
  if (!entitlementIsActive || !managedKey) return null;
  const talk = (buildGatewayConfigPatch({ includeTalkDefaults: true }) as {
    talk?: Record<string, unknown>;
  }).talk;
  if (!talk) return null;
  return {
    talk,
    credentialFingerprint: talkCredentialFingerprint(managedKey),
    credentialGeneration: managedTalkCredentialGeneration(),
  };
}

export async function authorizeManagedTalkInitialInstallWithClient(
  userId: string,
  lifecycleClient: GatewayLifecycleDatabaseClient,
  entitlementIsActive: boolean,
): Promise<ManagedTalkInitialInstall | null> {
  const install = managedTalkInitialInstallForEntitlement(entitlementIsActive);
  if (!install) return null;
  const desired = await gatewayService.promoteManagedTalkDesiredCredentialWithClient(
    lifecycleClient,
    userId,
    install.credentialFingerprint,
    install.credentialGeneration,
  );
  if (
    desired.generation !== install.credentialGeneration
      || desired.fingerprint !== install.credentialFingerprint
  ) {
    throw new Error('backend replica is not authoritative for the managed Talk initial credential');
  }
  return install;
}

interface ManagedTalkTarget {
  gatewayUrl: string;
  gatewayToken: string;
  setupPassword: string | undefined;
  managedCredentialFingerprint: string | null;
  desiredCredentialFingerprint: string | null;
  desiredCredentialGeneration: number;
}

export async function inspectManagedTalkTarget(
  userId: string,
  lifecycleClient: GatewayLifecycleDatabaseClient,
): Promise<ManagedTalkTarget | ManagedTalkConfigurationOutcome> {
  const creds = await gatewayService.getManagedTalkTargetWithClient(lifecycleClient, userId);
  if (!creds || creds.hosting_provider !== 'fly') return 'user_credentials_required';
  const appName = creds.fly_app_name?.trim();
  const machineId = creds.fly_machine_id?.trim();
  if (!appName || !machineId) {
    throw new Error('managed gateway ownership metadata is incomplete');
  }
  let targetUrl: URL;
  try {
    targetUrl = new URL(creds.gateway_url);
  } catch {
    throw new Error('managed gateway URL is invalid');
  }
  const expectedHost = `${appName.toLowerCase()}.fly.dev`;
  if (targetUrl.protocol !== 'https:' || targetUrl.hostname.toLowerCase() !== expectedHost || targetUrl.port) {
    throw new Error('managed gateway URL does not match the owned Fly app');
  }
  const machine = await getHostedGatewayProvisioning().getMachine(appName, machineId);
  assertManagedGatewayOwnership(machine.config?.env, {
    userId,
    backendUrl: env.BACKEND_PUBLIC_URL,
  });
  return {
    gatewayUrl: creds.gateway_url,
    gatewayToken: creds.gateway_token,
    setupPassword: machine.config?.env?.SETUP_PASSWORD,
    managedCredentialFingerprint: creds.managed_talk_credential_fingerprint,
    desiredCredentialFingerprint: creds.managed_talk_desired_credential_fingerprint ?? null,
    desiredCredentialGeneration: Number(creds.managed_talk_credential_generation ?? 0),
  };
}

function talkCredentialFingerprint(value: string): string {
  return crypto.createHash('sha256').update(value).digest('hex');
}

interface TalkCredentialSnapshot {
  managedProviderKey: string | null;
  hasManagedProviderCredential: boolean;
  hasConfiguredProviderKey: boolean;
  hasAlternateProviderSelection: boolean;
  hasManagedProviderSelection: boolean;
  hasManagedProviderConfiguration: boolean;
}

async function readTalkCredentialSnapshot(inspected: ManagedTalkTarget): Promise<TalkCredentialSnapshot> {
  return withGatewayRequester(
    inspected.gatewayUrl,
    inspected.gatewayToken,
    async (request) => {
      const response = await request('talk.config', { includeSecrets: true });
      if (!response.ok) {
        throw new Error(`talk.config failed: ${response.error?.message ?? 'unknown error'}`);
      }
      const talk = response.result?.config?.talk;
      const provider = typeof talk?.provider === 'string' ? talk.provider.trim().toLowerCase() : '';
      const activeApiKey = provider ? talk?.providers?.[provider]?.apiKey : undefined;
      const managedProvider = talk?.providers?.[DEFAULT_TALK_PROVIDER_ID];
      const managedApiKey = managedProvider?.apiKey;
      return {
        managedProviderKey: typeof managedApiKey === 'string' && managedApiKey.trim()
          ? managedApiKey.trim()
          : null,
        hasManagedProviderCredential: Boolean(
          (typeof managedApiKey === 'string' && managedApiKey.trim())
            || (typeof managedApiKey === 'object' && managedApiKey !== null && !Array.isArray(managedApiKey)),
        ),
        hasConfiguredProviderKey: Boolean(
          (typeof activeApiKey === 'string' && activeApiKey.trim())
            || (typeof activeApiKey === 'object' && activeApiKey !== null && !Array.isArray(activeApiKey)),
        ),
        hasAlternateProviderSelection: Boolean(
          provider && provider !== DEFAULT_TALK_PROVIDER_ID,
        ),
        hasManagedProviderSelection: provider === DEFAULT_TALK_PROVIDER_ID,
        hasManagedProviderConfiguration: Boolean(
          typeof managedProvider === 'object'
            && managedProvider !== null
            && !Array.isArray(managedProvider)
            && Object.keys(managedProvider).length > 0,
        ),
      };
    },
    inspected.setupPassword,
  );
}

async function applyManagedTalkPatch(
  inspected: ManagedTalkTarget,
  talk: Record<string, unknown>,
  requireActivated: boolean,
): Promise<void> {
  if (requireActivated) {
    await patchGatewayConfigHttp(
      inspected.gatewayUrl,
      inspected.gatewayToken,
      { talk },
      inspected.setupPassword,
      { requireActivated: true, timeoutMs: 120_000 },
    );
    return;
  }
  await patchGatewayConfig(
    inspected.gatewayUrl,
    inspected.gatewayToken,
    { talk },
    inspected.setupPassword,
  );
}

export async function reconcileManagedTalkConfigurationWithClient(
  userId: string,
  lifecycleClient: GatewayLifecycleDatabaseClient,
  options?: { requireActivated?: boolean },
): Promise<ManagedTalkConfigurationOutcome> {
  const inspected = await inspectManagedTalkTarget(userId, lifecycleClient);
  if (typeof inspected === 'string') return inspected;

  const [entitlement, credentialSnapshot] = await Promise.all([
    getEntitlementProvider().getCanonicalEntitlement(lifecycleClient, userId),
    readTalkCredentialSnapshot(inspected),
  ]);
  const configuredKey = credentialSnapshot.managedProviderKey;
  const managedKey = process.env.ELEVENLABS_API_KEY?.trim() || null;
  const configuredFingerprint = configuredKey ? talkCredentialFingerprint(configuredKey) : null;
  const currentManagedFingerprint = managedKey ? talkCredentialFingerprint(managedKey) : null;
  const isTrackedManagedKey = Boolean(
    configuredFingerprint
      && inspected.managedCredentialFingerprint
      && configuredFingerprint === inspected.managedCredentialFingerprint,
  );
  const isLegacyManagedKey = Boolean(configuredKey && managedKey && configuredKey === managedKey);

  if (!entitlement.isActive) {
    if (isTrackedManagedKey || isLegacyManagedKey) {
      if (!managedTalkFencedWriterRolloutComplete()) {
        // Keep both the key and pending bit intact during phase one. Removing the key while a
        // draining legacy wake writer exists would make that writer restore its own environment
        // key and full Talk defaults outside the durable lifecycle fence.
        return 'subscription_required';
      }
      await applyManagedTalkPatch(
        inspected,
        { providers: { [DEFAULT_TALK_PROVIDER_ID]: { apiKey: null } } },
        options?.requireActivated === true,
      );
      await gatewayService.setManagedTalkCredentialFingerprintWithClient(lifecycleClient, userId, null);
    } else if (inspected.managedCredentialFingerprint) {
      await gatewayService.setManagedTalkCredentialFingerprintWithClient(lifecycleClient, userId, null);
    }
    await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
    return (
      credentialSnapshot.hasManagedProviderCredential
        || credentialSnapshot.hasConfiguredProviderKey
        || credentialSnapshot.hasAlternateProviderSelection
    )
      && !isTrackedManagedKey && !isLegacyManagedKey
      ? 'user_credentials_required'
      : 'subscription_required';
  }

  if (!managedKey || !currentManagedFingerprint) return 'user_credentials_required';

  const localGeneration = managedTalkCredentialGeneration();
  const desired = await gatewayService.promoteManagedTalkDesiredCredentialWithClient(
    lifecycleClient,
    userId,
    currentManagedFingerprint,
    localGeneration,
  );
  if (desired.generation === localGeneration && desired.fingerprint !== currentManagedFingerprint) {
    throw new Error('managed Talk key generation conflicts with the durable desired fingerprint');
  }
  const localReplicaIsAuthoritative = desired.generation === localGeneration
    && desired.fingerprint === currentManagedFingerprint;

  if (!localReplicaIsAuthoritative) {
    // A draining replica may observe a newer desired generation that it cannot materialize. It may
    // acknowledge an already-converged gateway, but it must never write its older environment key.
    if (
      configuredFingerprint
        && configuredFingerprint === desired.fingerprint
        && configuredFingerprint === inspected.managedCredentialFingerprint
    ) {
      await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
      return 'already_configured';
    }
    throw new Error('backend replica has an older managed Talk key generation');
  }

  if (isTrackedManagedKey) {
    if (configuredFingerprint === currentManagedFingerprint) {
      await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
      return 'already_configured';
    }
    if (!managedTalkFencedWriterRolloutComplete()) {
      throw new Error('managed Talk credential rotation is waiting for the fenced-writer rollout');
    }
    await applyManagedTalkPatch(
      inspected,
      { providers: { [DEFAULT_TALK_PROVIDER_ID]: { apiKey: managedKey } } },
      options?.requireActivated === true,
    );
    await gatewayService.setManagedTalkCredentialFingerprintWithClient(
      lifecycleClient,
      userId,
      currentManagedFingerprint,
    );
    await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
    return 'repaired';
  }

  if (isLegacyManagedKey && localReplicaIsAuthoritative) {
    await gatewayService.setManagedTalkCredentialFingerprintWithClient(
      lifecycleClient,
      userId,
      currentManagedFingerprint,
    );
    await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
    return 'already_configured';
  }

  if (
    configuredKey
      || credentialSnapshot.hasManagedProviderCredential
      || credentialSnapshot.hasConfiguredProviderKey
      || credentialSnapshot.hasAlternateProviderSelection
  ) {
    if (inspected.managedCredentialFingerprint) {
      await gatewayService.setManagedTalkCredentialFingerprintWithClient(lifecycleClient, userId, null);
    }
    await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
    return 'user_credentials_required';
  }

  // A missing Rem credential does not transfer ownership of an existing ElevenLabs branch.
  // Preserve its provider/voice/model/output selections and add only the key Rem owns. The full
  // managed default is appropriate only when no canonical managed selection exists at all.
  if (
    credentialSnapshot.hasManagedProviderSelection
      || credentialSnapshot.hasManagedProviderConfiguration
  ) {
    if (localGeneration > 1 && !managedTalkFencedWriterRolloutComplete()) {
      throw new Error('managed Talk credential installation is waiting for the fenced-writer rollout');
    }
    await applyManagedTalkPatch(
      inspected,
      { providers: { [DEFAULT_TALK_PROVIDER_ID]: { apiKey: managedKey } } },
      options?.requireActivated === true,
    );
    await gatewayService.setManagedTalkCredentialFingerprintWithClient(
      lifecycleClient,
      userId,
      currentManagedFingerprint,
    );
    await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
    return 'repaired';
  }

  const talk = (buildGatewayConfigPatch() as { talk?: Record<string, unknown> }).talk;
  if (!talk) return 'user_credentials_required';
  if (localGeneration > 1 && !managedTalkFencedWriterRolloutComplete()) {
    throw new Error('managed Talk credential installation is waiting for the fenced-writer rollout');
  }
  await applyManagedTalkPatch(inspected, talk, options?.requireActivated === true);
  await gatewayService.setManagedTalkCredentialFingerprintWithClient(
    lifecycleClient,
    userId,
    currentManagedFingerprint,
  );
  await gatewayService.markManagedTalkReconciledWithClient(lifecycleClient, userId);
  return 'repaired';
}

export async function ensureManagedTalkConfigured(
  userId: string,
  options?: { requireActivated?: boolean },
): Promise<ManagedTalkConfigurationOutcome> {
  return withUserGatewayLifecycleLock(userId, (lifecycleClient) =>
    reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient, options));
}

export async function tryEnsureManagedTalkConfigured(
  userId: string,
  options?: { requireActivated?: boolean },
) {
  return tryWithUserGatewayLifecycleMutationLock(userId, (lifecycleClient) =>
    reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient, options));
}
