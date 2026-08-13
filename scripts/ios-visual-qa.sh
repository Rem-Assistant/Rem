#!/usr/bin/env bash
# Branch-scoped iOS visual QA helper.
#
# This helper builds the branch-local RemClaw iOS app, installs it on a named or
# id-addressed simulator, launches it with bounded simctl commands, and writes a
# durable screenshot/report bundle for PR evidence. It intentionally avoids
# mutating simulator app data unless --reset-simulator or --uninstall-app is
# passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ISSUE=""
OUT_DIR=""
SIMULATOR="${IOS_DEST_ID:-${IOS_DEST:-iPhone 17 Pro}}"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.remapp.rem}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PROJECT_ROOT/BuildResults/DerivedData-ios-visual-qa}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
BUILD_TIMEOUT_SECONDS="${BUILD_TIMEOUT_SECONDS:-600}"
RESET_SIMULATOR=0
UNINSTALL_APP=0
KILL_STALE_SIMCTL=1
SKIP_BUILD=0
SELF_TEST=0
COMPLETED=0
LAUNCH_ARGS=()

usage() {
  cat <<USAGE
Usage: $0 --issue <number> [options]

Options:
  --simulator <name|udid>       Simulator name or UDID (default: IOS_DEST_ID, IOS_DEST, or iPhone 17 Pro)
  --bundle-id <id>              App bundle id (default: $BUNDLE_ID)
  --derived-data-path <path>    DerivedData path (default: $DERIVED_DATA_PATH)
  --configuration <name>        Xcode configuration (default: $CONFIGURATION)
  --out-dir <path>              Evidence directory (default: docs/screenshots/issue-<number>/ios-visual-qa)
  --timeout <seconds>           Timeout for each simulator step (default: $TIMEOUT_SECONDS)
  --build-timeout <seconds>     Timeout for the Xcode build step (default: $BUILD_TIMEOUT_SECONDS)
  --reset-simulator             Shutdown/erase/boot simulator before install (destructive to that simulator)
  --uninstall-app               Uninstall this app before install (destructive only to this bundle id)
  --no-kill-stale-simctl        Do not terminate stale simctl install/launch/bootstatus processes
  --skip-build                  Reuse an existing app in DerivedData
  --launch-arg <arg>            Argument passed to the app at launch (repeatable)
  --self-test                   Validate helper parsing/timeout behavior without building or launching
  --help                        Show this help

Evidence:
  - report.md records commands, logs, timeouts, simulator/app identity, and result
  - ios-launch.png is written only when app launch and simulator screenshot succeed
  - full-screen macOS screenshots are never used
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      ISSUE="${2:-}"
      shift 2
      ;;
    --simulator)
      SIMULATOR="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --build-timeout)
      BUILD_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --reset-simulator)
      RESET_SIMULATOR=1
      shift
      ;;
    --uninstall-app)
      UNINSTALL_APP=1
      shift
      ;;
    --no-kill-stale-simctl)
      KILL_STALE_SIMCTL=0
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --launch-arg)
      LAUNCH_ARGS+=("${2:-}")
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$1" -gt 0 ]
}

