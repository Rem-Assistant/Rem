import { beforeEach, describe, expect, it, vi } from 'vitest';

const getGatewayCredentialsMock = vi.hoisted(() => vi.fn());
vi.mock('./gateway.service.js', () => ({
  getGatewayCredentials: getGatewayCredentialsMock,
}));

import {
  MODEL_RUNTIME_MODES,
  RUN_BLOCK_CODES,
  blockCodeForGatewayFailure,
  isModelRuntimeMode,
  isRunBlockCode,
  mayChargeRemManagedKey,
  modeForRuntime,
  resolveModelRuntimeMode,
} from './run-block.js';

const USER_ID = 'f8679a96-0000-4000-8000-0000000000aa';

beforeEach(() => {
  getGatewayCredentialsMock.mockReset();
});

describe('modeForRuntime', () => {
  it('calls a runtime the backend can address rem_managed', () => {
    // Holding a gateway's URL + token is exactly the precondition every site that applies
    // `buildGatewayConfigPatch` needs — and that patch installs the ORG GMI key as the PRIMARY
    // model (gateway-defaults.ts:489 + :152). So reachable ⇒ Rem's key is the brain there.
    expect(modeForRuntime(true)).toBe('rem_managed');
  });

  it('says unknown, NOT byok, when there is no gateway on record', () => {
    // An absent gateway is an absent fact. Answering `byok` would be inventing one — and would
    // send a client to "fix your API key" for a user who has no runtime at all.
    expect(modeForRuntime(false)).toBe('unknown');
  });

  it('NEVER answers byok — nothing in this product can currently prove it', () => {
    // THE REGRESSION THAT MATTERS MOST HERE, because an earlier revision of this file got it
    // wrong in the confident direction. It derived the mode from `users.hosting_provider`:
    // fly => rem_managed, railway/local/manual => byok, on the grounds that Rem "never
    // supplies" a key to those. Two places in this repo falsify that:
    //
    //   - the managed deploy pipeline — runRailwayPipeline onboards with the SAME
    //     buildGatewayConfigPatch the Fly pipeline uses, so a Railway gateway's DEFAULT model
    //     is `gmi/MiniMaxAI/MiniMax-M2.7` on the ORG key. The user's pasted key sits alongside
    //     it, not instead of it.
    //   - the fleet config-patch job — selects EVERY user with a gateway_url,
    //     with no hosting_provider filter, and applies the same patch. One fleet run puts Rem's
    //     provider, as primary, on local and manual gateways too.
    //
    // Both mistakes point the wrong way: a Railway user would have been told "your API key was
    // refused" about a key that is Rem's, and would have had their brief's connector enrichment
    // withheld to protect a bill Rem is already paying. `hosting_provider` describes where Rem
    // DEPLOYS, not whose key PAYS. This test exists so that reintroducing the shortcut is red.
    expect([modeForRuntime(true), modeForRuntime(false)]).not.toContain('byok');
  });

  it('takes no hosting_provider argument at all, so the shortcut cannot be reintroduced quietly', () => {
    // Binding on ARITY, not behaviour. The pure helper above can only be wrong if someone hands
    // it the column — so the strongest guard is that there is nowhere to hand it. Restoring the
    // old two-argument `modeForHosting` and calling it from the resolver has to change this
    // line too, which is exactly the review the change deserves.
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
  it('reports rem_managed for any gateway the backend holds credentials for', async () => {
    // Every topology, same answer — because the config patch does not discriminate either.
    for (const hosting of ['fly', 'railway', 'local', 'manual', null]) {
      getGatewayCredentialsMock.mockResolvedValue({
        gateway_url: 'https://gw.example',
        gateway_token: 't',
        hosting_provider: hosting,
      });
      await expect(resolveModelRuntimeMode(USER_ID), String(hosting)).resolves.toBe('rem_managed');
    }
  });

  it('reports unknown when the user has no gateway at all', async () => {
    getGatewayCredentialsMock.mockResolvedValue(null);
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('unknown');
  });

  it('NEVER returns byok, whatever the gateway record says', async () => {
    // The resolver-level statement of the same guarantee. The pure helper cannot be handed a
    // hosting provider, but the RESOLVER is where the shortcut lived and where it would come
    // back — it is the only place with the row in hand. Every topology, plus the no-gateway
    // case, and none of them may answer `byok` while nothing in the product can prove it.
    for (const creds of [
      { gateway_url: 'u', gateway_token: 't', hosting_provider: 'fly' },
      { gateway_url: 'u', gateway_token: 't', hosting_provider: 'railway' },
      { gateway_url: 'u', gateway_token: 't', hosting_provider: 'local' },
      { gateway_url: 'u', gateway_token: 't', hosting_provider: 'manual' },
      null,
    ]) {
      getGatewayCredentialsMock.mockResolvedValue(creds);
      await expect(
        resolveModelRuntimeMode(USER_ID),
        String(creds?.hosting_provider ?? 'none'),
      ).resolves.not.toBe('byok');
    }
  });

  it('never throws — a lookup failure degrades to unknown', async () => {
    // This runs inside failure paths (a task run that already went wrong, a cron tick). A
    // throw here would convert a transient DB hiccup into a second, unrelated failure — and
    // because `unknown` fails closed, degrading is also the conservative answer for billing.
    getGatewayCredentialsMock.mockRejectedValue(new Error('connection terminated'));
    await expect(resolveModelRuntimeMode(USER_ID)).resolves.toBe('unknown');
  });
});

describe('blockCodeForGatewayFailure', () => {
  it('maps every structured gateway failure reason to a code', () => {
    expect(blockCodeForGatewayFailure('no_gateway')).toBe('runtime_unavailable');
    expect(blockCodeForGatewayFailure('wake_failed')).toBe('runtime_unavailable');
    expect(blockCodeForGatewayFailure('timeout')).toBe('runtime_timeout');
    expect(blockCodeForGatewayFailure('error')).toBe('runtime_error');
  });

  it('never invents quota_exhausted or credential_rejected from a gateway turn', () => {
    // Those two codes carry the remedies that differ most (upgrade vs fix your key), so
    // producing one on a guess would send a user to the wrong screen. A gateway turn has no
    // structured provider-error class today, so the only honest answers are the runtime_*
    // ones. If this test ever needs relaxing, the gateway must have gained a real field
    // first — never a regex over `ack.error.message` (CLAUDE.md principle 5).
    const reasons = ['no_gateway', 'wake_failed', 'timeout', 'error'] as const;
    const produced = reasons.map(blockCodeForGatewayFailure);
    expect(produced).not.toContain('quota_exhausted');
    expect(produced).not.toContain('credential_rejected');
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
