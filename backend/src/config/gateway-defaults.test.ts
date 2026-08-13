import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import schemaContract from './gateway-schema-contract.json' with { type: 'json' };
import {
  DEFAULT_ALLOW_COMMANDS,
  DEFAULT_ELEVENLABS_MODEL_ID,
  DEFAULT_ELEVENLABS_VOICE_ID,
  DEFAULT_PRIMARY_MODEL,
  DEFAULT_TALK_PROVIDER_ID,
  GMI_BASE_URL,
  GMI_MINIMAX_MODEL_ID,
  GMI_PROVIDER_ID,
  IOS_NODE_COMMANDS,
  buildGatewayConfigPatch,
  buildManagedGatewayReconfigurePatch,
} from './gateway-defaults.js';

/**
 * Anti-drift guard for R1 (#810): the gateway "dangerous command" allowlist
 * must stay consistent with the commands the iOS node actually implements.
 *
 * The single source of truth for the registry is the Swift `NodeInvocationRouter`,
 * mirrored here as `IOS_NODE_COMMANDS`. If someone allow-lists a command the
 * device can't run (the old `contacts.add` bug) — or REMCLAW.md / the registry
 * drift apart — these assertions fail.
 */
describe('gateway-defaults command allowlist', () => {
  it('only allow-lists commands the iOS node actually implements', () => {
    const known = new Set<string>(IOS_NODE_COMMANDS);
    const phantom = DEFAULT_ALLOW_COMMANDS.filter((cmd) => !known.has(cmd));
    expect(phantom).toEqual([]);
  });

  it('does not allow-list a contacts command (no iOS handler exists)', () => {
    const contacts = DEFAULT_ALLOW_COMMANDS.filter((cmd) => cmd.startsWith('contacts.'));
    expect(contacts).toEqual([]);
  });

  it('exposes both levels of the task organization hierarchy', () => {
    expect(IOS_NODE_COMMANDS).toEqual(expect.arrayContaining([
      'folders.list',
      'folders.create',
      'lists.list',
      'lists.create',
    ]));
    expect(DEFAULT_ALLOW_COMMANDS).toEqual(expect.arrayContaining([
      'folders.create',
      'lists.create',
    ]));
  });

  /**
   * The brief names tasks in prose and carries no ids, so without an allow-listed name
   * lookup the agent cannot account for a line in its own brief. A node command the gateway
   * does not allow is a command the agent can never call, so the allow-list half is asserted
   * here. (The prose-documentation half lived in the deploy/ gateway hooks, which are not part
   * of the open-core seed.)
   */
  it('allow-lists a name lookup, so brief items can be resolved by title', () => {
    expect(IOS_NODE_COMMANDS).toContain('tasks.search');
    expect(DEFAULT_ALLOW_COMMANDS).toContain('tasks.search');
  });

  it('allow-lists every mutating capability the registry exposes', () => {
    // Mutating commands MUST be allow-listed or the gateway silently refuses
    // them (the hardcoded platform allowlist excludes "dangerous" commands).
    const mutating = IOS_NODE_COMMANDS.filter((cmd) =>
      /\.(add|create|update|delete)$/.test(cmd),
    );
    const allowed = new Set<string>(DEFAULT_ALLOW_COMMANDS);
    const missing = mutating.filter((cmd) => !allowed.has(cmd));
    expect(missing).toEqual([]);
  });

  it('has no duplicate allowlist entries', () => {
    expect(DEFAULT_ALLOW_COMMANDS.length).toBe(new Set(DEFAULT_ALLOW_COMMANDS).size);
  });

  it('emits the allowlist verbatim in the config patch', () => {
    const patch = buildGatewayConfigPatch() as {
      gateway: { nodes: { allowCommands: string[] } };
    };
    expect(patch.gateway.nodes.allowCommands).toEqual([...DEFAULT_ALLOW_COMMANDS]);
  });
});

/**
 * Enabling the browser plugin is not enough to make it usable: upstream's navigation
 * guard blocks every hostname URL unless an allowlist is set (verified live — see
 * DEFAULT_BROWSER_HOSTNAME_ALLOWLIST). These pin both halves: the browser can reach the
 * hosts our connect flows need, and it still cannot reach private/internal ranges.
 */
