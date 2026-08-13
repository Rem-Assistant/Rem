# Connector Credentials Handoff

Use this file when a connector is ready for live provider credentials. Do not
paste secrets into chat or issues. Fill in the non-secret registration values
here, then store actual secrets through the provider/backend path chosen for the
connector.

## Status

No live provider credentials are required yet. Current connector work can
continue with catalog rows, detail screens, capability states, requirement
routing, tests, and fixtures.

## When To Ask For Credentials

Ask the project admin for live provider credentials only after all of these are
true:

- A provider-specific issue exists with the exact user flow and acceptance
  criteria.
- The app has a provider detail row, capability copy, and disabled/error states
  for the target provider.
- The redirect URI, bundle id, app type, and requested scopes are known.
- The storage path is agreed: gateway-canonical token store, app warm-start
  Keychain cache, or Mac-local capability with no OAuth secret.
- A rollback or disable path exists before enabling the provider in production.

Until then, keep building with fixtures, catalog rows, requirement routing,
gateway RPC seams, and docs. The user should not be blocked on developer
credentials during scaffold work.

## Non-Secret Registration Values

Fill these values in the provider-specific issue before requesting any secret:

| Field | Example / current expectation | Notes |
|-------|-------------------------------|-------|
| Provider | Google Workspace, Gmail, GitHub, Notion, iMessage | Use the product-facing provider name from Settings > Connectors. |
| Platform app type | iOS/macOS public client, web backend, or Mac-local capability | Public clients use PKCE and should not require client secrets in the app. |
| Bundle id / app id | `app.remclaw.ios`, `app.remclaw.mac`, or backend id | Keep platform identifiers explicit so callback registration is auditable. |
| Redirect URI | `remclaw://oauth/callback/<providerId>` or backend callback | Must match `OAuthCallbackParser` / provider config exactly. |
| Initial scopes | Provider-specific read/write set | Start read-only unless write actions are part of the accepted slice. |
| Owner / console | Person who can edit the provider app | Avoid losing access to a single personal account. |

## Secret Handling

- Do not paste client secrets, API keys, refresh tokens, private keys, or
  provider console screenshots with secrets into chat, issues, docs, or PRs.
- If a provider requires a secret, store it in the backend or gateway secret path
  selected for that provider. The iOS/macOS app should receive public client ids
  and tokens through the OAuth flow, not embedded secrets.
- OAuth tokens are canonical on the gateway under
  `oauth.providers.<providerId>.users.<userId>`; the app Keychain is a
  warm-start cache only. See `Shared/Services/OAuth/README.md`.
- Provider credentials for Mac-local capabilities are not automatically cloud
  credentials. Treat local Apple/iMessage capabilities as device-scoped.

| Provider | Needed from project admin | Notes |
|----------|---------------------------|-------|
| Google umbrella | OAuth client id, approved redirect URI, enabled APIs, approved scopes for Gmail/Calendar/Drive/Docs/Sheets/Slides as each capability lands | Prefer one Google account connection with scope-aware capability rows instead of separate repeated sign-ins. Do not split Google Calendar from Google Workspace unless product deliberately wants separate consent surfaces. |
| Gmail | Covered by Google umbrella unless Gmail needs a separate consent surface | Use Gmail-specific copy/actions, but prefer the same Google OAuth app and account connection. |
| GitHub | OAuth app/client id as `GitHubOAuthClientID`, approved redirect URI `remclaw://oauth/callback/github`, initial scopes `read:user user:email` | The first app scaffold is credential-gated and does not need a secret. Repository access should be added as a later explicit consent decision because GitHub classic repo scopes quickly become write-capable. |
| Notion | OAuth integration/client id, approved redirect URI, workspace capability decision | Keep Notion capability copy separate from raw token storage details. |
| iMessage | No OAuth credentials expected; requires Mac-local capability design and a paired reachable Mac gateway | Treat as a Mac-local connector/capability if implemented through Messages, AppleScript, Shortcuts, EventKit-like Apple frameworks, or CLI tooling. It should not appear as a cloud connector unless a cloud-safe bridge exists. |

## Provider Readiness Order

1. **GitHub**: lowest ambiguity for skill requirement routing and read-only
   developer workflows.
2. **Google umbrella**: highest user value, but needs careful scope grouping so
   Calendar, Drive, Docs, Sheets, Slides, and Gmail can share one account
   connection without surprising consent.
3. **Notion**: useful for knowledge capture once the provider capability copy
   and workspace boundary are clear.
4. **iMessage / Apple local capabilities**: design as Mac-local first; defer
   until the app has a clear local-capability approval and audit surface.

## Google Umbrella Principle

Use one Google account connection as the identity anchor. Individual capability
rows can still show Gmail, Calendar, Drive, Docs, Sheets, and Slides status, but
the user should not be asked to sign into the same Google account repeatedly for
each surface. When a new Google capability lands, request only the incremental
scope needed for that accepted slice.

## iMessage Principle

iMessage should be considered a Mac-local capability before it is considered a
cloud connector. A likely implementation path is a paired Mac gateway using
local APIs or automation. That means:

- The user must understand the action runs on a reachable Mac.
- The capability needs local approval, logging, and a disable path.
- Cloud gateways should not claim iMessage support unless they can safely route
  through a trusted paired Mac.
- OAuth provider credentials are not expected for this lane.

## Handoff Rules

- Create or update a provider-specific issue before requesting credentials.
- List exact redirect URI, bundle id, provider app type, and scopes.
- Separate public config from secrets.
- Describe where credentials will live before asking for them.
- Add a rollback or disable path for any provider enabled in production.
