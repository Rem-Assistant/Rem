#!/usr/bin/env bash
#
# visual-verify-publish.sh — post visual-verify screenshots as a sticky PR comment
# with INLINE images, using BOUNDED storage.
#
# Storage model (why it doesn't grow forever):
#   - ONE folder per PR (`pr-<n>/`), OVERWRITTEN each run — not a new folder per
#     run. So the shots branch tip holds only (open PRs x screens), not every run.
#   - Images referenced by BRANCH URL (+ a `?<sha>` cache-bust), not by commit SHA.
#     That means a periodic squash can reclaim history WITHOUT breaking the images
#     shown in open PRs (they point at the branch tip, which the squash preserves).
#   - A companion workflow (visual-verify-cleanup.yml) removes a PR's folder only
#     when it is closed WITHOUT merging (abandoned); MERGED PRs keep their record.
#   This trades "immortal SHA-pinned images" for "branch-ref images, kept for merged
#   PRs and reclaimable by squash" — the right call for review evidence. Committed
#   copies are downscaled (shown at 200px, stored at 600px);
#   full-res stays in the run artifact.
#
# Env (from the workflow): GH_TOKEN, PRNUM, HEADSHA, GITHUB_REPOSITORY.
set -euo pipefail
: "${GH_TOKEN:?}"; : "${PRNUM:?}"; : "${HEADSHA:?}"; : "${GITHUB_REPOSITORY:?}"

SHOTS_BRANCH="visual-verify-shots"
SHORT="${HEADSHA:0:12}"
DIR="pr-${PRNUM}"   # one bounded folder per PR, overwritten each run

shopt -s nullglob
pngs=(visual-verify-out/*.png)
if [ "${#pngs[@]}" -eq 0 ]; then echo "no screenshots to publish"; exit 0; fi

TMP="$(mktemp -d)/shots"
AUTH="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git ls-remote --exit-code --heads "$AUTH" "$SHOTS_BRANCH" >/dev/null 2>&1; then
  git clone --quiet --depth 1 --branch "$SHOTS_BRANCH" "$AUTH" "$TMP"
else
  git clone --quiet --depth 1 "$AUTH" "$TMP"
  ( cd "$TMP" && git checkout --quiet --orphan "$SHOTS_BRANCH" && { git rm -rqf . >/dev/null 2>&1 || true; } )
fi

# Overwrite this PR's folder (bounded — no per-run accumulation).
rm -rf "${TMP:?}/${DIR}"
mkdir -p "$TMP/$DIR"
cp "${pngs[@]}" "$TMP/$DIR/"
# Downscale committed copies (sips is built in on macOS runners). Full-res is in
# the uploaded artifact; these are for glanceable in-PR review.
if command -v sips >/dev/null; then
  for p in "$TMP/$DIR"/*.png; do sips --resampleWidth 600 "$p" >/dev/null 2>&1 || true; done
fi
(
  cd "$TMP"
  git config user.name  "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add -A -- "$DIR"
  git commit --quiet -m "visual-verify: PR #${PRNUM} @ ${SHORT}" || echo "no image change to commit"
  git push --quiet origin "HEAD:${SHOTS_BRANCH}"
)

# Build the sticky comment. Branch-ref URL + per-run cache-bust query so a re-run
# shows fresh images even though the path is stable.
BODY="$(mktemp)"
{
  echo "<!-- visual-verify -->"
  echo "### 📸 Visual verify · \`${SHORT}\` · ${#pngs[@]} screens"
  echo
  echo "| Screen | Screen |"
  echo "|:--:|:--:|"
  i=0; row=""
  for f in "${pngs[@]}"; do
    n="$(basename "$f" .png)"
    url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${SHOTS_BRANCH}/${DIR}/${n}.png?${SHORT}"
    cell="**\`${n}\`**<br><img src=\"${url}\" width=\"200\">"
    if [ $((i % 2)) -eq 0 ]; then row="| ${cell} "; else echo "${row}| ${cell} |"; row=""; fi
    i=$((i + 1))
  done
  [ -n "$row" ] && echo "${row}|  |"
  echo
  echo "<sub>Rendered from the app's \`--rem-*-fixture\` launch args · mock data only · kept for merged PRs; removed only if the PR is abandoned.</sub>"
} > "$BODY"

PAYLOAD="$(mktemp)"
jq -n --arg b "$(cat "$BODY")" '{body: $b}' > "$PAYLOAD"
CID="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PRNUM}/comments" --paginate \
        -q '.[] | select(.body|startswith("<!-- visual-verify -->")) | .id' 2>/dev/null | head -1 || true)"
if [ -n "$CID" ]; then
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${CID}" --input "$PAYLOAD" >/dev/null
  echo "updated sticky comment ${CID}"
else
  gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PRNUM}/comments" --input "$PAYLOAD" >/dev/null
  echo "created sticky comment"
fi
