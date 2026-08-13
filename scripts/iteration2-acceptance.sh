#!/bin/bash
# Serialized Iteration 2 preflight and exact-platform build harness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_AUTOMATIONS_SIM="3B195358-6F0B-48C4-BBC1-0AD1B126D267"
REMAGENT_SIM="CB4A1333-CA0E-4948-9648-9775BE6E4FD1"
SIMULATOR_ID="${ITERATION2_SIMULATOR_ID:-$CODEX_AUTOMATIONS_SIM}"
EVIDENCE_ROOT="${ITERATION2_EVIDENCE_ROOT:-/Volumes/SatechiSSD/XcodeDerivedData}"
ACTION="status"
LOCK_DIR="/Volumes/SatechiSSD/XcodeDerivedData/.remclaw-iteration2-xcode.lock"
LOCK_ACQUIRED=0

usage() {
  cat <<'EOF'
Usage: scripts/iteration2-acceptance.sh [--status|--ios|--macos|--both]

  --status  Print exact git, simulator, dependency, process, and disk state (default).
  --ios     Build the iOS app for CodexAutomations.
  --macos   Build the macOS app without launching it.
  --both    Run the iOS build, then the macOS build, serially.

Environment:
  ITERATION2_SIMULATOR_ID   Focused-test simulator; defaults to CodexAutomations.
  ITERATION2_EVIDENCE_ROOT External log/DerivedData root.
  ITERATION2_OPENCLAW_SOURCE Optional exact OpenClaw checkout/worktree.

The authenticated RemAgent simulator is reserved for one final consolidated staging install and
visual acceptance. This harness intentionally refuses to build against it.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --status) ACTION="status" ;;
    --ios) ACTION="ios" ;;
    --macos) ACTION="macos" ;;
    --both) ACTION="both" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

git_sha() { git -C "$PROJECT_ROOT" rev-parse HEAD; }

root_worktree() {
  git -C "$PROJECT_ROOT" worktree list --porcelain |
    awk '/^worktree / { print substr($0, 10); exit }'
}

active_xcodebuilds() {
  local processes
  if ! processes="$(ps -axo pid=,command= 2>/dev/null)"; then
    echo "__PROCESS_CHECK_UNAVAILABLE__"
    return
  fi
  # Match the xcodebuild EXECUTABLE only — as a whole path component followed by a
  # space or end of line. A bare /xcodebuild/ substring also matches `xcodebuildmcp`
  # (the MCP server binary) and any agent command line that merely names it in an
  # --mcp-config payload, which made this guard fire permanently and refuse every
  # build with exit 3. The bracket on [x] keeps this awk from matching its own ps row.
  printf '%s\n' "$processes" | awk '/(^|[\/ ])[x]codebuild([ ]|$)/ { print }'
}

simulator_is_available() {
  xcrun simctl list devices available 2>/dev/null | grep -Fq "$1"
}

