# Permissions

macOS permission checking for Rem-visible local Mac capabilities.

Permissions is device/system scoped. Account integrations and capability
readiness, including Apple Calendar and Google Calendar, belong in Connectors.

## Files

| File | Purpose |
|------|---------|
| `MacPermissionManager.swift` | Checks and requests macOS permissions (Accessibility, Screen Recording, Microphone, Speech Recognition, local Apple Calendar, Notifications). Permissions UI promotes Accessibility, Screen Recording, Microphone, Speech Recognition, and Notifications; Calendar status is surfaced through Connectors. |

## Upstream parity notes

OpenClaw's macOS companion also documents Automation/AppleScript, Camera, and
related node permissions. Rem only promotes permission rows when they map to a
user-visible app capability:

- Microphone and Speech Recognition are first-class rows because Rem Voice is a
  user-visible Settings capability. The Voice flow still checks the same grants
  at first use so direct entry remains safe.
- Automation/AppleScript is a future capability unless Rem exposes a
  system-wide automation feature.
- Camera and Location are not advertised Rem capabilities today.
