#!/usr/bin/env bash
# next-version.sh — the single source of semver truth for releases.
# Arithmetic is the VENDORED, PINNED semver-tool 3.4.0 (bin/vendor/semver —
# Apache-2.0, see header); selection and doctrine stay ours:
#
#   selection: the highest VERSION tag reachable from HEAD, by sort -V.
#     NOT git describe — describe sorts equidistant tags by TAGGER DATE, and
#     that order is a live-fire bug class (2026-11-13: v1.0.0 minted first,
#     v0.2.0 minted later on the same commit => describe said "newest" was
#     v0.2.0 => major computed v1.0.0 => died on tag-exists).
#   --merged HEAD: only released history counts; a stray tag on an
#     abandoned branch cannot inflate the next version.
#
#   usage: next-version.sh patch|minor|major   → prints vMAJOR.MINOR.PATCH only
#          next-version.sh --current           → newest reachable v-tag or ''
#   exit:  0 ok · 2 garbage bump / malformed existing tag (stdout silent)
#
# no-tags rule (fresh repo, or history predating every release) — OWNER
# RULING, a deliberate deviation from the tool (which would say 0.0.1):
# major→v1.0.0, minor→v0.1.0, patch→v0.1.0.
# Prerelease bumps follow the TOOL's mechanical rule (minor on 3.0.0-rc.1 →
# 3.1.0), NOT npm-semver's. Estate tags are strictly vX.Y.Z (push-release.sh
# gate), so this is inherited behavior pinned by the test battery.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEMVER="$HERE/vendor/semver"
command -v sort >/dev/null || { echo "next-version: GNU sort -V required" >&2; exit 2; }

case "${1:-}" in
  --current)
    git tag --merged HEAD --list 'v[0-9]*' 2>/dev/null | sort -V | tail -1
    exit 0 ;;
esac

BUMP="${1:-}"
case "$BUMP" in
  patch|minor|major) ;;
  *) echo "next-version: bump must be patch|minor|major (got '${BUMP:-<empty>}')" >&2; exit 2 ;;
esac

LATEST=$(git tag --merged HEAD --list 'v[0-9]*' 2>/dev/null | sort -V | tail -1)

if [ -z "$LATEST" ]; then
  [ "$BUMP" = major ] && echo v1.0.0 || echo v0.1.0
  exit 0
fi

bash "$SEMVER" validate "$LATEST" 2>/dev/null | grep -qx valid || {
  echo "next-version: existing tag '$LATEST' is not vMAJOR.MINOR.PATCH[-prerelease]" >&2; exit 2; }

CORE="${LATEST#v}"
NEXT=$(bash "$SEMVER" bump "$BUMP" "$CORE") || {
  echo "next-version: semver-tool failed to bump '$CORE' ($BUMP)" >&2; exit 2; }
echo "v${NEXT}"
