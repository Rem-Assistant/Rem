# Contributing to Rem

Thanks for looking at Rem. Before anything else, please read the next section —
it tells you what you can actually do with this repo today, which is less than a
typical open-source project, and we would rather you find that out here than
after an afternoon of setup.

---

## Read this first: what you can and cannot run today

**You cannot currently run the full Rem app as an outside contributor.**

Both apps hard-gate on account sign-in. `RemClaw/RemClawApp.swift:308` reads:

```swift
guard authService.isAuthenticated, gateway.isConfigured else {
    launchState = .ready
    return
}
```

Anything short of an authenticated session lands on onboarding, and onboarding
offers exactly two ways forward: **Sign in with Apple** or **Sign in with
Google**. There is no dev-auth path, no offline mode, no seeded local account,
and no "skip sign-in" flag. Sign-in authenticates against Rem's hosted backend,
which mints the JWT and provisions the per-user gateway that the rest of the app
talks to.

So, concretely:

| You want to… | Can you, today? |
|---|---|
| Build both apps from a clean clone | **Yes** |
| Run the unit tests | **Yes** |
| Render individual app screens without an account | **Yes** — via debug fixtures, see below |
| Work on the backend end to end | **Yes** — it runs locally against local Postgres |
| Work on the gateway wrapper end to end | **Yes** — plain Node, tests run offline |
| Sign in and use the assistant | **No** — needs a Rem account against our backend |
| Exercise chat, voice, agenda, or connectors against a live gateway | **No** — same reason |

We know this is the single biggest barrier to outside contribution, and we would
like to fix it. If a dev-auth or local-account path matters to you, say so in an
issue — it helps us prioritize it. Until then, please pick work from the "Yes"
rows, and expect that a maintainer will have to verify anything in the "No" rows
on your behalf.

### The debug fixtures are the real workaround for UI work

The iOS app ships **28 fixture launch arguments**, compiled only under `#if
DEBUG`. Each one short-circuits the root view *before* the auth gate, rendering
one screen against canned data. That is how you iterate on UI without an
account.

In Xcode: **Product → Scheme → Edit Scheme → Run → Arguments**, add one, run.

```
--rem-settings-fixture
--rem-connectors-fixture
--rem-automations-fixture
--rem-model-picker-fixture
--rem-chat-day-divider-fixture
--rem-gateway-device-pairing-fixture
```

The full list is the `--rem-*-fixture` constants at the top of
`RemClaw/RemClawApp.swift`, dispatched in its `rootContent` view builder. If you
are adding a screen, adding a fixture for it is strongly encouraged — it is
often the only way a reviewer can see your change.

---

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| macOS + Xcode | **Xcode 26 or newer** — both app targets set a deployment target of `26.0` | iOS and macOS apps |
| Android Studio + Android SDK | SDK 26+ (compile/target 36); use the JDK that ships with Android Studio | Android client under `android/` |
| Node.js | **20+** for `backend/` | backend |
| PostgreSQL | 16 (what CI runs) | backend tests |
| Git | any recent version, but see the submodule note | everything |

You do not need Fly, Railway, or any cloud account to build or to run the tests.

## Getting the code

**Clone recursively.** `openclaw/` is a git submodule, and the Swift app targets
depend on `OpenClawKit`, `OpenClawChatUI`, and `OpenClawProtocol`, which resolve
from that path rather than from `Package.resolved`. A missing submodule does not
produce a helpful error — it produces a wall of "no such module" failures, and
it has broken our own builds.

```bash
git clone --recurse-submodules https://github.com/Rem-Assistant/Rem.git
cd Rem
```

Already cloned flat:

```bash
make setup          # or: ./scripts/setup.sh if make is unavailable
```

Working in a git worktree, or a network hiccup left `openclaw/` empty:

```bash
make bootstrap-submodules
```

To run `xcodebuild` from a fresh worktree without risking a skipped submodule
bootstrap, prefer the wrapper:

```bash
./scripts/xcodebuild-with-submodules.sh \
  -project RemClaw.xcodeproj -scheme RemClawMac \
  -destination 'platform=macOS' build
```

`README.md` has the full set of submodule escape hatches, including the shared
cache and the `REMCLAW_SUBMODULE_REFERENCE_ROOT` override.

## Building and testing

