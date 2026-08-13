/**
 * Shared gateway config defaults.
 * Single source of truth for values used by the managed deploy and fleet config-patch pipelines.
 */

// ─── Managed default model + provider ───────────────────────────────────────
//
// PROVIDER CONSOLIDATION: managed users run MiniMax on GMI's MaaS endpoint
// (https://api.gmi-serving.com/v1) instead of MiniMax's own API. GMI is our
// metered billing chokepoint (per-token usage now, billing to be layered on
// later), so consolidating the managed brain onto GMI is the point.
//
// The default is `gmi/MiniMaxAI/MiniMax-M2.7` — provider `gmi`, GMI's exact
// chat-endpoint model id `MiniMaxAI/MiniMax-M2.7`.
//
// HISTORY / WHY M2.7 (2026-07-01): the previous default `MiniMaxAI/MiniMax-M2.1`
// was NOT actually served by GMI — every managed chat run failed with
// `HTTP 400: Invalid model name: MiniMaxAI/MiniMax-M2.1`, which the gateway
// classified as `decision=surface_error reason=model_not_found`. The old comment
// claimed the id was "verified against GMI's live model list"; it was not. GMI
// had superseded M2.1. Verified 2026-07-01 by querying GMI directly:
//   • GET  https://api.gmi-serving.com/v1/models      → catalog lists M2.5/M2.7/M3
//   • POST https://api.gmi-serving.com/v1/chat/completions with each candidate:
//       - `MiniMaxAI/MiniMax-M2.1` → 400 Invalid model name (the outage)
//       - `MiniMaxAI/MiniMax-M2.5` → 400 Invalid model name (LISTED but NOT served
//         on the chat endpoint — /v1/models is not authoritative)
//       - `MiniMaxAI/MiniMax-M2.7` → 200, finish_reason=stop, real content, and a
//         reasoning_content field (reasoning model, matches the def below) ✓
//       - `MiniMaxAI/MiniMax-M3`   → 200 but non-reasoning (would mismatch
//         `reasoning: true`), so not chosen.
// M2.7 is the closest stable in-family successor to M2.1 and the id GMI actually
// accepts. To change models, re-run the /v1/chat/completions probe above — do NOT
// trust /v1/models alone.
//
// Why an explicit provider block (not just a `gmi/` model id): `gmi` is NOT a
// bundled OpenClaw provider (unlike `minimax`, keyed off MINIMAX_API_KEY at
// openclaw/src/secrets/provider-env-vars.ts:27), so the `gmi/` prefix would not
// resolve to a base URL or key on its own. We declare GMI as a custom
// OpenAI-compatible provider in the config patch (base URL + org GMI_API_KEY +
// the MiniMax model def). The model def mirrors how OpenAI-compatible providers
// ship MiniMax M2.x upstream (openclaw/extensions/deepinfra/openclaw.plugin.json:88-102:
// reasoning=true, 196608 ctx, compat.supportsUsageInStreaming) so reasoning
// output is handled correctly rather than leaking think tags.
//
// BYOK unaffected: a user's own auth profile (created at onboard) and their own
// provider stay intact; `models.mode` defaults to "merge" upstream so built-in
// providers are preserved (see buildGatewayConfigPatch below).
//
// REVERSIBLE: to roll back to MiniMax-via-its-own-provider, set
// DEFAULT_PRIMARY_MODEL back to 'minimax/MiniMax-M2.1'. The GMI provider block
// then goes inert (nothing references the gmi/ prefix) and can stay or be removed
// independently.
export const GMI_PROVIDER_ID = 'gmi';
export const GMI_BASE_URL = 'https://api.gmi-serving.com/v1';
// GMI's exact model id for MiniMax, sent verbatim as the OpenAI `model` param.
// Confirmed accepted by GMI's /v1/chat/completions endpoint 2026-07-01 (M2.1 and
// M2.5 both return HTTP 400 Invalid model name; see the note above).
export const GMI_MINIMAX_MODEL_ID = 'MiniMaxAI/MiniMax-M2.7';
export const DEFAULT_PRIMARY_MODEL = `${GMI_PROVIDER_ID}/${GMI_MINIMAX_MODEL_ID}`;