describe('buildGatewayConfigPatch — browser navigation policy', () => {
  type BrowserPatch = {
    browser?: {
      enabled?: boolean;
      noSandbox?: boolean;
      headless?: boolean;
      // Both gates, mirroring the config: #1008 asserted `allowedHostnames` here without
      // widening this type, which `tsc` rejects — and since vitest strips types rather than
      // checking them, the test passed while `npm run build` (tsc && …) failed. That broke
      // every staging deploy until it was spotted.
      ssrfPolicy?: {
        // Deliberately never emitted (see the test): the wrapper strips the stale flag on boot.
        dangerouslyAllowPrivateNetwork?: boolean;
        hostnameAllowlist?: string[];
        allowedHostnames?: string[];
      };
    };
  };

  const freshPatch = () => buildGatewayConfigPatch({ initializeBrowserPolicy: true }) as BrowserPatch;

  it('runs Chromium headless (Fly machines have no X server)', () => {
    // Upstream defaults headless to false; without this Chromium exits with
    // "Missing X server or $DISPLAY" and the browser never starts.
    const { browser } = buildGatewayConfigPatch() as BrowserPatch;
    expect(browser?.headless).toBe(true);
  });

  it('disables the Chromium sandbox (the gateway image runs as root)', () => {
    // Without this Chromium refuses to launch at all: "Running as root without
    // --no-sandbox is not supported" → "Failed to start Chrome CDP". Acceptable because
    // each user has a dedicated Fly VM; see the note on the patch.
    const { browser } = buildGatewayConfigPatch() as BrowserPatch;
    expect(browser?.noSandbox).toBe(true);
  });

  it('initializes a fresh gateway with an empty allowlist (empty = allow any public host)', () => {
    // Broad browsing is the goal — Notion, Google, docs, dashboards. A non-empty
    // hostnameAllowlist blocks everything not in it (what made Notion fail).
    // An empty allowlist matches every public host. Only creation opts into this value;
    // reconciliation must preserve the user's existing restriction choices.
    const { browser } = freshPatch();
    expect(browser?.enabled).toBe(true);
    expect(browser?.ssrfPolicy?.hostnameAllowlist).toEqual([]);
  });

  it('omits the entire user-owned SSRF policy during reconciliation', () => {
    const { browser } = buildGatewayConfigPatch() as BrowserPatch;
    expect(browser?.ssrfPolicy).toBeUndefined();
  });

  it('NEVER emits dangerouslyAllowPrivateNetwork — not false, not true, and CRUCIALLY not null', () => {
    // The STRICT flag (=== false) is what blocked Notion. We must not emit ANY value for it:
    //   • false → keeps STRICT mode, re-blocks public browsing (the regression this undoes);
    //   • true  → opens the private network to an injected page (never);
    //   • null  → would crash-loop any gateway still on the OLD wrapper image, whose merge
    //             writes the literal null into config and z.boolean().optional() rejects it.
    // So the key is simply ABSENT from the fresh patch. Existing gateways keep their complete
    // user-owned policy across boot and reconciliation; deleting a value requires an intentional
    // RFC 7386 user patch. `in` distinguishes "absent" from "present-but-undefined": the key must
    // not appear at all.
    const policy = (freshPatch().browser?.ssrfPolicy ?? {}) as Record<string, unknown>;
    expect('dangerouslyAllowPrivateNetwork' in policy).toBe(false);
  });

  it('keeps loopback reachable so the gateway can attach to its own Chromium', () => {
    // allowedHostnames exempts loopback from the private-network check the CDP probe runs
    // (resolvePinnedHostnameWithPolicy("127.0.0.1")). Without it, attachOnly fails with
    // "profile 'openclaw' is not running" while Chromium is serving /json/version. It also
    // keeps the resolved policy object non-empty so isChromeReachable actually runs.
    const { browser } = freshPatch();
    for (const host of ['127.0.0.1', 'localhost']) {
      expect(browser?.ssrfPolicy?.allowedHostnames).toContain(host);
    }
  });

  it('exempts ONLY loopback from private-network checks — no other private/metadata targets', () => {
    // allowedHostnames is an exact-match escape; it must stay exactly loopback so the
    // exemption can never be widened into a path to Fly 6PN or cloud metadata.
    const LOOPBACK = new Set(['127.0.0.1', 'localhost']);
    const entries = freshPatch().browser?.ssrfPolicy
      ?.allowedHostnames ?? [];
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.every((h) => LOOPBACK.has(h))).toBe(true);
  });
});

