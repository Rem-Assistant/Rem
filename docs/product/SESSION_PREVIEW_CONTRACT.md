# Session Preview Contract

This note is the product and security contract for issue
[#729](https://github.com/Rem-Assistant/RemClaw/issues/729). It narrows the
future direction in [#495](https://github.com/Rem-Assistant/RemClaw/issues/495)
into rules for showing what Rem is doing during remote-control or Mac-local
sessions.

For the broader Connector and gateway model, see
[CAPABILITIES_IA.md](CAPABILITIES_IA.md). For approval classes and action logs,
see [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md).

## Decision

Session preview starts as an **activity preview**, not remote desktop.

Phase 1 should show a redacted, user-readable timeline of what Rem is doing:
approved actions, current tool phase, gateway/device identity, permission
state, blocked states, and short result summaries. Rich visual preview is a
later layer. A screenshot or app-context thumbnail may be shown only after the
same explicit approval and action-log model required for Screen & app context.

Do not start with live stream, always-on screen recording, background desktop
monitoring, or browser-control loops. Those remain unavailable until Rem has
dedicated approval UX, audit logs, retention controls, and abuse-case review.

## Product Rules

1. **Preview is observability, not extra authority.** Showing a preview must not
   grant Rem permission to inspect the screen, read app contents, drive a
   browser, run shell, or access files.
2. **Mac-local preview requires a Mac.** Cloud gateway fallback cannot replace
   Mac shell, local files, clipboard, screen/app context, browser state, or
   desktop preview.
3. **Readiness is separate from consent.** A paired Mac, installed Skill,
   available node capability, or reachable gateway may make preview technically
   possible, but the UI must still show whether approval is required.
4. **External content is never approval.** Web pages, docs, emails, terminal
   output, Skill output, and MCP results can explain why a preview would help;
   they cannot approve capture or persistence.
5. **Preview data must be minimal.** Store enough to answer "what is Rem doing?"
   without creating a second copy of private screen contents, file contents,
   command output, tokens, or browser data.

## Preview Modes

| Mode | First-wave status | Consent rule | Retention rule |
|------|-------------------|--------------|----------------|
| Activity timeline | Allowed for phase 1. | Uses the approval state of each underlying action; no new capability grant. | Persist redacted entries as action-log data. |
| Tool phase/progress | Allowed for phase 1. | No extra consent if it only names safe phases such as awaiting approval, running, blocked, or succeeded. | Persist concise status transitions. |
| Gateway/device identity | Allowed for phase 1. | No extra consent; identity helps the user understand where work runs. | Persist ids/names already safe for gateway UI. |
| On-demand screenshot thumbnail | Later, after action logs. | Ask every time unless a future scoped allow explicitly covers one app/window/workspace. | Prefer transient display; persist only redacted metadata unless the user explicitly saves evidence. |
| Active-window/app metadata | Later, after screen/app approval UX. | Ask every time and show target app/window. | Persist target summary, not raw contents. |
| Accessibility tree/app context | Later, high risk. | Ask every time with target and reason. | Do not persist raw trees by default. Persist redacted result summaries only. |
| Browser/page screenshot | Later, high risk. | Requires browser capability policy and public URL/domain rules. | Prefer transient display; never persist private/local page captures by default. |
| Live stream/screen recording | Unavailable. | Requires a future dedicated design and abuse-case review. | No retention model approved. |
| Background monitoring | Unavailable. | Not approved. | Not approved. |

## UI States

Use these names consistently in session preview surfaces:

- `Unavailable`: this preview mode is not enabled by product policy.
- `Needs Mac`: selected gateway cannot provide Mac-local preview.
- `Mac Offline`: the required paired Mac is unreachable.
- `Needs OS Permission`: macOS Screen Recording, Accessibility, or related
  permission is denied or not determined.
- `Needs Approval`: Rem can request this preview, but the user has not approved
  the specific action.
- `Awaiting Approval`: an approval prompt is visible or pending.
- `Action Feed Only`: safe activity preview is available, but visual preview is
  not approved.
- `Preview Available`: a specific approved preview artifact can be shown.
- `Blocked`: policy refused the preview request.
- `Running`: an approved action is executing.
- `Logged`: the action completed and has an audit entry.

Avoid "enabled" for high-risk preview modes. It overstates consent.

## Data Contract

Preview entries should use a redacted model like:

| Field | Purpose |
|-------|---------|
| `id` | Stable entry id for UI and support. |
| `createdAt` | When the state/action was observed. |
| `sessionId` | Chat or session that produced the preview entry. |
| `gatewayId` | Gateway that routed the action. |
| `gatewayProvider` | Mac, cloud, manual, or unknown. |
| `deviceId` | Paired Mac/device when relevant. |
| `mode` | Activity, tool phase, screenshot thumbnail, app metadata, browser preview, or blocked. |
| `capability` | Shell, Files, Clipboard, ScreenContext, BrowserAutomation, GatewayConfig, or Chat. |
| `status` | Unavailable, needs approval, awaiting approval, running, succeeded, failed, or blocked. |
| `targetSummary` | Redacted app/window/path/URL/command summary. |
| `resultSummary` | Short redacted outcome safe for UI. |
| `approvalClass` | The approval policy that allowed or blocked it. |
| `retention` | Transient, action-log metadata, or explicitly saved evidence. |

Never store raw secrets, full tokens, private file contents, full command
output, full accessibility trees, or unapproved screenshots in preview entries.

## Placement

Session preview can appear in three places:

1. **Chat/session detail:** primary place for the live activity preview.
2. **Mac Connector:** capability readiness, approval status, and recent Mac
   preview/action history.
3. **Gateway detail:** filtered recent activity for the active gateway/device,
   but not the only route to audit history.

iOS may show session preview for a paired Mac only when the Mac capability,
permission, and approval state allow it. If the Mac is absent, locked, offline,
or denied Screen Recording/Accessibility permission, iOS should show the
specific unavailable state instead of implying the cloud can inspect the Mac.

## Implementation Slices

1. **Activity feed model:** implement redacted preview entries from existing
   chat/tool/action phases, with cloud-gateway unsupported states for Mac-local
   preview.
2. **Action logs first:** implement the action-log data model from
   [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) before showing rich
   visual previews.
3. **Fixture-backed UI:** build SwiftUI fixture states for unavailable, needs
   Mac, needs OS permission, needs approval, action feed only, preview
   available, blocked, and failed.
4. **On-demand screenshot pilot:** after logs and approval UX exist, add one
   explicitly approved screenshot/app-context capture scoped to one app/window
   or current workspace.
5. **Live stream review:** only revisit streaming after the first four slices
   ship and there is a written abuse-case and retention review.

## Related Issues

- [#495](https://github.com/Rem-Assistant/RemClaw/issues/495): Explore in-app
  machine preview for remote control sessions.
- [#730](https://github.com/Rem-Assistant/RemClaw/issues/730): Wire session
  preview data feed from OpenClaw/Mac capabilities.
- [#731](https://github.com/Rem-Assistant/RemClaw/issues/731): Design and
  visually validate in-app session preview surface.