export const DEFAULT_TALK_PROVIDER_ID = 'elevenlabs';
export const DEFAULT_ELEVENLABS_VOICE_ID = 'k7KSpqhTjZbrCkUR76Ip';
export const DEFAULT_ELEVENLABS_MODEL_ID = 'eleven_v3';

/**
 * Commands the iOS Rem node actually implements. This MUST mirror the Swift
 * handler registry (`NodeInvocationRouter`, the single source of truth that
 * drives what the device advertises at connect). Kept here so the backend
 * allowlist below can be guarded against drift — see gateway-defaults.test.ts
 * (R1 / #810). `system.run` is the gateway's dispatch wrapper (v2026.4.9+).
 */
export const IOS_NODE_COMMANDS = [
  'calendar.events',
  'calendar.add',
  'calendar.update',
  'calendar.delete',
  'reminders.list',
  'reminders.add',
  'reminders.update',
  'reminders.delete',
  'device.status',
  'device.info',
  'tasks.list',
  'tasks.get',
  'tasks.search',
  'tasks.create',
  'tasks.update',
  'tasks.delete',
  'lists.list',
  'lists.create',
  'folders.list',
  'folders.create',
  'system.notify',
  'system.which',
  'system.run',
] as const;

// NOTE: `contacts.add` was removed (2026-06-27, #810): iOS has no contacts
// handler in `NodeInvocationRouter`, so allow-listing it only advertised a
// command the device can't run. Every entry here must exist in
// IOS_NODE_COMMANDS (enforced by gateway-defaults.test.ts).
export const DEFAULT_ALLOW_COMMANDS = [
  'calendar.add',
  'calendar.update',
  'calendar.delete',
  'reminders.add',
  'reminders.update',
  'reminders.delete',
  'tasks.list',
  'tasks.get',
  // Read-only name→task resolution. Explicitly allow-listed because `tasks.*` is a
  // Rem-specific family that upstream's hardcoded platform policy does not know, so
  // even reads need listing here. Without it the agent can be handed a task name (the
  // only identifier that survives into brief prose) with no way to look it up.
  'tasks.search',
  'tasks.create',
  'tasks.update',
  'tasks.delete',
  'lists.list',
  'lists.create',
  'folders.list',
  'folders.create',
  'system.which',
  'system.run',
] as const;

// NOTE: the cloud browser now ships an OPEN posture (reach any public host; private
// network blocked) — see the browser.ssrfPolicy block below. We deliberately removed the
// old curated DEFAULT_BROWSER_HOSTNAME_ALLOWLIST (whatsapp/discord/github/…): a non-empty
// hostnameAllowlist blocks everything not in it, which made the browser unable to open
// Notion and most sites. The connect flows' hosts (WhatsApp/Discord/GitHub) are public, so
// they remain reachable under the open posture. A future opt-in "limit the browser to
// these sites" setting can reintroduce a curated list PER-USER as a tightening.

/**
 * Builds the standard gateway config patch applied to new and existing gateways.
 * Fresh onboarding opts into provider-owned Talk defaults and the initial browser policy;
 * reconciliation leaves every user-owned browser policy field intact.
 */