// The cron→runRoutine loop's secret handshake: the gateway-side `cron.webhookToken`
// (provisioned here) must equal the backend's `ROUTINE_WEBHOOK_SECRET` (checked by
// internal-routines.routes.ts). This proves the gateway end is fed from that same env.

describe('buildGatewayConfigPatch — cron.webhookToken handshake', () => {
  const prev = process.env.ROUTINE_WEBHOOK_SECRET;

  beforeEach(() => {
    delete process.env.ROUTINE_WEBHOOK_SECRET;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.ROUTINE_WEBHOOK_SECRET;
    else process.env.ROUTINE_WEBHOOK_SECRET = prev;
  });

  it('provisions cron.webhookToken from ROUTINE_WEBHOOK_SECRET (same value both ends)', () => {
    process.env.ROUTINE_WEBHOOK_SECRET = 'shared-routine-secret';
    const patch = buildGatewayConfigPatch() as { cron?: { webhookToken?: string } };
    expect(patch.cron).toEqual({ webhookToken: 'shared-routine-secret' });
  });

  it('omits cron entirely when ROUTINE_WEBHOOK_SECRET is unset (no empty token pushed)', () => {
    const patch = buildGatewayConfigPatch() as { cron?: unknown };
    expect(patch.cron).toBeUndefined();
  });
});

// Managed default = MiniMax M2.7 routed THROUGH GMI MaaS (provider consolidation).
// M2.7 is the GMI-served id (M2.1/M2.5 return HTTP 400 Invalid model name — see
// gateway-defaults.ts note). The default model must be a gmi/… ref carrying GMI's
// exact accepted MiniMax id, and —
// because gmi is NOT a bundled provider — the patch must also declare the custom
// provider (base URL + key + MiniMax model def) whenever GMI_API_KEY is present.

describe('buildGatewayConfigPatch — GMI managed provider', () => {
  const prev = process.env.GMI_API_KEY;

  beforeEach(() => {
    delete process.env.GMI_API_KEY;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.GMI_API_KEY;
    else process.env.GMI_API_KEY = prev;
  });

  it('defaults the primary model to MiniMax M2.7 via the gmi provider', () => {
    expect(DEFAULT_PRIMARY_MODEL).toBe(`${GMI_PROVIDER_ID}/${GMI_MINIMAX_MODEL_ID}`);
    expect(DEFAULT_PRIMARY_MODEL).toBe('gmi/MiniMaxAI/MiniMax-M2.7');
  });

  it('registers gmi as an OpenAI-compatible provider (baseUrl + key + MiniMax model) when GMI_API_KEY is set', () => {
    process.env.GMI_API_KEY = 'gmi-org-key';
    const patch = buildGatewayConfigPatch() as {
      models?: {
        mode?: string;
        providers?: Record<string, {
          baseUrl?: string;
          api?: string;
          apiKey?: string;
          models?: Array<{ id?: string; name?: string; reasoning?: boolean }>;
        }>;
      };
    };
    const gmi = patch.models?.providers?.[GMI_PROVIDER_ID];
    expect(patch.models?.mode).toBe('merge');
    expect(gmi?.baseUrl).toBe(GMI_BASE_URL);
    expect(gmi?.api).toBe('openai-completions');
    expect(gmi?.apiKey).toBe('gmi-org-key');
    expect(gmi?.models?.[0]?.name).toBe('MiniMax M2.7');
    expect(gmi?.models?.[0]?.name).not.toContain('GMI MaaS');
    // The default model's id (after the gmi/ prefix) must be declared in the
    // provider's models[], or the gmi/MiniMaxAI/MiniMax-M2.7 ref won't resolve.
    expect(gmi?.models?.[0]?.id).toBe(GMI_MINIMAX_MODEL_ID);
    expect(gmi?.models?.[0]?.reasoning).toBe(true);
    expect(`${GMI_PROVIDER_ID}/${gmi?.models?.[0]?.id}`).toBe(DEFAULT_PRIMARY_MODEL);
  });

  it('omits the models/providers block when GMI_API_KEY is unset (no empty-key provider)', () => {
    const patch = buildGatewayConfigPatch() as { models?: unknown };
    expect(patch.models).toBeUndefined();
  });
});

