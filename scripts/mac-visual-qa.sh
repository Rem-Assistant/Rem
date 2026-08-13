#!/bin/bash
# Branch-scoped Mac visual QA helper.
#
# This script intentionally avoids full-screen screenshots. It targets a single
# Rem.app build path, records window diagnostics, and times out Peekaboo calls
# so a broken visual harness cannot stall the orchestrator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH=""
ISSUE=""
OUT_DIR=""
KILL_EXISTING=0
CLICK_SETTINGS=0
SELF_TEST=0
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-15}"
WINDOW_WAIT_SECONDS="${WINDOW_WAIT_SECONDS:-8}"
LAUNCH_ARGS=()

usage() {
  cat <<USAGE
Usage: $0 --app-path /path/to/Rem.app --issue <number> [options]

Options:
  --out-dir <path>       Evidence directory. Defaults to docs/screenshots/issue-<number>/mac-visual-qa
  --kill-existing        Kill other local Rem.app processes before launching the target app
  --click-settings       Try Rem > Settings... after launch and record a second window listing
  --launch-arg <arg>     Argument passed to Rem at launch (repeatable)
  --timeout <seconds>    Timeout for each Peekaboo call (default: $TIMEOUT_SECONDS)
  --window-wait <seconds>
                         Wait this long for a real app-sized window after launch (default: $WINDOW_WAIT_SECONDS)
  --self-test            Validate helper parsing without launching Rem
  --help                 Show this help

Evidence:
  - window JSON and command logs are always written when commands run
  - screenshots are written only when scoped window capture succeeds
  - if an app-sized window is available, the helper uses window-scoped capture only
  - full-screen capture is never used
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --issue)
      ISSUE="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --kill-existing)
      KILL_EXISTING=1
      shift
      ;;
    --click-settings)
      CLICK_SETTINGS=1
      shift
      ;;
    --launch-arg)
      LAUNCH_ARGS+=("${2:-}")
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --window-wait)
      WINDOW_WAIT_SECONDS="${2:-}"
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

run_with_timeout() {
  local log_path="$1"
  shift

  set +e
  python3 - "$TIMEOUT_SECONDS" "$log_path" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
log_path = sys.argv[2]
command = sys.argv[3:]

with open(log_path, "w", encoding="utf-8") as log:
    try:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        log.write(f"Timed out after {timeout} seconds: {' '.join(command)}\n")
        sys.exit(124)

sys.exit(result.returncode)
PY
  local status=$?
  set -e

  return "$status"
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
    echo "$name must be a positive integer, got: $value" >&2
    exit 2
  fi
}

clear_visual_qa_launch_env() {
  launchctl unsetenv REM_MAC_VISUAL_QA 2>/dev/null || true
}

rem_pids_for_path() {
  pgrep -f "$APP_EXECUTABLE" 2>/dev/null || true
}

pid_was_running_before_launch() {
  local candidate="$1"
  local previous_pid

  for previous_pid in $PRE_LAUNCH_PIDS; do
    if [ "$candidate" = "$previous_pid" ]; then
      return 0
    fi
  done

  return 1
}

select_target_pid() {
  local selected_pid=""
  local candidate

  for candidate in $PIDS; do
    if ! pid_was_running_before_launch "$candidate"; then
      selected_pid="$candidate"
      break
    fi
  done

  if [ -z "$selected_pid" ]; then
    selected_pid="$(printf '%s\n' $PIDS | tail -1)"
  fi

  printf '%s\n' "$selected_pid"
}

