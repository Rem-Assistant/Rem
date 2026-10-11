# DesignSystemAdapter (iOS)

> The thin adapter between the app and the canonical Rem design system
> ([Rem-Assistant/Rem-Design-System](https://github.com/Rem-Assistant/Rem-Design-System)). It maps the app's
> existing state onto the design system's display values and routes the design system's actions back
> to the app's existing calls. Auth, subscriptions, model selection (managed or BYOK), backend
> transport, persistence and approvals stay where they are.

## Directory Structure

```
DesignSystemAdapter/
├── DesignSystemAdapterFlag.swift # The DEBUG `--rem-ds-chat` launch flag behind every surface below
├── RemChatScreenAdapter.swift   # Ordinary and task chat through ChatScreen; Agent activity from the header
├── ChatDisplayMapper.swift      # Pure app state → DS values (header, composer, transcript, empty state)
├── ChatActionRouter.swift       # DS actions → existing app calls (send path, abort, voice, sheet rows)
├── RemInboxScreenAdapter.swift  # Phase 2: the Inbox through InboxScreen
└── TaskDisplayMapper.swift      # Pure tasks → DS values (Inbox rows, task chat header, Agent activity)
```

Tests: `RemTests/ChatDisplayMapperTests.swift`, `RemTests/TaskDisplayMapperTests.swift`.

## Rules

- `import RemDesignSystem` only in this folder (and in tests of it). The app module defines types
  with the same names (`RemFaceMark`, `MessageBubble`, `DesignTokens`, `RemComposerBar`, …), and app
  types shadow imported ones, so always qualify design-system types as `RemDesignSystem.<Type>`.
- The package is pinned by `revision` in `Rem.xcodeproj` and `Package.resolved`. Bump the pin
  deliberately. Contract: `docs/contracts/chat-adapter.md` in the design-system repo.
- iOS target only. macOS is out of scope for now.
- The adapter owns no effects of its own. Sending goes through `Shared/ViewModels/ChatSendCoordinator`,
  the same path `SharedRemChatView` uses; everything else is an existing `RemChatViewModel` call or a
  hook `RemChatView` already had.
- Truth over completeness: never infer a receipt, never offer an action the app cannot perform, and
  label anything the design system cannot show yet as shown in the classic chat, with a button that
  hands the conversation back.

## Chat (phases 1b and 2)

Launch a DEBUG build with `--rem-ds-chat` (Product → Scheme → Edit Scheme → Run → Arguments).
`RemChatView` then renders `RemChatScreenAdapter` for ordinary chats and, since phase 2, **task chats**
(`rem-task-<uuid>` session keys, `runtimeOwnsConversation`). These stay on the classic
`SharedRemChatView`: the durable brief conversation (brief preview, resolved brief, suggestion
snapshot, scroll-to-brief), voice (talk mode active or auto-start), and any conversation the person
handed back with **Open classic chat**. The same flag switches the Inbox tab (below). Release builds
never read the flag (`DesignSystemAdapterFlag`).

| Design system | From the app |
|---|---|
| `ChatHeaderDisplay.activity` | `Working` while `pendingRunCount > 0`, else `GatewayConnectionState.shortStatusText` (`Connected` for runtime-owned chats); task chats: see below |
| `ChatHeaderDisplay.status` | `.needsYou` only when `needsDeviceRePair`, else `.connected` |
| `ChatHeaderDisplay.isWorking` | `pendingRunCount > 0` |
| `showsBack` / `showsOverflow` / `showsActivityDetails` | `true` / `false` / `true` (no overflow route; the capsule opens Agent activity) |
| `showsCall` | voice hook present and quota available |
| `ChatComposerState.draft` | `RemChatViewModel.input` |
| `attachments` | `RemPendingAttachment`: id = UUID string, title = file name, `image/*` → `.image`, else `.file` |
| `availability` | `.disabled(reason:)` when quota is denied (banner text), while a send is being prepared (model repair + quota, no run to cancel yet), or while an explicit model waits for provider evidence; else `.enabled` |
| `phase` | `.idle` with no pending run; `.sending` with a run and no streamed text; `.streaming` once text arrives |
| `voiceAvailable` | voice hook present and quota available |
| `showsModel` | `RemChatViewModel.showsModelPicker` (the catalog is non-empty), as the classic picker |
| `modelLabel` | `ModelPickerPresentation.composerTitle` for the effective selection |
| `ChatModelMenu.providers` | `ModelPickerPolicy.composerGroups` with the runtime provider evidence, exactly the classic picker's groups: managed MiniMax only, BYOK providers only when runtime-authenticated, none until evidence is authoritative; ids are `selectionID`s, names via `ModelUserFacingCopy` |
| `ChatModelMenu.selection` | `ChatSendCoordinator.effectiveModelSelectionID`; `defaultModelSelectionID` ↔ `.automatic` |
| `ChatMessageDisplay` | user/assistant prose only, cleaned by `MessageCleaner` via `SharedRemChatView.splitContent`, after the classic `visibleMessages` collapse |
| `delivery` | always `.none`: the app has no acceptance or read evidence |
| `time` | the message's own timestamp, host-formatted (short time); none without one |
| `meta` | `Cloud browser` on a user turn sent with the browser chip |
| `.timestamp` entries | the classic chat's `separatorLabels` |
| `.hostContent` | tool-result messages with standalone cards → app `ToolResultCardView`; activity (thinking, tool calls, folded results; consecutive ones collapse), attachments and inline payloads of a message, unknown roles → labelled classic hand-back; a live run → `Working`; `errorText` → error row |
| `ChatEmptyState` | `Start a conversation` with the classic subtitle and starters; hidden while history is pending (`ChatEmptyStateGate.isInitialHistoryPending`) or a draft is present |

| Action | App call |
|---|---|
| `composer(.send)` | `ChatSendCoordinator.prepare` + `dispatch` (quota slot via `RemChatView.consumeQuotaSlot`) |
| `composer(.cancel)` | `RemChatViewModel.abort()` |
| `composer(.draftChanged)` | `RemChatViewModel.input` |
| `composer(.add)` | image file importer → `SharedRemChatView.importImageFiles` (Photos and camera stay classic) |
| `composer(.removeAttachment)` | `RemChatViewModel.removeAttachment(_:)` |
| `composer(.speak)`, `call` | `RemChatView.onVoiceTap` (starting voice switches to the classic surface, which owns the voice UI) |
| `back` | `dismiss` |
| `activityDetails` | pushes `AgentActivityScreen` (`navigationDestination(isPresented:)` on the app's `NavigationStack`) |
| `starter` | fills the draft and focuses it, like the classic starters |
| `transcript(.requestActions)` | `RemDesignSystem.MessageActionSheet` with Reply, Copy, Select Text; no reactions |
| Reply / Copy / Select Text | quote into the draft / `UIPasteboard` / a selectable text sheet |
| `ChatModelMenu` select | `RemChatViewModel.selectModel(_:)`, the classic picker's call |
| `ChatModelMenu` Manage Models | the classic Manage Models sheet (`RemChatView`'s gateway-backed `SharedModelsSettingsScreen`) |

The design-system composer disables its model trigger whenever input is disabled or a turn is in
flight (`ChatComposerState.modelEnabled`). The classic picker stays open in more states (only
preparing or sending a message closes it), so it can offer Automatic while an explicit model waits for
provider evidence; the design-system surface cannot until the design system lets the host enable the
menu separately.

## Task chat (phase 2)

A task chat is the same `ChatScreen` with the same send path: `ChatSendCoordinator` →
`RemChatTransport`, which routes a `rem-task-<uuid>` session's turns to the task continuation
(`TaskChatTranscriptCoordinator`), and `RemChatView.consumeQuotaSlot` already skips the gateway slot
for task sessions. Nothing about sending changes. Only the header differs, from the task's own run
state (`TaskStore.allTasks`, passed to `RemChatView.designSystemTaskRecords` as plain
`DesignSystemTaskRecord`s):

| Design system | From the app |
|---|---|
| `ChatHeaderDisplay` | `Working` (thinking face) while `pendingRunCount > 0`; else `InboxItemState.header` for the task's state (table below), the same truth its Inbox row shows; `Connected` when the task is not loaded |
| `showsBack` / `showsOverflow` / `showsActivityDetails` / `showsCall` | `true` / `false` / `true` / voice hook present and quota available |

Like the classic chat, the add button stays available although the task transport rejects attachments
("Task conversations do not support attachments yet."); the design-system composer has no way to hide it.

## Inbox (phase 2)

With the flag, `ContentView`'s Inbox tab renders `RemInboxScreenAdapter` over the same
`InboxViewModel.unscheduledTasks` instead of `InboxView`.

| Design system | From the app |
|---|---|
| `InboxItemDisplay.id` | the task's UUID string |
| `title` | `TaskEvent.title` (`Untitled task` when blank) |
| `state` (`InboxItemState`) | completed task → `.completed`; no run status or `idle` → `.none`; `running` → `.executing`; `review`, `blocked` → `.blocked` (Needs you; never `.needsApproval`, the app has no approval for it); `done` → `.completed`; unrecognized → `.unknown` |
| `empty` | `RemContentUnavailableView` with the classic copy (Inbox is empty / Tasks you capture will appear here) |

| Action | App call |
|---|---|
| `InboxAction.open` | `navigationPath.append(task.id)`: the classic row's `NavigationLink(value:)` destination, task detail, from which the existing task chat opens |
| pull to refresh | `InboxViewModel.pullToRefresh()` |

Not offered (no design-system equivalent yet): the classic swipe actions (complete, snooze, delete), inline
scheduling and calendar info on rows, and the hydrating skeleton.

## Agent activity (phase 2)

The chat header capsule (ordinary and task chats) pushes `AgentActivityScreen`.

| Design system | From the app |
|---|---|
| `AgentActivityDisplay.current` | `AgentActivityCurrent(header)`: exactly the chat header's state, never derived from history |
| `days` | finished agent runs on loaded tasks: `runStatus` `review` / `blocked` / `done` with a `runStartedAt`, newest first, grouped by the run's start day (Today, Yesterday, then a short date) |
| `AgentActivityEvent` | id = task UUID, title = task title, outcome = `TaskRunStatus.displayName` (Done, Needs review, Needs attention), time = `Started <short time>`: the app records only when a run started, so no finish time is shown |
| Approvals tab | the design system's labelled data gap (the app has no approvals data) |

No new data is fetched: the app has no agent-level activity feed, so the timeline is what the loaded
tasks already carry. With no finished runs the design system's empty state shows. Per-task comment
threads (`TaskActivityHistoryView`) stay in task detail; rows are not interactive.

## Phases

1. **1a:** add the package and a probe view (removed in 1b; the Chat adapter supersedes it).
2. **1b:** ordinary Chat through `ChatScreen`, behind the DEBUG `--rem-ds-chat` flag,
   reusing the existing send path unchanged.
3. **1c:** the model menu (done: wired to the classic picker's policy and calls); the long-press
   message sheet's remaining rows.
4. **2:** task chat, Inbox, Agent activity (done, behind the same flag).
5. **3:** Settings.
