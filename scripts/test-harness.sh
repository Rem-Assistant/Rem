#!/bin/bash
# RemClaw Test Harness for per-worktree CI and agent verification
# Usage: ./scripts/test-harness.sh [--ios|--macos|--all] [--boot-sim] [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IOS_DEST="${IOS_DEST:-iPhone 17 Pro}"
MACOS_DEST="${MACOS_DEST:-platform=macOS}"
BUILD_RESULTS_DIR="${BUILD_RESULTS_DIR:-$PROJECT_ROOT/BuildResults}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$BUILD_RESULTS_DIR/DerivedData}"
RESULT_ROOT="${RESULT_ROOT:-$BUILD_RESULTS_DIR/TestResults}"
IOS_RETRIES="${IOS_RETRIES:-2}"
MACOS_ISOLATED_XCTEST_SUITES=(
  "RemClawMacTests/MacCalendarCommandRouterTests"
)
MACOS_SWIFT_TESTING_SUITES=(
  "RemClawMacTests/LaunchAgentSecretsMigratorMacTests"
)

VERBOSE="${VERBOSE:-0}"
BOOT_SIM="${BOOT_SIM:-1}"
PLATFORM="${PLATFORM:-all}"

for arg in "$@"; do
  case $arg in
    --ios) PLATFORM="ios" ;;
    --macos) PLATFORM="macos" ;;
    --all) PLATFORM="all" ;;
    --boot-sim) BOOT_SIM=1 ;;
    --no-boot-sim) BOOT_SIM=0 ;;
    --verbose) VERBOSE=1 ;;
    --help)
      echo "Usage: $0 [--ios|--macos|--all] [--boot-sim|--no-boot-sim] [--verbose]"
      echo "  --ios      Only run iOS tests"
      echo "  --macos    Only run macOS tests"
      echo "  --all      Run all tests (default)"
      echo "  --boot-sim Boot simulator before testing (default)"
      echo "  --no-boot-sim Skip simulator boot/readiness wait"
      echo "  --verbose  Show detailed output"
      echo ""
      echo "Environment:"
      echo "  IOS_DEST, IOS_DEST_ID, MACOS_DEST"
      echo "  BUILD_RESULTS_DIR, DERIVED_DATA_ROOT, RESULT_ROOT"
      echo "  IOS_RETRIES"
      exit 0
      ;;
  esac
done

log() {
  echo "[$(date '+%H:%M:%S')] $1"
}

bootstrap_required_submodules() {
  log "Bootstrapping required submodules"
  "$PROJECT_ROOT/scripts/bootstrap-submodules.sh"
}

array_contains() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done

  return 1
}

bootstrap_required_submodules

