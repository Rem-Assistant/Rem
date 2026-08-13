#!/usr/bin/env bash
# pre-commit hook — runs before every commit
# Install: cp scripts/pre-commit.sh .git/hooks/pre-commit
#          chmod +x .git/hooks/pre-commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Run README enforcement on staged files
"$REPO_ROOT/scripts/check-dirty-readmes.sh" --staged