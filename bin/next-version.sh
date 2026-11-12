#!/usr/bin/env bash
# next-version.sh — the single source of semver truth for release.yml.
# Computes the next release tag from the newest v-tag in the CURRENT repo.
#
#   usage: next-version.sh patch|minor|major   → prints vMAJOR.MINOR.PATCH only
#          next-version.sh --current           → prints the newest v-tag or ''
#   exit:  0 ok · 2 garbage bump / malformed existing tag (stdout stays silent)
#
# no-tags rule (fresh repo, or a branch that predates every release):
# major→v1.0.0, minor→v0.1.0, patch→v0.1.0 — the 0.x line is born first,
# a major bump is what graduates it.
set -uo pipefail

case "${1:-}" in
  --current)
    git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true
    exit 0 ;;
esac

BUMP="${1:-}"
case "$BUMP" in
  patch|minor|major) ;;
  *) echo "next-version: bump must be patch|minor|major (got '${BUMP:-<empty>}')" >&2; exit 2 ;;
esac

LATEST=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) || LATEST=""

if [ -z "$LATEST" ]; then
  [ "$BUMP" = major ] && echo v1.0.0 || echo v0.1.0
  exit 0
fi

[[ "$LATEST" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
  echo "next-version: existing tag '$LATEST' is not vMAJOR.MINOR.PATCH" >&2; exit 2; }

M=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; p=${BASH_REMATCH[3]}
case "$BUMP" in
  major) M=$((10#$M+1)); m=0; p=0 ;;
  minor) m=$((10#$m+1)); p=0 ;;
  patch) p=$((10#$p+1)) ;;
esac
echo "v${M}.${m}.${p}"
