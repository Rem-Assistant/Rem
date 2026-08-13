/**
 * Staging-only, fail-closed repair for a Daily Brief whose durable transcript contains a verified
 * gateway-authored artifact while legacy #1213 fallback rows still own `/brief`.
 *
 * Dry-run is the default. Commit requires `--commit`, an explicit user UUID + local day, and the
 * exact SHA-256 digest of the intended transcript message. `--message-id` further disambiguates
 * when the gateway exposes one. Verification may wake a sleeping Fly gateway even in dry-run mode.
 * Prose, gateway URLs, tokens, and setup credentials are never logged.
 */
import { fileURLToPath } from 'node:url';
import '../config/env.js';
import {
  BriefRepairError,
  repairCanonicalBrief,
} from '../services/brief-repair.service.js';

interface Arguments {
  userId?: string;
  localDay?: string;
  digest?: string;
  messageId?: string;
  commit: boolean;
}

// Stable Railway identity, not an operator-supplied label. Preview and production environments
// have different immutable IDs, so exporting RAILWAY_ENVIRONMENT_NAME=staging cannot bypass this.
export const STAGING_RAILWAY_ENVIRONMENT_ID = '4b54fc6f-1198-46dd-8fc6-7b23d4365056';

export function parseRepairArguments(argv: string[]): Arguments {
  const args: Arguments = { commit: false };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--commit') {
      args.commit = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for ${token}`);
    if (token === '--user-id') args.userId = value;
    else if (token === '--local-day') args.localDay = value;
    else if (token === '--digest') args.digest = value;
    else if (token === '--message-id') args.messageId = value;
    else throw new Error(`unknown argument: ${token}`);
    index += 1;
  }
  return args;
}

export function assertStagingEnvironment(env: NodeJS.ProcessEnv = process.env): void {
  const name = (env.RAILWAY_ENVIRONMENT_NAME ?? '').trim().toLowerCase();
  const id = (env.RAILWAY_ENVIRONMENT_ID ?? '').trim().toLowerCase();
  if (name !== 'staging' || id !== STAGING_RAILWAY_ENVIRONMENT_ID) {
    throw new Error('refusing to run outside the immutable Railway staging environment');
  }
}

async function main(): Promise<void> {
  assertStagingEnvironment();
  const args = parseRepairArguments(process.argv.slice(2));
  if (!args.userId || !args.localDay || !args.digest) {
    throw new Error('required: --user-id UUID --local-day YYYY-MM-DD --digest SHA256 [--message-id ID] [--commit]');
  }

  const result = await repairCanonicalBrief({
    userId: args.userId,
    localDay: args.localDay,
    transcriptDigest: args.digest,
    messageId: args.messageId,
    commit: args.commit,
  });
  const target = `${args.userId.slice(0, 8)}…/${result.localDay}`;
  console.log(
    `[brief-repair] mode=${result.mode} target=${target} slot=${result.authoredSlot} `
      + `digest=${result.transcriptDigest} message_id_verified=${result.messageIdVerified} `
      + `fallback_artifacts_invalidated=${result.invalidatedFallbackArtifacts} `
      + `fallback_cache_rows_invalidated=${result.invalidatedFallbackCacheRows} `
      + `already_adopted=${result.alreadyAdopted}`,
  );
  if (result.mode === 'dry-run') {
    console.log('[brief-repair] dry-run only; rerun with --commit after reviewing this identity');
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error: unknown) => {
    const code = error instanceof BriefRepairError ? error.code : 'fatal';
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[brief-repair] ${code}: ${message}`);
    process.exit(1);
  });
}
