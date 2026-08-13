# API Versioning Design

## Problem Statement

RemClaw has three independently deployed components:

1. **iOS/Mac apps** -- distributed via App Store; users update on their own schedule, often weeks behind the latest release.
2. **Backend** -- Node.js/Express on Railway; deployed instantly via `railway up`.
3. **Per-user gateways** -- OpenClaw binary on Fly.io; Docker image updated independently per user.

Today, there is **no version negotiation** between the iOS client and the backend. The backend can ship a breaking change (rename a JSON field, remove an endpoint, change response shape) and every older client in the field will break immediately with no warning and no fallback path.

### Concrete risks from the current codebase

- **Response shape changes**: The iOS app hard-decodes `GatewayCredentialsResponse` (fields: `gatewayUrl`, `gatewayToken`, `hostingProvider`) from `GET /me/credentials`. Provider API keys are deliberately excluded from this device-facing contract. If the backend renames `gatewayUrl` to `gateway_url` or adds a required wrapper object, every shipped client fails silently or crashes.
- **Endpoint removal**: The deploy flow (`POST /deploy`, `GET /deploy/status`) is called from both iOS and Mac. Removing or restructuring these endpoints breaks onboarding for all clients that haven't updated.
- **New required fields**: If `POST /auth/login` starts requiring a new field (e.g., `client_platform`), older clients that don't send it get 400 errors and can't sign in.
- **Task API evolution**: The tasks CRUD surface (`/api/v1/tasks`) is used by both iOS and Mac with specific field expectations. Adding required fields or changing `formatTask()` output breaks both clients.
- **Gateway protocol mismatch**: The gateway already handles this (see below), but a client built against protocol v3 connecting to a gateway running protocol v4 will get a clean `protocol mismatch` error. The *backend* API has no equivalent mechanism.

## Current State

### What versioning exists today

**Backend API: Visibility only.**
- All routes are mounted under `/api/v1` but this is a static path prefix, not a versioning mechanism. There is no v2, and the v1 prefix has never been used to gate behavior.
- The `requireJwt` middleware checks token validity but does not inspect any client version.
- Request logging reads `X-Client-Version` and `X-Client-Platform` so the backend can observe which app builds are hitting the API. There is no minimum-version enforcement yet.

**iOS/Mac clients: Version and platform headers are sent.**
- Shared `ClientVersion` sets `X-Client-Version` as `<CFBundleShortVersionString>+<CFBundleVersion>` and `X-Client-Platform` as `ios` or `mac`.
- The centralized iOS/Mac authenticated HTTP clients apply both headers automatically.
- Raw backend `URLRequest` call sites for auth/login, refresh, profile/usage, and account deletion call the same shared helper.

**Gateway protocol: Fully versioned.**
- OpenClaw uses `minProtocol`/`maxProtocol` negotiation during WebSocket handshake (`PROTOCOL_VERSION = 3` as of today).
- If client and server protocol ranges don't overlap, the connection is cleanly rejected with a `protocol mismatch` error including the expected version. This is well-designed and does not need changes.

## Proposed Strategy

### 1. Client version header (start here)

Add `X-Client-Version` and `X-Client-Platform` headers to every iOS/Mac request. The version should include the marketing version and build number (for example `1.4.2+42`).

**iOS** -- add a shared `URLRequest` builder or extension:
```swift
extension URLRequest {
    mutating func setRemHeaders(token: String?) {
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        setValue("\(short)+\(build)", forHTTPHeaderField: "X-Client-Version")
        setValue("ios", forHTTPHeaderField: "X-Client-Platform")
    }
}
```

**Mac** -- same pattern in `MacGatewaySessionManager`.

**Backend** -- read and log the headers in middleware (no enforcement yet):
```typescript
function extractClientInfo(req: Request) {
  return {
    version: req.headers['x-client-version'] as string ?? null,
    platform: req.headers['x-client-platform'] as string ?? null,
  };
}
```

This step is **zero-risk** and backward compatible. Old clients that don't send the header just get `null`. Start here because it gives you visibility into what client versions are hitting the backend before you need to enforce anything.

### 2. Minimum version enforcement (add when needed)

When you need to make a breaking change, add a middleware that checks `X-Client-Version` against a minimum:

```typescript
// In env config or database
const MIN_CLIENT_VERSIONS: Record<string, string> = {
  ios: '1.5.0',
  mac: '1.5.0',
};

function requireMinVersion(req: Request, res: Response, next: NextFunction) {
  const clientVersion = req.headers['x-client-version'] as string;
  const platform = req.headers['x-client-platform'] as string;

  // Allow requests without version header (backward compat during rollout)
  if (!clientVersion) return next();

  const minVersion = MIN_CLIENT_VERSIONS[platform];
  if (minVersion && semver.lt(clientVersion, minVersion)) {
    return res.status(426).json({
      error: 'update_required',
      message: 'Please update the app to continue.',
      minimum_version: minVersion,
      update_url: 'https://apps.apple.com/app/rem/id...',
    });
  }
  next();
}
```

