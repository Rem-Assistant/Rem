# Connection Reliability Analysis

## Overview

RemClaw maintains **two simultaneous WebSocket connections** to the per-user OpenClaw gateway:

1. **Node session** (`role: "node"`) — advertises device capabilities, receives AI tool invocations
2. **Operator session** (`role: "operator"`) — handles chat transport (`chat.send`, `chat.history`, `sessions.list`)

Both must be connected for the app to function. The UI shows `.connected` only when **both** sessions are up.

## Observed Issues

### Issue 1: "Disconnected" / "Unreachable" in Settings View

The gateway connection drops or fails to establish, showing "Unreachable" or "Disconnected" in the Settings view.

### Issue 2: "Operation timed out" When Sending Messages

When sending a chat message, the `chat.send` request times out with: `"gateway receive: The operation couldn't be completed. Operation timed out"`

### Issue 3: "Approval Pending" With `device signature invalid`

The app can show `Approval Pending` even though the gateway never creates a
pending device request. In live Fly validation on 2026-05-11, gateway logs showed
the connection closing with `device signature invalid` before
`device.pair.list` contained any iOS pending request.

The root cause was a deployed-gateway/client compatibility mismatch:

- the Swift OpenClawKit client signed the gateway connect request with the v3
  device-auth payload;
- current OpenClaw gateway server code accepts v3 and falls back to v2, but older
  deployed Fly gateways may verify only the v2 canonical payload;
- when an older gateway receives a v3-signed Swift connect request, it rejects the
  device before pairing can begin, so backend auto-approve finds no pending
  device to approve.

Fix direction:

- keep managed Fly gateways upgradable through the backend image-update path;
- keep the Swift client compatible with older deployed gateways by signing with
  the v2 canonical payload until the gateway fleet is known to be uniformly
  upgraded;
- on explicit managed-cloud re-pair, rotate local device identity and clear cached
  device-auth state before reconnecting.

Validation signal after the fix:

- gateway/app logs move from `device signature invalid` to `pairing required`;
- backend auto-approve succeeds;
- the operator session connects;
- Settings > Gateways shows `Connected`.

---

## Connection Flow

```
connectIfConfigured()
  └─ GatewayClient.connect(provider)
       ├─ 1. setState(.connecting)
       ├─ 2. Convert HTTPS URL → WSS URL
       ├─ 3. Build capabilities + permissions snapshot
       ├─ 4. Connect operator session FIRST  ← if fails, .unreachable immediately
       └─ 5. Connect node session SECOND     ← if fails, .unreachable
              ├─ onConnected → both up? → .connected → start keepalive
              └─ onDisconnected(reason)
                   ├─ "pairing" → .pairingRequired → auto-approve
                   ├─ "unauthorized/1008" → .unauthorized
                   └─ other → .unreachable → scheduleReconnect()
```

## Message Send Flow

```
sendMessage()
  ├─ 1. ensureNodeConnected()     ← probes NODE only (5s timeout)
  ├─ 2. patchSessionDefaults()    ← sessions.patch (10s timeout)
  └─ 3. chat.send                 ← via OPERATOR session (125s timeout)
         └─ AI processes, invokes device tools via node
```

## Timeout Reference

| Operation | Timeout | File:Line |
|-----------|---------|-----------|
| Node health probe | 5s | `GatewayClient.swift:256` |
| Operator health check | 5s | `GatewayClient.swift:341` |
| Keepalive interval | 20s | `GatewaySessionManager.swift:50` |
| `chat.send` (WebSocket RPC) | 125s | `RemChatTransport.swift:241` |
| `chat.send` (gateway param) | 120,000ms | `RemChatTransport.swift:226` |
| `chat.history` | 15s | `RemChatTransport.swift:162` |
| `sessions.patch` | 10s | `GatewaySessionManager.swift:403` |
| `chat.abort` | 10s | `RemChatTransport.swift` |
| Auto-approve (iOS→backend) | 45s | `GatewaySessionManager.swift:217` |
| Auto-approve (backend loop) | 30s | `gateway.routes.ts:55` |
| Config patch (backend WS) | 15s | `gateway-pair.service.ts:114` |
| Reconnect backoff | 1s→30s max | `GatewaySessionManager.swift:160` |
| Post-reconnect grace | 2s | `GatewaySessionManager.swift:365` |

## Reconnection Mechanisms

### 1. Auto-Reconnect (Exponential Backoff)
- Triggered when state becomes `.unreachable`
- Delays: 1s, 2s, 4s, 8s, 16s, max 30s
- Resets to 0 on successful `.connected`

### 2. Node-Only Reconnect (Keepalive)
- Every 20s, probes node with a `health` RPC (5s timeout)
- If dead, reconnects only the node session (preserves operator/chat)
- Falls back to full reconnect if node-only reconnect fails

### 3. Foreground Reconnect
- `scenePhase == .active` triggers check
- If not connected → full `reconnect()`
- If connected → `reconnectIfPermissionsChanged()` → probe node

### 4. Auto-Approve Pairing
- Node disconnect with "pairing required" → `POST /api/v1/approve-device`
- Backend polls gateway's `device.pair.list` for up to 30s
- On approval, iOS reconnects after 2s grace period

---

## Root Cause Analysis

### Why Gateway Connection Times Out (Issue 1)

**RC-1: No timeout on initial WebSocket handshake.**
`GatewayClient.connect()` calls `nodeSession.connect()` and `operatorSession.connect()` without an explicit timeout wrapper. These rely on OpenClawKit's internal timeout, which may be very long. If the gateway is slow (Fly.io cold start, network latency), the app hangs at "Connecting..." indefinitely.

