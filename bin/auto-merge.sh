#!/usr/bin/env bash
# auto-merge.sh — runs INSIDE the vortex repo's workflow (its GITHUB_TOKEN).
# Merges a PR iff every guard holds; otherwise exits 0 silently, leaving the
# PR to humans. The guards are the contract — a bump PR is not trusted
# because of who opened it, only because of what it provably contains:
#
#   1. head ref matches bump/<app>-<tag>
#   2. label deploy-bump present
#   3. every changed file is applications/<app>/kustomization.yaml
#   4. every changed LINE is inside the images: block (no surprises in
#      rendered output — validate-manifests covers semantics, this covers syntax)
#   5. required checks green (validate-manifests)
#   6. the repo variable DEPLOY_AUTOMERGE is exactly "on" (absent = off)
#
#   usage: auto-merge.sh <pr-number> [--dry-run]
set -uo pipefail
PR="${1:?pr number}"; DRY="${2:-}"
cd "${VORTEX_DIR:-.}"

say() { echo "[auto-merge] $*"; }
bail() { say "NOT eligible: $*"; exit 0; }   # silence IS the safe answer

JSON=$(gh pr view "$PR" --json headRefName,labels,files --jq \
  '{head: .headRefName, labels: [.labels[].name], files: [.files[].path]}')
HEAD=$(jq -r .head <<<"$JSON")
[[ "$HEAD" =~ ^bump/[a-z0-9-]+-[a-z0-9._-]+$ ]] || bail "head ref '$HEAD'"
jq -e '.labels | index("deploy-bump")' <<<"$JSON" >/dev/null || bail "missing label"
FILES=$(jq -r '.files[]' <<<"$JSON")
[ -n "$FILES" ] || bail "no files"
while IFS= read -r f; do
  [[ "$f" =~ ^applications/[a-z0-9-]+/kustomization\.yaml$ ]] || bail "path $f outside the fence"
done <<<"$FILES"

# line fence: allow only images: stanza syntax in added/removed lines
while IFS= read -r line; do
  case "$line" in
    '+++'*|'---'*|'@@'*|'diff '*|'index '*) continue ;;
    '+'*|'-'*)
      body=${line#?}
      [[ "$body" =~ ^[[:space:]]*$ ]] && continue
      [[ "$body" =~ ^images:[[:space:]]* ]] && continue
      [[ "$body" =~ ^-[[:space:]]+(name|newName|newTag):[[:space:]]*[^[:space:]] ]] && continue
      # canonical kustomize emits the continuation keys INDENTED, not as list
      # items — newName/newTag exist only under images:, so these two names are
      # still fence-safe (a `name:` key lives elsewhere too; it stays list-only)
      [[ "$body" =~ ^[[:space:]]+(newName|newTag):[[:space:]]*[^[:space:]] ]] && continue
      [[ "$body" =~ ^[[:space:]]#.* ]] && continue   # comment changes allowed
      bail "line outside images: block: $body" ;;
  esac
done < <(gh pr diff "$PR")

# checks — EMPTY IS FATAL (fail-open fix, 2026-11-13): `labeled` fires the
# moment the PR opens, before validate-manifests even exists as a check-run.
# An empty list once meant "no required checks, proceed" — it also meant
# "checks not yet created", i.e. merge blind.
# v2 (2026-11-13, pre-enable audit): the first fix broke EARLY — any non-empty
# state (IN_PROGRESS!) exited the loop and then failed the SUCCESS test, so
# the guard would have bailed on every PR forever. Now: poll until the check
# reaches a TERMINAL state, only SUCCESS satisfies, anything else (or a
# timeout with no terminal verdict) hands the PR to humans.
DEADLINE=$((SECONDS + 600))
FINAL=""
while [ $SECONDS -lt $DEADLINE ]; do
  STATUSES=$(gh pr checks "$PR" --json name,state --jq '[.[] | select(.name=="validate-manifests") | .state] | @tsv' 2>/dev/null || echo "")
  case "$STATUSES" in
    ""|*PENDING*|*QUEUED*|*IN_PROGRESS*) sleep 15 ;;
    *) FINAL="$STATUSES"; break ;;
  esac
done
[ "$FINAL" = "SUCCESS" ] || bail "validate-manifests not green (${FINAL:-<no terminal verdict in 10min>})"

# kill switch — repo variable, absent means OFF
VAL=$(gh api "repos/${GITHUB_REPOSITORY:?}/actions/variables/DEPLOY_AUTOMERGE" --jq .value 2>/dev/null || echo "")
[ "$VAL" = "on" ] || bail "DEPLOY_AUTOMERGE='${VAL:-<absent>}' — switch is off by design"

say "guards GREEN — merging #$PR (squash)"
[ -n "$DRY" ] && { say "dry-run, not merged"; exit 0; }
gh pr merge "$PR" --squash --delete-branch
say "merged. Argo syncs within its poll interval; rollback = git revert + human PR."