export function buildGatewayConfigPatch(
  overrides?: {
    model?: string;
    includeTalkDefaults?: boolean;
    includeTalkConfiguration?: boolean;
    initializeBrowserPolicy?: boolean;
  },
): Record<string, unknown> {
  const talkApiKey = process.env.ELEVENLABS_API_KEY?.trim();
  const patch: Record<string, unknown> = {
    agents: {
      defaults: {
        model: { primary: overrides?.model ?? DEFAULT_PRIMARY_MODEL },
        // NOTE — the LLM idle watchdog is NO LONGER configurable at the pinned ref.
        // Historically we set `agents.defaults.llm.idleTimeoutSeconds: 300` because upstream's
        // 120s default aborted healthy turns from the slow GMI/MiniMax-M2.7 reasoning model under
        // congestion ("[llm-idle-timeout] … produced no reply before the idle watchdog"). By the
        // pinned OpenClaw (a99c65a973 / 2026.5.10-beta.1) that key was REMOVED — the strict
        // `agents.defaults.llm` schema now holds only model-override options, so emitting
        // idleTimeoutSeconds would be an unknown key → "Config invalid" → gateway crash-loop.
        // The idle timeout is now derived by resolveLlmIdleTimeoutMs (llm-idle-timeout.ts) and
        // CAPPED at the 120s DEFAULT_LLM_IDLE_TIMEOUT_SECONDS (agents.defaults.timeoutSeconds only
        // clamps it DOWN), so 300s is no longer expressible. Kept acceptable by the fact that the
        // watchdog resets on EVERY stream event and MiniMax-M2.7 streams reasoning_content deltas
        // continuously, so a healthy turn rarely sees 120s of true silence; the residual risk is a
        // congestion-time abort. Runtime-bump follow-up: add a per-model request-timeout knob if
        // canary device-validation shows aborts.
      },
    },
    // Forbid the agent from restarting / reconfiguring the gateway from a chat turn (#956). The
    // agent was calling the `gateway` tool's `restart` action mid-conversation and bouncing the
    // gateway DURING the WhatsApp `whatsapp_login` handshake (~30-60s), so the link aborted with
    // "cannot link new device right now, try again later" and the session logged out. REMCLAW.md
    // already tells the agent never to restart, but guidance was ignored.
    //
    // Two layers, because the flag alone is insufficient on the deployed image:
    //   1. `commands.restart: false` — `isRestartEnabled` (openclaw config/commands.flags.ts) gates
    //      the restart *action* on this. BUT the unified `gateway` tool also exposes `config.patch`,
    //      and on the pinned image (OPENCLAW_GIT_REF=v2026.4.9) the agent-config-write guard only
    //      blocks `tools.exec.*` — so the agent could `config.patch` this flag back to true and
    //      restart again, reopening the race.
    //   2. `tools.deny: ["gateway"]` — remove the entire `gateway` tool from the agent's toolset
    //      (denylist > allowlist, openclaw src/agents/openclaw-tools.ts:332). With no `gateway`
    //      tool the agent can neither `restart` NOR `config.patch`, so it can't undo layer 1. This
    //      matches the REMCLAW rule that gateway lifecycle/config is operator-only, never chat.
    // Legitimate restarts remain operator-controlled: the hosted gateway image's kill+respawn on
    // config-patch/onboarding (operated separately) and image redeploys do NOT go
    // through the agent tool and are unaffected.
    commands: { restart: false },
    tools: { deny: ["gateway"] },
    gateway: {
      nodes: { allowCommands: [...DEFAULT_ALLOW_COMMANDS] },
      controlUi: {
        dangerouslyDisableDeviceAuth: true,
        dangerouslyAllowHostHeaderOriginFallback: true,
      },
      // Raise the chat.history per-text-block cap from the 8_000-char default
      // (openclaw src/gateway/chat-display-projection.ts DEFAULT_CHAT_HISTORY_TEXT_MAX_CHARS).
      // Agent tool results can carry large inline `data:image/...;base64,…` images — the
      // whatsapp_login pairing QR is ~12 KB on a single line — and the default truncates them
      // mid-base64 with `...(truncated)...`, so the image markdown loses its closing `)` and no
      // client can render the QR (it arrives as broken text). A generous cap keeps such
      // image-bearing tool results intact end-to-end. Pairs with the client renderer that shows
      // inline tool-result images (Shared/Views/Chat/ToolResultCards/ToolResultCardView.swift).
      webchat: { chatHistoryMaxChars: 200_000 },
    },
    hooks: { internal: { enabled: true } },
    // Pre-enable the plugins we ship so they load on gateway boot, via the
    // per-entry `plugins.entries.<id>.enabled: true` shape. That branch activates
    // a plugin regardless of origin (openclaw src/plugins/config-activation-
    // shared.ts:253, cause "enabled-by-effective-config"). We deliberately do NOT
    // use `plugins.allow`: a non-empty `allow` list is treated as an EXCLUSIVE
    // allowlist (…:226, cause "not-in-allowlist") and would disable every other
    // bundled plugin. The per-entry form is additive. The gateway's plugin-
    // sanitizer keeps these entries because each id resolves under
    // /openclaw/extensions, and every extension is built into the hosted gateway
    // image (operated separately), so enabling them can't
    // fail on missing runtime deps (baileys etc.).
    //
    //   • browser  — headless-Chromium web automation. `enabledByDefault: true`
    //     upstream (extensions/browser/openclaw.plugin.json); this is a
    //     belt-and-suspenders enable.
    //
    //   • whatsapp / discord — channel plugins. Both ship
    //     `activation.onStartup: false` (extensions/{whatsapp,discord}/
    //     openclaw.plugin.json), so WITHOUT this they do NOT load and the in-chat
    //     login tool (`whatsapp_login`) is absent. When a user asked to connect
    //     WhatsApp, the agent then tried to enable the plugin + restart the
    //     gateway via `systemctl --user` — which does not exist in our hosted
    //     runtime (the gateway image, operated separately, runs the gateway as a
    //     child process, not under systemd) — and the flow hung/timed out before
    //     ever showing a QR. Pre-enabling here means the plugin is already loaded,
    //     so connecting only needs the agent to call `whatsapp_login` (QR) — no
    //     agent-driven restart. Existing gateways need a re-patch to pick this up.
    plugins: {
      entries: {
        browser: { enabled: true },
        whatsapp: { enabled: true },
        discord: { enabled: true },
        // ── Metering: per-turn LLM usage reporting (PR2) ──────────────────────
        //
        // First-party Rem extension vendored into the hosted gateway image
        // (operated separately; the billing extension is compiled into the
        // openclaw workspace by the image build). It registers OpenClaw's `llm_output` plugin
        // hook — the only signal that carries token usage — and POSTs each
        // turn's usage to /api/v1/usage/record (idempotent via event_id=runId,
        // PR1 #966) so managed GMI chat is metered. Best-effort: a failed report
        // never blocks the chat turn (durable JSONL spool + periodic retry).
        //
        // Enabled via the additive per-entry form (NOT plugins.allow, which is
        // exclusive — see the browser/whatsapp note above). Existing gateways
        // need a re-patch AND an image redeploy to pick this up: the plugin only
        // exists in images built after this change (gateway IMAGE rebuild
        // required — the hook compiles into the openclaw dist).
        'remclaw-billing': { enabled: true },
        // ── Memory Lane D: native OpenClaw memory (see docs/rebuild/31-MEMORY-LANE-D.md) ──
        //
        // We adopt OpenClaw's own two-layer memory instead of Rem's scheduled
        // "memory keeper" chat (backend/src/scripts/extract-memories.ts), which
        // reinvented consolidation by opening a `rem-memory-<date>` chat and
        // string-parsing durable facts. The native path is the upstream-blessed
        // mechanism (CLAUDE.md principle 1 — mirror upstream).
        //
        //   Layer 1 — DREAMING (memory-core): a background consolidation sweep
        //   that promotes only high-signal short-term material into MEMORY.md,
        //   gated on score/recall/query-diversity, with reviewable DREAMS.md
        //   output. Opt-in upstream (disabled by default), so we enable it here.
        //   Config shape + default cadence mirror openclaw/docs/concepts/dreaming.md
        //   (`plugins.entries.memory-core.config.dreaming`, frequency `0 3 * * *`,
        //   model = runtime default). We pin frequency + timezone explicitly so
        //   the managed cron cadence is deterministic across the fleet rather than
        //   relying on the upstream default drifting.
        //
        //   NOTE: dreaming's managed cron only fires when the default agent
        //   heartbeat is enabled and its target is not `none` (docs/concepts/
        //   dreaming.md — "Dreaming never runs: status shows blocked"). Verify
        //   heartbeat on the dev gateway before claiming dreaming is live.
        // DREAMING DISABLED (founder decision, #1075). The dreaming cron emits
        // poetic first-person "diary" entries (DREAMS.md) into a chat — e.g. a
        // 3am "Light sleep… Openclaw dreaming…" monologue — which read as
        // confusing noise, not memory the user asked for. Rem's memory model is
        // tasks + chats + the structured memory-wiki layer below, not a poetic
        // consolidation diary. memory-core still provides recall; only the
        // dreaming promotion/diary is off. Reversible: flip `enabled` back true.
        // NOTE: existing gateways keep their current config until re-patched —
        // this only changes newly-provisioned/patched gateways.
        'memory-core': {
          config: {
            dreaming: {
              enabled: false,
              frequency: '0 3 * * *',
              timezone: 'UTC',
            },
          },
        },
        //   Layer 2 — MEMORY-WIKI in BRIDGE mode: a provenance-rich knowledge
        //   layer *beside* memory-core (it does not replace recall/promotion/
        //   dreaming). Bridge mode reads the active memory plugin's PUBLIC
        //   artifacts through documented SDK seams — no private-internals access —
        //   and compiles them into a wiki vault with structured claims + evidence,
        //   contradiction/freshness/low-confidence dashboards, and the `wiki.*`
        //   Gateway RPC (wiki.search/wiki.get/…). This provenance layer is the
        //   differentiator over a plain MEMORY.md.
        //
        //   Config keys mirror openclaw/extensions/memory-wiki/README.md +
        //   docs/plugins/memory-wiki.md verbatim (vaultMode:"bridge",
        //   bridge.{enabled,readMemoryArtifacts,indexDreamReports,indexDailyNotes,
        //   indexMemoryRoot,followMemoryEvents}, render.{createDashboards,
        //   createBacklinks}). search.corpus:"all" so a single memory_search spans
        //   both the memory-core recall layer and the compiled wiki. We leave
        //   context.includeCompiledDigestPrompt at its upstream default (false) so
        //   prompt shape is unchanged until we intentionally opt in.
        'memory-wiki': {
          enabled: true,
          config: {
            vaultMode: 'bridge',
            // Pin the wiki vault under the gateway's PERSISTED workspace
            // (`OPENCLAW_WORKSPACE_DIR` = /data/workspace, on the Fly/Railway
            // persistent volume — set by the hosted gateway image, operated
            // separately). By default the vault would land at
            // `~/.openclaw/wiki/main` (openclaw/docs/plugins/memory-wiki.md:382),
            // OUTSIDE the volume, so it would (a) not be readable by the existing
            // Settings→Memory endpoints (#949: GET /setup/api/workspace/{list,file}
            // read WORKSPACE_DIR only) and (b) be dropped by the memory-follows-user
            // snapshot (docs/rebuild/29), which snapshots /data/workspace. Putting
            // the vault under /data/workspace/wiki/main fixes both and survives
            // restarts / image rolls. Shape mirrors the memory-wiki config schema
            // (openclaw/extensions/memory-wiki/openclaw.plugin.json:54-65:
            // `vault: { path, renderMode }`; renderMode enum ["native","obsidian"]).
            // renderMode "native" — no Obsidian dependency on the headless gateway.
            vault: {
              path: '/data/workspace/wiki/main',
              renderMode: 'native',
            },
            bridge: {
              enabled: true,
              readMemoryArtifacts: true,
              indexDreamReports: true,
              indexDailyNotes: true,
              indexMemoryRoot: true,
              followMemoryEvents: true,
            },
            search: {
              backend: 'shared',
              corpus: 'all',
            },
            render: {
              createDashboards: true,
              createBacklinks: true,
            },
          },
        },
      },
    },
    // `plugins.entries.browser.enabled` above only loads the plugin. Fresh creation also
    // initializes the open-public-host posture below so the browser is immediately usable.
    // Existing gateways retain their complete user-owned ssrfPolicy: repair/reconfigure/bulk
    // patches deliberately omit it, including an explicit dangerouslyAllowPrivateNetwork:false.
    browser: {
      enabled: true,
      // Chromium refuses to start its sandbox as root, and our gateway image has no USER
      // directive (the image is operated separately), so the browser died at launch:
      //   "Running as root without --no-sandbox is not supported" (crbug.com/638180)
      //   → "Failed to start Chrome CDP on port 18800 for profile openclaw"
      // Verified live on remclaw-00000000 — this is the wall immediately behind the SSRF
      // one; both must be set or the browser is unusable.
      //
      // Upstream rightly says keep this off where possible (schema.help.ts: "process
      // isolation protections are reduced"). We accept it here because the sandbox is
      // defense-in-depth, not our tenant boundary: every user gets their OWN Fly app +
      // machine (`managedFlyAppNameForDeploy(userId)` → remclaw-{userId[:8]}), i.e. a
      // dedicated Firecracker VM holding only that user's agent and data. A renderer
      // escape reaches that user's own gateway and no one else's, and the SSRF allowlist
      // above already bars the browser from private/internal ranges, so it can't pivot.
      // The stronger fix — run the gateway as a non-root user and keep the sandbox — needs
      // a Dockerfile USER + chown of the existing /data volumes across the fleet; worth
      // doing, but it is a migration, not a config flag.
      noSandbox: true,
      // Upstream defaults `headless` to FALSE (openclaw src/config/types.browser.ts:72), so
      // Chromium tries to open a window and dies on a headless Fly machine:
      //   "Missing X server or $DISPLAY" → "The platform failed to initialize. Exiting."
      // Verified live on remclaw-00000000 — the wall immediately behind noSandbox. The
      // hosted image already describes this as "headless Chromium"; nothing ever set the
      // flag. CDP screenshots/snapshots work headless, so the in-app preview and
      // takeover surfaces are unaffected.
      headless: true,
      // ATTACH, don't launch. The plugin's own launch path waits for CDP with a HARDCODED
      // 8s budget (openclaw@v2026.4.11 CDP_READY_AFTER_LAUNCH_WINDOW_MS = 8000,
      // extensions/browser/src/browser/server-context.availability.ts:130-147). Chromium
      // needs ~15s on a cold shared-cpu-2x Fly machine, so the plugin abandoned a browser
      // that was still coming up and every browser call failed with "not reachable after
      // start" — timed live at 8.06s, cold AND warm. That budget is NOT configurable at
      // this ref (which is exactly why localCdpReadyTimeoutMs isn't in its schema, and why
      // setting it crash-looped the fleet — #999/#1000).
      //
      // So the hosted image owns the browser now: it starts Chromium at gateway boot and keeps
      // it alive (the gateway image, operated separately), and this flag makes
      // the plugin attach to that endpoint. ensureBrowserAvailable short-circuits on a
      // reachable HTTP endpoint BEFORE the launch path (…availability.ts:186-194), so the
      // 8s window never runs and Chromium may take as long as it needs to boot.
      //
      // `cdpUrl` is deliberately NOT set: the plugin already derives
      // http://127.0.0.1:18800 from the gateway port, and pinning an explicit URL risks
      // tripping the isRemote branch. The wrapper defaults to that same port
      // (REMCLAW_BROWSER_CDP_PORT).
      attachOnly: true,
      ...(overrides?.initializeBrowserPolicy ? { ssrfPolicy: {
        // OPEN BROWSING POSTURE. The cloud browser may navigate to ANY PUBLIC host. The
        // product goal is broad browsing (Notion, Google, docs, dashboards); a curated
        // allowlist made the browser useless for that — it couldn't even open Notion.
        // Private/internal/metadata ranges stay BLOCKED: upstream only permits private IPs
        // when dangerouslyAllowPrivateNetwork === true (which we NEVER set); an ABSENT key
        // behaves as "block private" for that gate (src/infra/net/ssrf.ts). Verified against
        // navigation-guard.ts:131-142 tests — `ssrfPolicy: {}` allows public hostnames,
        // `{ …: false }` rejects them (STRICT mode was the real Notion blocker, not the list).
        //
        // This block is emitted ONLY while creating a fresh gateway. Existing-gateway repair,
        // approval recovery, and bulk reconciliation omit the ENTIRE ssrfPolicy object so they
        // cannot overwrite a user's "limit to these sites" choice. hostnameAllowlist: [] means
        // every public host on a new gateway; the settings surface owns subsequent changes.
        // dangerouslyAllowPrivateNetwork is absent on fresh gateways. Existing-gateway patches
        // omit the whole policy, and the wrapper performs no boot migration, so an explicit false
        // (or any future user-owned policy field) survives every repair and restart. We do not send
        // null from defaults: deletion must be an intentional user-owned RFC 7386 patch.
        //
        // allowedHostnames is initialized on fresh gateways: it keeps the resolved policy object
        // non-empty so
        // isChromeReachable still runs its loopback check, and it exempts loopback so the
        // gateway can attach to its OWN Chromium (…→ resolvePinnedHostnameWithPolicy
        // ("127.0.0.1")). Fly 6PN (fdaa::/16) and cloud metadata (169.254.169.254) remain
        // blocked — clearing the allowlist does not touch the private-network gate.
        allowedHostnames: ['127.0.0.1', 'localhost'],
        hostnameAllowlist: [],
      } } : {}),
    },
    // OpenClaw's strict Talk schema selects one provider at `talk.provider` and keeps
    // provider-owned settings under the matching `talk.providers.<id>` entry. The legacy
    // flat `talk.apiKey` / `voiceId` / `modelId` keys are rejected by the deployed runtime;
    // its boot-time doctor removes them, which previously left managed agents with no active
    // speech provider. Fresh onboarding opts into the initial voice/model defaults. Callers that
    // do not own Talk must use buildManagedGatewayReconfigurePatch(), while ownership-aware Talk
    // reconciliation extracts only this branch and narrows it before writing.
    ...(overrides?.includeTalkConfiguration === false ? {} : {
      talk: {
        provider: DEFAULT_TALK_PROVIDER_ID,
        providers: {
          [DEFAULT_TALK_PROVIDER_ID]: {
            ...(talkApiKey ? { apiKey: talkApiKey } : {}),
            ...(overrides?.includeTalkDefaults
              ? {
                  voiceId: DEFAULT_ELEVENLABS_VOICE_ID,
                  modelId: DEFAULT_ELEVENLABS_MODEL_ID,
                }
              : {}),
          },
        },
      },
    }),
  };

  // Cron webhook auth (the routines cron→runRoutine loop). When the gateway's cron
  // scheduler fires a routine job, it POSTs the webhook with
  // `Authorization: Bearer <cfg.cron.webhookToken>` (openclaw
  // src/gateway/server-cron-notifications.ts:68-76, sourced from `cfg.cron?.webhookToken`).
  // The backend's inbound handler (internal-routines.routes.ts) checks that bearer
  // against its own `ROUTINE_WEBHOOK_SECRET`. The two values MUST be identical, so we
  // provision the gateway-side token from the SAME backend env var here — every place
  // that applies this patch (the managed deploy, pre-warm pool, gateway routes, and
  // fleet config-patch pipelines) keeps each gateway's token in lockstep with the
  // backend secret. Omitted when unset so we never push an empty token (the backend
  // fails closed on an unset secret anyway, so an empty gateway token would only 401).
  const webhookToken = process.env.ROUTINE_WEBHOOK_SECRET;
  if (webhookToken) {
    patch.cron = { webhookToken };
  }

  // Register GMI MaaS as an OpenAI-compatible managed model provider so the
  // default model (`gmi/…`, see DEFAULT_PRIMARY_MODEL) resolves to a base URL +
  // key at runtime. Config shape mirrors OpenClaw's ModelsConfig
  // (openclaw/src/config/types.models.ts: `models.providers.<id>` with baseUrl,
  // apiKey, api, models[]). `mode: "merge"` (also the upstream default) keeps the
  // built-in providers that BYOK relies on (anthropic/openai/venice) intact.
  //
  // Keyed off the org GMI_API_KEY (same key backend gmi.service.ts uses), embedded
  // in the patch exactly like `talk.apiKey` above. Omitted when unset so we never
  // push an empty-key provider — in that case a `gmi/…` default won't resolve, so
  // GMI_API_KEY MUST be present in the backend env for the managed default to work.
  const gmiApiKey = process.env.GMI_API_KEY?.trim();
  if (gmiApiKey) {
    patch.models = {
      mode: 'merge',
      providers: {
        [GMI_PROVIDER_ID]: {
          baseUrl: GMI_BASE_URL,
          api: 'openai-completions',
          auth: 'api-key',
          apiKey: gmiApiKey,
          // The 5.10-beta replacement for the removed `agents.defaults.llm.idleTimeoutSeconds`.
          // Upstream's own migration note ("agents.defaults.llm is legacy; use
          // models.providers.<id>.timeoutSeconds for slow model/provider timeouts") — this feeds the
          // model request timeout that resolveLlmIdleTimeoutMs consumes (attempt.ts modelRequestTimeoutMs
          // → llm-idle-timeout.ts), and unlike agents.defaults.timeoutSeconds it can RAISE the idle
          // watchdog above the 120s default. MiniMax-M2.7 is a slow reasoning MaaS whose time-to-first
          // -token under a full REMCLAW.md + tool-schema context can exceed 120s under GMI congestion,
          // which aborted+retried healthy turns; 300s gives them room. See the note in agents.defaults above.
          timeoutSeconds: 300,
          models: [
            {
              id: GMI_MINIMAX_MODEL_ID,
              // User-facing catalog name. Routing/billing provider details stay in diagnostics,
              // not in the model picker or Settings.
              name: 'MiniMax M2.7',
              api: 'openai-completions',
              // Compat mirrors upstream MiniMax M2.x defs on OpenAI-compatible
              // providers (openclaw/extensions/deepinfra/openclaw.plugin.json:88-102):
              // MiniMax M2.x is a reasoning model, 196K context.
              reasoning: true,
              input: ['text'],
              // Cost is USD / million tokens. Left at 0 for now — GMI meters usage
              // server-side and billing is layered on later; the exact GMI MiniMax
              // rate is TBD. 0 only affects local budget accounting, not routing.
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              contextWindow: 196608,
              maxTokens: 196608,
              compat: { supportsUsageInStreaming: true },
            },
          ],
        },
      },
    };
  }

  return patch;
}

/**
 * Broad repair/redeploy configuration intentionally excludes Talk. Provider selection, provider
 * credentials, and voice/model choices have their own fingerprint-aware lifecycle and must be
 * reconciled only after the canonical managed gateway pointer is durable.
 */
export function buildManagedGatewayReconfigurePatch(
  overrides?: { model?: string },
): Record<string, unknown> {
  return buildGatewayConfigPatch({
    ...overrides,
    includeTalkConfiguration: false,
  });
}
