# Local Model Strategy

This note is the product/technical recommendation for issue
[#570](https://github.com/Rem-Assistant/RemClaw/issues/570). It answers whether
Rem should support a free/local model path and how that fits beside paid cloud
gateway value.

## Recommendation

Support local model use as a **local-first adoption lane**, not as the primary
business model and not as a promise that every Rem capability works offline.

The strongest near-term positioning is:

- Free/local Rem: run the Mac app, local OpenClaw gateway, and user-selected
  local or BYOK model where possible, with clear quality and safety caveats.
- Paid Rem: managed cloud gateway, backup/restore of gateway state, cross-device
  reachability when the Mac is off, and smoother recovery/provisioning.
- Hybrid Rem: local Mac for private/local computer control, cloud gateway for
  always-available cloud-safe work.

This strengthens the funnel rather than hurting the business: users can trust
Rem locally before paying, while the subscription remains attached to reliability,
continuity, backup, and managed infrastructure instead of raw model access only.

## Current Evidence

- OpenClaw documents local models as a supported path. Its current local-model
  guidance recommends LM Studio plus a large local model as the lowest-friction
  starting point, with Ollama also supported.
- OpenClaw model provider state is already part of the gateway runtime. Rem's
  Mac troubleshooting doc already tells users to run `openclaw models list`,
  `openclaw models set <provider>`, and restart the gateway when a provider is
  hung or rate-limited.
- OpenCode is not "free because magic." Its local path is provider-based:
  OpenCode supports local providers through OpenAI-compatible endpoints such as
  llama.cpp, LM Studio, and Ollama. Ollama also documents an `ollama launch
  opencode` integration.
- Local models can be private and cheap after setup, but they are more variable
  in quality, latency, context length, function/tool calling, and install
  friction than hosted frontier providers.
- Agent-grade local use is not automatic. High-risk tool use needs a model with
  enough context, reliable instruction following, and prompt-injection
  resistance. Small or aggressively quantized local models may be fine for
  summaries, but should not be treated as safe substitutes for autonomous Mac
  control.

Sources checked:

- <https://docs.openclaw.ai/gateway/local-models>
- <https://dev.opencode.ai/docs/providers/>
- <https://docs.ollama.com/integrations/opencode>
- [docs/MAC_GATEWAY_TROUBLESHOOTING.md](../MAC_GATEWAY_TROUBLESHOOTING.md)

## Product Model

Model choice should not live under Connectors. A model provider is runtime
configuration, closer to Gateway settings:

```text
Settings
  Gateways
    Mac Gateway
      Runtime
        Model Provider
        Provider auth
        Local model server readiness
    Cloud Gateway
      Runtime
        Managed default model
        BYOK/provider override later
```

Connectors answer "what can Rem use?" Model providers answer "which brain does
the gateway use to plan and write?" Keep those separate.

## Viable Options

| Option | User promise | Pros | Risks | Recommendation |
|--------|--------------|------|-------|----------------|
| Hosted default provider | Rem works out of the box. | Best quality, simplest support, predictable tools. | Cost, rate limits, privacy concerns. | Keep as the reliable default for paid/cloud. |
| BYOK hosted provider | Use your own OpenAI/Anthropic/etc key. | Lower Rem model cost, advanced-user friendly. | Support surface, key storage/security UX. | Good follow-up after provider settings are clearer. |
| LM Studio local server | Run a local OpenAI-compatible model server. | Strong local UX, good Mac fit, easy GUI. | User must manage model size/server state. | Best first local validation path. |
| Ollama local server | Run local models through Ollama. | Popular, scriptable, OpenCode/OpenClaw support. | Tool-calling and model behavior vary by model/config. | Support after LM Studio or as parallel advanced option. |
| llama.cpp server | Power-user local server. | Minimal, flexible, no GUI dependency. | Too technical for normal onboarding. | Advanced/manual only. |
| OpenCode as worker | Cheap/offline coding worker. | Useful for bounded docs/audits/patches. | Not validated for Rem lifecycle; tool reliability varies. | Keep as orchestration experiment, not app product feature. |

## Tradeoffs

### Quality

Local models are plausible for summarization, simple planning, extraction, and
bounded helper tasks. They are risky for autonomous long-horizon execution,
complex tool use, security-sensitive decisions, and production-quality coding
without review.

### Latency

Local latency depends on model size, Apple Silicon generation, RAM, quantization,
and whether the local server is already warm. Cloud can be faster for large
models and slower when a gateway/model provider is cold or rate-limited.

### Privacy And Security

Local-only is the strongest privacy story for prompts and local computer
context. It does not remove the need for capability scopes, action logs, and
approval UX, because the local model can still ask tools to affect the user's
Mac.

### Business

Free/local support should make Rem more credible as open-core software. The paid
boundary should move to managed reliability:

- managed cloud gateway
- cloud gateway backup/restore
- cross-device reachability when the Mac is off
- support for gateway repair/redeploy
- hosted default model usage, if Rem pays for it
- future team/shared capabilities

Avoid charging only for "AI responses" if the open-source/local path is central
to the brand.

## Small Validation Slice

Create a Mac-only local model readiness screen or command that does not change
pricing:

1. Detect whether LM Studio is reachable at `http://127.0.0.1:1234/v1`.
2. Detect whether Ollama is reachable at `http://127.0.0.1:11434/v1` or its
   native endpoint.
3. Show the active OpenClaw model provider from `openclaw models list`.
4. Offer copy-only setup guidance instead of writing provider config on the
   user's behalf.
5. Run one low-risk "hello" probe directly against the detected local endpoint
   only. Do not route this through the active OpenClaw provider, do not use a
   hosted fallback, and do not change gateway model settings.

Success criteria:

- A user can see why local mode is unavailable without opening Terminal.
- The app does not store new provider secrets.
- The probe does not change gateway model settings.
- The probe cannot create hosted-model cost or leak prompts to a hosted fallback.
- The result is readiness evidence only, not proof of quality/safety parity with
  hosted frontier models.
- The result can be attached as visual evidence in a future PR.

## Non-Goals For Now

- Do not build a custom local inference runtime inside Rem.
- Do not download large model weights from the app until storage, consent,
  App Store rules, and uninstall behavior are designed.
- Do not promise cloud-gateway equivalence for Mac-local control.
- Do not make local models the default for users who have not explicitly chosen
  local runtime behavior.

## Follow-Up Issues

- Implement local model provider readiness in Mac Gateway Runtime settings.
- Design BYOK provider key storage and revocation in Permissions & Privacy.
- Add benchmark/dogfood evidence for LM Studio and Ollama with the current Mac
  app, using the same visual/PR evidence rules as UI work.
- Update pricing copy after cloud gateway backup/restore and reliability are
  clearer.
