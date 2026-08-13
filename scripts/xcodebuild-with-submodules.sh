#!/usr/bin/env bash
set -euo pipefail

# Agent/worktree-safe xcodebuild wrapper.
#
# Fresh git worktrees often start with an empty `openclaw/` submodule path.
# Running xcodebuild directly then fails during package resolution before the
# agent gets useful validation output. Bootstrap first so Xcode can resolve the
# local OpenClawKit package without ad hoc symlinks or repeated reclones.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/bootstrap-submodules.sh"

exec xcodebuild "$@"
