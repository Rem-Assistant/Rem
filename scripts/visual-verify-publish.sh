#!/usr/bin/env bash
#
# visual-verify-publish.sh — post visual-verify screenshots as a sticky PR comment
# with INLINE images. Runs in CI on pull_request events, after visual-verify.sh.
#
# Images are hosted by committing them to a dedicated `visual-verify-shots` branch
# and linking by COMMIT-SHA raw URL, so the evidence survives the PR branch being
# deleted (the repo's PR-evidence rule). The comment is sticky: it carries an HTML
# marker and is updated in place on re-runs instead of piling up duplicates.
#
# Env (provided by the workflow): GH_TOKEN, PRNUM, HEADSHA, GITHUB_REPOSITORY.
set -euo pipefail
: "${GH_TOKEN:?}"; : "${PRNUM:?}"; : "${HEADSHA:?}"; : "${GITHUB_REPOSITORY:?}"

SHOTS_BRANCH="visual-verify-shots"
SHORT="${HEADSHA:0:12}"
DIR="pr-${PRNUM}/${SHORT}"

shopt -s nullglob
pngs=(visual-verify-out/*.png)
if [ "${#pngs[@]}" -eq 0 ]; then echo "no screenshots to publish"; exit 0; fi

# --- host the images on the shots branch ---
TMP="$(mktemp -d)/shots"
AUTH="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git ls-remote --exit-code --heads "$AUTH" "$SHOTS_BRANCH" >/dev/null 2>&1; then
  git clone --quiet --depth 1 --branch "$SHOTS_BRANCH" "$AUTH" "$TMP"
else
  git clone --quiet --depth 1 "$AUTH" "$TMP"
  ( cd "$TMP" && git checkout --quiet --orphan "$SHOTS_BRANCH" && { git rm -rqf . >/dev/null 2>&1 || true; } )
fi
mkdir -p "$TMP/$DIR"
cp "${pngs[@]}" "$TMP/$DIR/"
(
  cd "$TMP"
  git config user.name  "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$DIR"
  git commit --quiet -m "visual-verify: PR #${PRNUM} @ ${SHORT}"
  git push --quiet origin "HEAD:${SHOTS_BRANCH}"
)
SHOTSHA="$(git -C "$TMP" rev-parse HEAD)"

# --- build the sticky comment body (2-column table of inline images) ---
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
    url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${SHOTSHA}/${DIR}/${n}.png"
    cell="**\`${n}\`**<br><img src=\"${url}\" width=\"200\">"
    if [ $((i % 2)) -eq 0 ]; then row="| ${cell} "; else echo "${row}| ${cell} |"; row=""; fi
    i=$((i + 1))
  done
  [ -n "$row" ] && echo "${row}|  |"
  echo
  echo "<sub>Rendered from the app's \`--rem-*-fixture\` launch args · mock data only · images pinned by commit SHA so they survive branch deletion.</sub>"
} > "$BODY"

# --- post or update the sticky comment ---
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