**RC-2: Fly.io cold starts add 5-15 seconds.**
Per-user gateways on Fly.io can be suspended when idle. The first connection attempt hits a cold machine, and the WebSocket handshake may fail before the machine is ready. The app transitions to `.unreachable` and starts backoff, compounding the perceived delay.

**RC-3: Sequential operator-then-node connection.**
If the operator fails (line 134-140), the entire connection attempt fails immediately. A single flaky operator handshake blocks everything.

### Why Message Sending Times Out (Issue 2)

**RC-4: `ensureNodeConnected()` doesn't check the operator session.**
At `GatewaySessionManager.swift:356`, the pre-send health check probes `probeNodeAlive()` but never verifies the operator session. If the operator silently dropped (iOS backgrounding, network switch), `ensureNodeConnected()` passes, then `chat.send` goes to a dead operator WebSocket and times out after **125 seconds** with no recourse.

**RC-5: No operator keepalive.**
The 20-second keepalive only monitors the node session. The operator session has **zero health monitoring**. A silently dead operator is only discovered when the user tries to send a message and waits 125 seconds for a timeout.

**RC-6: Post-reconnect grace period is too short.**
`ensureNodeConnected()` sleeps only 2 seconds after triggering reconnect (line 365). If the reconnect takes longer (Fly.io cold start), `chat.send` proceeds against a partially-connected node, and tool invocations fail silently.

### Why Approval Pending Can Have No Pending Request (Issue 3)

**RC-7: Device-auth payload version drift.**
OpenClaw's gateway protocol can evolve independently from already-deployed per-user
gateway images. A client and current server may both know about a newer auth
payload, while an older deployed gateway still verifies the older payload only.
This is distinct from OpenClaw's `minProtocol`/`maxProtocol` WebSocket protocol
negotiation because the signature is checked during connect authentication.

**RC-8: Backend auto-approve depends on a pending request existing.**
`POST /api/v1/approve-device` can only approve requests the gateway has accepted
far enough to list in `device.pair.list`. If signature verification fails first,
there is no pending request and the backend correctly reports that no pending
device was found.

---

## Identified Gaps

### Gap 1: No Operator Session Keepalive
The node gets probed every 20s. The operator gets nothing. This is the most likely cause of chat timeouts.

**Fix:** Probe the operator session alongside the node in `startKeepalive()`. If dead, reconnect it independently.

### Gap 2: Pre-Send Check Ignores Operator Health
`ensureNodeConnected()` should also probe the operator before allowing `chat.send`.

**Fix:** Add an `ensureOperatorConnected()` or combined `ensureBothSessionsConnected()` method.

### Gap 3: No Connection-Level Timeout
The initial `connect()` calls have no explicit timeout wrapper.

**Fix:** Wrap `nodeSession.connect()` and `operatorSession.connect()` in a `Task` with a 15-second timeout. Fail fast instead of hanging.

### Gap 4: `reconnectNodeOnly()` is Fire-and-Forget
Called at line 107 (keepalive) and line 348 (foreground) without awaiting or verifying success.

**Fix:** Await the reconnect, verify with a follow-up probe, and transition to `.unreachable` if it fails.

### Gap 5: No User Feedback During Reconnection
UI shows static "Unreachable" without indicating retry progress.

**Fix:** Expose `reconnectAttempt` and next retry time to the UI. Show "Retrying in Xs..." in the banner.

### Gap 6: `hasRequestedAutoApprove` Guard Can Deadlock
Set to `true` at line 176, only resets after 10 seconds (line 200). Manual "Pair Device" tap within that window is silently ignored.

**Fix:** Reset the flag on explicit user action, not just on a timer.

---

## Recommended Improvements (Prioritized)

### P0 — Fix Chat Timeout (Biggest User Impact)

1. **Add operator keepalive** — Probe operator session every 20s alongside node. If dead, reconnect it.
2. **Pre-send operator check** — Verify operator is alive before `chat.send`. Prevents 125s timeout on dead socket.

### P1 — Improve Initial Connection Reliability

3. **Explicit connection timeout** — Wrap `connect()` with 15s timeout. Fail fast on slow/cold gateways.
4. **Fly.io cold start handling** — Detect cold start scenario, use 30s timeout on first attempt, show "Gateway starting..." UI.

### P2 — Better Recovery & UX

5. **Await and verify reconnects** — Make keepalive/foreground reconnect await results and verify.
6. **Show retry progress** — "Retrying in Xs..." instead of static "Unreachable".
7. **Fix auto-approve deadlock** — Reset `hasRequestedAutoApprove` on explicit user tap.

### P3 — Robustness

8. **Connection timeout for operator-then-node** — If operator connects but node fails, retry node independently instead of full reconnect.
9. **Backoff cap visibility** — Log and surface when max backoff (30s) is reached.

### Gateway Fleet Compatibility

10. **Update managed Fly gateway images in batches** — Use the backend
    image-update script to roll managed gateways forward while preserving `/data`
    volumes. Start with `--dry-run` and a small `--limit`.
11. **Keep client auth backward-compatible** — Do not assume every user gateway is
    on the newest OpenClaw image. Client compatibility should cover older
    deployed gateways, local Mac gateways, and self-managed gateways where
    feasible.
12. **Record live proof for upstream protocol fixes** — When contributing fixes
    upstream to OpenClaw, include redacted before/after logs or screenshots. A
    source-level explanation is useful, but upstream review expects inspectable
    behavior proof for auth/protocol changes.
