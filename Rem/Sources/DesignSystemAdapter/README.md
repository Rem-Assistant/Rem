# DesignSystemAdapter (iOS)

> The thin adapter between the app and the canonical Rem design system
> ([Rem-Assistant/Rem-Design-System](https://github.com/Rem-Assistant/Rem-Design-System)). It maps the app's
> existing state onto the design system's display values and routes the design system's actions back
> to the app's existing calls. Auth, subscriptions, model selection (managed or BYOK), backend
> transport, persistence and approvals stay where they are.

## Directory Structure

```
DesignSystemAdapter/
├── RemChatScreenAdapter.swift   # Phase 1b: ordinary chat through RemDesignSystem.ChatScreen
├── ChatDisplayMapper.swift      # Pure app state → DS values (header, composer, transcript, empty state)
└── ChatActionRouter.swift       # DS actions → existing app calls (send path, abort, voice, sheet rows)
```

Tests: `RemTests/ChatDisplayMapperTests.swift`.

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

## Chat (phase 1b)

Launch a DEBUG build with `--rem-ds-chat` (Product → Scheme → Edit Scheme → Run → Arguments).
`RemChatView` then renders `RemChatScreenAdapter` for **ordinary** chats only. These stay on the classic
`SharedRemChatView`: task chats (`runtimeOwnsConversation` / task session keys), the durable brief
conversation (brief preview, resolved brief, suggestion snapshot, scroll-to-brief), voice (talk mode
active or auto-start), and any conversation the person handed back with **Open classic chat**. Release
builds never read the flag.

| Design system | From the app |
|---|---|
| `ChatHeaderDisplay.activity` | `Working` while `pendingRunCount > 0`, else `GatewayConnectionState.shortStatusText` (`Connected` for runtime-owned chats) |
| `ChatHeaderDisplay.status` | `.needsYou` only when `needsDeviceRePair`, else `.connected` |
| `ChatHeaderDisplay.isWorking` | `pendingRunCount > 0` |
| `showsBack` / `showsOverflow` / `showsActivityDetails` | `true` / `false` / `false` (no overflow or activity routes yet) |
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

## Phases

1. **1a:** add the package and a probe view (removed in 1b; the Chat adapter supersedes it).
2. **1b:** ordinary Chat through `ChatScreen`, behind the DEBUG `--rem-ds-chat` flag,
   reusing the existing send path unchanged.
3. **1c:** the model menu (done: wired to the classic picker's policy and calls); the long-press
   message sheet's remaining rows.
4. **2:** task chat, Inbox, Agent activity.
5. **3:** Settings.