display_path() {
  case "$1" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${1#$PROJECT_ROOT/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

target_window_id_from_log() {
  local json_path="$1"

  if [ ! -s "$json_path" ]; then
    return 1
  fi

  python3 - "$json_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(1)

windows = payload.get("data", {}).get("windows", [])
eligible = []

for window in windows:
    window_id = window.get("window_id")
    if not window_id:
        continue

    bounds = window.get("bounds") or []
    try:
        width = int(bounds[1][0])
        height = int(bounds[1][1])
    except Exception:
        width = 0
        height = 0

    area = width * height
    title = str(window.get("title") or "")
    is_main = bool(window.get("isMainWindow"))
    has_app_window_size = width >= 300 and height >= 200
    looks_like_app_window = has_app_window_size and (is_main or title in {"Agenda", "Inbox", "Sessions", "Settings", "Rem"} or area > 0)

    if looks_like_app_window:
        eligible.append((0 if is_main else 1, -area, window_id))

if eligible:
    eligible.sort()
    print(eligible[0][2])
    sys.exit(0)

sys.exit(1)
PY
}

window_diagnostics_summary() {
  local json_path="$1"

  if [ ! -s "$json_path" ]; then
    return 1
  fi

  python3 - "$json_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(1)

windows = payload.get("data", {}).get("windows", [])
parts = []
for window in windows:
    bounds = window.get("bounds") or []
    try:
        width = int(bounds[1][0])
        height = int(bounds[1][1])
    except Exception:
        width = 0
        height = 0
    title = str(window.get("title") or "(untitled)")
    window_id = window.get("window_id", "?")
    main = " main" if window.get("isMainWindow") else ""
    parts.append(f"{window_id}:{width}x{height}:{title}{main}")

print(", ".join(parts) if parts else "no windows")
PY
}

wait_for_target_window() {
  local window_log="$1"
  local label="$2"
  local waited=0
  local sleep_interval=1
  local status
  local summary

  while ! target_window_id_from_log "$window_log" >/dev/null; do
    summary="$(window_diagnostics_summary "$window_log" || printf 'unreadable window listing')"
    if [ "$waited" -ge "$WINDOW_WAIT_SECONDS" ]; then
      echo "- Window wait $label: no app-sized window after ${waited}s. Last windows: \`$summary\`." >>"$REPORT"
      return 1
    fi

    sleep "$sleep_interval"
    waited=$((waited + sleep_interval))
    if run_with_timeout "$window_log" peekaboo list windows --app "$PEEKABOO_APP_TARGET" --json --no-remote; then
      echo "- Window wait $label: refreshed window listing after ${waited}s: \`$(display_path "$window_log")\`" >>"$REPORT"
    else
      status=$?
      echo "- Window wait $label: refresh failed or timed out with status \`$status\`: \`$(display_path "$window_log")\`" >>"$REPORT"
    fi
  done

  return 0
}

capture_window_snapshot() {
  local label="$1"
  local window_log="$2"
  local screenshot_path="$3"
  local screenshot_log="$4"
  local screencapture_log="$5"
  local status
  local window_id

  window_id="$(target_window_id_from_log "$window_log" || true)"
  if [ -n "$window_id" ]; then
    if run_with_timeout "$screencapture_log" screencapture -x -l "$window_id" "$screenshot_path"; then
      echo "- Window screenshot $label: \`screencapture -l $window_id\` saved \`$(display_path "$screenshot_path")\`." >>"$REPORT"
      return 0
    fi

    status=$?
    echo "- Window screenshot $label \`screencapture -l $window_id\` failed or timed out with status \`$status\`: \`$(display_path "$screencapture_log")\`" >>"$REPORT"
    rm -f "$screenshot_path"
  else
    echo "- Window screenshot $label fallback skipped: no target \`window_id\` found in \`$(display_path "$window_log")\`." >>"$REPORT"
  fi

  if [ -z "$window_id" ]; then
    echo "- Window screenshot $label Peekaboo fallback skipped: no app-sized window was available." >>"$REPORT"
    return 1
  fi

  if run_with_timeout "$screenshot_log" peekaboo image --app "$PEEKABOO_APP_TARGET" --mode window --window-index 0 --path "$screenshot_path" --json --no-remote; then
    echo "- Window screenshot $label Peekaboo fallback: \`$(display_path "$screenshot_path")\`" >>"$REPORT"
    return 0
  fi

  status=$?
  echo "- Window screenshot $label Peekaboo fallback failed or timed out with status \`$status\`: \`$(display_path "$screenshot_log")\`" >>"$REPORT"
  rm -f "$screenshot_path"

  return 1
}

settings_route_expression() {
  printf '%s\n' 'DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("remclaw.openMainWindowScreen"), object: "settings") }'
}

route_settings_with_lldb() {
  local log_path="$1"
  local expression

  expression="$(settings_route_expression)"

  run_with_timeout "$log_path" \
    lldb -p "$PID" --batch \
      -o "expr -l swift -- import Foundation" \
      -o "expr -l swift -- $expression" \
      -o "process detach"
}

console_is_locked() {
  local console_state
  console_state="$(/usr/sbin/ioreg -n Root -d1 2>/dev/null || true)"
  printf '%s\n' "$console_state" | grep -Eq 'CGSSessionScreenIsLocked.*Yes|IOConsoleLocked.*Yes'
}

self_test() {
  local tmp_dir
  local fixture
  local parsed
  local route_expression

  tmp_dir="$(mktemp -d)"
  fixture="$tmp_dir/windows.json"

  cat >"$fixture" <<'JSON'
{
  "data": {
    "windows": [
      { "title": "Agenda", "window_id": 30721, "isMainWindow": true, "bounds": [[100, 100], [700, 727]] }
    ]
  }
}
JSON

  parsed="$(target_window_id_from_log "$fixture")"
  if [ "$parsed" != "30721" ]; then
    echo "Expected first window id 30721, got '$parsed'" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  cat >"$fixture" <<'JSON'
{
  "data": {
    "windows": [
      { "title": "", "window_id": 30722, "isMainWindow": false, "bounds": [[0, 0], [1680, 30]] },
      { "title": "Settings", "window_id": 30723, "isMainWindow": true, "bounds": [[100, 100], [700, 727]] }
    ]
  }
}
JSON

  parsed="$(target_window_id_from_log "$fixture")"
  if [ "$parsed" != "30723" ]; then
    echo "Expected Settings window id 30723, got '$parsed'" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  cat >"$fixture" <<'JSON'
{
  "data": {
    "windows": [
      { "title": "Backup", "window_id": 30724, "isMainWindow": false, "bounds": [[100, 100], [700, 727]] },
      { "title": "", "window_id": 30725, "isMainWindow": true, "bounds": [[0, 0], [1680, 30]] }
    ]
  }
}
JSON

  parsed="$(target_window_id_from_log "$fixture")"
  if [ "$parsed" != "30724" ]; then
    echo "Expected Backup window id 30724 over tiny main menu bar, got '$parsed'" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  cat >"$fixture" <<'JSON'
{
  "data": {
    "windows": [
      { "title": "", "window_id": 30726, "isMainWindow": true, "bounds": [[0, 0], [1680, 30]] }
    ]
  }
}
JSON

  if target_window_id_from_log "$fixture" >/dev/null; then
    echo "Expected tiny-only window list to return failure" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  printf '{"data":{"windows":[]}}\n' >"$fixture"
  if target_window_id_from_log "$fixture" >/dev/null; then
    echo "Expected empty window list to return failure" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  route_expression="$(settings_route_expression)"
  case "$route_expression" in
    *"DispatchQueue.main.async"*'"remclaw.openMainWindowScreen"'*'object: "settings"'*) ;;
    *)
      echo "Settings route expression is missing main-queue route notification: $route_expression" >&2
      rm -rf "$tmp_dir"
      exit 1
      ;;
  esac

  rm -rf "$tmp_dir"
  echo "mac-visual-qa self-test passed"
}

