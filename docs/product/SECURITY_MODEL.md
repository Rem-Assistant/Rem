# Security Model

This note defines the product security model for Connectors, Capabilities,
Skills, MCP servers, and Mac/cloud gateways. It complements
[CAPABILITIES_IA.md](CAPABILITIES_IA.md): that doc explains where concepts live
in the product; this doc explains the trust boundaries and default safety rules.
For in-app session preview rules, see
[SESSION_PREVIEW_CONTRACT.md](SESSION_PREVIEW_CONTRACT.md).

## Product Promise

Rem is a personal assistant that can help with real work across accounts,
devices, and gateways. That power has to be visible and bounded. Users should be
able to tell:

- what Rem can access,
- where the work will run,
- which device or account grants that access,
- what Rem just did, and
- why a request cannot run safely.

The default posture is fail-closed. If Rem cannot prove a capability is allowed
and available on the selected runtime, it should say what is missing instead of
falling back to a broader or more dangerous route.

## Vocabulary

| Term | Security meaning |
|------|------------------|
| Connector | User-facing thing Rem can use, such as Calendar, Gmail, Browser, Files, or Mac. |
| Capability | Permissioned action under a Connector, such as read events, create files, run shell, read clipboard, or open a browser link. |
| Gateway | Runtime/control plane that routes work. A gateway is not itself an integration account. |
| Mac gateway / node | Local execution surface for Mac-only capabilities. Treat it as powerful operator authority on that Mac. |
| Cloud gateway | Cloud-safe runtime for reachable work. It must not silently replace Mac-local shell, files, clipboard, screen, browser, or app context. |
| Skill | OpenClaw-managed implementation package. Users should usually see the Connector requirement it satisfies, not the raw package first. |
| MCP server | Advanced/custom tool provider. Adding one grants the assistant a new tool source and should be treated as a trust decision. |
| Connected Account | OAuth or provider identity/token relationship used by one or more Connectors. |

## Principles

1. **Fail closed.** Missing auth, missing pairing, unsupported URL, offline Mac,
   disabled tool, or unknown capability should produce an unavailable state, not
   a hidden fallback.
2. **No silent runtime substitution.** Cloud can help with cloud-capable work,
   but Mac-local requests require a reachable paired Mac.
3. **Separate readiness from permission.** Installed Skill, configured MCP
   server, connected OAuth account, OS permission, paired node, and per-action
   approval are different states.
4. **High-risk actions need explicit controls.** Shell, file access, clipboard,
   screen/app context, browser automation, and gateway config mutation should be
   visible, scoped, and auditable.
5. **Pairing establishes device trust; it is not blanket consent.** A paired
   node can advertise capabilities, but risky capabilities still need product
   policy and user-visible controls.
6. **Keep the trust model personal.** Rem/OpenClaw should not imply hostile
   multi-tenant isolation for a single gateway. The product should explain the
   actual boundary: user-owned accounts, user-owned devices, and managed cloud
   runtime when explicitly selected.
7. **Connector content is context, not authority.** Emails, docs, web pages,
   calendar text, MCP tool results, Skill output, and browser content may inform
   Rem, but they are not user approval and must not be treated as instructions
   to perform high-risk actions.

## Trust Boundaries

### User Intent And Untrusted Content

The Rem user is the authority for goals, approvals, and persistent trust
changes. Content fetched from Connectors, Skills, MCP servers, browser pages,
emails, documents, calendars, or gateway tools is untrusted input. It can be
useful context, but it can also contain prompt injection, misleading
instructions, stale data, or malicious links.

Rules:

- External content can inform an answer, but cannot approve a capability,
  install a Skill, add an MCP server, mutate gateway config, run shell, write
  files, send messages, spend money, delete data, or open local/private URLs.
- High-risk actions caused by external content still require user-visible
  confirmation and the normal capability policy.
- UI copy should distinguish "Rem found this in your email/document/browser"
  from "you asked Rem to do this."
- Audit logs should eventually record when external content influenced an
  action.

### Accounts

Provider OAuth and connected account state grant Rem access to external service
data. These grants are account-level and should appear under the relevant
Connector, for example Calendar, Gmail, Notion, GitHub, or Linear.

Rules:

- Show which provider account is connected.
- Explain what the Connector can do with that account.
- Store tokens in the intended secure store, not hidden UI state.
- Revocation should be discoverable from the Connector detail.

### Device Permissions

OS-level permissions are device-local. Calendar, microphone, notifications,
screen recording, accessibility, files, and local network access may differ
between iPhone and Mac.

Rules:

- Device permissions belong in Permissions & Privacy.
- Connector detail can summarize them, but should not pretend they are portable
  account permissions.
- A denied OS permission should produce a human-readable repair path.

### Gateway Capabilities

Gateways route tool execution. The same Connector may have different readiness
on Mac and cloud because installed Skills, binaries, auth profiles, MCP servers,
and paired devices differ by runtime.

Rules:

