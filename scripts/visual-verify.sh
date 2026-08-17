#!/usr/bin/env bash
#
# visual-verify.sh — build the iOS app once, then screenshot each fixture screen
# on a simulator. This is the VERIFY middle of the autonomous pipeline: an agent
# (or CI) drives the real app to a screen and captures evidence, so a UI change
# is confirmed by looking, not by trusting a green unit test.
#
# It leans on the app's existing `--rem-<screen>-fixture` DEBUG launch args
# (RemClawApp.swift): each renders one screen against canned data BEFORE the
# sign-in gate, so no account, gateway, or network is needed.
#
# Batch by design: the build is ~80% of the cost, so we build ONCE and amortize
# it across many screenshots. Runs locally on a Mac or on a CI macOS runner.
#
# Usage:
#   scripts/visual-verify.sh                 # the CORE set (below)
#   scripts/visual-verify.sh all             # every known fixture
#   scripts/visual-verify.sh task-detail settings suggestions   # explicit subset
#     (names are the fixture stem WITHOUT the leading `rem-` or trailing `-fixture`)
#
# Env overrides: VV_OUT (out dir), VV_SIM (sim name), VV_DERIVED (DerivedData),
#                VV_SLEEP (render wait seconds, default 4).
set -euo pipefail

SCHEME="RemClaw"
BUNDLE_ID="com.remapp.rem"
OUT="${VV_OUT:-visual-verify-out}"
SIM="${VV_SIM:-iPhone 16}"
DERIVED="${VV_DERIVED:-$PWD/BuildResults/VisualVerify}"
SLEEP="${VV_SLEEP:-4}"

# Highest-traffic screens. Keep this list intentional — it is the default batch.
CORE=(task-detail suggestions settings connectors automations
      chat-lifecycle onboarding voice-settings model-picker gateway-detail)

# Full set — MUST stay in sync with the `--rem-*-fixture` flags in RemClawApp.swift.
# (Regenerate: git grep -oE '\-\-rem-[a-z-]+-fixture' RemClaw/RemClawApp.swift
#              | sed -E 's/^--rem-(.*)-fixture$/\1/' | sort -u)
ALL=(activity-history ai-data-sharing-consent automations browser-live-card
     chat-day-divider chat-diagnostics chat-diagnostics-row chat-lifecycle
     clawhub-review clawhub-unavailable cloud-deploy collaboration connectors
     custom-scheme-link first-use-hint gateway-connection-recovery gateway-detail
     gateway-device-pairing gateway-update-targets guided-flow
     launch-connection-recovery-route launch-recovery-copy mcp-add-server
     model-picker onboarding onboarding-keychain-error post-setup-nux
     restored-session-scroll session-preview settings skill-provider-requirements
     suggestions task-detail voice-settings)

if [ "$#" -eq 0 ]; then FIXTURES=("${CORE[@]}")
elif [ "$1" = "all" ]; then FIXTURES=("${ALL[@]}")
else FIXTURES=("$@"); fi

command -v xcrun >/dev/null || { echo "error: xcrun not found (needs Xcode/macOS)" >&2; exit 2; }
[ -e "RemClaw.xcodeproj" ] || { echo "error: run from the repo root (RemClaw.xcodeproj not here)" >&2; exit 2; }

mkdir -p "$OUT"
echo "==> Building $SCHEME (Debug, simulator) once…"
xcodebuild -project RemClaw.xcodeproj -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tail -3

APP="$(find "$DERIVED/Build/Products" -maxdepth 3 -name '*.app' 2>/dev/null | head -1)"
[ -n "$APP" ] || { echo "error: no .app produced under $DERIVED" >&2; exit 1; }
echo "==> App: $APP"

# Resolve (or create) a simulator. Never touches a device the user has booted by
# name — we create a dedicated 'vv-<sim>' device if the named one isn't available.
UDID="$(xcrun simctl list devices available | grep -m1 "    $SIM (" | grep -oE '[0-9A-Fa-f-]{36}' || true)"
if [ -z "$UDID" ]; then
  echo "==> Creating dedicated simulator vv-$SIM"
  RUNTIME="$(xcrun simctl list runtimes | grep -m1 -oE 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' || true)"
  UDID="$(xcrun simctl create "vv-$SIM" "$SIM" ${RUNTIME:+$RUNTIME})"
fi
echo "==> Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

fail=0
for f in "${FIXTURES[@]}"; do
  arg="--rem-${f}-fixture"
  printf '==> %-42s' "$arg"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if xcrun simctl launch "$UDID" "$BUNDLE_ID" "$arg" >/dev/null 2>&1; then
    sleep "$SLEEP"
    if xcrun simctl io "$UDID" screenshot "$OUT/${f}.png" >/dev/null 2>&1; then
      echo "ok  → $OUT/${f}.png"
    else echo "SCREENSHOT FAILED"; fail=1; fi
  else echo "LAUNCH FAILED"; fail=1; fi
done

echo
echo "==> ${#FIXTURES[@]} screens attempted; output in $OUT/"
ls -1 "$OUT" 2>/dev/null | sed 's/^/    /'
exit "$fail"
