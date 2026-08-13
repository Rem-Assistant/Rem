#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere inside the repo.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

echo "Initializing/updating required submodules..."
./scripts/bootstrap-submodules.sh

if [ -d "openclaw/.git" ] || [ -f "openclaw/.git" ]; then
  echo "openclaw submodule is ready."
else
  echo "warning: openclaw submodule is not initialized correctly" >&2
  exit 1
fi

echo "Setup complete."