- Show the active gateway for capability-sensitive work.
- Do not silently use cloud for Mac-local actions.
- Do not silently use Mac-local powers when the user expected cloud-safe work.
- Gateway repair/redeploy can fix runtime health, but should not create new
  trust grants without visible copy.

### Mac-Local Powers

Mac shell, local files, clipboard, screen/app context, and browser/app actions
are high-trust powers. They can affect private data and the user’s live desktop.

Rules:

- Shell/files/clipboard/screen/browser should be modeled as Mac capabilities,
  not generic chat powers.
- Browser link opening starts with ask-first approval and public `http`/`https`
  only.
- Broader browser automation, file write scopes, shell allow rules, and screen
  context need explicit follow-up design before being presented as finished
  user-ready capabilities.

### Skills And MCP

Skills and MCP servers are implementation substrates for capabilities. They can
be powerful, especially when they install binaries, read local files, or expose
remote tool servers.

Rules:

- Normal users should see requirements in Connector language: “Install `gh` to
  enable GitHub actions on this Mac.”
- Advanced users can still manage Skills and custom MCP servers directly.
- Skill install should show provenance, required binaries, required auth, and
  likely capability impact before installation.
- MCP add flow should describe the server as an advanced trust grant.

## Current Implemented Guardrails

- Gateway tokens are separated from visible metadata and stored through the
  gateway config/token store.
- Device pairing is explicit and visible through pending/paired device views.
- Mac browser link opening requires approval, only allows public `http`/`https`
  URLs, and rejects local/private/obfuscated loopback forms before approval.
- Chat transcript cleaning hides raw low-level node/browser diagnostics for the
  browser-link flow.
- Cloud gateway repair distinguishes managed cloud recovery from local Mac
  pairing and reachability.
- Mac-local capability scope policy is defined in
  [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md).
- Session preview starts as redacted activity observability, not remote desktop;
  see [SESSION_PREVIEW_CONTRACT.md](SESSION_PREVIEW_CONTRACT.md).

## Known Gaps

| Gap | Risk | Follow-up |
|-----|------|-----------|
| Mac shell/files/clipboard need implementation of the documented scope and log model. | Users cannot tell which local powers Rem may use or review what happened. | Implement [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) before making these feel “finished.” |
| Permissions screen mostly covers OS permissions, not gateway capability policy. | Users may confuse OS access with assistant/tool access. | Add Connector/capability permission summaries. |
| Status UI can present powerful tools as simply enabled. | “Enabled” may overstate safety. | Use readiness plus policy language. |
| Skill install lacks first-class provenance/risk UX. | Users may install implementation packages without understanding trust impact. | Add install confirmation with source, binaries, auth, and capabilities. |
| MCP add flow needs stronger trust-boundary copy. | Remote tool providers can materially expand assistant powers. | Treat MCP add as an advanced Connector trust grant. |
| Managed cloud gateway helper powers are not fully explained. | Backend-assisted repair/auto-approval can feel surprising. | Document managed-cloud exception and show clear copy in deploy/repair flows. |
| Capability/action logs are missing. | Users cannot audit what Rem used after the fact. | Add activity history by Connector, gateway, device, and capability. |

## UI Rules

- Use Connector names for user-facing trust: Calendar, Gmail, GitHub, Mac,
  Browser, Files.
- Use Capability names when asking for approval: “Open youtube.com in your
  default browser?”, “Read files in this folder?”, “Run this shell command?”
- Use Gateway names for runtime health and reachability: Cloud gateway, Mac
  gateway, paired Mac, selected gateway.
- Do not expose raw OpenClaw errors as the primary UX. Convert them into
  unavailable, needs permission, unsupported, offline, or repair states.
- Persistent allow rules must live under this security model, not as hidden tool
  flags.

## Near-Term Slices

1. Add a product/security doc link from Connector and Permissions implementation
   issues.
2. Implement the Mac capability scopes and action log model in
   [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md).
3. Add capability/action logs.
4. Add Skill install provenance and requirement disclosure.
5. Strengthen MCP add copy and validation.
6. Add phase-specific unavailable states for Mac offline, cloud-safe fallback,
   capability disabled, unsupported URL, approval denied, and missing auth.

## Related Issues

- [#572](https://github.com/Rem-Assistant/RemClaw/issues/572): Security posture
  for Connectors, Skills, and gateway capabilities.
- [#574](https://github.com/Rem-Assistant/RemClaw/issues/574): Ask-first browser
  link opening.
- [#377](https://github.com/Rem-Assistant/RemClaw/issues/377): Curated MCP
  integrations.
- [#313](https://github.com/Rem-Assistant/RemClaw/issues/313): Skills browse,
  install, configure, and enable.
- [#446](https://github.com/Rem-Assistant/RemClaw/issues/446): Mac Settings and
  Connectors IA.
- [#582](https://github.com/Rem-Assistant/RemClaw/issues/582): MCP add flow
  should present advanced trust grant.
- [#583](https://github.com/Rem-Assistant/RemClaw/issues/583): Mac capability
  scopes and action logs.
- [#584](https://github.com/Rem-Assistant/RemClaw/issues/584): Skill install
  provenance, requirements, and capability impact.
