#!/usr/bin/env bash
set -euo pipefail

# Xcode Canvas and SwiftPM use the internal macOS data volume for temporary
# files even when DerivedData is on an external drive. Run this before trusting
# preview/build errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$PROJECT_ROOT/RemClaw.xcodeproj}"
SCHEME="${SCHEME:-RemClaw}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/Volumes/SatechiSSD/XcodeDerivedData/RemClaw-preview-health}"
MIN_INTERNAL_FREE_GB="${MIN_INTERNAL_FREE_GB:-20}"
SKIP_PACKAGE_RESOLUTION="${SKIP_PACKAGE_RESOLUTION:-0}"

failures=0

section() {
  printf "\n== %s ==\n" "$1"
}

pass() {
  printf "[ok] %s\n" "$1"
}

warn() {
  printf "[warn] %s\n" "$1"
}

fail() {
  printf "[fail] %s\n" "$1"
  failures=$((failures + 1))
}

bytes_available() {
  df -k "$1" | awk 'NR == 2 { print $4 * 1024 }'
}

format_gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1024 / 1024 / 1024 }'
}

section "Disk"
internal_bytes="$(bytes_available /private/tmp)"
min_internal_bytes=$((MIN_INTERNAL_FREE_GB * 1024 * 1024 * 1024))

if (( internal_bytes < min_internal_bytes )); then
  fail "Internal macOS data volume has $(format_gib "$internal_bytes") free; need at least ${MIN_INTERNAL_FREE_GB} GiB before trusting Xcode previews."
else
  pass "Internal macOS data volume has $(format_gib "$internal_bytes") free."
fi

if [[ -d /Volumes/SatechiSSD ]]; then
  external_bytes="$(bytes_available /Volumes/SatechiSSD)"
  pass "/Volumes/SatechiSSD is mounted with $(format_gib "$external_bytes") free."
else
  fail "/Volumes/SatechiSSD is not mounted."
fi

derived_data_probe="$DERIVED_DATA_PATH/.remclaw-preview-health-write-test.$$"
if mkdir -p "$DERIVED_DATA_PATH" 2>/dev/null && touch "$derived_data_probe" 2>/dev/null && rm -f "$derived_data_probe" 2>/dev/null; then
  pass "External DerivedData path is writable: $DERIVED_DATA_PATH"
else
  rm -f "$derived_data_probe" 2>/dev/null || true
  fail "External DerivedData path is not writable: $DERIVED_DATA_PATH"
fi

section "Toolchain"
if xcrun swiftc --version >/tmp/remclaw-swiftc-version.txt 2>/tmp/remclaw-swiftc-version.err; then
  pass "swiftc is discoverable: $(head -1 /tmp/remclaw-swiftc-version.txt)"
else
  fail "swiftc is not discoverable: $(cat /tmp/remclaw-swiftc-version.err)"
fi

if xcrun simctl list devices available >/tmp/remclaw-simctl-devices.txt 2>/tmp/remclaw-simctl-devices.err; then
  device_count="$(grep -c 'iPhone' /tmp/remclaw-simctl-devices.txt || true)"
  if (( device_count == 0 )); then
    fail "CoreSimulator is reachable, but no iPhone simulator entries were found."
  else
    pass "CoreSimulator is reachable (${device_count} iPhone simulator entries found)."
  fi
else
  fail "CoreSimulator is not reachable: $(cat /tmp/remclaw-simctl-devices.err)"
fi

section "SwiftPM"
if [[ "$SKIP_PACKAGE_RESOLUTION" == "1" ]]; then
  warn "Skipped package resolution because SKIP_PACKAGE_RESOLUTION=1."
elif (( failures > 0 )); then
  warn "Skipped package resolution until disk/toolchain preflight passes."
else
  if "$SCRIPT_DIR/xcodebuild-with-submodules.sh" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resolvePackageDependencies \
    >/tmp/remclaw-package-resolution.log 2>&1; then
    pass "SwiftPM package resolution succeeded."
  else
    fail "SwiftPM package resolution failed. See /tmp/remclaw-package-resolution.log."
  fi
fi

section "Result"
if (( failures > 0 )); then
  cat <<EOF
Xcode preview health check failed.

Do not trust Canvas/package/widget-cycle errors until the failures above are
fixed. After freeing disk, restart Xcode/CoreSimulator and run this script again.
EOF
  exit 1
fi

pass "Xcode preview environment is healthy enough to trust build and Canvas failures."
