import dotenv from 'dotenv';
import path from 'node:path';

// Load .env.local for development, .env.production for production, then .env fallback.
const envFile = process.env.NODE_ENV === 'production' ? '.env.production' : '.env.local';
dotenv.config({ path: path.resolve(process.cwd(), envFile) });
dotenv.config({ path: path.resolve(process.cwd(), '.env') });

function required(key: string): string {
  const v = process.env[key]?.trim();
  if (!v) throw new Error(`Missing required env: ${key}`);
  return v;
}

function optional(key: string, fallback = ''): string {
  return process.env[key]?.trim() || fallback;
}

/** Lazy-required: only throws when the value is actually accessed and empty.
 *  Does NOT prevent the server from starting. */
function requiredForDeploy(key: string): string {
  const v = process.env[key]?.trim();
  if (!v) throw new Error(`Missing env var required for deploy: ${key}`);
  return v;
}

export const env = {
  get DATABASE_URL() {
    return required('DATABASE_URL');
  },
  get JWT_SECRET() {
    return required('JWT_SECRET');
  },
  get GATEWAY_ENCRYPTION_KEY() {
    return required('GATEWAY_ENCRYPTION_KEY');
  },

  // Auth providers (optional — only needed if federated login is used)
  get GOOGLE_CLIENT_ID() {
    return optional('GOOGLE_CLIENT_ID');
  },
  get APPLE_CLIENT_ID() {
    return optional('APPLE_CLIENT_ID');
  },

  // Railway API (optional — only needed for self-hosted Railway deploy)
  get RAILWAY_API_TOKEN() {
    return optional('RAILWAY_API_TOKEN');
  },
  get RAILWAY_TEMPLATE_REPO() {
    return optional('RAILWAY_TEMPLATE_REPO');
  },

  // Safety guard: when "true", the backend refuses to create/destroy/mutate
  // Fly gateway infrastructure (apps + machines). Set on the STAGING Railway
  // environment so a staging backend pointed at the prod DB (the staging→prod
  // DB swap) can never re-deploy or destroy the real 88-gateway fleet. Prod
  // leaves this unset (mutations allowed). Fail-safe: only the literal "true"
  // enables normal mutations to be blocked, so a typo can't silently disable prod.
  get GATEWAY_MUTATIONS_DISABLED() {
    return optional('GATEWAY_MUTATIONS_DISABLED').toLowerCase() === 'true';
  },

  // Pool apps keep their `remclaw-pool-*` Fly identity after assignment because Fly apps cannot
  // be renamed in place. That violates the managed-gateway contract (`remclaw-{user}`) and leaks
  // infrastructure identity into durable user records. Keep claims fail-closed until assignment
  // can transfer a pre-warmed gateway into a canonical per-user app while preserving its volume.
  get GATEWAY_POOL_ASSIGNMENT_ENABLED() {
    return optional('GATEWAY_POOL_ASSIGNMENT_ENABLED').toLowerCase() === 'true';
  },

  // Fly.io managed deploy
  get FLY_ORG_TOKEN() {
    return requiredForDeploy('FLY_ORG_TOKEN');
  },
  get FLY_ORG_SLUG() {
    return optional('FLY_ORG_SLUG', 'personal');
  },
  get FLY_REGION() {
    return optional('FLY_REGION', 'iad');
  },
  get FLY_GATEWAY_IMAGE() {
    return requiredForDeploy('FLY_GATEWAY_IMAGE');
  },
  get BACKEND_PUBLIC_URL() {
    return requiredForDeploy('BACKEND_PUBLIC_URL');
  },

  // LLM provider keys (org-level, injected into managed deploys)
  get ANTHROPIC_API_KEY() {
    return requiredForDeploy('ANTHROPIC_API_KEY');
  },
  get VENICE_API_KEY() {
    return optional('VENICE_API_KEY');
  },
  get OPENAI_API_KEY() {
    return optional('OPENAI_API_KEY');
  },
  get DEFAULT_LLM_PROVIDER() {
    return optional('DEFAULT_LLM_PROVIDER', 'anthropic');
  },

  // Apple In-App Purchase (App Store Server API)
  get APPLE_IAP_ISSUER_ID() {
    return optional('APPLE_IAP_ISSUER_ID');
  },
  get APPLE_IAP_KEY_ID() {
    return optional('APPLE_IAP_KEY_ID');
  },
  get APPLE_IAP_PRIVATE_KEY() {
    return optional('APPLE_IAP_PRIVATE_KEY');
  },
  get APPLE_IAP_BUNDLE_ID() {
    return optional('APPLE_IAP_BUNDLE_ID');
  },
  get APPLE_IAP_APPLE_APP_ID() {
    return optional('APPLE_IAP_APPLE_APP_ID');
  },
  get APPLE_IAP_ROOT_CA_PATHS() {
    return optional('APPLE_IAP_ROOT_CA_PATHS');
  },
  get APPLE_IAP_ENABLE_ONLINE_CHECKS() {
    return optional('APPLE_IAP_ENABLE_ONLINE_CHECKS', 'true');
  },

  // Apple Sign-In token revocation (required for App Store compliance)
  get APPLE_TEAM_ID() {
    return optional('APPLE_TEAM_ID');
  },
  get APPLE_KEY_ID() {
    return optional('APPLE_KEY_ID');
  },
  get APPLE_PRIVATE_KEY() {
    return optional('APPLE_PRIVATE_KEY');
  },

  // APNs remote push (optional — sendPush is a no-op until all four are set).
  // Token-based (.p8) auth, mirroring openclaw/src/infra/push-apns.ts.
  get APNS_KEY_ID() {
    return optional('APNS_KEY_ID');
  },
  get APNS_TEAM_ID() {
    return optional('APNS_TEAM_ID');
  },
  get APNS_BUNDLE_ID() {
    return optional('APNS_BUNDLE_ID');
  },
  // The .p8 contents. Newlines may arrive escaped as "\n" from the deploy env.
  get APNS_AUTH_KEY() {
    return optional('APNS_AUTH_KEY');
  },

  // Optional backend telemetry
  get POSTHOG_API_KEY() {
    return optional('POSTHOG_API_KEY');
  },
  get POSTHOG_HOST() {
    return optional('POSTHOG_HOST', 'https://us.i.posthog.com');
  },

  // Gateway service token for backend-to-gateway auth
  get BACKEND_SERVICE_TOKEN() {
    return optional('BACKEND_SERVICE_TOKEN');
  },

  // Shared secret the gateway cron webhook presents when calling the inbound
  // routine-run handler (gateway→backend, no user JWT). Unset → the inbound
  // handler rejects every call (fail-closed). See internal-routines.routes.ts.
  get ROUTINE_WEBHOOK_SECRET() {
    return optional('ROUTINE_WEBHOOK_SECRET');
  },

  // Local dev: return these from GET /me/credentials when user has no gateway in DB
  get LOCAL_GATEWAY_URL() {
    return optional('LOCAL_GATEWAY_URL');
  },
  get LOCAL_GATEWAY_TOKEN() {
    return optional('LOCAL_GATEWAY_TOKEN');
  },
  /** Where the local gateway stores state (default ~/.openclaw). Token read from {dir}/gateway.token when LOCAL_GATEWAY_TOKEN not set. */
  get LOCAL_GATEWAY_STATE_DIR() {
    return optional('LOCAL_GATEWAY_STATE_DIR') || path.join(process.env.HOME || process.env.USERPROFILE || '/tmp', '.openclaw');
  },
};
