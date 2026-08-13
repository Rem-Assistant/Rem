import { describe, expect, it } from 'vitest';
import { resolveGatewayUpdateReadiness } from './gateway-update.service.js';

describe('resolveGatewayUpdateReadiness', () => {
  it('returns no_gateway when the user has no configured gateway', () => {
    expect(resolveGatewayUpdateReadiness(null, null)).toMatchObject({
      canUpdate: false,
      status: 'no_gateway',
      hostingProvider: 'none',
      gatewayUrl: null,
      managedFlyAppName: null,
      requiredChecks: [],
      preflightChecks: [],
      approvedTargets: [],
    });
  });

  it('keeps managed Fly updates disabled until the safe-update preflight contract exists', () => {
    const readiness = resolveGatewayUpdateReadiness(
      {
        gateway_url: 'https://remclaw-00000000.fly.dev',
        hosting_provider: 'fly',
      },
      {
        fly_app_name: 'remclaw-00000000',
      },
    );

    expect(readiness).toMatchObject({
      canUpdate: false,
      status: 'managed_fly_preflight_required',
      hostingProvider: 'fly',
      gatewayUrl: 'https://remclaw-00000000.fly.dev',
      managedFlyAppName: 'remclaw-00000000',
    });
    expect(readiness.requiredChecks).toEqual([
      'same_gateway_target',
      'backup_or_snapshot',
      'approved_gateway_image',
      'post_update_health_check',
      'rollback_path',
    ]);
    expect(readiness.preflightChecks).toEqual([
      {
        id: 'same_gateway_target',
        label: 'Same Gateway Target',
        status: 'ready',
        message: 'Managed Fly app remclaw-00000000 is known. Machine and volume checks still need to run before updates can be enabled.',
      },
      {
        id: 'backup_or_snapshot',
        label: 'Backup Or Snapshot',
        status: 'blocked',
        message: 'A tested gateway backup or volume snapshot is required before Rem can expose an in-app update action.',
      },
      {
        id: 'approved_gateway_image',
        label: 'Approved Gateway Image',
        status: 'ready',
        message: 'The stable OpenClaw gateway image is approved for preflight display, but installation remains disabled until every safety gate passes.',
      },
      {
        id: 'post_update_health_check',
        label: 'Post-Update Health Check',
        status: 'not_run',
        message: 'A post-update health probe has not run for this gateway and must pass before updates can be enabled.',
      },
      {
        id: 'rollback_path',
        label: 'Rollback Path',
        status: 'blocked',
        message: 'A tested rollback path is required before Rem can offer managed gateway updates.',
      },
    ]);
    expect(readiness.approvedTargets).toEqual([
      {
        id: 'openclaw-stable',
        label: 'OpenClaw stable',
        channel: 'stable',
        image: 'ghcr.io/rem-assistant/openclaw-gateway:stable',
        requiredCapabilities: ['skills.search'],
        enabled: false,
        disabledReason: 'Not installable yet. Safe in-app updates require backup/snapshot, same-gateway targeting, health check, and rollback preflight.',
      },
    ]);
  });

  it('treats non-managed or metadata-incomplete gateways as manual updates', () => {
    expect(resolveGatewayUpdateReadiness(
      {
        gateway_url: 'https://example.up.railway.app',
        hosting_provider: 'railway',
      },
      null,
    )).toMatchObject({
      canUpdate: false,
      status: 'manual_update',
      hostingProvider: 'railway',
      managedFlyAppName: null,
      preflightChecks: [],
      approvedTargets: [],
    });

    expect(resolveGatewayUpdateReadiness(
      {
        gateway_url: 'https://remclaw-00000000.fly.dev',
        hosting_provider: 'fly',
      },
      {
        fly_app_name: '   ',
      },
    )).toMatchObject({
      canUpdate: false,
      status: 'manual_update',
      hostingProvider: 'fly',
      managedFlyAppName: null,
      preflightChecks: [],
      approvedTargets: [],
    });
  });

  it('returns defensive copies of approved targets, capability arrays, and preflight checks', () => {
    const first = resolveGatewayUpdateReadiness(
      {
        gateway_url: 'https://remclaw-00000000.fly.dev',
        hosting_provider: 'fly',
      },
      {
        fly_app_name: 'remclaw-00000000',
      },
    );
    first.approvedTargets[0].requiredCapabilities.push('mutated.capability');
    first.preflightChecks[0].status = 'blocked';

    const second = resolveGatewayUpdateReadiness(
      {
        gateway_url: 'https://remclaw-00000000.fly.dev',
        hosting_provider: 'fly',
      },
      {
        fly_app_name: 'remclaw-00000000',
      },
    );

    expect(second.approvedTargets[0].requiredCapabilities).toEqual(['skills.search']);
    expect(second.preflightChecks[0]).toMatchObject({
      id: 'same_gateway_target',
      status: 'ready',
    });
  });
});