if [ "$SELF_TEST" = "1" ]; then
  require_positive_integer "--timeout" "$TIMEOUT_SECONDS"
  require_positive_integer "--window-wait" "$WINDOW_WAIT_SECONDS"
  self_test
  exit 0
fi

require_positive_integer "--timeout" "$TIMEOUT_SECONDS"
require_positive_integer "--window-wait" "$WINDOW_WAIT_SECONDS"

if [ -z "$APP_PATH" ] || [ -z "$ISSUE" ]; then
  usage >&2
  exit 2
fi

if [ ! -d "$APP_PATH" ]; then
  echo "App path does not exist: $APP_PATH" >&2
  exit 2
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$PROJECT_ROOT/docs/screenshots/issue-$ISSUE/mac-visual-qa"
fi

mkdir -p "$OUT_DIR"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Rem"
REPORT="$OUT_DIR/report.md"

{
  echo "# Mac Visual QA Report"
  echo
  echo "- Issue: #$ISSUE"
  echo "- App: \`$(display_path "$APP_PATH")\`"
  echo "- Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Launch mode: \`REM_MAC_VISUAL_QA=1\` (skips launch-time Keychain/autoconnect work)"
  echo "- Launch arguments: \`${LAUNCH_ARGS[*]:-none}\`"
  echo "- Full-screen capture: disabled by policy"
  echo
} >"$REPORT"

if console_is_locked; then
  {
    echo "## Result"
    echo
    echo "Skipped: the macOS desktop session is locked, so window screenshots and menu automation would target \`loginwindow\` or time out."
    echo
    echo "Unlock the desktop and rerun this helper for visual evidence."
  } >>"$REPORT"
  echo "$REPORT"
  exit 78
fi

if [ "$KILL_EXISTING" = "1" ]; then
  {
    echo "## Cleanup"
    echo
    echo "Killed existing local Rem processes before launching the branch app."
    echo
  } >>"$REPORT"
  pkill -f "/Contents/MacOS/Rem" 2>/dev/null || true
  sleep 1
fi

