/**
 * check-env-parity — audit staging vs production backend env vars.
 *
 * Why: staging instability + "works in prod, breaks in staging" almost always
 * traces to an env var that is set in one Railway service and missing/different
 * in the other. This classifies every known backend var (per
 * docs/rebuild/05-STAGING-PARITY.md) and reports divergences that matter.
 *
 * Usage:
 *   # Export each Railway service's vars to JSON ({ "VAR": "value", ... }):
 *   railway variables --json   > /tmp/staging.json   # (in the staging service)
 *   railway variables --json   > /tmp/prod.json      # (in the prod service)
 *   tsx src/scripts/check-env-parity.ts /tmp/staging.json /tmp/prod.json
 *
 * Exit code is non-zero when any blocking parity issue is found (CI-friendly).
 */

export type ParityClass =
  /** Must exist in BOTH; value is a secret we don't compare. Freeze per env. */
  | 'stable-secret'
  /** Values SHOULD be equal across envs (parity). Flag if they differ. */
  | 'should-match'
  /** Values MUST differ across envs. Flag if identical (e.g. staging on prod DB). */
  | 'must-differ'
  /** May legitimately differ (separate keys/projects). Informational only. */
  | 'may-differ';

/** Classification of backend env vars (source: config/env.ts + doc 05). */
export const ENV_CLASSIFICATION: Record<string, ParityClass> = {
  // Frozen, per-env secrets — must be present in both; never compare values.
  JWT_SECRET: 'stable-secret',
  GATEWAY_ENCRYPTION_KEY: 'stable-secret',
  BACKEND_SERVICE_TOKEN: 'stable-secret',

  // Must differ — identical values mean staging is pointed at prod resources.
  DATABASE_URL: 'must-differ',
  BACKEND_PUBLIC_URL: 'must-differ',

  // Should match — behavior parity so prod bugs reproduce in staging.
  FLY_GATEWAY_IMAGE: 'should-match',
  FLY_REGION: 'should-match',
  FLY_ORG_SLUG: 'should-match',
  DEFAULT_LLM_PROVIDER: 'should-match',
  APPLE_CLIENT_ID: 'should-match',
  FREE_PLAN_DAILY_LIMIT: 'should-match',
  FREE_PLAN_MONTHLY_LIMIT: 'should-match',
  PRO_PLAN_DAILY_LIMIT: 'should-match',
  PRO_PLAN_MONTHLY_LIMIT: 'should-match',

  // May differ — separate keys/projects per env is fine.
  ANTHROPIC_API_KEY: 'may-differ',
  OPENAI_API_KEY: 'may-differ',
  VENICE_API_KEY: 'may-differ',
  POSTHOG_API_KEY: 'may-differ',
  POSTHOG_HOST: 'may-differ',
};

export type Severity = 'blocking' | 'warning' | 'info';

export interface ParityFinding {
  key: string;
  class: ParityClass;
  severity: Severity;
  message: string;
}

export interface ParityReport {
  findings: ParityFinding[];
  blocking: number;
  warnings: number;
  ok: boolean;
}

function present(map: Record<string, string>, key: string): boolean {
  const v = map[key];
  return typeof v === 'string' && v.trim().length > 0;
}

/**
 * Pure parity comparison. No I/O — fully unit-testable.
 * @param staging staging service vars (VAR -> value)
 * @param prod    production service vars (VAR -> value)
 */
export function compareEnvParity(
  staging: Record<string, string>,
  prod: Record<string, string>,
): ParityReport {
  const findings: ParityFinding[] = [];

  for (const [key, klass] of Object.entries(ENV_CLASSIFICATION)) {
    const inStaging = present(staging, key);
    const inProd = present(prod, key);

    switch (klass) {
      case 'stable-secret': {
        if (!inStaging || !inProd) {
          findings.push({
            key, class: klass, severity: 'blocking',
            message: `${key} must be set in both envs (frozen secret); missing in ${!inStaging ? 'staging' : 'prod'}.`,
          });
        }
        break;
      }
      case 'must-differ': {
        if (!inStaging || !inProd) {
          findings.push({
            key, class: klass, severity: 'blocking',
            message: `${key} must be set in both envs; missing in ${!inStaging ? 'staging' : 'prod'}.`,
          });
        } else if (staging[key].trim() === prod[key].trim()) {
          findings.push({
            key, class: klass, severity: 'blocking',
            message: `${key} is IDENTICAL across envs — staging may be pointed at production resources.`,
          });
        }
        break;
      }
      case 'should-match': {
        if (inStaging && inProd && staging[key].trim() !== prod[key].trim()) {
          findings.push({
            key, class: klass, severity: 'warning',
            message: `${key} differs (staging="${staging[key]}" prod="${prod[key]}") — should match for parity.`,
          });
        } else if (inStaging !== inProd) {
          findings.push({
            key, class: klass, severity: 'warning',
            message: `${key} is set in ${inStaging ? 'staging' : 'prod'} only — parity gap.`,
          });
        }
        break;
      }
      case 'may-differ': {
        if (inStaging !== inProd) {
          findings.push({
            key, class: klass, severity: 'info',
            message: `${key} set in ${inStaging ? 'staging' : 'prod'} only (allowed to differ).`,
          });
        }
        break;
      }
    }
  }

  // Unknown vars present in one env but not the other (possible drift).
  const known = new Set(Object.keys(ENV_CLASSIFICATION));
  const allKeys = new Set([...Object.keys(staging), ...Object.keys(prod)]);
  for (const key of allKeys) {
    if (known.has(key)) continue;
    const inS = present(staging, key);
    const inP = present(prod, key);
    if (inS !== inP) {
      findings.push({
        key, class: 'may-differ', severity: 'info',
        message: `Unclassified ${key} set in ${inS ? 'staging' : 'prod'} only — review if it should be parity.`,
      });
    }
  }

  const blocking = findings.filter((f) => f.severity === 'blocking').length;
  const warnings = findings.filter((f) => f.severity === 'warning').length;
  return { findings, blocking, warnings, ok: blocking === 0 };
}

export function formatReport(report: ParityReport): string {
  if (report.findings.length === 0) return '✅ Env parity: no issues found.';
  const order: Severity[] = ['blocking', 'warning', 'info'];
  const icon: Record<Severity, string> = { blocking: '❌', warning: '⚠️ ', info: 'ℹ️ ' };
  const lines = order.flatMap((sev) =>
    report.findings.filter((f) => f.severity === sev).map((f) => `${icon[sev]} ${f.message}`),
  );
  lines.push('', `Summary: ${report.blocking} blocking, ${report.warnings} warnings.`);
  return lines.join('\n');
}

// ── CLI ──────────────────────────────────────────────────────────────────────
// Run only when invoked directly (not when imported by tests).
const invokedDirectly =
  typeof process !== 'undefined' &&
  process.argv[1] &&
  import.meta.url === `file://${process.argv[1]}`;

if (invokedDirectly) {
  const [, , stagingPath, prodPath] = process.argv;
  if (!stagingPath || !prodPath) {
    console.error('Usage: tsx src/scripts/check-env-parity.ts <staging.json> <prod.json>');
    process.exit(2);
  }
  const fs = await import('node:fs');
  const read = (p: string): Record<string, string> => JSON.parse(fs.readFileSync(p, 'utf8'));
  const report = compareEnvParity(read(stagingPath), read(prodPath));
  console.log(formatReport(report));
  process.exit(report.ok ? 0 : 1);
}
