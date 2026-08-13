# Native reference vs Rem — layout, tokens, and batch checklist

Canonical Native app: `/Volumes/SatechiSSD/Developer/DesignSystem/Native` (local; not in repo).

## Native’s **settings layout options** (same content, different chrome)

The Native Xcode project ships **multiple** settings screen templates (see `NativeApp` → `Settings` → `router.currentSettingsScreen`):

| Screen | Pattern | Notes |
|--------|---------|--------|
| **One** | `NavigationSplitView` | Sidebar list + detail; sidebar min **200** / ideal **240**; detail min **360** / ideal **448**. |
| **Two** | `NavigationStack` + **TabView** | No split; min **360** / ideal **480**. |
| **Three** | `NavigationSplitView` | Same split metrics as One. |
| **Four** | `NavigationStack` + **TabView** | Wider: min **600**. |
| **Five** | `NavigationSplitView` + **searchable(placement: .sidebar)** | Same split; search in sidebar. |

**Takeaway:** Native is a **layout showcase**, not a single mandated pattern. product choice can be **tabs**, **wide single column**, or **split**; what reads “native” is **consistent widths**, **`Form` + `.grouped`**, **`LabeledContent`**, and **section footers**—not the split per se.

## How this can influence `DesignTokens`

- **Not** a 1:1 “copy Native’s `DesignTokens`” (Native does not define a Rem-style token file; it encodes design in **components**).
- **In Rem (implemented):** `DesignTokens.Layout` (macOS) holds **min/ideal/max width** hints from the Native `Settings*View` sources; these frame **`SharedSettingsView`**, **Billing**, **About (Mac)**, and **`PermissionsTab`**.
- **In Rem (implemented):** `SettingsIcon` uses the same **rounded tile** (white glyph on color) on **iOS and macOS** (product preference over Native’s hierarchical-only glyph).
- **`insetGrouped` on Mac:** not in the **macOS** SwiftUI API; **OpenClaw** / settings use **`Form` + `.grouped`** on Mac with the same width tokens as a substitute for “inset grouped” density.
- **In Rem (implemented):** macOS **root settings** and **drill-in** (Billing, About, Permissions) use **`Form` + `.formStyle(.grouped)`** instead of a bare `List` + `inset` / `ScrollView` + `GroupBox` stacks.

- **Next (optional):** more **`LabeledContent`** for simple key/value rows; tune gateway **connection detail** lists the same way.

## Rem: Mac settings and sheets

- **Implemented:** in-app settings are canonical. `Rem > Settings...` / **Cmd+,** route into the main-window `MacFullSettingsView` (`NavigationStack` + `SharedSettingsView`). The app no longer declares a native SwiftUI `Settings` scene, so macOS should not expose a second Settings menu item/window.
- **Sheets** on Mac: keep **min width/height** in the same ballpark as `DesignTokens.Layout.settingsDetail*`, use **`Form`/grouped** in the sheet, and avoid **iOS-only** nav chrome where it fights AppKit. Native uses **sheets** sparingly for main settings; **push** inside `NavigationStack` or a **dedicated window** when the flow is large.

## User-facing copy

- Do not expose internal milestone, branch, or worktree language in product UI. Avoid strings such as **Wave 2**, **staging**, **build**, or PR/issue labels in app surfaces. Replace them with capability/state language such as “not available on this machine yet,” “requires a Mac,” or “available in a future update.”

## Device pairing UI (scoped IA, completed in this batch)

- **Before:** A **Device Pairing** section with a drill-in **plus** peer rows (**Pair New Device**, **This Device’s Name**, **Re-pair**).
- **After:** A **single** row under **Configuration** — **“Devices & Pairing”** — that opens **`SharedGatewayDevicePairingScreen`**, which contains: pending, paired, then **“This device”** (pair new when local, rename on iOS, re-pair).
- **Unchanged by design:** `SharedDevicePairingListView` (pending + paired only) for **Chat**’s approval sheet, etc.

## Visual / UX items captured (update as you ship)

**You reported**

- [ ] Mac settings: match Native **density** and **row** patterns; avoid “giant iPhone list in the detail pane” without at least `Form`/grouping/min widths.
- [ ] Mac sheets: **frame** and **form** styling; consider push/navigation for heavy flows.
- [x] **Device pairing:** consolidation + drill-in (this batch).
- [x] **Gateways** row: orange icon; top-level product copy no longer says **OpenClaw**.
- [ ] **Gateway details** / naming: keep OpenClaw where it specifically means the gateway implementation, not the app surface.
- [ ] **Gateway** list: long “unreachable” strings — truncation / row layout (partially addressed; re-verify in-app).

**Easy to miss later**

- [ ] `Logo.png` in `AppIcon.appiconset` (macOS + iOS) — must exist in catalog for icons to show.
- [x] Two settings surfaces (main window vs **Settings** window) — main-window settings are canonical; the native Settings scene has been removed.
- [ ] iOS + Mac **parity** on **navigation titles** (e.g. “Chat sessions” vs other).

**When the initiative is “done”:** replace this list with a short “shipped in release X” blurb in the PR / release notes.
