# Rem Typography Audit

Issue: #615

## Current Scale

| Role | Token | Size | Intended surfaces |
| --- | --- | --- | --- |
| Large title | `DesignTokens.Typography.largeTitle` | 34 | Launch/onboarding hero titles only |
| Title 1 | `DesignTokens.Typography.title1` | 28 | Major screen titles in content areas |
| Title 3 | `DesignTokens.Typography.title3` | 20 | Section titles, compact panels, settings headings |
| Body | `DesignTokens.Typography.body` | 17 | Settings rows, form body text, normal content |
| Footnote | `DesignTokens.Typography.footnote` | 13 | Secondary explanatory text, chat chrome labels |
| Caption | `DesignTokens.Typography.caption1` | 12 | Dense metadata, status text, compact badges |

## Chat Roles

| Role | Token | Rule |
| --- | --- | --- |
| User bubble text | `DesignTokens.Typography.chatMessage` | Same scale as assistant prose and composer |
| Assistant prose | `DesignTokens.Typography.chatMessage` | Rendered through `AssistantMarkdownView` |
| Composer input | `DesignTokens.Typography.chatMessage` | Match the message that will be sent |
| Expanded Thinking diagnostics | `DesignTokens.Typography.chatMessage` / `chatCode` | Diagnostics should read like chat text, not tiny logs |
| Thinking disclosure label | `DesignTokens.Typography.chatMeta` | Slightly quieter than content, but not caption-small |
| Compact chat controls | `DesignTokens.Typography.chatChrome` | Send/thinking picker/status chrome only |

## Findings

- The shared chat surface was mostly aligned around 17pt body text, but user bubbles used raw `.body`, composer used `DesignTokens.Typography.body`, assistant prose used `DesignTokens.Typography.body`, and diagnostics code blocks used `.callout` monospace.
- This made user/composer/assistant text technically close but not explicit, and made diagnostic code blocks feel like a separate UI layer.
- The Thinking disclosure label used raw caption sizing; this was visually quieter than the diagnostic content and contributed to the feeling that Thinking had its own scale.
- Settings root rows already use body/caption roles in the shared settings surface. Child settings screens still mix `body`, `callout`, `footnote`, `caption`, and custom icon sizes; those should be normalized per screen during each settings IA refresh rather than with a broad mechanical sweep.

## Applied Slice

- Added chat-specific typography aliases to `DesignTokens.Typography`.
- Updated assistant markdown prose/code, user bubbles, composer input, and Thinking disclosure chrome to use the chat roles.
- Kept existing title/body/caption scale unchanged to avoid broad visual churn.

## Follow-Up

- As each settings child view is redesigned, replace raw `.body`, `.callout`, `.footnote`, and `.caption` usage with semantic `DesignTokens.Typography` roles.
- Preserve platform-native controls where SwiftUI forms pick the correct system font automatically.
- Avoid viewport-scaled font sizes; use semantic roles plus layout constraints instead.
