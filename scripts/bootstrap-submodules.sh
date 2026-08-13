#!/usr/bin/env bash
set -euo pipefail

# Bootstrap required submodules for fresh Codex/Symphony worktrees.
#
# The normal git submodule path is still preferred. When network access flakes,
# a local populated root checkout can be used as a shared reference so agents do
# not copy another worktree's .git pointer into the submodule directory.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

cd "$REPO_ROOT"

REQUIRED_SUBMODULES="${REMCLAW_REQUIRED_SUBMODULES:-openclaw}"
REFERENCE_ROOT="${REMCLAW_SUBMODULE_REFERENCE_ROOT:-}"
CACHE_ROOT="${REMCLAW_SUBMODULE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/RemClaw/submodules}"
DISABLE_CACHE="${REMCLAW_DISABLE_SUBMODULE_CACHE:-0}"
LOCK_TIMEOUT_SECONDS="${REMCLAW_SUBMODULE_LOCK_TIMEOUT_SECONDS:-180}"
LOCK_POLL_SECONDS="${REMCLAW_SUBMODULE_LOCK_POLL_SECONDS:-1}"
LOCK_ROOT="${REMCLAW_SUBMODULE_LOCK_ROOT:-}"
if [ -n "$LOCK_ROOT" ]; then
  if ! mkdir -p "$LOCK_ROOT"; then
    echo "error: cannot create submodule lock root: $LOCK_ROOT" >&2
    echo "hint: set REMCLAW_SUBMODULE_LOCK_ROOT to a writable directory, or rerun with permission to write that path." >&2
    exit 1
  fi
  BOOTSTRAP_LOCK_DIR="$LOCK_ROOT/remclaw-submodule-bootstrap.$(printf '%s' "$REPO_ROOT" | shasum -a 256 | awk '{print $1}').lock"
else
  BOOTSTRAP_LOCK_DIR="$(git rev-parse --git-path remclaw-submodule-bootstrap.lock)"
fi

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$1" -gt 0 ]
}

validate_lock_config() {
  if ! is_positive_integer "$LOCK_TIMEOUT_SECONDS"; then
    echo "error: REMCLAW_SUBMODULE_LOCK_TIMEOUT_SECONDS must be a positive integer, got '$LOCK_TIMEOUT_SECONDS'" >&2
    return 1
  fi

  if ! is_positive_integer "$LOCK_POLL_SECONDS"; then
    echo "error: REMCLAW_SUBMODULE_LOCK_POLL_SECONDS must be a positive integer, got '$LOCK_POLL_SECONDS'" >&2
    return 1
  fi
}

lock_owner_pid() {
  [ -f "$BOOTSTRAP_LOCK_DIR/pid" ] || return 1
  awk 'NR == 1 { print $1 }' "$BOOTSTRAP_LOCK_DIR/pid"
}

release_bootstrap_lock() {
  local owner_pid=""

  owner_pid="$(lock_owner_pid || true)"
  if [ "$owner_pid" = "$$" ]; then
    rm -rf "$BOOTSTRAP_LOCK_DIR"
  fi
}

remove_stale_bootstrap_lock() {
  local stale_pid="$1"
  local current_pid=""
  local stale_dir=""

  current_pid="$(lock_owner_pid || true)"
  if [ "$current_pid" != "$stale_pid" ]; then
    return 1
  fi

  stale_dir="${BOOTSTRAP_LOCK_DIR}.stale.$$.$(date +%s)"
  if mv "$BOOTSTRAP_LOCK_DIR" "$stale_dir" 2>/dev/null; then
    rm -rf "$stale_dir"
    return 0
  fi

  return 1
}

lock_owner_for() {
  local lock_dir="$1"

  [ -f "$lock_dir/pid" ] || return 1
  awk 'NR == 1 { print $1 }' "$lock_dir/pid"
}

release_path_lock() {
  local lock_dir="$1"
  local owner_pid=""

  owner_pid="$(lock_owner_for "$lock_dir" || true)"
  if [ "$owner_pid" = "$$" ]; then
    rm -rf "$lock_dir"
  fi
}

remove_stale_path_lock() {
  local lock_dir="$1"
  local stale_pid="$2"
  local current_pid=""
  local stale_dir=""

  current_pid="$(lock_owner_for "$lock_dir" || true)"
  if [ "$current_pid" != "$stale_pid" ]; then
    return 1
  fi

  stale_dir="${lock_dir}.stale.$$.$(date +%s)"
  if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
    rm -rf "$stale_dir"
    return 0
  fi

  return 1
}

