import { describe, expect, it } from 'vitest';
import { compareEnvParity } from './check-env-parity.js';

/** A baseline pair that should be fully clean. */
function cleanPair() {
  const common = {
    JWT_SECRET: 'stg-secret',
    GATEWAY_ENCRYPTION_KEY: 'stg-key',
    BACKEND_SERVICE_TOKEN: 'stg-svc',
    FLY_GATEWAY_IMAGE: 'registry/img:v9',
    FLY_REGION: 'iad',
    FLY_ORG_SLUG: 'personal',
    DEFAULT_LLM_PROVIDER: 'anthropic',
    APPLE_CLIENT_ID: 'com.remapp.rem',
  };
  const staging: Record<string, string> = {
    ...common,
    DATABASE_URL: 'postgres://staging-db',
    BACKEND_PUBLIC_URL: 'https://backend-staging.up.railway.app',
  };
  const prod: Record<string, string> = {
    ...common,
    // prod uses different secret VALUES (allowed; we don't compare secret values)
    JWT_SECRET: 'prod-secret',
    GATEWAY_ENCRYPTION_KEY: 'prod-key',
    BACKEND_SERVICE_TOKEN: 'prod-svc',
    DATABASE_URL: 'postgres://prod-db',
    BACKEND_PUBLIC_URL: 'https://backend-production.up.railway.app',
  };
  return { staging, prod };
}

describe('compareEnvParity', () => {
  it('reports no issues for a correctly-configured pair', () => {
    const { staging, prod } = cleanPair();
    const report = compareEnvParity(staging, prod);
    expect(report.ok).toBe(true);
    expect(report.blocking).toBe(0);
    expect(report.warnings).toBe(0);
  });

  it('flags a missing frozen secret as blocking', () => {
    const { staging, prod } = cleanPair();
    delete (staging as Record<string, string>).JWT_SECRET;
    const report = compareEnvParity(staging, prod);
    expect(report.ok).toBe(false);
    expect(report.findings.some((f) => f.key === 'JWT_SECRET' && f.severity === 'blocking')).toBe(true);
  });

  it('flags identical must-differ values as blocking (staging on prod resources)', () => {
    const { staging, prod } = cleanPair();
    staging.DATABASE_URL = prod.DATABASE_URL; // staging pointed at prod DB
    const report = compareEnvParity(staging, prod);
    expect(report.ok).toBe(false);
    expect(report.findings.some((f) => f.key === 'DATABASE_URL' && f.severity === 'blocking')).toBe(true);
  });

  it('warns when a should-match var diverges', () => {
    const { staging, prod } = cleanPair();
    staging.FLY_GATEWAY_IMAGE = 'registry/img:OLD';
    const report = compareEnvParity(staging, prod);
    expect(report.ok).toBe(true); // warning, not blocking
    expect(report.warnings).toBeGreaterThan(0);
    expect(report.findings.some((f) => f.key === 'FLY_GATEWAY_IMAGE' && f.severity === 'warning')).toBe(true);
  });

  it('warns when a should-match var is set in only one env', () => {
    const { staging, prod } = cleanPair();
    delete (prod as Record<string, string>).APPLE_CLIENT_ID;
    const report = compareEnvParity(staging, prod);
    expect(report.findings.some((f) => f.key === 'APPLE_CLIENT_ID' && f.severity === 'warning')).toBe(true);
  });

  it('treats may-differ keys present in one env as info, not blocking', () => {
    const { staging, prod } = cleanPair();
    staging.POSTHOG_API_KEY = 'phc_staging';
    const report = compareEnvParity(staging, prod);
    expect(report.ok).toBe(true);
    expect(report.findings.some((f) => f.key === 'POSTHOG_API_KEY' && f.severity === 'info')).toBe(true);
  });
});