```bash
# iOS app tests
make test
make test-all

# macOS app
xcodebuild -project RemClaw.xcodeproj -scheme RemClawMac \
  -destination 'platform=macOS' build

# Android dogfood client (see android/README.md)
cd android && ./gradlew :app:assembleDebug

# Backend — build/typecheck runs offline with no keys and no database:
cd backend && npm install && npm run build
# Integration tests need a local PostgreSQL 16 (set DATABASE_URL / TEST_DATABASE_URL):
npm run test:integration
```

Two gotchas that will cost you an hour each if you hit them cold:

- **Keep Xcode output off your boot volume.** Pass
  `-derivedDataPath "$PWD/BuildResults/DerivedData"`, or use `make test`, which
  already does. Full-disk build failures here look like unrelated compile errors.
- **`set -o pipefail` if you pipe `xcodebuild` anywhere.** Piping through `grep`
  or `xcpretty` makes `$?` the exit status of the *pipe*, so a `BUILD FAILED`
  silently reports success. Our own CI carries a comment about this because we
  got caught by it.

CI runs on every PR to `staging` and `main`: backend build and contract tests,
and a build of both `RemClaw` and `RemClawMac` schemes.

## Where the code lives

| Path | What it is |
|---|---|
| `RemClaw/` | iOS app |
| `android/` | Native Android client (Kotlin / Compose). Early dogfood. |
| `RemClawMac/` | macOS app — menu bar, local gateway host |
| `Shared/` | Cross-platform models, protocols, and SwiftUI views used by both apps |
| `backend/` | Node/Express: auth, gateway provisioning, connectors |
| `openclaw/` | Submodule: our MIT fork of upstream OpenClaw |
| `docs/` | Product and architecture docs |

Most folders carry their own `README.md` describing local conventions. Read the
one next to the code you are changing, and update it if your change moves the
folder's purpose or key files.

Two conventions worth knowing before your first PR:

- **New UI goes in `Shared/Views/`** unless it genuinely needs UIKit or AppKit.
  Shared views are generic over `GatewaySessionProviding` so both apps use the
  same code; platform roots are thin wrappers.
- **Check upstream OpenClaw before inventing an abstraction.** If `openclaw/`
  already solves a problem — pairing, gateway lifecycle, setup codes — mirror its
  pattern instead of writing a parallel one, and cite the upstream file.

`CLAUDE.md` and `AGENTS.md` document these in full. They are written for
AI coding agents, but they are the most accurate description of how this
codebase expects to be changed, so they are worth reading regardless.

## Pull requests

- Branch from the latest `origin/staging`.
- **Open PRs against `staging`, not `main`.**
- Keep PRs focused. If you find an unrelated bug, file an issue.
- For UI changes, include before/after screenshots or a recording, plus at least
  one click-through. Given the sign-in gate, a fixture screenshot is usually the
  practical way to show your work.
- Explain *why*, not just *what*. If you deviated from an existing pattern, say
  which one and why.
- Expect an independent review before merge.

Good first contributions, given the constraints: backend and gateway-wrapper
work, shared SwiftUI views with a fixture attached, documentation, folder
READMEs, test coverage, and accessibility fixes.

## Licensing of contributions

Rem's own code is **Apache-2.0** (see `LICENSE`). The `openclaw/` submodule is
our fork of upstream OpenClaw and stays **MIT**, matching upstream — that is
deliberate, because Apache-2.0 is only one-way compatible with MIT and we want
to keep upstreaming patches.

**There is no CLA and no DCO.** Contributions are inbound=outbound: by opening a
pull request you agree that your contribution is licensed under the same license
as the file you are changing — Apache-2.0 for this repo, MIT for anything under
`openclaw/`. Apache-2.0 §5 already says this; we are not asking you to sign
anything on top.

If you are contributing code you did not write, or code derived from another
project, **say so in the PR** and name the source and its license. We would
much rather have that conversation up front.

## Reporting bugs and security issues

- **Security vulnerabilities:** do not open a public issue. Follow
  [`SECURITY.md`](SECURITY.md).
- **Bugs:** open an issue with the platform, app version or commit SHA, steps to
  reproduce, and what you expected instead.
- **Behavior of the AI agent itself** is often a function of the gateway and the
  model, not of this repo. Include the gateway version if you can.

## Code of Conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
Report unacceptable behavior to **admin@userem.site**.
