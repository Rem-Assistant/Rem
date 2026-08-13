# Mac Capability Scopes And Action Logs

This note is the product/security decision for issue
[#583](https://github.com/Rem-Assistant/RemClaw/issues/583). It extends
[SECURITY_MODEL.md](SECURITY_MODEL.md) for Mac-local powers: shell, files,
clipboard, screen/app context, browser automation, and gateway configuration.

The design goal is simple: a paired Mac can make Rem powerful, but users should
always understand what Rem may do, which approval allowed it, and what happened
afterward.

## Decision

Treat Mac-local powers as **Mac Connector capabilities**, not as generic chat
powers and not as cloud-gateway fallback behavior. Treat gateway configuration
mutation as a related **Gateway capability** that uses the same approval and log
model because it changes the runtime that executes work.

Expose Mac capabilities in product language:

- Shell
- Files
- Clipboard
- Screen & app context
- Browser automation

Expose Gateway configuration separately when the action changes pairing,
runtime config, MCP servers, auth, redeploy, repair, or canonical gateway state.

Pairing a Mac only proves that the device is trusted enough to be reachable. It
does not grant blanket consent for risky actions. Each capability needs a
policy, a user-visible scope, and an action log entry when used.

## Approval Classes

| Class | Meaning | Examples |
|-------|---------|----------|
| Unavailable | Rem must not offer the action yet. | Broad browser automation before UI review, unknown gateway mutation. |
| Ask every time | User confirms each individual action. | Running a shell command, writing files, reading clipboard, opening a URL. |
| Allow once | User approves one action with a visible target and reason. | Open `https://example.com`, copy a generated snippet to clipboard. |
| Allow for session | User approves repeated similar actions in the current chat/session. | Read several files in one selected project folder. |
| Persistent scoped allow | User creates an ongoing rule with a bounded target. | Read-only access to one folder, open public URLs on one approved domain after explicit user intent. |
| Blocked by policy | Rem refuses even if a tool can technically do it. | Local/private URL opening from untrusted content, destructive gateway mutation from external content. |

Start conservative. If the product cannot explain the action in one sentence
and log it cleanly afterward, use ask-every-time or unavailable.

## Capability Matrix

| Capability | Default policy | Persistent allow rules | Must stay unavailable until |
|------------|----------------|------------------------|----------------------------|
| Shell | Ask every time. Show command, working directory, gateway, and risk summary. | Later: session allow for read-only commands in a selected folder. | Arbitrary background shell execution without visible command and result. |
| Files | Ask every time for writes. Ask or session-allow for reads in a selected folder. | Folder-scoped read, folder-scoped write, explicit file picker grants. | Home-wide or disk-wide access without scoped UI and logs. |
| Clipboard | Ask every time for read and write. Show direction and preview. | Later: allow write-only generated content for current session. | Silent clipboard reads, especially caused by external content. |
| Screen & app context | Ask every time. Show which app/window/screen context will be inspected. | Later: session allow for one app or current workspace. | Always-on screen capture or background monitoring without dedicated UX. |
| Browser automation | Ask every time. Public `http`/`https` link opening only at first. | Later: domain-scoped allow for opening public URLs. | Login flows, private/local URLs, form submission, downloads, purchases, or browser-control loops. |
| Gateway configuration | Ask every time. Show exact config change and affected gateway. | Later: allow low-risk health repair for the canonical managed cloud gateway. | Adding MCP servers, changing auth, deleting data, redeploying, or switching canonical gateway without explicit confirmation. |

## External Content Rule

External content is never approval.

Emails, web pages, documents, calendar text, Skill output, MCP tool results,
terminal output, and gateway responses can suggest an action. They cannot
approve the action, create a persistent allow rule, or bypass the capability
policy. When external content materially influenced an action, log that fact.

Examples:

- A web page can contain a YouTube link; the user still approves opening it.
- A README can suggest a shell command; the user still approves the command.
- An MCP server can expose a setup instruction; the user still approves config
  changes or token entry.

## Action Log Model

Every high-risk Mac capability use should produce an action log event. The log
is not only telemetry; it is a user-facing audit trail.

Required fields:

| Field | Purpose |
|-------|---------|
| `id` | Stable event id for support and UI deep links. |
| `createdAt` | When the action was requested or executed. |
| `sessionId` | Chat/session that produced the action, if any. |
| `connector` | User-facing surface, usually `Mac`, `Browser`, `Files`, or `Gateway`. |
| `capability` | Shell, Files, Clipboard, ScreenContext, BrowserAutomation, GatewayConfig. |
| `gatewayId` | Gateway that routed the action. |
| `gatewayProvider` | Mac, cloud, manual, or unknown. |
| `deviceId` | Paired Mac/device that executed or was targeted. |
| `approvalClass` | Ask every time, allow once, session allow, persistent scoped allow. |
| `approvalSource` | User tap, prior scoped rule, system policy, or denied. |
| `targetSummary` | Redacted command/path/URL/app/config target. |
| `riskLevel` | Low, medium, high, blocked. |
| `externalContentInfluenced` | Whether untrusted external content materially suggested the action. |
| `status` | Requested, approved, denied, running, succeeded, failed, blocked. |
| `resultSummary` | Redacted outcome suitable for UI. |

Do not log raw secrets, full tokens, private file contents, or large command
output. Store enough to answer "what happened?" without creating a second copy
of private data.

## UI Placement

Use three layers:

1. **Settings > Connectors > Mac**: user-facing summary of Mac capabilities,
   their readiness, and the paired Macs that can provide them.
2. **Settings > Permissions & Privacy**: approval rules, scoped allows, denied
   permissions, and security explanations.
3. **Gateway detail**: runtime health, pairing, repair, and which gateway/device
   is currently able to execute the capability.

Action logs should be reachable from both the Mac Connector and Permissions &
Privacy. Gateway detail can show a filtered "recent activity on this gateway"
view, but it should not be the only route to audit history.

## State Model

Capability rows should distinguish these states:

- `Unavailable`: product has not enabled this class yet.
- `Needs Mac`: selected gateway cannot perform a Mac-local action.
- `Mac Offline`: paired Mac is known but unreachable.
- `Needs OS Permission`: macOS permission is denied or not determined.
- `Needs Approval`: tool is ready but user approval is required.
- `Allowed For Session`: temporary approval is active.
- `Scoped Allow`: persistent bounded rule is active.
- `Blocked`: policy refused the action.
- `Running`: action is executing.
- `Logged`: completed action has an audit entry.

Avoid a single "Enabled" state for high-risk capabilities. "Ready" means the
tool exists; it does not mean Rem has consent to use it freely.

## Implementation Slices

1. Add an action log data model and local store with redaction helpers.
2. Add log writes around browser link opening and gateway config mutation first.
3. Add Mac Connector capability summary rows that read readiness plus policy.
4. Add approval state UI under Permissions & Privacy.
5. Add folder-scoped file approvals and session approvals only after logs are in
   place.
6. Keep broad browser automation and background screen monitoring unavailable
   until dedicated design and abuse-case review are complete.

## Related Docs

- [SECURITY_MODEL.md](SECURITY_MODEL.md)
- [CAPABILITIES_IA.md](CAPABILITIES_IA.md)
- [VISION.md](VISION.md)