describe('buildGatewayConfigPatch — canonical managed Talk provider', () => {
  const previousApiKey = process.env.ELEVENLABS_API_KEY;

  beforeEach(() => {
    delete process.env.ELEVENLABS_API_KEY;
  });

  afterEach(() => {
    if (previousApiKey === undefined) delete process.env.ELEVENLABS_API_KEY;
    else process.env.ELEVENLABS_API_KEY = previousApiKey;
  });

  it('emits the strict nested provider shape used by every full gateway patch', () => {
    process.env.ELEVENLABS_API_KEY = 'managed-elevenlabs-key';
    const { talk } = buildGatewayConfigPatch({ includeTalkDefaults: true }) as {
      talk?: {
        provider?: string;
        providers?: Record<string, {
          apiKey?: string;
          voiceId?: string;
          modelId?: string;
        }>;
      };
    };

    expect(talk?.provider).toBe(DEFAULT_TALK_PROVIDER_ID);
    expect(talk?.providers?.[DEFAULT_TALK_PROVIDER_ID]).toEqual({
      apiKey: 'managed-elevenlabs-key',
      voiceId: DEFAULT_ELEVENLABS_VOICE_ID,
      modelId: DEFAULT_ELEVENLABS_MODEL_ID,
    });
  });

  it('never re-emits the rejected legacy flat Talk keys', () => {
    const { talk } = buildGatewayConfigPatch() as { talk?: Record<string, unknown> };

    expect(Object.keys(talk ?? {}).sort()).toEqual(['provider', 'providers']);
    expect(talk).not.toHaveProperty('apiKey');
    expect(talk).not.toHaveProperty('voiceId');
    expect(talk).not.toHaveProperty('modelId');
  });

  it('does not overwrite a user-selected voice or model during repair/bulk reconciliation', () => {
    process.env.ELEVENLABS_API_KEY = 'rotated-managed-key';
    const { talk } = buildGatewayConfigPatch() as {
      talk?: { providers?: Record<string, Record<string, unknown>> };
    };

    expect(talk?.providers?.[DEFAULT_TALK_PROVIDER_ID]).toEqual({
      apiKey: 'rotated-managed-key',
    });
  });

  it('keeps the provider selection canonical without erasing a stored key when the secret is unavailable', () => {
    const { talk } = buildGatewayConfigPatch() as {
      talk?: { provider?: string; providers?: Record<string, { apiKey?: string }> };
    };

    expect(talk?.provider).toBe(DEFAULT_TALK_PROVIDER_ID);
    expect(talk?.providers?.[DEFAULT_TALK_PROVIDER_ID]).toEqual({});
  });

  it('omits the entire Talk branch from broad managed gateway reconfiguration', () => {
    process.env.ELEVENLABS_API_KEY = 'must-not-enter-the-broad-patch';

    const patch = buildManagedGatewayReconfigurePatch();

    expect(patch).not.toHaveProperty('talk');
    expect(patch).toHaveProperty('gateway.nodes.allowCommands');
  });
});

/**
 * THE CONTRACT TEST — the guard that was missing on 2026-07-16.
 *
 * I added `browser.localLaunchTimeoutMs` / `localCdpReadyTimeoutMs` to the patch after
 * verifying them in the `openclaw/` submodule. The submodule is not what runs: the hosted
 * gateway image (operated separately) pins its own OpenClaw ref, whose browser schema is
 * `.strict()` and predates those keys. An unknown key is not ignored — the gateway prints
 * "Config invalid" and exits code=1, so every patched gateway crash-looped. And because
 * /setup/api/reconfigure deep-MERGES, a config patch can never remove a key, so reverting
 * the code could not heal them; recovery took `openclaw doctor --fix` on the machine.
 *
 * So: every key we emit must be one the DEPLOYED build accepts. The accepted set is
 * derived from the pinned ref's real schema and checked in as
 * `gateway-schema-contract.json`, because CI does not check out the submodule.
 */
