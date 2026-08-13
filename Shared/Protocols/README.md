# Shared/Protocols

Cross-platform protocol and type compatibility layer for gateway session managers and task surfaces.

## Files

| File | Purpose |
|------|---------|
| `GatewaySessionProviding.swift` | Protocol + GatewayConnectionState enum. Defines the contract both iOS and macOS session managers conform to. |
| `GatewaySessionConformance.swift` | Backward-compat typealiases (RemGatewayConnectionState, MacConnectionState, MacLinkedDevice, etc.) so existing code compiles without changes. |
| `TaskDisplayable.swift` | Read-only task contract the shared task views render from (`TaskEvent` on iOS, `MacTask` on Mac), plus `TaskStoreProviding`. Carries the backend's structured fields — `runStatus` (migration 019) and `staleAt` (migration 116) — each with a `nil` default so previews and fixtures keep compiling. Derived accessors (`resolvedRunStatus`, `isStale`, `deemphasisReasons`, `isDeemphasized`) live here so every surface resolves them identically. |

## Adding a backend-owned field

Give it a default in the protocol extension, mirror it unconditionally **including `nil`** in both
sync paths (`RemTaskSyncService` pull + `TaskSyncManager` write-ACK), and derive the view's decision
here rather than in each view — a second copy of the rule is how two surfaces start disagreeing.
`staleAt` is the worked example: it is read *alongside* `status`, never folded into it.
