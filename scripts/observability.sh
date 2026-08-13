#!/bin/bash
# RemClaw Observability Agent Tools
# Provides log query and build metrics for AI agents
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
BUILD_LOG="$LOG_DIR/build.log"
TEST_LOG="$LOG_DIR/test.log"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Collect build metrics
collect_build_metrics() {
  local destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
  local config="${2:-Debug}"

  log "Collecting build metrics..."

  xcodebuild -project "$PROJECT_ROOT/RemClaw.xcodeproj" \
    -scheme RemClaw \
    -configuration "$config" \
    -destination "$destination" \
    build 2>&1 | tee "$BUILD_LOG"

  log "Build metrics saved to $BUILD_LOG"
}

# Collect test metrics
collect_test_metrics() {
  local destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"

  log "Collecting test metrics..."

  xcodebuild -project "$PROJECT_ROOT/RemClaw.xcodeproj" \
    -scheme RemClaw \
    -configuration Debug \
    -destination "$destination" \
    test 2>&1 | tee "$TEST_LOG"

  log "Test metrics saved to $TEST_LOG"
}

# Query build logs
query_logs() {
  local pattern="${1:-}"
  local log_file="${2:-$BUILD_LOG}"

  if [ -z "$pattern" ]; then
    echo "Usage: query_logs <pattern> [log_file]"
    echo "  pattern   - Search pattern (grep regex)"
    echo "  log_file - Log file to search (default: build.log)"
    return 1
  fi

  if [ ! -f "$log_file" ]; then
    echo "Log file not found: $log_file"
    return 1
  fi

  echo "=== Search results for: $pattern ==="
  grep -n -E "$pattern" "$log_file" || echo "No matches found"
  echo ""
}

# Get build summary
build_summary() {
  local log_file="${1:-$BUILD_LOG}"

  if [ ! -f "$log_file" ]; then
    echo "No build log found. Run collect_build_metrics first."
    return 1
  fi

  echo "=== Build Summary ==="
  echo "Log: $log_file"
  echo "Last modified: $(stat -f '%Sm' "$log_file" 2>/dev/null || stat -c '%y' "$log_file")"
  echo ""
  echo "Errors: $(grep -c 'error:' "$log_file" 2>/dev/null || echo 0)"
  echo "Warnings: $(grep -c 'warning:' "$log_file" 2>/dev/null || echo 0)"
  echo ""
  echo "=== Recent Errors ==="
  grep -A2 'error:' "$log_file" | head -30
  echo ""
  echo "=== Recent Warnings ==="
  grep -A2 'warning:' "$log_file" | head -30
}

# Get test summary
test_summary() {
  local log_file="${1:-$TEST_LOG}"

  if [ ! -f "$log_file" ]; then
    echo "No test log found. Run collect_test_metrics first."
    return 1
  fi

  echo "=== Test Summary ==="
  echo "Log: $log_file"
  echo ""
  grep -E "Test Suite.*passed|Test Suite.*failed|BUILD" "$log_file" | tail -20
}

# Parse Xcode build timing
build_timing() {
  local log_file="${1:-$BUILD_LOG}"

  if [ ! -f "$log_file" ]; then
    echo "No build log found."
    return 1
  fi

  echo "=== Build Timing Analysis ==="
  echo "Compile phases:"
  grep -E 'CompileSwift|CompileC|Linking' "$log_file" | \
    sed 's/.*CompileSwift /CompileSwift /' | \
    sed 's/.*CompileC /CompileC /' | \
    head -20
}

# Main entry point
main() {
  local command="${1:-help}"
  shift || true

  case "$command" in
    collect-build)
      collect_build_metrics "$@"
      ;;
    collect-test)
      collect_test_metrics "$@"
      ;;
    collect-all)
      collect_build_metrics "$@" && collect_test_metrics "$@"
      ;;
    query|logs)
      query_logs "$@"
      ;;
    build-summary|bs)
      build_summary "$@"
      ;;
    test-summary|ts)
      test_summary "$@"
      ;;
    timing)
      build_timing "$@"
      ;;
    help|--help)
      echo "RemClaw Observability Tools"
      echo ""
      echo "Commands:"
      echo "  collect-build [dest] [config]  - Build iOS app and save logs"
      echo "  collect-test [dest]           - Run tests and save logs"
      echo "  collect-all [dest]             - Build and test"
      echo "  query <pattern> [log]         - Search logs for pattern"
      echo "  build-summary [log]           - Show build summary"
      echo "  test-summary [log]            - Show test summary"
      echo "  timing [log]                  - Show build timing analysis"
      echo ""
      echo "Examples:"
      echo "  $0 collect-all 'platform=iOS Simulator,name=iPhone 17 Pro'"
      echo "  $0 query 'error:'"
      echo "  $0 query 'warning:.*SwiftLint'"
      echo "  $0 build-summary"
      echo "  $0 test-summary"
      ;;
    *)
      echo "Unknown command: $command"
      echo "Run '$0 help' for usage"
      exit 1
      ;;
  esac
}

main "$@"