Use HTTP 426 (Upgrade Required) -- it's semantically correct and distinct from auth errors.

The iOS app should handle 426 by showing a non-dismissable "update required" screen with a link to the App Store. This is standard practice for mobile apps.

### 3. Additive-only changes as the default

The best versioning strategy is **not needing it**. Most backend changes can be made backward-compatible:

- **Adding fields**: Always safe. Old clients ignore unknown fields (`Codable` in Swift skips them by default).
- **Removing fields**: Make them optional first, wait 2 releases, then remove.
- **Renaming fields**: Send both old and new names for a transition period.
- **New endpoints**: Always safe. Old clients don't call them.
- **Changing field types**: Don't. Add a new field instead.

Document this as a team rule: **"Every backend change must work for clients 2 versions behind."**

### 4. Gateway protocol -- no changes needed

The OpenClaw gateway already has proper protocol versioning via `minProtocol`/`maxProtocol`. The iOS client (via OpenClawKit) sends its supported range, and the gateway rejects mismatches cleanly. This is working well and does not need additional versioning from RemClaw's side.

If you update the gateway Docker image and it bumps `PROTOCOL_VERSION`, the iOS client's OpenClawKit dependency needs to support that version. This is a dependency update, not an API versioning problem.

### 5. Deprecation timeline

For a small team with App Store distribution:
- **2 weeks minimum** between deploying a breaking backend change and requiring the new client version. This gives users time to update.
- **4 weeks preferred** for significant changes (new auth flows, restructured endpoints).
- **Never break auth endpoints** (`/auth/login`, `/auth/refresh`) without a very long runway. If a user can't sign in, they can't update their app state.
- Store `MIN_CLIENT_VERSION` in the database (not hardcoded) so you can adjust it without a backend deploy.

## Implementation Plan

### Phase 1: Visibility (do this now, 1-2 hours)

1. Add `X-Client-Version` and `X-Client-Platform` headers to all iOS `URLRequest` calls (in `RemAuthService`, `restoreGatewayCredentialsIfNeeded`, and anywhere else that calls the backend). **Done for the current Wave 2 release line.**
2. Add the same headers in `MacGatewaySessionManager`. **Done for the current Wave 2 release line.**
3. Add backend middleware that reads and logs these headers. No enforcement. **Done for the current Wave 2 release line.**
4. Ship the iOS/Mac update.

### Phase 2: Monitoring (do this after Phase 1 ships)

1. Add the client version to backend request logs so you can see the distribution of client versions hitting your API.
2. Optionally add a `GET /api/v1/client-config` endpoint that returns feature flags and minimum version. This lets the client check on launch whether it needs an update, without waiting for a 426 on a real request.

### Phase 3: Enforcement (do this when you have a breaking change)

1. Add the `requireMinVersion` middleware to the routes that need it.
2. Add a 426 handler in the iOS/Mac apps that shows an "update required" screen.
3. Set the minimum version in the database.
4. Deploy the backend change.

## What NOT To Do

- **Don't add URL-path versioning** (e.g., `/api/v2/tasks`). You already have `/api/v1` in all your paths. Adding `/api/v2` means maintaining two sets of route handlers forever. For a small team, this is a maintenance nightmare. Header-based versioning is simpler and more flexible.

- **Don't build an API gateway or proxy layer.** Tools like Kong, Traefik, or custom reverse proxies add operational complexity that a small team doesn't need. Express middleware is enough.

- **Don't version individual endpoints.** "This endpoint is v3 but that one is v2" creates confusion. Version the whole API surface together with a single minimum client version.

- **Don't use GraphQL.** It solves a different problem (flexible querying across many clients). RemClaw has two clients (iOS and Mac) that you control. REST with additive changes is simpler.

- **Don't over-invest in backward compatibility infrastructure before you have a breaking change.** Phase 1 (adding the header) takes an hour and gives you everything you need to make decisions later. Don't build the enforcement middleware until you actually need it.

- **Don't forget the Mac app.** It's easy to focus on iOS and forget that `MacGatewaySessionManager` makes the same backend calls. Both clients need the version header.

- **Don't conflate gateway protocol versioning with backend API versioning.** They are independent concerns. The gateway protocol is already well-versioned. The backend API is the gap.
