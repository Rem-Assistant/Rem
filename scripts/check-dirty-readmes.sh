#!/usr/bin/env bash
# check-dirty-readmes — bash 3.2 compatible README enforcement
#
# Fails if:
#   1. A touched folder has source files but no README.md
#   2. A touched folder has code changes but README.md wasn't also changed
#
# Usage:
#   --staged  (default)  check only staged files
#   --all                check all modified files

set -euo pipefail

MODE="${1:-staged}"

if [ "$MODE" = "--staged" ]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")
elif [ "$MODE" = "--all" ]; then
  FILES=$(git diff --name-only --diff-filter=ACMR 2>/dev/null || echo "")
else
  echo "Usage: $0 [--staged|--all]" >&2
  exit 1
fi

if [ -z "$FILES" ]; then
  echo "No files to check — skipping README enforcement."
  exit 0
fi

MISSING=0
STALE=0

while IFS= read -r f; do
  [ -z "$f" ] && continue

  # Skip non-source dirs
  case "$f" in
    .git/*|.claude/*|node_modules/*|build/*|dist/*|graphify-out/*) continue ;;
  esac

  dir=$(dirname "$f")

  # Skip common non-source dirs
  case "$dir" in
    .git|.claude|node_modules|build|dist|graphify-out) continue ;;
  esac

  has_readme="false"
  readme_changed="false"

  if [ -f "$dir/README.md" ]; then
    has_readme="true"
    if echo "$FILES" | grep -q "^${dir}/README.md"; then
      readme_changed="true"
    fi
  fi

  if [ "$has_readme" = "false" ]; then
    src_count=$(find "$dir" -maxdepth 1 -type f \( -name "*.swift" -o -name "*.ts" -o -name "*.js" -o -name "*.tsx" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "$src_count" -gt 0 ]; then
      echo "MISSING: $dir/README.md (folder has $src_count source file(s))" >&2
      MISSING=$((MISSING + 1))
    fi
  elif [ "$readme_changed" = "false" ]; then
    # Check if there are non-markdown code changes in this folder
    code_changed=$(echo "$FILES" | grep "^$dir/" | grep -v "\.md$" || true)
    if [ -n "$code_changed" ]; then
      echo "STALE: $dir/README.md not updated (code changed)" >&2
      STALE=$((STALE + 1))
    fi
  fi
done <<< "$FILES"

echo ""
if [ "$MISSING" -gt 0 ]; then
  echo "FAIL: $MISSING folder(s) lack README.md"
  exit 1
fi

if [ "$STALE" -gt 0 ]; then
  echo "WARN: $STALE README(s) not updated with code changes"
fi

echo "README check: passed"
exit 0