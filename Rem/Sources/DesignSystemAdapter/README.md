# DesignSystemAdapter (iOS)

> The thin adapter between the app and the canonical Rem design system
> ([Rem-Assistant/Rem-Design-System](https://github.com/Rem-Assistant/Rem-Design-System)). It maps the app's
> existing state onto the design system's display values and routes the design system's actions back
> to the app's existing calls. Auth, subscriptions, model selection (managed or BYOK), backend
> transport, persistence and approvals stay where they are.

## Directory Structure

```
DesignSystemAdapter/
└── DesignSystemProbeView.swift   # Phase 1a: proves the package resolves, links and renders
```

## Rules

- `import RemDesignSystem` only in this folder. The app module defines types with the same names
  (`RemFaceMark`, `MessageBubble`, `DesignTokens`, …), so always qualify design-system types as
  `RemDesignSystem.<Type>`.
- The package is pinned by `revision` in `Rem.xcodeproj` and `Package.resolved`. Bump the pin
  deliberately.
- iOS target only. macOS is out of scope for now.

## Phases

1. **1a (this change):** add the package and the probe view.
2. **1b:** ordinary Chat through `ChatScreen`, behind a DEBUG launch flag, reusing the existing send
   path unchanged.
3. **1c:** the long-press message sheet and the model menu.
4. **2:** task chat, Inbox, Agent activity.
5. **3:** Settings.