describe('buildGatewayConfigPatch — deployed gateway schema contract', () => {
  it('emits no browser key the deployed build would reject', () => {
    const { browser } = buildGatewayConfigPatch() as { browser?: Record<string, unknown> };
    const accepted = new Set<string>(schemaContract.accepts.browser);
    const rejected = Object.keys(browser ?? {}).filter((k) => !accepted.has(k));
    // A single unknown key here = "Config invalid" = gateway exits code=1 = crash-loop.
    expect(rejected).toEqual([]);
  });

  /**
   * The same drift can bite ANY section, not just browser — the outage happened to land
   * there first. Each entry maps a section of the emitted patch to the contract extracted
   * from the deployed build.
   */
  it.each([
    ['gateway', (p: Record<string, any>) => p.gateway],
    ['cron', (p: Record<string, any>) => p.cron],
    ['hooks', (p: Record<string, any>) => p.hooks],
    ['plugins', (p: Record<string, any>) => p.plugins],
    ['talk', (p: Record<string, any>) => p.talk],
    // (agents.defaults.llm removed at the 5.10-beta bump — we no longer emit under it; the block
    // early-returned as a no-op, so it's dropped rather than left as a dead row.)
  ])('emits no %s key the deployed build would reject', (section, pick) => {
    const emitted = pick(buildGatewayConfigPatch() as Record<string, any>);
    if (!emitted) return; // section not emitted in this env (e.g. cron needs a secret)
    const accepted = new Set<string>(
      (schemaContract.accepts as Record<string, string[]>)[section] ?? [],
    );
    expect(accepted.size).toBeGreaterThan(0); // a missing contract section must not pass vacuously
    expect(Object.keys(emitted).filter((k) => !accepted.has(k))).toEqual([]);
  });

  it('covers every section the patch actually writes (no silent gaps)', () => {
    // If someone adds a new top-level section to the patch, the contract must grow with it
    // — otherwise that section ships unchecked, which is exactly how #999 happened.
    const patch = buildGatewayConfigPatch() as Record<string, unknown>;
    const covered = new Set(Object.keys(schemaContract.accepts).map((k) => k.split('.')[0]));
    // `models` is a provider block whose schema lives in another file. `agents` joined it at the
    // pinned ref: we now emit only the stable agents.defaults.model.primary (the pinned ref
    // removed the agents.defaults.llm.idleTimeoutSeconds we used to contract-check).
    const knownUncovered = new Set(['models', 'commands', 'tools', 'agents']);
    const uncovered = Object.keys(patch).filter(
      (k) => !covered.has(k) && !knownUncovered.has(k),
    );
    expect(uncovered).toEqual([]);
  });

  it('emits no browser.ssrfPolicy key the deployed build would reject', () => {
    const { browser } = buildGatewayConfigPatch({ initializeBrowserPolicy: true }) as {
      browser?: { ssrfPolicy?: Record<string, unknown> };
    };
    const accepted = new Set<string>(schemaContract.accepts['browser.ssrfPolicy']);
    const rejected = Object.keys(browser?.ssrfPolicy ?? {}).filter((k) => !accepted.has(k));
    expect(rejected).toEqual([]);
  });

  it('the #999 keys are now legal at the pinned ref (they were the outage at v2026.4.11)', () => {
    // localLaunchTimeoutMs/localCdpReadyTimeoutMs were ABSENT from the v2026.4.11 browser schema —
    // emitting them crash-looped the fleet (#999). The pinned ref (a99c65a973 / 2026.5.10-beta.1)
    // ADDED them, so the old guard flipped exactly as its comment predicted. We still do NOT emit
    // them (the wrapper pre-warm + attachOnly fix doesn't need them), but the deployed build would
    // no longer reject them if we did.
    const accepted = new Set<string>(schemaContract.accepts.browser);
    expect(accepted.has('localLaunchTimeoutMs')).toBe(true);
    expect(accepted.has('localCdpReadyTimeoutMs')).toBe(true);
  });
});

/**
 * attachOnly is the load-bearing half of the pre-warm fix (#1001): the plugin's launch
 * path waits for CDP with a hardcoded 8s budget it cannot meet on a cold Fly machine, so
 * the wrapper starts Chromium itself and the plugin must ATTACH rather than launch.
 */
