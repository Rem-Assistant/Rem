# Components (iOS)

> A toolkit of reusable UI building blocks used across the iOS app: the task/event row you see in Agenda and Inbox, a shimmer loading skeleton for it, a status menu for marking tasks done, a "gateway disconnected" warning banner, a circular countdown ring, permission utilities, and the generic sign-in button.

Reusable SwiftUI components shared across the iOS app's views.

## Key Files

| File | Purpose |
|------|---------|
| `TaskEventRowView.swift` | Primary task/event row: time indicator (with tappable date picker for agenda), title, calendar badge, duration/priority pills, overdue indicator. Contains `PillView` and `OverduePillView` subcomponents. |
| `TaskEventRowSkeleton.swift` | Shimmer loading placeholder mirroring `TaskEventRowView` layout. Uses `shimmering()` modifier for animation. |
| `TaskStatusIndicator.swift` | Interactive status menu (To Do → In Progress → Completed). Uses `StatusUpdateDebouncer` actor (300ms) to prevent rapid overlapping sync requests. |
| `GatewayDisconnectedBanner.swift` | Connection status banner with state-specific icons, titles, action buttons, and an optional Review CTA into the shared connection recovery surface. Uses `ultraThinMaterial` background. |
| `PermissionUtils.swift` | `PermissionType` enum + `PermissionChecker` utility for checking/requesting the App Store-approved iOS permissions (Calendar, Reminders, Microphone, Notifications, Speech Recognition, Camera). Contacts and Location are intentionally omitted from the iOS release path. Includes `PermissionStatusBadge` view. |
| `SignInButton.swift` | Generic sign-in button with ViewBuilder icon, title, and action closure. Full-width with DesignTokens styling. |
| `DailyBriefCard.swift` | Inline Agenda summary with separate open-chat and explicit `Read latest brief`/Stop playback actions; avoids nested buttons. The card and Read action are available only for an exact backend-authorized canonical Today transcript—synthesized `/brief` fallback prose never becomes an unavailable CTA. The pure presentation resolver prefers the canonical summary, then a concise canonical-markdown excerpt; count capsules appear only for a genuinely prose-less structured brief, so a zero-count artifact never renders synthesized `0 of 0` copy. Its accessibility label uses that same resolved prose. The header renders the brief's AUTHORED headline (`DailyBrief.briefHeadline`, from `daily_brief_artifacts.headline`) — the same string the orchestrator chat titles itself with via `BriefContext.displayTitle` — and falls back to the clock-derived time-of-day greeting only when the artifact carries no headline. Reading routes into the durable Today voice conversation rather than narrating the compact Agenda summary in place. After the full authored brief finishes, Agenda adopts that exact transcript before an account- and brief-qualified local completion receipt changes the action to `Read again`; stopping early, switching accounts, or merely continuing the chat does not mark the current brief read. |
| `DailyBriefAgendaPresentation.swift` | Pure presentation resolver for the Agenda summary card — `title`, `prose`, `shouldShowCounts`, `markdownExcerpt` — split out of `DailyBriefCard.swift` so it imports **Foundation only**. That split is load-bearing: `title` is one half of the "one headline, both surfaces" contract (the other half is `BriefContext.displayTitle`), and keeping it free of SwiftUI/UIKit lets the convergence check compile and run on macOS, so the two titles can be asserted against the same decoded `DailyBrief` without booting a simulator. Keep this file UI-import-free. |

## Patterns & Conventions

- **DesignTokens**: All components reference centralized `DesignTokens` (colors, typography, spacing) — no hardcoded values.
- **ViewBuilder composition**: `SignInButton` and `TaskEventRowView` use `@ViewBuilder` for flexible content slots.
- **Debounced sync**: `TaskStatusIndicator` uses an actor-based debouncer to batch rapid status changes into single network requests.
- **Skeleton pattern**: `TaskEventRowSkeleton` mirrors `TaskEventRowView` layout exactly for seamless loading transitions.
- **Environment services**: `TaskStatusIndicator` and `GatewayDisconnectedBanner` access `RemGatewaySessionManager` and `taskSyncService` via `@Environment`.
- **Conditional compilation**: `PermissionUtils` uses `#if canImport()` guards for platform-specific APIs (AVFoundation, EventKit, UserNotifications).

## Shared Components

- `MiniPlayerBar` now lives in `Shared/Views/Components/MiniPlayerBar.swift` so
  active voice/focus controls use one shared visual component inside and outside
  chat. Keep iOS-only wrappers thin and pass platform state into the shared
  component instead of creating another mini bar.
