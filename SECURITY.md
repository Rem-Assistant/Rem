# Security Policy

If you believe you have found a security issue in Rem, report it privately first.

Rem is a personal AI assistant: an iOS app, a macOS app, a Node backend, and a
per-user gateway built on [OpenClaw](https://github.com/openclaw/openclaw). It
handles account identity, calendar and contact data, connector credentials, and
a gateway that can execute approved actions on a user's device. We take reports
against that surface seriously.

## Reporting a Vulnerability

**Use GitHub's private vulnerability reporting:**

> [Report a vulnerability](https://github.com/Rem-Assistant/RemClaw/security/advisories/new)

That opens a private security advisory visible only to you and the maintainers.
It is the preferred channel because it keeps the report, the discussion, and the
eventual fix in one private place.

If you cannot use GitHub Security Advisories, email **admin@userem.site** with
`SECURITY` in the subject line.

**Please do not** open a public issue, pull request, or discussion that
discloses an unpatched vulnerability, an exploit path, a working proof of
concept, or a leaked secret. Maintainers may hide or delete public posts that do
so, and will redirect the report through the private process.

We do not currently run a paid bug bounty program. We will credit reporters in
the advisory unless you ask us not to.

## Routing: is it actually our bug?

Rem depends on upstream OpenClaw, and a good number of interesting findings live
there rather than here.

| If the issue is in… | Report to |
|---|---|
| The Rem iOS or macOS app, the Rem backend, or the gateway wrapper | **This repo** — [private advisory](https://github.com/Rem-Assistant/RemClaw/security/advisories/new) |
| OpenClaw core, the gateway protocol, the agent runtime, or OpenClawKit | [openclaw/openclaw](https://github.com/openclaw/openclaw/security/advisories/new) — see their [SECURITY.md](https://github.com/openclaw/openclaw/blob/main/SECURITY.md) |
| A third-party dependency | That project, then tell us so we can pin or patch |

If you are not sure, report it to us privately and we will route it.

## What to include

The reports we can act on fastest contain:

- What you found, and which trust boundary it crosses.
- The affected component and the commit SHA or app build number.
- Reproduction steps or a proof of concept.
- The actual impact — what an attacker gets, and what access they needed to
  start.
- Any remediation advice or a focused patch, if you have one.

Reports without reproduction steps or demonstrated impact are deprioritized.
Raw scanner output is not a report.

## Trust model

Rem inherits OpenClaw's operator trust model, and it matters for triage. A
gateway is a **single-user** trust domain: the person who paired it is a trusted
operator, and by design they can grant the agent shell access, file access, and
device control on their own machine. A gateway is not a security boundary
between mutually adversarial users.

Against that model, these are usually **not** vulnerabilities on their own:

- Prompt injection with no accompanying auth, approval, permission, or
  tool-boundary bypass.
- A trusted operator deliberately using a local capability we document, such as
  Mac shell execution.
- A malicious skill or plugin that the operator installed themselves.
- Expecting per-user isolation from two adversarial users sharing one gateway.
- Deployment choices our docs already warn against.

These **are** in scope and we want to hear about them:

- Cross-account access in the backend — reading, deploying to, or controlling
  another user's gateway, data, or billing state.
- Authentication or session bypass in Apple/Google sign-in or JWT handling.
- Gateway pairing or device-approval bypass — attaching to a gateway you were
  never approved for.
- Escaping the node command allowlist, or invoking a command the user never
  granted permission for.
- **Secret exposure.** Provider API keys, gateway auth tokens, and OAuth refresh
  tokens must live in the Mac Keychain (service `app.remclaw.mac`) or in the
  upstream-canonical config files, never in a world-readable file. A path that
  writes a secret somewhere else on disk is a real bug — this class has bitten
  us before.
- Connector credential leakage across users or across connected accounts.
- Anything that lets a remote party drive a user's device without approval.

## Response

We are a small team. What you can expect:

- An acknowledgement that a human has read your report, generally within a few
  business days.
- An assessment of whether we agree it is a vulnerability, and a rough severity.
- For confirmed issues, a fix and a published advisory. Timelines depend on
  severity and on whether a fix needs an App Store release, which we do not
  fully control.

These are intentions, not a contractual SLA. If a report goes quiet longer than
you think is reasonable, please ping the advisory thread.

## Coordinated disclosure

Please give us a reasonable window to ship a fix before publishing. We will work
with you on timing and we will not ask you to stay quiet indefinitely. If we
cannot fix an issue, we will tell you that rather than stall.