report_lock_create_failure() {
  local label="$1"
  local lock_dir="$2"
  local parent_dir=""

  parent_dir="$(dirname "$lock_dir")"

  if [ ! -d "$parent_dir" ]; then
    echo "error: cannot create $label lock because parent directory does not exist: $parent_dir" >&2
  elif [ ! -w "$parent_dir" ]; then
    echo "error: cannot create $label lock because parent directory is not writable: $parent_dir" >&2
  else
    echo "error: cannot create $label lock at $lock_dir" >&2
  fi

  echo "hint: rerun with permission to write that path, or set REMCLAW_SUBMODULE_LOCK_ROOT to a writable directory such as .remclaw-locks." >&2
}

try_mkdir_lock() {
  local lock_dir="$1"
  local label="$2"
  local mkdir_error=""

  mkdir_error="$(mktemp "${TMPDIR:-/tmp}/remclaw-lock.XXXXXX")"
  if mkdir "$lock_dir" 2>"$mkdir_error"; then
    rm -f "$mkdir_error"
    return 0
  fi

  if [ -d "$lock_dir" ]; then
    rm -f "$mkdir_error"
    return 1
  fi

  report_lock_create_failure "$label" "$lock_dir"
  if [ -s "$mkdir_error" ]; then
    sed 's/^/detail: /' "$mkdir_error" >&2
  fi
  rm -f "$mkdir_error"
  return 2
}

acquire_path_lock() {
  local lock_dir="$1"
  local label="$2"
  local started_at=""
  local now=""
  local owner_pid=""
  local mkdir_status=0

  started_at="$(date +%s)"

  while true; do
    set +e
    try_mkdir_lock "$lock_dir" "$label"
    mkdir_status=$?
    set -e
    if [ "$mkdir_status" -eq 0 ]; then
      break
    fi
    if [ "$mkdir_status" -eq 2 ]; then
      return 1
    fi

    owner_pid="$(lock_owner_for "$lock_dir" || true)"

    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "warning: removing stale $label lock from pid $owner_pid" >&2
      remove_stale_path_lock "$lock_dir" "$owner_pid" || true
      continue
    fi

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
      if [ -n "$owner_pid" ]; then
        echo "error: timed out waiting for $label lock held by pid $owner_pid at $lock_dir" >&2
      else
        echo "error: timed out waiting for $label lock at $lock_dir" >&2
      fi
      return 1
    fi

    sleep "$LOCK_POLL_SECONDS"
  done

  printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock_dir/pid"
}

acquire_bootstrap_lock() {
  local started_at=""
  local now=""
  local owner_pid=""
  local mkdir_status=0

  started_at="$(date +%s)"

  while true; do
    set +e
    try_mkdir_lock "$BOOTSTRAP_LOCK_DIR" "submodule bootstrap"
    mkdir_status=$?
    set -e
    if [ "$mkdir_status" -eq 0 ]; then
      break
    fi
    if [ "$mkdir_status" -eq 2 ]; then
      return 1
    fi

    owner_pid="$(lock_owner_pid || true)"

    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "warning: removing stale submodule bootstrap lock from pid $owner_pid" >&2
      remove_stale_bootstrap_lock "$owner_pid" || true
      continue
    fi

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$LOCK_TIMEOUT_SECONDS" ]; then
      if [ -n "$owner_pid" ]; then
        echo "error: timed out waiting for submodule bootstrap lock held by pid $owner_pid at $BOOTSTRAP_LOCK_DIR" >&2
      else
        echo "error: timed out waiting for submodule bootstrap lock at $BOOTSTRAP_LOCK_DIR" >&2
      fi
      return 1
    fi

    sleep "$LOCK_POLL_SECONDS"
  done

  printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BOOTSTRAP_LOCK_DIR/pid"
  trap release_bootstrap_lock EXIT
  trap 'release_bootstrap_lock; exit 130' INT
  trap 'release_bootstrap_lock; exit 143' TERM
}

