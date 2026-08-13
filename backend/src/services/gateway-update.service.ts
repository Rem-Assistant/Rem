export type GatewayUpdateReadinessStatus =
  | 'no_gateway'
  | 'managed_fly_preflight_required'
  | 'manual_update';

interface GatewayUpdateCredentials {
  gateway_url: string;
  hosting_provider: string;
}

interface GatewayUpdateFlyMetadata {
  fly_app_name: string | null;
}

export interface GatewayUpdateApprovedTarget {
  id: string;
  label: string;
  channel: 'stable';
  image: string;
  requiredCapabilities: string[];
  enabled: false;
  disabledReason: string;
}

export type GatewayUpdatePreflightCheckStatus = 'ready' | 'blocked' | 'not_run';

export interface GatewayUpdatePreflightCheck {
  id: typeof SAFE_UPDATE_PREFLIGHT_CHECKS[number];
  label: string;
  status: GatewayUpdatePreflightCheckStatus;
  message: string;
}

export interface GatewayUpdateReadiness {
  canUpdate: false;
  status: GatewayUpdateReadinessStatus;
  hostingProvider: string;
  gatewayUrl: string | null;
  managedFlyAppName: string | null;
  message: string;
  requiredChecks: string[];
  preflightChecks: GatewayUpdatePreflightCheck[];
  approvedTargets: GatewayUpdateApprovedTarget[];
}

const SAFE_UPDATE_PREFLIGHT_CHECKS = [
  'same_gateway_target',
  'backup_or_snapshot',
  'approved_gateway_image',
  'post_update_health_check',
  'rollback_path',
] as const;

const APPROVED_GATEWAY_TARGETS: GatewayUpdateApprovedTarget[] = [
  {
    id: 'openclaw-stable',
    label: 'OpenClaw stable',
    channel: 'stable',
    image: 'ghcr.io/rem-assistant/openclaw-gateway:stable',
    requiredCapabilities: ['skills.search'],
    enabled: false,
    disabledReason: 'Not installable yet. Safe in-app updates require backup/snapshot, same-gateway targeting, health check, and rollback preflight.',
  },
];

export function listApprovedGatewayUpdateTargets(): GatewayUpdateApprovedTarget[] {
  return APPROVED_GATEWAY_TARGETS.map((target) => ({
    ...target,
    requiredCapabilities: [...target.requiredCapabilities],
  }));
}

function listManagedFlyPreflightChecks(managedFlyAppName: string): GatewayUpdatePreflightCheck[] {
  return [
    {
      id: 'same_gateway_target',
      label: 'Same Gateway Target',
      status: 'ready',
      message: `Managed Fly app ${managedFlyAppName} is known. Machine and volume checks still need to run before updates can be enabled.`,
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
  ];
}

export function resolveGatewayUpdateReadiness(
  credentials: GatewayUpdateCredentials | null,
  flyMetadata: GatewayUpdateFlyMetadata | null,
): GatewayUpdateReadiness {
  if (!credentials?.gateway_url) {
    return {
      canUpdate: false,
      status: 'no_gateway',
      hostingProvider: 'none',
      gatewayUrl: null,
      managedFlyAppName: null,
      message: 'Connect a gateway before checking for updates.',
      requiredChecks: [],
      preflightChecks: [],
      approvedTargets: [],
    };
  }

  const hostingProvider = credentials.hosting_provider || 'railway';
  const managedFlyAppName = flyMetadata?.fly_app_name?.trim() || null;

  if (hostingProvider === 'fly' && managedFlyAppName) {
    return {
      canUpdate: false,
      status: 'managed_fly_preflight_required',
      hostingProvider,
      gatewayUrl: credentials.gateway_url,
      managedFlyAppName,
      message: 'Gateway updates require a tested backup, same-gateway deploy target, health check, and rollback path before they can be enabled.',
      requiredChecks: [...SAFE_UPDATE_PREFLIGHT_CHECKS],
      preflightChecks: listManagedFlyPreflightChecks(managedFlyAppName),
      approvedTargets: listApprovedGatewayUpdateTargets(),
    };
  }

  return {
    canUpdate: false,
    status: 'manual_update',
    hostingProvider,
    gatewayUrl: credentials.gateway_url,
    managedFlyAppName,
    message: 'This gateway is not eligible for managed in-app updates yet. Update it outside Rem, then reconnect if needed.',
    requiredChecks: [],
    preflightChecks: [],
    approvedTargets: [],
  };
}
