import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolQueryMock = vi.hoisted(() => vi.fn());
vi.mock('../db/pool.js', () => ({ pool: { query: poolQueryMock } }));

import {
  MODEL_RUNTIME_MODES,
  RUN_BLOCK_CODES,
  blockCodeForGatewayFailure,
  blockCodeForRuntimeFailure,
  isModelRuntimeMode,
  isRunBlockCode,
  mayChargeRemManagedKey,
  modeForRuntime,
  resolveModelRuntimeMode,
} from './run-block.js';

const USER_ID = 'f8679a96-0000-4000-8000-0000000000aa';

beforeEach(() => {
  poolQueryMock.mockReset();
});

describe('modeForRuntime', () => {
  it('accepts each durable runtime-mode wire value', () => {
    expect(modeForRuntime('rem_managed')).toBe('rem_managed');
    expect(modeForRuntime('byok')).toBe('byok');
  });

  it('fails closed on missing or invalid stored state', () => {
    expect(modeForRuntime(null)).toBe('unknown');
    expect(modeForRuntime('gateway')).toBe('unknown');
  });

  it('takes only the durable mode value, never gateway topology', () => {
    expect(modeForRuntime.length).toBe(1);
  });
});

describe('mayChargeRemManagedKey', () => {
  it('permits the operator key ONLY for a proven rem_managed runtime', () => {
    expect(mayChargeRemManagedKey('rem_managed')).toBe(true);
    expect(mayChargeRemManagedKey('byok')).toBe(false);
  });

  it('FAILS CLOSED on unknown — a failed mode lookup is not permission to bill', () => {
    // The whole asymmetry of this predicate. Being wrong towards `false` costs a skipped
    // enrichment the user can retry; being wrong towards `true` silently spends the operator's
    // key on a user who is paying their own provider. Those are not comparable mistakes.
    expect(mayChargeRemManagedKey('unknown')).toBe(false);
  });

  it('permits exactly one member of the mode set', () => {
    // Pins the shape rather than the members: adding a mode must force a decision here, not
    // inherit `false` by accident (or, worse, `true`).
    expect(MODEL_RUNTIME_MODES.filter(mayChargeRemManagedKey)).toEqual(['rem_managed']);
  });
});

describe('resolveModelRuntimeMode', () => {
  it('reads durable payer ownership without consulting gateway credentials', async () => {
    poolQueryMock.mockResolvedValue({ rows: [{ model_runtime_mode: 'rem_managed' }] });
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('rem_managed');
    expect(poolQueryMock).toHaveBeenCalledWith(
      expect.stringContaining('SELECT model_runtime_mode FROM users'),
      [USER_ID],
    );
  });

  it('reports byok only from the explicit durable state', async () => {
    poolQueryMock.mockResolvedValue({ rows: [{ model_runtime_mode: 'byok' }] });
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('byok');
  });

  it('reports unknown when the user row is absent', async () => {
    poolQueryMock.mockResolvedValue({ rows: [] });
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('unknown');
  });

  it('fails closed on an invalid stored value', async () => {
    poolQueryMock.mockResolvedValue({ rows: [{ model_runtime_mode: 'manual' }] });
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('unknown');
  });

  it('never throws — a lookup failure degrades to unknown', async () => {
    // This runs inside failure paths (a task run that already went wrong, a cron tick). A
    // throw here would convert a transient DB hiccup into a second, unrelated failure — and
    // because `unknown` fails closed, degrading is also the conservative answer for billing.
    poolQueryMock.mockRejectedValue(new Error('connection terminated'));
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('unknown');
  });
});

describe('blockCodeForGatewayFailure', () => {
  it('maps every structured gateway failure reason to a code', () => {
    expect(blockCodeForGatewayFailure('no_gateway')).toBe('runtime_unavailable');
    expect(blockCodeForGatewayFailure('wake_failed')).toBe('runtime_unavailable');
    expect(blockCodeForGatewayFailure('timeout')).toBe('runtime_timeout');
    expect(blockCodeForGatewayFailure('cancelled')).toBe('runtime_error');
    expect(blockCodeForGatewayFailure('error')).toBe('runtime_error');
  });

  it('never invents quota_exhausted or credential_rejected from a gateway turn', () => {
    // Those two codes carry the remedies that differ most (upgrade vs fix your key), so
    // producing one on a guess would send a user to the wrong screen. A gateway turn has no
    // structured provider-error class today, so the only honest answers are the runtime_*
    // ones. If this test ever needs relaxing, the gateway must have gained a real field
    // first — never a regex over `ack.error.message` (CLAUDE.md principle 5).
    const reasons = ['no_gateway', 'wake_failed', 'timeout', 'cancelled', 'error'] as const;
    const produced = reasons.map(blockCodeForGatewayFailure);
    expect(produced).not.toContain('quota_exhausted');
    expect(produced).not.toContain('credential_rejected');
  });
});

describe('blockCodeForRuntimeFailure', () => {
  it('maps every provider-independent runtime failure reason to a code', () => {
    expect(blockCodeForRuntimeFailure('unavailable')).toBe('runtime_unavailable');
    expect(blockCodeForRuntimeFailure('startup_failed')).toBe('runtime_unavailable');
    expect(blockCodeForRuntimeFailure('quota_exhausted')).toBe('quota_exhausted');
    expect(blockCodeForRuntimeFailure('credential_rejected')).toBe('credential_rejected');
    expect(blockCodeForRuntimeFailure('timeout')).toBe('runtime_timeout');
    expect(blockCodeForRuntimeFailure('cancelled')).toBe('runtime_error');
    expect(blockCodeForRuntimeFailure('error')).toBe('runtime_error');
  });
});

describe('wire guards', () => {
  it('accepts exactly the declared members', () => {
    for (const code of RUN_BLOCK_CODES) expect(isRunBlockCode(code)).toBe(true);
    for (const mode of MODEL_RUNTIME_MODES) expect(isModelRuntimeMode(mode)).toBe(true);
  });

  it('rejects anything else, including near-misses and non-strings', () => {
    for (const bad of ['quota', 'QUOTA_EXHAUSTED', '', null, undefined, 42, {}]) {
      expect(isRunBlockCode(bad)).toBe(false);
      expect(isModelRuntimeMode(bad)).toBe(false);
    }
  });

  it('keeps the wire values the SQL CHECK constraints were written against', () => {
    // migration 121 hard-codes both sets in CHECK constraints. A rename here without a
    // matching migration would make every blocked run fail its INSERT in production while
    // every unit test stayed green, so the literal list is pinned on purpose.
    expect([...RUN_BLOCK_CODES]).toEqual([
      'quota_exhausted',
      'credential_rejected',
      'runtime_unavailable',
      'runtime_timeout',
      'runtime_error',
      'policy_blocked',
    ]);
    expect([...MODEL_RUNTIME_MODES]).toEqual(['rem_managed', 'byok', 'unknown']);
  });
});