is_git_repo() {
  [ -e "$1/.git" ] || return 1
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

is_git_reference() {
  [ -d "$1" ] || return 1
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

is_bare_reference() {
  [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]
}

git_common_checkout_root() {
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common_dir" ] || return 1

  case "$common_dir" in
    /*) ;;
    *) common_dir="$REPO_ROOT/$common_dir" ;;
  esac

  if [ "$(basename "$common_dir")" = ".git" ]; then
    (cd "$(dirname "$common_dir")" && pwd -P)
    return 0
  fi

  return 1
}

infer_reference_root() {
  local common_root=""

  if [ -n "$REFERENCE_ROOT" ]; then
    return 0
  fi

  common_root="$(git_common_checkout_root || true)"
  if [ -n "$common_root" ] && [ "$common_root" != "$REPO_ROOT" ] && is_git_repo "$common_root"; then
    REFERENCE_ROOT="$common_root"
    return 0
  fi

  # Fallback for older/manual Symphony layouts where the common-dir lookup is
  # unavailable but the worktree still lives under the primary checkout.
  case "$REPO_ROOT" in
    */.symphony-workspaces/*)
      local candidate="${REPO_ROOT%%/.symphony-workspaces/*}"
      if is_git_repo "$candidate"; then
        REFERENCE_ROOT="$candidate"
      fi
      ;;
  esac
}

infer_reference_root

validate_lock_config
acquire_bootstrap_lock

is_submodule_ready() {
  local submodule_path="$1"
  local expected_sha="${2:-}"
  local actual_sha=""

  [ -e "$submodule_path/.git" ] && is_git_repo "$submodule_path" || return 1

  if [ -n "$expected_sha" ]; then
    actual_sha="$(git -C "$submodule_path" rev-parse HEAD 2>/dev/null || true)"
    [ "$actual_sha" = "$expected_sha" ] || return 1
  fi

  return 0
}

submodule_sha() {
  local submodule_path="$1"
  git ls-tree HEAD -- "$submodule_path" | awk '{print $3}'
}

default_reference_for() {
  local submodule_path="$1"

  if [ -n "$REFERENCE_ROOT" ] && is_git_repo "$REFERENCE_ROOT/$submodule_path"; then
    printf '%s\n' "$REFERENCE_ROOT/$submodule_path"
    return 0
  fi

  if [ -n "${REMCLAW_OPENCLAW_REFERENCE:-}" ] && [ "$submodule_path" = "openclaw" ] && is_git_reference "$REMCLAW_OPENCLAW_REFERENCE"; then
    printf '%s\n' "$REMCLAW_OPENCLAW_REFERENCE"
    return 0
  fi

  return 1
}

submodule_url() {
  local submodule_path="$1"
  local url=""

  url="$(git config -f .gitmodules --get "submodule.$submodule_path.url" 2>/dev/null || true)"
  if [ -z "$url" ]; then
    url="$(git config --get "submodule.$submodule_path.url" 2>/dev/null || true)"
  fi

  printf '%s\n' "$url"
}

submodule_branch() {
  local submodule_path="$1"
  local branch=""

  branch="$(git config -f .gitmodules --get "submodule.$submodule_path.branch" 2>/dev/null || true)"
  printf '%s\n' "$branch"
}

cache_name_for() {
  local submodule_path="$1"
  printf '%s' "$submodule_path" | tr -c 'A-Za-z0-9._-' '_'
}

cache_has_commit() {
  local cache_path="$1"
  local expected_sha="$2"

  [ -n "$expected_sha" ] || return 1
  git -C "$cache_path" cat-file -e "$expected_sha^{commit}" >/dev/null 2>&1
}

cache_reference_for() {
  local submodule_path="$1"
  local expected_sha="$2"
  local url=""
  local branch=""
  local cache_path=""
  local cache_lock=""
  local clone_args=(clone --bare)

  case "$DISABLE_CACHE" in
    1|true|TRUE|yes|YES) return 1 ;;
  esac

  url="$(submodule_url "$submodule_path")"
  [ -n "$url" ] || return 1
  branch="$(submodule_branch "$submodule_path")"

  cache_path="$CACHE_ROOT/$(cache_name_for "$submodule_path").git"
  cache_lock="$cache_path.lock"
  mkdir -p "$CACHE_ROOT"
  acquire_path_lock "$cache_lock" "$submodule_path cache"

  if is_git_reference "$cache_path"; then
    local fetch_args=(fetch --prune origin)
    if [ -n "$branch" ]; then
      fetch_args+=("+refs/heads/$branch:refs/heads/$branch")
    fi

    if git -C "$cache_path" "${fetch_args[@]}"; then
      if cache_has_commit "$cache_path" "$expected_sha"; then
        printf '%s\n' "$cache_path"
        release_path_lock "$cache_lock"
        return 0
      fi

      echo "warning: refreshed cached $submodule_path clone is missing $expected_sha" >&2
      release_path_lock "$cache_lock"
      return 1
    fi

    if cache_has_commit "$cache_path" "$expected_sha"; then
      echo "warning: could not refresh cached $submodule_path clone; using cached commit $expected_sha" >&2
      printf '%s\n' "$cache_path"
      release_path_lock "$cache_lock"
      return 0
    fi

    echo "warning: cached $submodule_path clone is stale and missing $expected_sha" >&2
    release_path_lock "$cache_lock"
    return 1
  fi

  if [ -n "$branch" ]; then
    clone_args+=(--single-branch --branch "$branch")
  fi

  echo "Creating cached bare clone for $submodule_path: $cache_path" >&2
  if git "${clone_args[@]}" "$url" "$cache_path"; then
    if cache_has_commit "$cache_path" "$expected_sha"; then
      printf '%s\n' "$cache_path"
      release_path_lock "$cache_lock"
      return 0
    fi

    echo "warning: cached $submodule_path clone was created but is missing $expected_sha" >&2
  fi

  rm -rf "$cache_path"
  release_path_lock "$cache_lock"
  return 1
}

prepare_target_for_reference_clone() {
  local submodule_path="$1"

  if [ ! -e "$submodule_path" ]; then
    return 0
  fi

  if is_git_repo "$submodule_path"; then
    return 0
  fi

  if [ -d "$submodule_path" ] && [ -z "$(find "$submodule_path" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    rmdir "$submodule_path"
    return 0
  fi

  local stale_path="${submodule_path}.bootstrap-failed-$(date +%Y%m%d%H%M%S)"
  echo "warning: moving non-git $submodule_path aside to $stale_path before local reference clone" >&2
  mv "$submodule_path" "$stale_path"
}

bootstrap_from_reference() {
  local submodule_path="$1"
  local reference_path="$2"
  local expected_sha="$3"

  if [ -z "$expected_sha" ]; then
    echo "error: could not determine expected commit for $submodule_path" >&2
    return 1
  fi

  prepare_target_for_reference_clone "$submodule_path"

  if ! is_git_repo "$submodule_path"; then
    echo "Cloning $submodule_path from local reference: $reference_path"
    if is_bare_reference "$reference_path"; then
      local reference_url=""
      reference_url="$(git -C "$reference_path" config --get remote.origin.url 2>/dev/null || true)"
      [ -n "$reference_url" ] || {
        echo "error: cached reference $reference_path does not have a remote.origin.url" >&2
        return 1
      }
      git clone --reference-if-able "$reference_path" --dissociate "$reference_url" "$submodule_path"
    else
      git clone --shared "$reference_path" "$submodule_path"
    fi
  fi

  if ! git -C "$submodule_path" checkout --detach "$expected_sha"; then
    echo "warning: $expected_sha was not present in $reference_path; fetching before retry" >&2
    git -C "$submodule_path" fetch --all --tags --prune
    git -C "$submodule_path" checkout --detach "$expected_sha"
  fi
  git -C "$submodule_path" submodule update --init --recursive --jobs 8
  if ! git submodule absorbgitdirs -- "$submodule_path"; then
    echo "warning: could not absorb git dir for $submodule_path; leaving standalone checkout in place" >&2
  fi
}

bootstrap_one() {
  local submodule_path="$1"
  local reference_path=""
  local expected_sha=""
  local args=(submodule update --init --recursive --jobs 8)

  expected_sha="$(submodule_sha "$submodule_path")"

  if is_submodule_ready "$submodule_path" "$expected_sha"; then
    echo "$submodule_path submodule is already ready."
    return 0
  fi

  if reference_path="$(default_reference_for "$submodule_path")"; then
    echo "Using local reference for $submodule_path: $reference_path"
    bootstrap_from_reference "$submodule_path" "$reference_path" "$expected_sha"
    echo "$submodule_path submodule is ready from local reference."
    return 0
  fi

  if reference_path="$(cache_reference_for "$submodule_path" "$expected_sha")"; then
    echo "Using cached reference for $submodule_path: $reference_path"
    bootstrap_from_reference "$submodule_path" "$reference_path" "$expected_sha"
    echo "$submodule_path submodule is ready from cached reference."
    return 0
  fi

  git submodule sync --recursive -- "$submodule_path"

  if git "${args[@]}" -- "$submodule_path"; then
    echo "$submodule_path submodule is ready."
    return 0
  fi

  if [ -n "$reference_path" ]; then
    echo "warning: git submodule update failed for $submodule_path; retrying via shared local clone" >&2
    bootstrap_from_reference "$submodule_path" "$reference_path" "$expected_sha"
    echo "$submodule_path submodule is ready from local reference."
    return 0
  fi

  echo "error: failed to initialize $submodule_path and no local reference was available" >&2
  return 1
}

IFS=',' read -ra SUBMODULES <<< "$REQUIRED_SUBMODULES"
for submodule_path in "${SUBMODULES[@]}"; do
  submodule_path="$(printf '%s' "$submodule_path" | xargs)"
  [ -z "$submodule_path" ] && continue
  bootstrap_one "$submodule_path"
done

echo "Submodule bootstrap complete."