describe('buildGatewayConfigPatch — browser attaches to the pre-warmed Chromium', () => {
  it('sets attachOnly so the plugin never runs its 8s launch race', () => {
    const { browser } = buildGatewayConfigPatch() as { browser?: { attachOnly?: boolean } };
    expect(browser?.attachOnly).toBe(true);
  });

  it('does not pin cdpUrl (the plugin derives loopback; an explicit URL risks isRemote)', () => {
    const { browser } = buildGatewayConfigPatch() as { browser?: { cdpUrl?: string } };
    expect(browser?.cdpUrl).toBeUndefined();
  });

  it('attachOnly is a key the deployed build accepts', () => {
    // Belt-and-braces against the #999 class of bug: this fix leans on attachOnly, so
    // assert the pinned build actually knows it.
    expect(new Set<string>(schemaContract.accepts.browser).has('attachOnly')).toBe(true);
  });
});

/**
 * The gateway must be able to reach its OWN browser. The plugin probes its CDP endpoint
 * through this same ssrfPolicy (isChromeReachable → assertCdpEndpointAllowed →
 * resolvePinnedHostnameWithPolicy), so turning the policy on without an exact-match
 * loopback escape makes the gateway block itself: "attachOnly is enabled and profile
 * 'openclaw' is not running" while Chromium is demonstrably serving /json/version.
 */
describe('buildGatewayConfigPatch — the gateway can reach its own CDP endpoint', () => {
  type P = {
    browser?: {
      ssrfPolicy?: {
        allowedHostnames?: string[];
        hostnameAllowlist?: string[];
        dangerouslyAllowPrivateNetwork?: boolean;
      };
    };
  };

  it('exact-match allows loopback so the CDP probe is not blocked by our own policy', () => {
    const { browser } = buildGatewayConfigPatch({ initializeBrowserPolicy: true }) as P;
    expect(browser?.ssrfPolicy?.allowedHostnames).toContain('127.0.0.1');
  });

  it('still does NOT re-open the private network wholesale', () => {
    // The loopback escape must stay exact-match — not a blanket private-network opening.
    // The strict flag is not emitted at all (the wrapper strips the stale one on boot); the
    // invariant is only that it is never `true` (which would open the private network).
    const { browser } = buildGatewayConfigPatch({ initializeBrowserPolicy: true }) as P;
    expect(browser?.ssrfPolicy?.dangerouslyAllowPrivateNetwork).not.toBe(true);
    const allowed = browser?.ssrfPolicy?.allowedHostnames ?? [];
    // Fly 6PN + cloud metadata must never appear here.
    expect(allowed.some((h) => /^fdaa|169\.254|metadata/i.test(h))).toBe(false);
    expect(allowed.length).toBeLessThanOrEqual(2);
  });

  it('allowedHostnames is a key the deployed build accepts', () => {
    expect(new Set<string>(schemaContract.accepts['browser.ssrfPolicy']).has('allowedHostnames')).toBe(
      true,
    );
  });
});

/**
 * The LLM idle watchdog USED to be configurable (agents.defaults.llm.idleTimeoutSeconds), which we
 * set to 300s for the slow GMI/MiniMax-M2.7 reasoning model that aborted at the 120s default under
 * congestion. The pinned ref (a99c65a973 / 2026.5.10-beta.1) REMOVED that key — the strict
 * agents.defaults.llm schema now holds only model-override options, so emitting idleTimeoutSeconds
 * would be an unknown key → "Config invalid" → gateway crash-loop. The idle timeout is now derived
 * and capped at the 120s default. This locks in that we no longer emit the crash-looping key.
 */
describe('buildGatewayConfigPatch — LLM idle watchdog is no longer configurable at the pinned ref', () => {
  type P = { agents?: { defaults?: { llm?: { idleTimeoutSeconds?: number } } } };

  it('does NOT emit agents.defaults.llm.idleTimeoutSeconds (removed upstream → would crash-loop)', () => {
    const { agents } = buildGatewayConfigPatch() as P;
    expect(agents?.defaults?.llm?.idleTimeoutSeconds).toBeUndefined();
  });

  it('still sets the managed model alongside it (no clobbering agents.defaults)', () => {
    // agents.defaults is a deepMerge target — adding llm must not drop model.primary.
    const patch = buildGatewayConfigPatch() as {
      agents?: { defaults?: { model?: { primary?: string } } };
    };
    expect(patch.agents?.defaults?.model?.primary).toBe(DEFAULT_PRIMARY_MODEL);
  });
});
