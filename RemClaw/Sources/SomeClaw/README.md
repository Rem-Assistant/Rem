# SomeClaw Relay Client (iOS, DEBUG only)

> Internal-only mobile client for the SomeClaw Claude Code wrapper, exposed
> over a WebSocket relay (`relay_server.py`). Tracked under #94. Only
> compiled into Debug builds — there is no release surface.

## Architecture

```
iPhone (RemClaw, Debug build)
  → SomeClawClient (URLSessionWebSocketTask)
  → wss://192.168.1.x:8888/ws (self-signed TLS, optional)
    → SSH tunnel to dev VM
      → relay_server.py (port 18790, Python/aiohttp)
        → Plugboard local REST proxy (port 8087)
          → Claude API
```

The client is **deliberately self-contained** — no `OpenClawKit` or other
gateway dependency. SomeClaw is a separate Claude Code wrapper, not a Rem
gateway, so wiring it through `RemGatewaySessionManager` would be wrong.

## Files

| File | Purpose |
|------|---------|
| `SomeClawClient.swift` | `URLSessionWebSocketTask`-based client. Handles connect/disconnect, JSON encode/decode, exponential-backoff reconnect, WebSocket-level pings, and an opt-in self-signed-cert trust override. Exposes incoming events as an `AsyncStream`. |
| `SomeClawChatViewModel.swift` | `@Observable` UI state for one chat session: messages array, streaming buffer, thinking flag. Pure reducer that takes `IncomingEvent` and produces UI changes — unit-testable without a live WebSocket. |
| `SomeClawChatView.swift` | Chat surface — bubbles, animated thinking dots, single-line composer with submit-to-send. Uses system colors so we can pull this whole folder later without touching `DesignTokens`. |
| `SomeClawSettingsView.swift` | Endpoint config (URL + cert toggle), live connection status row, connect/disconnect button, navigation link to `SomeClawChatView`. Persists endpoint and cert flag in `UserDefaults` under `debug.someclaw.*` keys. |

The `RemClaw` `SettingsView` passes a `debugSectionContent` closure into
`SharedSettingsView` (also added in #94) so the SomeClaw entry appears in
the Settings list under a "Debug" section in DEBUG builds only. The Mac
`MacFullSettingsView` does not pass that closure, so SomeClaw is never
visible on macOS.

## Protocol

| Direction | Type | Fields |
|-----------|------|--------|
| Client → | `message` | `session_id`, `text` |
| Client → | `new_session` | `session_id` |
| Client → | `list_sessions` | — |
| Client → | `clear_session` | `session_id` |
| ← Server | `status` | `session_id`, `state` |
| ← Server | `chunk` | `session_id`, `text`, `done` |
| ← Server | `response` | `session_id`, `text`, `done` |
| ← Server | `error` | `session_id`, `text` *or* `error` |
| ← Server | `sessions` | `sessions[]` (string ids or objects with `id`) |

The relay sends `error` either with a `text` field or an `error` field —
`SomeClawEventDecoder` accepts both.

## Self-signed TLS

Default: `allowSelfSignedCert = true`. The override only bypasses identity
verification — the channel itself is still TLS-encrypted. Toggle in
`SomeClawSettingsView`. Backed by a separate `URLSessionDelegate` so the
trust callback is `nonisolated`.

## Testing

`RemClawTests/SomeClawClientTests.swift` covers:

- `SomeClawEventDecoder` — every protocol event type (status / chunk /
  response / error / sessions / unknown), including the `error`/`text`
  fallback and the string-vs-object form of `sessions`.
- `SomeClawChatViewModel` — chunk accumulation, the `response`-after-`chunk`
  case (final response should not clobber streamed text the user already
  read), error handling, and the local clear.

WebSocket I/O is intentionally not exercised by unit tests — the client is
small and the real surface area we care about (event decoding + view-model
reducer) is covered without bringing up a server.

## Open Items

See #94 — voice mode integration, server-side session history, auth on the
WebSocket handshake, and longer-term distribution all remain to be designed.
