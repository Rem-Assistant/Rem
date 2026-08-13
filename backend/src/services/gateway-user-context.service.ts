import * as gatewayService from './gateway.service.js';
import { patchGatewayConfig } from './gateway-pair.service.js';
import { resolveStoredUserTimezone } from './brief-authoring.service.js';

/**
 * OpenClaw's native `chat.send` path keeps the transcript body raw and adds the current timestamp
 * only to `BodyForAgent` (openclaw/src/gateway/server-methods/agent-timestamp.ts). The timestamp is
 * resolved from `agents.defaults.userTimezone`, so Rem mirrors the device timezone stored in
 * `users.timezone` into that upstream-owned setting instead of prepending hidden text to messages.
 */
export function buildUserTimezoneConfigPatch(timezone: string): Record<string, unknown> {
  return {
    agents: {
      defaults: {
        userTimezone: timezone,
      },
    },
  };
}

/**
 * Reconciles backend-owned user timezone state into the user's gateway.
 *
 * Source of truth: persisted user/check-in timezone through `resolveStoredUserTimezone`.
 * Recovery: callers run this both after a timezone write and after a successful gateway wake.
 * A failed immediate write therefore heals on the next app launch/foreground wake.
 * Missing persisted state is a no-op, while lookup failures throw to the best-effort caller. This
 * prevents the display-only UTC fallback from overwriting a previously correct gateway timezone.
 */
export async function syncUserTimezoneToGateway(
  userId: string,
  timezone?: string,
): Promise<'synced' | 'no_gateway' | 'no_timezone'> {
  const resolvedTimezone = timezone ?? await resolveStoredUserTimezone(userId);
  if (!resolvedTimezone) return 'no_timezone';
  const creds = await gatewayService.getGatewayCredentials(userId);
  if (!creds) return 'no_gateway';

  const setupPassword = await gatewayService.getSetupPassword(userId).catch(() => undefined);
  await patchGatewayConfig(
    creds.gateway_url,
    creds.gateway_token,
    buildUserTimezoneConfigPatch(resolvedTimezone),
    setupPassword,
  );
  return 'synced';
}

/**
 * Runs after gateway credentials become authoritative. The timezone may have been persisted before
 * deployment, when there was no gateway to patch, so credential creation is a required recovery
 * trigger. The credential write remains successful when reconciliation is temporarily unavailable.
 */
export async function reconcileUserTimezoneAfterGatewaySave(
  userId: string,
): Promise<'synced' | 'no_gateway' | 'no_timezone' | 'failed'> {
  try {
    return await syncUserTimezoneToGateway(userId);
  } catch (error) {
    console.error(`[users] gateway timezone sync failed after credential save for user ${userId}:`, error);
    return 'failed';
  }
}
