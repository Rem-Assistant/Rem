# AGENTS.md — working agreement for AI agents on RemClaw

> **Read [`AI_FAILURE_MODES.md`](AI_FAILURE_MODES.md) before diagnosing anything.** It records the
> specific ways agents have been confidently wrong in this repo — stale worktrees, false-empty
> greps, two-of-everything (services, accounts, tables, simulators), and tooling that lies about
> exit codes. Every entry cost real time at least once.


This file is auto-read by Codex (and is the shared, tool-neutral home for how we work here).
It complements `CLAUDE.md` (architecture, decision principles, per-feature gotchas) and the
per-folder `README.md` files. **Read `CLAUDE.md` and the relevant folder README before editing.**

RemClaw is an iOS + macOS SwiftUI app that connects to per-user OpenClaw gateways on Fly.io,
with a Node/TypeScript backend on Railway. See `CLAUDE.md` for the full picture.

## Active continuation ledger

Before resuming the feedback-driven Iteration 2 delivery run, read
[`docs/release/iteration-2-delivery-ledger.md`](docs/release/iteration-2-delivery-ledger.md). It records
the lane-level product contracts, open PR checkpoint heads and live findings, authenticated simulator
truth, and the exact review/build/acceptance sequence. Refresh its drift-prone SHAs and statuses rather
than assuming the captured checkpoint is current. Use `scripts/iteration2-acceptance.sh --status`
before starting Xcode work.

## 1. Delivery discipline (this is why work ships clean — do not skip)

1. **Independent review before EVERY merge — no exceptions.** After finishing a change, run a
   SEPARATE adversarial review pass (fresh context) that verifies the diff against the actual
   files, not against your own description. A self-review does not count. This has repeatedly
   caught P1 bugs in changes that looked "done".
2. **Build BOTH platforms green before merge**: iOS scheme `RemClaw` AND macOS scheme `RemClawMac`.
   Add or update unit tests wherever the logic is pure (classifiers, predicates, parsers).
3. **Read inline PR review comments (Codex/CI) before merging.** Note which are stale — pinned to
   an old commit and already resolved by a later rewrite — vs. live and still applicable.
4. **One focused PR per change**, targeting `main`. Put a 4-line pre-coding summary in the PR
   body: pattern mirrored · user outcome (in user words) · in-scope · out-of-scope.
5. **Mirror an existing in-repo/upstream pattern** before inventing a new abstraction (Decision
   Principle 1 in `CLAUDE.md`). Cite the file you mirrored.
6. **Update the folder `README.md`** when a change affects that folder's purpose, key files, or
   patterns.
7. **Own the lifecycle**: think through create / read / update / delete / recover for any
   stateful flow — not just the happy path (Decision Principle 2).

## 2. Deploy safety (destructive if ignored)

- **PR → `main` only. Never push directly to `main`. Never deploy without the
  founder's explicit say** — merges land on `main` and stop there.
- **`backend/` is linked to PRODUCTION on Railway.** A bare `railway up` ships to prod. Always run
  `railway status` first and target the staging service. `railway logs --build` shows *a* build,
  not necessarily yours — verify by image timestamp.
- Active work integrates on `main` via PRs. Expect plumbing drift between
  client cache, gateway config, and backend — name the source of truth before changing a stateful flow.
- The `rem-cron` "fail" health signal is a known chronic FALSE POSITIVE — verify against the actual
  logs/email before treating a cron-failure alert as real.

## 3. iOS/macOS build & tooling gotchas (will waste hours if unknown)

- **`openclaw` submodule is an EMPTY mount inside git worktrees**, so SwiftPM can't resolve
  `OpenClawKit`. Before building in a worktree:
  ```sh
  rmdir openclaw && ln -s /Volumes/SatechiSSD/Developer/Apps/Swift/RemClaw/openclaw openclaw
  ```
  Restore it afterward (`rm openclaw && mkdir openclaw`) and revert any generated
  `RemClaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` so the tree is clean.
- **Prefer invoking `xcodebuild` directly** with explicit flags
  (`-project -scheme -destination -derivedDataPath -clonedSourcePackagesDirPath`). If you use
  XcodeBuildMCP, know that `build_sim` uses the ACTIVE session profile's project/derivedData and
  **silently ignores** explicit `projectPath`/`derivedDataPath` args — it can build the wrong worktree.