display_path() {
  case "$1" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${1#$PROJECT_ROOT/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

run_with_timeout() {
  local timeout="$1"
  local log_path="$2"
  shift 2

  python3 - "$timeout" "$log_path" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
log_path = sys.argv[2]
command = sys.argv[3:]

with open(log_path, "w", encoding="utf-8") as log:
    log.write(f"$ {' '.join(command)}\n")
    try:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        log.write(f"Timed out after {timeout} seconds\n")
        sys.exit(124)

sys.exit(result.returncode)
PY
  local status=$?

  return "$status"
}

resolve_simulator_udid() {
  local target="$1"

  if [[ "$target" =~ ^[A-Fa-f0-9-]{20,}$ ]]; then
    printf '%s\n' "$target"
    return 0
  fi

  xcrun simctl list devices available |
    awk -v name="$target" 'index($0, name) > 0 && match($0, /\([A-F0-9-]+\)/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }'
}

kill_stale_simctl_for_device() {
  local udid="$1"
  local stale_pids=""

  stale_pids="$(pgrep -f "simctl (bootstatus|install|launch|terminate|io).*${udid}" 2>/dev/null || true)"
  if [ -n "$stale_pids" ]; then
    echo "$stale_pids" | xargs kill 2>/dev/null || true
    sleep 1
  fi
}

app_path() {
  printf '%s\n' "$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphonesimulator/RemClaw.app"
}

write_report_header() {
  cat >"$REPORT" <<EOF
# iOS Visual QA

- Issue: #$ISSUE
- Worktree: \`$(display_path "$PROJECT_ROOT")\`
- Simulator: \`$SIMULATOR\`
- Bundle id: \`$BUNDLE_ID\`
- DerivedData: \`$(display_path "$DERIVED_DATA_PATH")\`
- Reset simulator: \`$RESET_SIMULATOR\`
- Uninstall app: \`$UNINSTALL_APP\`
- Timeout per simulator step: \`${TIMEOUT_SECONDS}s\`
- Timeout for build: \`${BUILD_TIMEOUT_SECONDS}s\`
- Launch arguments: \`${LAUNCH_ARGS[*]:-none}\`

## Steps
EOF
}

append_step() {
  local status="$1"
  local message="$2"
  local log_path="${3:-}"

  if [ -n "$log_path" ]; then
    echo "- $status $message: \`$(display_path "$log_path")\`" >>"$REPORT"
  else
    echo "- $status $message" >>"$REPORT"
  fi
}

run_step() {
  local label="$1"
  local log_name="$2"
  shift 2

  local log_path="$OUT_DIR/$log_name"
  local status=0
  set +e
  run_with_timeout "$TIMEOUT_SECONDS" "$log_path" "$@"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    append_step "OK" "$label" "$log_path"
    return 0
  fi

  append_step "FAILED($status)" "$label" "$log_path"
  return "$status"
}

simulator_state() {
  local udid="$1"

  xcrun simctl list devices available |
    awk -v udid="$udid" 'index($0, "(" udid ")") > 0 {
      if (match($0, /\((Booted|Shutdown|Creating|Shutting Down|Unavailable)\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }'
}

run_bootstatus_step() {
  local label="$1"
  local log_name="$2"
  shift 2

  local log_path="$OUT_DIR/$log_name"
  local status=0
  set +e
  run_with_timeout "$TIMEOUT_SECONDS" "$log_path" "$@"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    append_step "OK" "$label" "$log_path"
    return 0
  fi

  local state
  state="$(simulator_state "$SIMULATOR_UDID")"
  if [ "$status" -eq 124 ] && [ "$state" = "Booted" ]; then
    append_step "WARN(124)" "$label timed out, but simulator is Booted; continuing" "$log_path"
    return 0
  fi

  append_step "FAILED($status)" "$label; simulator state: \`${state:-unknown}\`" "$log_path"
  return "$status"
}

run_optional_step() {
  local label="$1"
  local log_name="$2"
  shift 2

  local log_path="$OUT_DIR/$log_name"
  local status=0
  set +e
  run_with_timeout "$TIMEOUT_SECONDS" "$log_path" "$@"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    append_step "OK" "$label" "$log_path"
    return 0
  fi

  append_step "WARN($status)" "$label" "$log_path"
  return 0
}

run_build_step() {
  local label="$1"
  local log_name="$2"
  shift 2

  local log_path="$OUT_DIR/$log_name"
  local status=0
  set +e
  run_with_timeout "$BUILD_TIMEOUT_SECONDS" "$log_path" "$@"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    append_step "OK" "$label" "$log_path"
    return 0
  fi

  append_step "FAILED($status)" "$label" "$log_path"
  return "$status"
}

run_self_test() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local log_path="$tmp_dir/timeout.log"
  local fake_bin="$tmp_dir/bin"

  TIMEOUT_SECONDS=1
  if run_with_timeout "$TIMEOUT_SECONDS" "$log_path" python3 -c 'import time; time.sleep(3)'; then
    echo "self-test failed: timeout command succeeded unexpectedly" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! grep -q "Timed out after 1 seconds" "$log_path"; then
    echo "self-test failed: timeout log missing expected text" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$fake_bin"
  cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "devices" ]; then
  cat <<'DEVICES'
-- iOS 26.0 --
    iPhone 17 Pro (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)
    iPhone 17 Pro Max (FFFFFFFF-1111-2222-3333-444444444444) (Shutdown)
DEVICES
  exit 0
fi
exit 64
SH
  chmod +x "$fake_bin/xcrun"

  local original_path="$PATH"
  PATH="$fake_bin:$PATH"
  local state
  state="$(simulator_state "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")"
  PATH="$original_path"
  if [ "$state" != "Booted" ]; then
    echo "self-test failed: simulator_state returned '$state'" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"
  echo "ios-visual-qa self-test passed"
}

if [ "$SELF_TEST" = "1" ]; then
  run_self_test
  exit 0
fi

if [ -z "$ISSUE" ]; then
  echo "error: --issue is required" >&2
  usage >&2
  exit 2
fi

if ! is_positive_integer "$TIMEOUT_SECONDS"; then
  echo "error: --timeout must be a positive integer, got '$TIMEOUT_SECONDS'" >&2
  exit 2
fi

if ! is_positive_integer "$BUILD_TIMEOUT_SECONDS"; then
  echo "error: --build-timeout must be a positive integer, got '$BUILD_TIMEOUT_SECONDS'" >&2
  exit 2
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$PROJECT_ROOT/docs/screenshots/issue-$ISSUE/ios-visual-qa"
fi

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.md"
write_report_header
trap 'status=$?; if [ "$status" -ne 0 ] && [ "$COMPLETED" != "1" ] && [ -n "${REPORT:-}" ] && [ -f "$REPORT" ]; then printf "\nResult: failed with exit code %s before screenshot capture.\n" "$status" >>"$REPORT"; fi' EXIT

cd "$PROJECT_ROOT"
"$PROJECT_ROOT/scripts/bootstrap-submodules.sh" >>"$OUT_DIR/bootstrap.log" 2>&1
append_step "OK" "Submodule bootstrap" "$OUT_DIR/bootstrap.log"

SIMULATOR_UDID="$(resolve_simulator_udid "$SIMULATOR")"
if [ -z "$SIMULATOR_UDID" ]; then
  append_step "FAILED" "Could not resolve simulator '$SIMULATOR'"
  echo "error: could not resolve simulator '$SIMULATOR'" >&2
  exit 1
fi
append_step "OK" "Resolved simulator UDID \`$SIMULATOR_UDID\`"

if [ "$KILL_STALE_SIMCTL" = "1" ]; then
  kill_stale_simctl_for_device "$SIMULATOR_UDID"
  append_step "OK" "Terminated stale simctl processes for simulator if present"
fi

if [ "$SKIP_BUILD" != "1" ]; then
  run_build_step "Build branch-local iOS app" "build.log" \
    "$PROJECT_ROOT/scripts/xcodebuild-with-submodules.sh" \
      -project RemClaw.xcodeproj \
      -scheme RemClaw \
      -configuration "$CONFIGURATION" \
      -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      CODE_SIGNING_ALLOWED=NO \
      build
else
  append_step "OK" "Skipped build by request"
fi

APP_PATH="$(app_path)"
if [ ! -d "$APP_PATH" ]; then
  append_step "FAILED" "Expected app bundle missing at \`$(display_path "$APP_PATH")\`"
  echo "error: app bundle missing at $APP_PATH" >&2
  exit 1
fi

if [ "$RESET_SIMULATOR" = "1" ]; then
  run_optional_step "Shutdown simulator before erase" "sim-shutdown.log" xcrun simctl shutdown "$SIMULATOR_UDID"
  run_step "Erase simulator" "sim-erase.log" xcrun simctl erase "$SIMULATOR_UDID"
fi

run_optional_step "Boot simulator if needed" "sim-boot.log" xcrun simctl boot "$SIMULATOR_UDID"
run_bootstatus_step "Wait for simulator boot" "sim-bootstatus.log" xcrun simctl bootstatus "$SIMULATOR_UDID" -b

if [ "$UNINSTALL_APP" = "1" ]; then
  run_optional_step "Uninstall existing app bundle" "sim-uninstall.log" xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_ID"
fi

run_step "Install branch-local app bundle" "sim-install.log" xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
run_optional_step "Terminate existing app process" "sim-terminate.log" xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID"
run_step "Launch app" "sim-launch.log" xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"

sleep 3

SCREENSHOT_PATH="$OUT_DIR/ios-launch.png"
run_step "Capture simulator screenshot" "sim-screenshot.log" xcrun simctl io "$SIMULATOR_UDID" screenshot "$SCREENSHOT_PATH"

if [ -s "$SCREENSHOT_PATH" ]; then
  echo "" >>"$REPORT"
  echo "## Screenshot" >>"$REPORT"
  echo "" >>"$REPORT"
  echo "![iOS launch](ios-launch.png)" >>"$REPORT"
  echo "" >>"$REPORT"
  echo "Result: screenshot captured from branch-local app launch." >>"$REPORT"
else
  append_step "FAILED" "Screenshot file was not created"
  exit 1
fi

echo "iOS visual QA report: $(display_path "$REPORT")"
COMPLETED=1
