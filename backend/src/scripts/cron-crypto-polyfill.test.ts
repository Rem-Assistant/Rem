import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

/**
 * Every cron entrypoint must install the Web Crypto polyfill BEFORE anything can load the
 * Composio SDK.
 *
 * WHAT THIS CAUGHT. `crypto-polyfill.ts` existed and was imported by `server.ts` only. The cron
 * scripts were not, so every 15-minute tick loaded the Composio SDK on a runtime where
 * `globalThis.crypto` is undefined and threw the exact error the polyfill's own docblock names:
 *
 *   [brief-input] gmail collect failed for user …:
 *     class=TypeError reason=Cannot read properties of undefined (reading 'randomUUID')
 *
 * Observed live in `rem-cron` on 2026-08-11. Consequence: the Gmail collector threw on every
 * run, so a connector the user had actually connected contributed nothing to any brief — and
 * the failure was invisible until a diagnostic log line was added, because the collector
 * reported the generic `connector_unavailable` either way.
 *
 * A static check is the right shape here: the defect is a MISSING IMPORT, and import order is
 * load-bearing (the polyfill must run before the SDK's module initialization, which is why
 * server.ts pins it to line 1). Asserting the first statement is exactly the property that broke.
 */
const CRON_ENTRYPOINTS = [
  'cron-all.ts',
  'daily-checkins.ts',
  'run-routines.ts',
  'run-brief-authoring.ts',
] as const;

describe('cron entrypoints install the Web Crypto polyfill', () => {
  for (const entry of CRON_ENTRYPOINTS) {
    it(`${entry} imports crypto-polyfill as its very first statement`, () => {
      const source = readFileSync(resolve(__dirname, entry), 'utf8');
      const firstCode = source
        .split('\n')
        .map((line) => line.trim())
        .find((line) => line.length > 0 && !line.startsWith('//') && !line.startsWith('/*') && !line.startsWith('*'));

      expect(
        firstCode,
        `${entry} must import '../crypto-polyfill.js' before any other statement, or the Composio `
          + 'SDK loads without globalThis.crypto and throws '
          + "\"Cannot read properties of undefined (reading 'randomUUID')\" on every cron tick.",
      ).toContain('crypto-polyfill');
    });
  }

  it('the polyfill actually installs globalThis.crypto when it is missing', async () => {
    const original = globalThis.crypto;
    try {
      // Simulate a runtime that does not expose the Web Crypto global.
      Reflect.deleteProperty(globalThis as unknown as Record<string, unknown>, 'crypto');
      expect(globalThis.crypto).toBeUndefined();

      // Fresh module instance so the top-level guard re-runs. Vite cannot resolve a
      // variable dynamic import, so reset the registry and import statically.
      vi.resetModules();
      await import('../crypto-polyfill.js');

      expect(globalThis.crypto).toBeDefined();
      expect(typeof globalThis.crypto.randomUUID).toBe('function');
      expect(globalThis.crypto.randomUUID()).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      );
    } finally {
      (globalThis as unknown as { crypto: Crypto }).crypto = original;
    }
  });
});