- **Never pipe a build to `head`** — the SIGPIPE kills `xcodebuild` mid-build. Redirect to a logfile,
  then `grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`. Use `set -o pipefail` (a `grep` filter can
  otherwise mask a `BUILD FAILED`).
- **Boot disk is chronically full** — put DerivedData on `/Volumes/SatechiSSD/...`.
- **Sim visual-verify is auth-gated**: a fresh install lands on the Apple/Google sign-in screen,
  which can't be completed headless. For pure client-logic changes, verify via the `--rem-*-fixture`
  launch-args in `RemClaw/RemClawApp.swift` + unit tests + review. State plainly when a visual check
  was auth-blocked rather than implying it was eyeballed.

## 4. Shared code / DRY

New UI goes in `Shared/Views/` unless it needs platform-specific APIs (UIKit/AppKit). Shared views
are generic over `GatewaySessionProviding`; platform roots are thin wrappers injecting the concrete
session manager. Reconcile `Shared/Views/DesignTokens.swift` with the local Native reference project
for any change claiming macOS/Native parity (Decision Principle 6 in `CLAUDE.md`). Loading states use
a **shimmer skeleton of the real layout**, not a spinner.

## 5. How not to fool yourself

These wrong answers are all wrong the *same way*: **a check returns a confident result while measuring something adjacent to the question.** Not carelessness — the agent is careful. What catches it is always something structurally different looking at the same claim.

**You may reject the premise of your task.** If the problem described does not exist, say so and stop. Lanes have corrected their own brief — sometimes the correction came from the person who wrote it. A correct "this isn't a bug" is worth more than a plausible fix.

**Prove your test measures the thing.** Delete your fix, keep your test, run it. If it still passes, the test is worthless. Paste RED and GREEN. Real cases: a contract test kept all four assertions green while the P1 it was named for was reintroduced (`String.contains` over a whole file); `expect(x).not.toBeNull()` passed with the serializer deleted (a missing key reads back as `undefined`); a suite passed 22/22 with the Mac chat route replaced by `Text("Mac chat is completely broken")`.

**Read code from `origin/main`, never a stale working checkout.** A working checkout can sit on a detached HEAD, many commits behind. Reading a stale tree can produce a confident, wrong diagnosis of a live bug and a proposed fix that does harm. Use `git show origin/main:<path>`, and cite `origin/main:<file>:<line>` so a reader can tell which tree a claim came from.

**Greps lie here in four documented ways.**

| trap | symptom |
|---|---|
| the shell's `grep` is a `ugrep` wrapper | silently drops matches on multi-directory invocations — use `/usr/bin/grep` |
| a control string proves the probe **ran**, not its **scope** | an over-scoped search finds the control too and reports success. For scope, assert the **file list**, not the hit count |
| zsh does not word-split an unquoted `$VAR` | grep gets one bogus filename, errors into `/dev/null`, every term returns a clean `0` |
| in Swift the declared type name is the wrong unit | extension members (`.blurFromBottom()`) and key paths (`\.taskApiService`) share no text with their declaration. Five "dead" files were live for exactly this reason |

Also: `RemClaw.xcodeproj` is an Xcode 16 **synchronized-folder** project with zero `.swift` references in the pbxproj. "Not in project.pbxproj = dead" is worthless here.

**A push is not a merge, and a commit count is not content.** Confirm your change reached the base branch. Squash merges discard SHAs, so `git log origin/main..HEAD` lists everything and reads as "nothing landed" even when it did. Verify by content: `git show origin/main:<path> | grep -c '<distinctive string>'`. Commits have been silently lost this way.

**Known-red baselines — these are NOT yours.** The iOS suite is order- and load-dependent and already fails on clean `origin/main` (7–12 failures, set shifts between runs in both directions); re-run in isolation with `-only-testing` before attributing a failure, **and before concluding your change is clean**. `Gateway Tests` intermittently fails on `live browser view` / `cross-site iframe must attach` under runner contention — CI has Chromium and it passes routinely, so it is a timing flake, not a missing service.

**CI compiles the Swift tests but does not run them.** A false assertion is green here forever. Do not read a green Apple check as "the tests pass."

**Simulators.** Never touch `CB4A1333` or `580207F9` — the founder's, signed in, actively used. Create your own with `xcrun simctl create` and delete it. Pass an **explicit** simulator id to every XcodeBuildMCP call: `build_run_sim` with empty arguments resolves to a stored default and can hit a forbidden device without the name ever appearing in your command.