validate_macos_swift_testing_inventory() {
  local tests_dir="$PROJECT_ROOT/RemClawMacTests"
  local file
  local suite
  local missing=()

  while IFS= read -r -d '' file; do
    if grep -Eq '^[[:space:]]*import[[:space:]]+Testing\b' "$file"; then
      suite="RemClawMacTests/$(basename "$file" .swift)"
      if ! array_contains "$suite" "${MACOS_SWIFT_TESTING_SUITES[@]}"; then
        missing+=("$suite")
      fi
    fi
  done < <(find "$tests_dir" -name '*Tests.swift' -print0)

  if [ ${#missing[@]} -gt 0 ]; then
    log "macOS Swift Testing suite inventory is stale."
    log "Add these suites to MACOS_SWIFT_TESTING_SUITES before running the harness:"
    local missing_suite
    for missing_suite in "${missing[@]}"; do
      log "  - $missing_suite"
    done
    return 1
  fi

  return 0
}

ios_destination_id_for_name() {
  local name="$1"
  xcrun simctl list devices available |
    awk -v name="$name" 'index($0, name) > 0 && match($0, /\([A-F0-9-]+\)/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }'
}

resolve_ios_destination() {
  if [ -n "${IOS_DEST_ID:-}" ]; then
    echo "platform=iOS Simulator,id=$IOS_DEST_ID"
    return
  fi

  if [[ "$IOS_DEST" == *id=* ]]; then
    echo "$IOS_DEST"
    return
  fi

  if [[ "$IOS_DEST" =~ name=([^,]+) ]]; then
    local name="${BASH_REMATCH[1]}"
    local id
    id="$(ios_destination_id_for_name "$name")"
    if [ -n "$id" ]; then
      echo "platform=iOS Simulator,id=$id"
    else
      echo "$IOS_DEST"
    fi
    return
  fi

  local id
  id="$(ios_destination_id_for_name "$IOS_DEST")"

  if [ -n "$id" ]; then
    echo "platform=iOS Simulator,id=$id"
  else
    echo "platform=iOS Simulator,name=$IOS_DEST"
  fi
}

ios_simctl_target() {
  local destination="$1"

  if [[ "$destination" =~ id=([^,]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$destination" =~ name=([^,]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  echo "$IOS_DEST"
}

boot_ios_simulator_if_needed() {
  local destination="$1"

  if [ "$BOOT_SIM" != "1" ]; then
    return
  fi

  local simctl_target
  simctl_target="$(ios_simctl_target "$destination")"
  log "Booting iOS Simulator: $simctl_target"
  xcrun simctl boot "$simctl_target" 2>/dev/null || true
  xcrun simctl bootstatus "$simctl_target" -b
}

run_xcodebuild_logged() {
  local log_path="$1"
  shift

  set +e
  "$@" >"$log_path" 2>&1
  local exit_code=$?
  set -e

  if [ "$VERBOSE" = "1" ]; then
    cat "$log_path"
  else
    tail -120 "$log_path"
  fi

  return $exit_code
}

xcresult_total_tests() {
  local result_path="$1"
  if [ ! -d "$result_path" ]; then
    echo 0
    return
  fi

  xcrun xcresulttool get test-results summary --path "$result_path" 2>/dev/null |
    sed -n 's/.*"totalTestCount" : \([0-9][0-9]*\).*/\1/p' |
    tail -1
}

xcresult_failed_tests() {
  local result_path="$1"
  if [ ! -d "$result_path" ]; then
    echo 0
    return
  fi

  xcrun xcresulttool get test-results summary --path "$result_path" 2>/dev/null |
    sed -n 's/.*"failedTests" : \([0-9][0-9]*\).*/\1/p' |
    tail -1
}

validate_result_bundle() {
  local platform="$1"
  local result_path="$2"
  local total
  local failed

  total="$(xcresult_total_tests "$result_path")"
  failed="$(xcresult_failed_tests "$result_path")"
  total="${total:-0}"
  failed="${failed:-0}"

  log "$platform result bundle: $total tests, $failed failures"

  if ! [[ "$total" =~ ^[0-9]+$ ]] || ! [[ "$failed" =~ ^[0-9]+$ ]]; then
    log "$platform result bundle summary could not be parsed; treating as harness failure"
    return 1
  fi

  if [ "$total" -eq 0 ]; then
    log "$platform tests produced a zero-test success; treating as harness failure"
    return 1
  fi

  if [ "$failed" -ne 0 ]; then
    log "$platform result bundle reports failures"
    return 1
  fi
}

is_early_runner_exit() {
  local log_path="$1"
  grep -Eq "Early unexpected exit|operation never finished bootstrapping|test runner exited with code 0 before establishing connection" "$log_path"
}

run_ios_tests() {
  log "Running iOS tests..."

  cd "$PROJECT_ROOT"

  mkdir -p "$BUILD_RESULTS_DIR" "$DERIVED_DATA_ROOT" "$RESULT_ROOT"

  local destination
  destination="$(resolve_ios_destination)"
  boot_ios_simulator_if_needed "$destination"

  local attempt=1
  local max_attempts=$((IOS_RETRIES + 1))
  local exit_code=1

  while [ "$attempt" -le "$max_attempts" ]; do
    local derived_data="$DERIVED_DATA_ROOT/ios"
    local result_path="$RESULT_ROOT/ios.xcresult"
    local log_path="$BUILD_RESULTS_DIR/ios-test.log"

    rm -rf "$result_path"
    log "iOS test attempt $attempt/$max_attempts ($destination)"

    run_xcodebuild_logged "$log_path" \
      xcodebuild -project RemClaw.xcodeproj \
      -scheme RemClaw \
      -configuration Debug \
      -destination "$destination" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$result_path" \
      test
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      if validate_result_bundle "iOS" "$result_path"; then
        log "iOS tests PASSED"
        return 0
      fi
      exit_code=1
    fi

    if [ "$attempt" -lt "$max_attempts" ] && is_early_runner_exit "$log_path"; then
      log "iOS test runner exited before bootstrapping; retrying after simulator readiness wait"
      boot_ios_simulator_if_needed "$destination"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  log "iOS tests FAILED (exit code: $exit_code)"
  return $exit_code
}

run_macos_tests() {
  log "Running macOS tests..."

  cd "$PROJECT_ROOT"

  mkdir -p "$BUILD_RESULTS_DIR" "$DERIVED_DATA_ROOT" "$RESULT_ROOT"

  validate_macos_swift_testing_inventory || return 1

  local derived_data="$DERIVED_DATA_ROOT/macos"
  local isolated_xctest_result_path="$RESULT_ROOT/macos-calendar-xctest.xcresult"
  local remaining_xctest_result_path="$RESULT_ROOT/macos-xctest.xcresult"
  local swift_testing_result_path="$RESULT_ROOT/macos-swift-testing.xcresult"
  local isolated_xctest_log_path="$BUILD_RESULTS_DIR/macos-calendar-xctest.log"
  local remaining_xctest_log_path="$BUILD_RESULTS_DIR/macos-xctest.log"
  local swift_testing_log_path="$BUILD_RESULTS_DIR/macos-swift-testing.log"
  local isolated_xctest_only_args=()
  local xctest_skip_args=()
  local swift_testing_only_args=()
  rm -rf "$isolated_xctest_result_path" "$remaining_xctest_result_path" "$swift_testing_result_path"

  # Running every macOS test suite in one app-host invocation can crash the
  # test host with an invalid free in MacCalendarCommandRouterTests before
  # Xcode retries selected tests. Keep the fragile XCTest suite and Swift
  # Testing suites in separate invocations so each runner owns a fresh app host
  # and result bundle, while the remaining XCTest phase still picks up future
  # XCTest classes automatically (#475).
  for suite in "${MACOS_ISOLATED_XCTEST_SUITES[@]}"; do
    isolated_xctest_only_args+=("-only-testing:$suite")
    xctest_skip_args+=("-skip-testing:$suite")
  done
  for suite in "${MACOS_SWIFT_TESTING_SUITES[@]}"; do
    xctest_skip_args+=("-skip-testing:$suite")
    swift_testing_only_args+=("-only-testing:$suite")
  done

  log "macOS isolated XCTest phase"
  run_xcodebuild_logged "$isolated_xctest_log_path" \
    xcodebuild -project RemClaw.xcodeproj \
      -scheme RemClawMac \
      -configuration Debug \
      -destination "$MACOS_DEST" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$isolated_xctest_result_path" \
      "${isolated_xctest_only_args[@]}" \
      test

  local exit_code=$?
  if [ $exit_code -ne 0 ] || ! validate_result_bundle "macOS isolated XCTest" "$isolated_xctest_result_path"; then
    log "macOS tests FAILED (exit code: $exit_code)"
    return 1
  fi

  log "macOS remaining XCTest phase"
  run_xcodebuild_logged "$remaining_xctest_log_path" \
    xcodebuild -project RemClaw.xcodeproj \
      -scheme RemClawMac \
      -configuration Debug \
      -destination "$MACOS_DEST" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$remaining_xctest_result_path" \
      "${xctest_skip_args[@]}" \
      test

  exit_code=$?
  if [ $exit_code -ne 0 ] || ! validate_result_bundle "macOS remaining XCTest" "$remaining_xctest_result_path"; then
    log "macOS tests FAILED (exit code: $exit_code)"
    return 1
  fi

  log "macOS Swift Testing phase"
  run_xcodebuild_logged "$swift_testing_log_path" \
    xcodebuild -project RemClaw.xcodeproj \
      -scheme RemClawMac \
      -configuration Debug \
      -destination "$MACOS_DEST" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$swift_testing_result_path" \
      "${swift_testing_only_args[@]}" \
      test

  exit_code=$?
  if [ $exit_code -ne 0 ] || ! validate_result_bundle "macOS Swift Testing" "$swift_testing_result_path"; then
    log "macOS tests FAILED (exit code: $exit_code)"
    return 1
  fi

  log "macOS tests PASSED"
  return 0
}

main() {
  log "RemClaw Test Harness"
  log "Platform: $PLATFORM"
  log "Project: $PROJECT_ROOT"
  echo ""

  local exit_code=0

  case $PLATFORM in
    ios)
      run_ios_tests || exit_code=1
      ;;
    macos)
      run_macos_tests || exit_code=1
      ;;
    all)
      run_ios_tests || exit_code=1
      echo ""
      run_macos_tests || exit_code=1
      ;;
  esac

  echo ""
  if [ $exit_code -eq 0 ]; then
    log "All tests PASSED"
  else
    log "Some tests FAILED"
  fi

  exit $exit_code
}

main
