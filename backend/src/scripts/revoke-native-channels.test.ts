import { describe, it, expect, vi } from 'vitest';

// Importing the script pulls in the pg pool, which reads DATABASE_URL at module load. Mocked so the
// pure helpers stay unit-testable without a database (house pattern — see
// automation-inputs.service.test.ts).
vi.mock('../db/pool.js', () => ({ pool: { query: async () => ({ rows: [] }) } }));

import {
  isLiveGrant,
  buildDisablePatch,
  parseArgs,
} from './revoke-native-channels.js';

/**
 * The native-channel teardown is the off switch that replaces the deleted `/api/v1/channels`
 * disconnect route, so its selection rule and patch shape are the load-bearing parts: a grant
 * missed here is a connector nobody can turn off.
 */
describe('revoke-native-channels', () => {
  it('selects every row whose connector could still be running', () => {
    expect(isLiveGrant({ status: 'connected', has_credential: false })).toBe(true);
    expect(isLiveGrant({ status: 'connecting', has_credential: false })).toBe(true);
    // A `disconnected` row that still holds a credential is a failed teardown, not a clean row.
    expect(isLiveGrant({ status: 'disconnected', has_credential: true })).toBe(true);
    expect(isLiveGrant({ status: 'disconnected', has_credential: false })).toBe(false);
  });

  it('disables the connector without clobbering sibling channel config', () => {
    expect(buildDisablePatch('discord')).toEqual({ channels: { discord: { enabled: false } } });
    expect(buildDisablePatch('whatsapp')).toEqual({ channels: { whatsapp: { enabled: false } } });
    // No token / dmPolicy keys: this is a pure disable, and config.patch deep-merges.
    expect(Object.keys(buildDisablePatch('discord').channels as object)).toEqual(['discord']);
  });

  it('defaults to a dry run so an accidental invocation cannot revoke anything', () => {
    expect(parseArgs([]).apply).toBe(false);
    expect(parseArgs(['--limit=5']).apply).toBe(false);
    expect(parseArgs(['--apply']).apply).toBe(true);
    expect(parseArgs(['--apply', '--limit=5']).limit).toBe(5);
    expect(() => parseArgs(['--limit=0'])).toThrow();
    expect(() => parseArgs(['--limit=abc'])).toThrow();
  });
});
