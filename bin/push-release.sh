#!/usr/bin/env bash
# push-release.sh — the cascade key. Pushes the release tag with
# RELEASE_BOT_PAT, NOT with the run's GITHUB_TOKEN: events created by the
# default token NEVER trigger another workflow, so a tag pushed "normally"
# is a release that silently never deploys. The PAT is mechanism, not
# preference. The GitHub release object is minted with the same identity.
#
#   usage: push-release.sh vX.Y.Z
#   env:   RELEASE_BOT_PAT   fine-grained PAT, contents:write on this repo
#          GITHUB_REPOSITORY owner/repo (Actions sets it)
#          GITHUB_SERVER_URL optional (default https://github.com)
#          DRY_RUN=1         print intent, touch nothing
set -uo pipefail
V="${1:?usage: push-release.sh vX.Y.Z}"
[[ "$V" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "push-release: '$V' is not vX.Y.Z" >&2; exit 2; }

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY-RUN: would push refs/tags/$V via https://x-access-token:***@github.com/${GITHUB_REPOSITORY:-owner/repo}.git"
  echo "DRY-RUN: then gh release create $V --generate-notes"
  exit 0
fi

[ -n "${RELEASE_BOT_PAT:-}" ] || {
  echo "push-release: RELEASE_BOT_PAT is empty — REFUSING to push a tag whose event" >&2
  echo "  would come from GITHUB_TOKEN and therefore never trigger release.yml." >&2
  echo "  A release that silently does not deploy is worse than a red job." >&2
  exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "push-release: GITHUB_REPOSITORY required" >&2; exit 2; }
HOST="${GITHUB_SERVER_URL:-https://github.com}"; HOST="${HOST#https://}"

git push -q "https://x-access-token:${RELEASE_BOT_PAT}@${HOST}/${GITHUB_REPOSITORY}.git" "refs/tags/${V}"
echo "tag $V pushed via PAT — the tag-push event can now cascade to release.yml"

# If gh fails from here the tag is already public: say so loudly and hand the
# operator the recovery line instead of leaving an orphan.
GH_TOKEN="$RELEASE_BOT_PAT" gh release create "$V" --generate-notes --title "$V" \
  --repo "$GITHUB_REPOSITORY" || {
  echo "push-release: tag $V IS PUSHED but the release object failed." >&2
  echo "  Recovery: GH_TOKEN=\$RELEASE_BOT_PAT gh release create $V --generate-notes" >&2
  echo "  (or undo: git push origin :refs/tags/$V, then re-approve the bump)" >&2
  exit 1; }
echo "release $V created"