dependency_source() {
  local repository expected candidate candidate_sha submodule_git_dir
  repository="$(root_worktree)"
  expected="$(expected_dependency_sha)"
  submodule_git_dir="$(git -C "$repository" rev-parse --path-format=absolute --git-common-dir)/modules/openclaw"
  for candidate in \
    "${ITERATION2_OPENCLAW_SOURCE:-}" \
    "$repository/.worktrees/_openclaw-${expected:0:3}"; do
    if [ -z "$candidate" ] || [ ! -f "$candidate/apps/shared/OpenClawKit/Package.swift" ]; then
      continue
    fi
    candidate_sha="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
    if [ "$candidate_sha" = "$expected" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  # Dependency worktree names are intentionally not a contract. Discover every registration at
  # the expected SHA and validate that its path is still live; a prunable stale registration must
  # not mask a later usable checkout. Missing/uninitialized submodule metadata is best-effort here
  # so an explicit source above or the checked-out root source below can still be considered.
  if [ -d "$submodule_git_dir" ]; then
    while IFS= read -r candidate; do
      # Git reports the submodule's primary checkout as its administrative gitdir in some linked
      # worktree topologies. That directory contains repository metadata, not Package.swift.
      if [ "$candidate" = "$submodule_git_dir" ]; then
        candidate="$repository/openclaw"
      fi
      if [ -z "$candidate" ] || [ ! -f "$candidate/apps/shared/OpenClawKit/Package.swift" ]; then
        continue
      fi
      candidate_sha="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
      if [ "$candidate_sha" = "$expected" ]; then
        printf '%s\n' "$candidate"
        return
      fi
    done < <(
      git --git-dir="$submodule_git_dir" worktree list --porcelain 2>/dev/null |
        awk -v expected="$expected" '
          /^worktree / { path = substr($0, 10) }
          /^HEAD / && $2 == expected { print path }
        ' || true
    )
  fi

  candidate="$repository/openclaw"
  if [ -f "$candidate/apps/shared/OpenClawKit/Package.swift" ]; then
    candidate_sha="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
    if [ "$candidate_sha" = "$expected" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  printf '%s/.missing-openclaw-%s\n' "$repository" "${expected:0:12}"
}

expected_dependency_sha() {
  git -C "$PROJECT_ROOT" rev-parse HEAD:openclaw
}

actual_dependency_sha() {
  local source
  source="$(dependency_source)"
  if [ ! -f "$source/apps/shared/OpenClawKit/Package.swift" ]; then
    return 0
  fi
  git -C "$source" rev-parse HEAD 2>/dev/null || true
}

print_status() {
  local active expected actual free_space branch project_changes dependency_changes dependency_source_path
  active="$(active_xcodebuilds)"
  expected="$(expected_dependency_sha)"
  actual="$(actual_dependency_sha)"
  branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  project_changes="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"
  dependency_source_path="$(dependency_source)"
  if [ -f "$dependency_source_path/apps/shared/OpenClawKit/Package.swift" ]; then
    dependency_changes="$(git -C "$dependency_source_path" status --porcelain --untracked-files=all)"
  else
    dependency_changes="invalid dependency source: $dependency_source_path"
  fi
  free_space="$(df -h "$EVIDENCE_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }')"

  log "project=$PROJECT_ROOT"
  log "branch=${branch:-detached} sha=$(git_sha)"
  log "origin/staging=$(git -C "$PROJECT_ROOT" rev-parse origin/staging 2>/dev/null || echo unavailable)"
  log "focused_simulator=$SIMULATOR_ID available=$(simulator_is_available "$SIMULATOR_ID" && echo yes || echo no)"
  log "authenticated_remagent=$REMAGENT_SIM reserved_for_final_acceptance=yes"
  log "openclaw_expected=$expected openclaw_source=${actual:-unavailable}"
  if [ -n "$project_changes" ]; then
    log "project_worktree_clean=no"
    printf '%s\n' "$project_changes"
  else
    log "project_worktree_clean=yes"
  fi
  if [ -n "$dependency_changes" ]; then
    log "openclaw_worktree_clean=no"
    printf '%s\n' "$dependency_changes"
  else
    log "openclaw_worktree_clean=yes"
  fi
  log "evidence_root=$EVIDENCE_ROOT free=${free_space:-unknown}"
  if [ "$active" = "__PROCESS_CHECK_UNAVAILABLE__" ]; then
    log "xcodebuild_active=unknown (process inspection unavailable; run outside the sandbox)"
  elif [ -n "$active" ]; then
    log "xcodebuild_active=yes"
    printf '%s\n' "$active"
  else
    log "xcodebuild_active=no"
  fi
}

preflight_build() {
  local active expected actual project_changes dependency_changes
  active="$(active_xcodebuilds)"
  if [ "$active" = "__PROCESS_CHECK_UNAVAILABLE__" ]; then
    echo "Refusing Xcode work because concurrent-process inspection is unavailable." >&2
    echo "Run this harness outside the sandbox so it can prove builds are serialized." >&2
    exit 3
  fi
  if [ -n "$active" ]; then
    echo "Refusing concurrent Xcode work. Active processes:" >&2
    printf '%s\n' "$active" >&2
    exit 3
  fi

  if [ "$ACTION" != "macos" ] && [ "$SIMULATOR_ID" = "$REMAGENT_SIM" ]; then
    echo "Refusing to use authenticated RemAgent for focused build work." >&2
    exit 4
  fi

  if [ "$ACTION" != "macos" ] && ! simulator_is_available "$SIMULATOR_ID"; then
    echo "Focused-test simulator is unavailable: $SIMULATOR_ID" >&2
    exit 5
  fi

  expected="$(expected_dependency_sha)"
  actual="$(actual_dependency_sha)"
  if [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
    echo "Refusing an inexact OpenClaw dependency." >&2
    echo "Expected: $expected" >&2
    echo "Root source: ${actual:-unavailable}" >&2
    echo "Check out the exact dependency in an isolated dependency worktree first." >&2
    exit 6
  fi

  project_changes="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"
  if [ -n "$project_changes" ]; then
    echo "Refusing to attribute a dirty worktree to exact HEAD $(git_sha):" >&2
    printf '%s\n' "$project_changes" >&2
    exit 7
  fi

  dependency_changes="$(git -C "$(dependency_source)" status --porcelain --untracked-files=all)"
  if [ -n "$dependency_changes" ]; then
    echo "Refusing an OpenClaw checkout with uncommitted changes:" >&2
    printf '%s\n' "$dependency_changes" >&2
    exit 8
  fi
}

OPENCLAW_WAS_EMPTY=0

acquire_build_lock() {
  mkdir -p "$EVIDENCE_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another Iteration 2 harness owns the cross-worktree build lock: $LOCK_DIR" >&2
    echo "If no build is active, inspect and remove the stale empty lock directory manually." >&2
    exit 9
  fi
  LOCK_ACQUIRED=1
}

release_build_lock() {
  if [ "$LOCK_ACQUIRED" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_ACQUIRED=0
  fi
}

mount_dependency() {
  local expected mounted
  expected="$(expected_dependency_sha)"
  if [ -L "$PROJECT_ROOT/openclaw" ] || [ -f "$PROJECT_ROOT/openclaw/package.json" ]; then
    if [ -f "$PROJECT_ROOT/openclaw/apps/shared/OpenClawKit/Package.swift" ]; then
      mounted="$(git -C "$PROJECT_ROOT/openclaw" rev-parse HEAD 2>/dev/null || true)"
    else
      mounted=""
    fi
    if [ "$mounted" = "$expected" ]; then
      return
    fi
    echo "Refusing an already-mounted but inexact OpenClaw dependency: ${mounted:-unavailable}" >&2
    exit 10
  fi
  if [ -d "$PROJECT_ROOT/openclaw" ] && [ -z "$(ls -A "$PROJECT_ROOT/openclaw")" ]; then
    rmdir "$PROJECT_ROOT/openclaw"
    OPENCLAW_WAS_EMPTY=1
    ln -s "$(dependency_source)" "$PROJECT_ROOT/openclaw"
    return
  fi
  echo "Cannot safely mount OpenClaw: expected an empty worktree mount." >&2
  exit 11
}

restore_worktree_mount() {
  if [ "$OPENCLAW_WAS_EMPTY" = "1" ]; then
    if [ -L "$PROJECT_ROOT/openclaw" ]; then
      unlink "$PROJECT_ROOT/openclaw"
      mkdir "$PROJECT_ROOT/openclaw"
    elif [ ! -d "$PROJECT_ROOT/openclaw" ]; then
      mkdir "$PROJECT_ROOT/openclaw"
    fi
    OPENCLAW_WAS_EMPTY=0
  fi
}

cleanup() {
  restore_worktree_mount
  release_build_lock
}

run_build() {
  local platform scheme destination slug stamp run_root derived log_path exit_code
  platform="$1"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  slug="$(git_sha | cut -c1-12)-$platform-$stamp"
  run_root="$EVIDENCE_ROOT/RemClaw-iteration2-$slug"
  derived="$run_root/DerivedData"
  log_path="$run_root/build.log"
  mkdir -p "$run_root" "$derived" "$run_root/tmp"

  if [ "$platform" = "ios" ]; then
    scheme="RemClaw"
    destination="platform=iOS Simulator,id=$SIMULATOR_ID"
  else
    scheme="RemClawMac"
    destination="platform=macOS"
  fi

  log "building platform=$platform sha=$(git_sha) evidence=$run_root"
  set +e
  TMPDIR="$run_root/tmp" xcodebuild \
    -project "$PROJECT_ROOT/RemClaw.xcodeproj" \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$derived/SourcePackages" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -jobs 2 \
    build >"$log_path" 2>&1
  exit_code=$?
  set -e

  grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' "$log_path" | tail -80 || true
  cat >"$run_root/evidence.env" <<EOF
ITERATION2_GIT_SHA=$(git_sha)
ITERATION2_PLATFORM=$platform
ITERATION2_DESTINATION=$destination
ITERATION2_EXIT_CODE=$exit_code
ITERATION2_FINISHED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  if [ "$exit_code" -ne 0 ]; then
    echo "Build failed; see $log_path" >&2
    return "$exit_code"
  fi
}

if [ "$ACTION" = "status" ]; then
  print_status
  exit 0
fi

acquire_build_lock
trap cleanup EXIT INT TERM
preflight_build
mount_dependency

case "$ACTION" in
  ios) run_build ios ;;
  macos) run_build macos ;;
  both) run_build ios; run_build macos ;;
esac

log "acceptance build action completed: $ACTION"
