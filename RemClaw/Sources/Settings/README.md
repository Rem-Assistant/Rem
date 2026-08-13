# Settings (iOS)

> Everything behind the Settings tab on iOS. Shows your gateway connection status, request usage, device permissions, paired devices (including Rem for Mac), skills you can enable, and your account/legal info.

Settings views for the iOS app covering gateway connection, usage, permissions, paired devices, skills management, and legal documents.

The nested Agent Settings Memory page is shared with macOS and currently presents only the read-only OpenClaw defaults Soul, Tools, and Agents. Generated diary/daily-log/wiki files and the legacy user-facts store are intentionally not shown; no stored data is deleted by this UI policy. Agent Settings also owns the shared Voice page: it loads the gateway's dynamic voice catalog, previews a voice through the gateway, and persists the canonical Talk selection across devices without exposing provider credentials.

## Key Files

| File | Purpose |
|------|---------|
| `SettingsView.swift` | Root settings screen — wraps `SharedSettingsView` with iOS-specific sections. The OpenClaw row lives under the “Your agent runtime” header and uses the shared OpenClaw vector mark. Other sections include permissions, skills, paired devices, about, legal (Terms/Privacy baked into `LegalContent` enum), and account deletion. `DevicePermissionsView` lists the App Store-approved iOS permissions (Calendar, Reminders, Microphone, Speech Recognition, Camera, Notifications) grouped into Device Data / Media & Voice / Notifications sections. Contacts and Location are intentionally omitted from the iOS release path. |

## Patterns & Conventions

- **Shared settings core**: `SettingsView` delegates to `SharedSettingsView` (in `Shared/Views/`) with iOS-specific closures for permissions, about, and sign-out/delete handlers.
- **Connectors**: `SharedSettingsView`'s "Connectors" row (Composio-hosted connect for Gmail/Calendar/GitHub, replacing the old in-app OAuthClient) is on by default here — `SettingsView` no longer passes `showsConnectorsEntry: false`, so iOS gets parity with Mac's `MacFullSettingsView`.
- **Environment-based services**: Uses `@Environment` for `RemGatewaySessionManager` and `RemAuthService`.
- **Connection status mapping**: Status icons and colors are mapped from `GatewayConnectionState` (green=connected, orange=connecting, gray=disconnected, red=unauthorized/unreachable, yellow=pairingRequired).
- **Scene phase tracking**: `DevicePermissionsView` refreshes permission status when the app returns to foreground (after user grants in System Settings).
- **RPC for skills**: Skills loaded via `chatSession.request(method: "skills.status")` and toggled via `skills.update`.
- **Legal content**: Full Terms of Service (7 sections) and Privacy Policy (13 sections) are embedded in `LegalContent` enum within `SettingsView.swift`.
- **Account deletion**: Requires user to type "delete" for confirmation, calls backend `DELETE /api/v1/auth/me`.
- **Debug section (`#if DEBUG` only)**: When built in Debug, `SettingsView` passes a `debugSectionContent` closure into `SharedSettingsView` that surfaces internal-only entries. Currently exposes the SomeClaw relay client (#94) — see `RemClaw/Sources/SomeClaw/`.