PRE_LAUNCH_PIDS="$(rem_pids_for_path | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
launchctl setenv REM_MAC_VISUAL_QA 1
trap clear_visual_qa_launch_env EXIT
open -n -F "$APP_PATH" --args "${LAUNCH_ARGS[@]}"
sleep 3
clear_visual_qa_launch_env
trap - EXIT

PIDS="$(rem_pids_for_path | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ -z "$PIDS" ]; then
  {
    echo "## Result"
    echo
    echo "Failed: no running Rem process matched the target app path."
  } >>"$REPORT"
  exit 1
fi

PID="$(select_target_pid)"
PEEKABOO_APP_TARGET="PID:$PID"
{
  echo "## Launch"
  echo
  echo "- Pre-launch matching PIDs: \`${PRE_LAUNCH_PIDS:-none}\`"
  echo "- Target PID: \`$PID\`"
  echo "- Peekaboo app target: \`$PEEKABOO_APP_TARGET\`"
  echo "- Matching PIDs: \`$PIDS\`"
  echo
} >>"$REPORT"

WINDOW_LOG="$OUT_DIR/windows-before.json"
if run_with_timeout "$WINDOW_LOG" peekaboo list windows --app "$PEEKABOO_APP_TARGET" --json --no-remote; then
  echo "- Window listing before click: \`$(display_path "$WINDOW_LOG")\`" >>"$REPORT"
else
  status=$?
  echo "- Window listing before click failed or timed out with status \`$status\`: \`$(display_path "$WINDOW_LOG")\`" >>"$REPORT"
fi
wait_for_target_window "$WINDOW_LOG" "before click" || true

capture_window_snapshot \
  "before click" \
  "$WINDOW_LOG" \
  "$OUT_DIR/window-before.png" \
  "$OUT_DIR/screenshot.txt" \
  "$OUT_DIR/screencapture-window.txt" || true

if [ "$CLICK_SETTINGS" = "1" ]; then
  MENU_LOG="$OUT_DIR/menu-settings.txt"
  if run_with_timeout "$MENU_LOG" peekaboo menu click --app "$PEEKABOO_APP_TARGET" --path "Rem > Settings..." --no-remote; then
    echo "- Menu click: \`Rem > Settings...\` succeeded." >>"$REPORT"
  else
    status=$?
    echo "- Menu click failed or timed out with status \`$status\`: \`$(display_path "$MENU_LOG")\`" >>"$REPORT"
    ROUTE_LOG="$OUT_DIR/settings-route-fallback.txt"
    if route_settings_with_lldb "$ROUTE_LOG"; then
      echo "- Settings route fallback: posted \`.openMainWindowScreen(settings)\` in-process via LLDB." >>"$REPORT"
    else
      status=$?
      echo "- Settings route fallback failed or timed out with status \`$status\`: \`$(display_path "$ROUTE_LOG")\`" >>"$REPORT"
    fi
  fi

  sleep 1
  WINDOW_AFTER_LOG="$OUT_DIR/windows-after-settings.json"
  if run_with_timeout "$WINDOW_AFTER_LOG" peekaboo list windows --app "$PEEKABOO_APP_TARGET" --json --no-remote; then
    echo "- Window listing after settings click: \`$(display_path "$WINDOW_AFTER_LOG")\`" >>"$REPORT"
  else
    status=$?
    echo "- Window listing after settings click failed or timed out with status \`$status\`: \`$(display_path "$WINDOW_AFTER_LOG")\`" >>"$REPORT"
  fi
  wait_for_target_window "$WINDOW_AFTER_LOG" "after settings route" || true

  capture_window_snapshot \
    "after settings route" \
    "$WINDOW_AFTER_LOG" \
    "$OUT_DIR/window-after-settings.png" \
    "$OUT_DIR/screenshot-after-settings.txt" \
    "$OUT_DIR/screencapture-window-after-settings.txt" || true
fi

{
  echo
  echo "## Notes"
  echo
  echo "- Use the PID-scoped files above in PR evidence."
  echo "- If Peekaboo image capture fails, the helper may fall back to \`screencapture -l <window_id>\`, which is still window-scoped and not a full-screen capture."
  echo "- If menu automation fails, the Settings route fallback uses Rem's in-process main-window route as harness evidence, not as a replacement for user-click validation."
  echo "- If both scoped capture paths fail while window listing succeeds, treat that as a harness blocker and link #500."
  echo "- Do not substitute a full-screen screenshot unless the user explicitly approves the privacy risk for that run."
} >>"$REPORT"

echo "$REPORT"
