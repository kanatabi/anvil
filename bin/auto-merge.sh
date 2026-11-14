#!/usr/bin/env bash
# auto-merge.sh — runs INSIDE the vortex repo's workflow (its GITHUB_TOKEN).
# Merges a PR iff every guard holds; otherwise exits 0 silently, leaving the
# PR to humans. The guards are the contract — a bump PR is not trusted
# because of who opened it, only because of what it provably contains:
#
#   1. head ref matches the bump grammar — NEW: bump/<app>-<env>-<tag> with
#      env ∈ foundation|staging|production; LEGACY (deprecated, accepted):
#      bump/<app>-<tag> ⇒ env=production. Unparseable env ⇒ BAIL — the
#      pre-env code kept going with a widened generic fence on an
#      unrecognized ref; silence-with-a-wider-gate is exactly the widening
#      this script must never do.
#   2. label deploy-bump present
#   3. every changed file is inside the FENCE OF PATTERNS (never keyed on app
#      or env LISTS): the new model admits any file under
#      environments/<env-from-head-ref>/ (the env's overlays hold the pin,
#      the epoch trio, and the same-env gate lockstep stanzas). TRANSITION
#      (legacy-shaped branches only — delete together with the vortex
#      env-model PR that removes the overlays/ tree): applications/<app>/
#      kustomization.yaml (the old pin — STRANDED by the 2026-11-14 bases/
#      rename: the path no longer exists, so the deprecated legacy bump
#      grammar has nothing left to touch; kept for fence archaeology),
#      overlays/production/<any>/
#      kustomization.yaml (the old gate-image lockstep), and any *.yaml under
#      overlays/production/<app-from-head-ref>/ (the old epoch pair).
#   4. every changed LINE is fence-legal syntax: inside the images: block, or
#      a config.epoch annotation line (BOTH trio sides — the pod-template
#      annotation and the ExternalSecret metadata annotation share this
#      pattern; they live in fence-admitted paths), or a --declared arg line
#      (validate-manifests covers semantics, this covers syntax)
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
# ---- branch grammar (env model, owner ruling) ------------------------------
#   NEW     bump/<app>-<env>-<tag>       env ∈ foundation|staging|production
#   LEGACY  bump/<app>-<tag>             ⇒ production. DEPRECATED: kept only
#           for bump branches minted before the restructure; removal rides the
#           same vortex env-model PR that deletes the overlays/ tree.
#   else    BAIL. An env we cannot parse is an env we cannot fence, and the
#           pre-grammar fallback (generic patterns, APP="") was a WIDENING —
#           fail-safe doctrine says narrower-or-nothing, never silently wider.
# The env alternatives are LITERALS, so the greedy first group resolves
# "bump/lumen-staging-production-v1.0.0" as app=lumen-staging, env=production:
# the env marker is the LAST literal before the tag.
REF="${HEAD#bump/}"
PR_APP="" PR_ENV="" LEGACY_BRANCH=""
if [[ "$REF" =~ ^([a-z0-9-]+)-(foundation|staging|production)-(.+)$ ]]; then
  PR_APP="${BASH_REMATCH[1]}"
  PR_ENV="${BASH_REMATCH[2]}"
else
  # DEPRECATED legacy shapes (env implied production) — v-tags end at the
  # first dash-less segment (bump/<app>-vX.Y.Z), sha- tags at sha-<hex>.
  case "$REF" in
    *-v[0-9]*) PR_APP="${REF%-v[0-9]*}"; PR_ENV=production; LEGACY_BRANCH=1 ;;
    *-sha-*)   PR_APP="${REF%-sha-*}";  PR_ENV=production; LEGACY_BRANCH=1 ;;
    *)         bail "cannot parse env from '$HEAD' — expected bump/<app>-<env>-<tag> (env: foundation|staging|production) or the deprecated bump/<app>-<tag>" ;;
  esac
fi
jq -e '.labels | index("deploy-bump")' <<<"$JSON" >/dev/null || bail "missing label"
FILES=$(jq -r '.files[]' <<<"$JSON")
[ -n "$FILES" ] || bail "no files"
while IFS= read -r f; do
  # new model: the bump's whole world lives under its env — pin, trio, and
  # the same-env gate lockstep stanzas. PR_ENV is regex-derived from three
  # literals; PR_APP from [a-z0-9.-] — both safe to interpolate.
  [[ "$f" =~ ^environments/${PR_ENV}/ ]] && continue
  # ---- TRANSITION fence — legacy-shaped branches ONLY (a new-grammar
  # staging/foundation branch must never touch the shared base or the
  # production overlay). Delete with the overlays/ tree (vortex env-model
  # PR); until then these are the pre-restructure pin/lockstep/pair paths.
  [ -n "$LEGACY_BRANCH" ] || bail "path $f outside the fence for env '$PR_ENV'"
  [[ "$f" =~ ^applications/[a-z0-9-]+/kustomization\.yaml$ ]] && continue # legacy pin path, stranded by the bases/ rename (grammar deprecated)
  [[ "$f" =~ ^overlays/production/[a-z0-9-]+/kustomization\.yaml$ ]] && continue
  [[ "$f" =~ ^overlays/production/${PR_APP}/.*\.yaml$ ]] && continue
  bail "path $f outside the fence"
done <<<"$FILES"

# line fence: allow only images: stanza + epoch-trio syntax in added/removed
# lines — every side of the trio is fence-legal BY PATTERN (config.epoch
# covers the pod-template AND the ExternalSecret metadata annotation — same
# line shape, different fence-admitted file; --declared is the gate arg),
# never by app or file enumeration
while IFS= read -r line; do
  case "$line" in
    '+++'*|'---'*|'@@'*|'diff '*|'index '*) continue ;;
    '+'*|'-'*)
      body=${line#?}
      [[ "$body" =~ ^[[:space:]]*$ ]] && continue
      [[ "$body" == *config.epoch* ]] && continue      # annotation side of the pair
      [[ "$body" == *--declared* ]] && continue        # arg side of the pair
      [[ "$body" =~ ^images:[[:space:]]* ]] && continue
      [[ "$body" =~ ^-[[:space:]]+(name|newName|newTag):[[:space:]]*[^[:space:]] ]] && continue
      # canonical kustomize emits the continuation keys INDENTED, not as list
      # items — newName/newTag exist only under images:, so these two names are
      # still fence-safe (a `name:` key lives elsewhere too; it stays list-only)
      [[ "$body" =~ ^[[:space:]]+(newName|newTag):[[:space:]]*[^[:space:]] ]] && continue
      [[ "$body" =~ ^[[:space:]]*#.* ]] && continue   # comment changes allowed (ANY indent — walked: 4-space comments inside patches bailed a legit bump)
      bail "line outside images: block: $body" ;;
  esac
done < <(gh pr diff "$PR")

# checks — EMPTY IS FATAL (fail-open fix, 2026-11-13): `labeled` fires the
# moment the PR opens, before validate-manifests even exists as a check-run.
# An empty list once meant "no required checks, proceed" — it also meant
# "checks not yet created", i.e. merge blind.
# v3 (first auto-merge in anger, PR #7): the NAME CONTRACT was the bug —
# a check-run is named after the JOB, and vortex's job id was `validate`,
# so select(.name=="validate-manifests") matched NOTHING, forever. The v1
# fail-open bug had been masking it (empty meant proceed!) — fixing the
# masking exposed the mismatch. Accept both forms (runs created before the
# workflow gained an explicit name still say `validate`), raise the budget
# to 15min, and on bail DUMP the observed checks — name-contract failures
# must be self-diagnosing, not archaeology.
DEADLINE=$((SECONDS + 900))
FINAL=""
while [ $SECONDS -lt $DEADLINE ]; do
  STATUSES=$(gh pr checks "$PR" --json name,state --jq '[.[] | select(.name=="validate-manifests" or .name=="validate") | .state] | @tsv' 2>/dev/null || echo "")
  case "$STATUSES" in
    ""|*PENDING*|*QUEUED*|*IN_PROGRESS*) sleep 15 ;;
    *) FINAL="$STATUSES"; break ;;
  esac
done
if [ "$FINAL" != "SUCCESS" ]; then
  say "observed checks: $(gh pr checks "$PR" --json name,state --jq '[.[]|"\(.name)=\(.state)"]|join(" ")' 2>/dev/null)"
  bail "validate-manifests not green (${FINAL:-<no terminal verdict in 15min>})"
fi

# kill switch — read from ENV: the workflow passes vars.DEPLOY_AUTOMERGE.
# 2026-11-13 lesson (PR #8): GITHUB_TOKEN CANNOT read the variables API —
# 403 "Resource not accessible by integration" is BY DESIGN; the `vars`
# context inside the workflow is the only door. Env wins; the API fallback
# exists for manual runs with a real token, and its output is SANITIZED —
# only the literal on/off counts; error bodies (even JSON ones) mean
# ABSENT, never a verdict. Absent = off: fail-safe doctrine unchanged.
VAL="${DEPLOY_AUTOMERGE:-}"
if [ -z "$VAL" ]; then
  RESP=$(gh api "repos/${GITHUB_REPOSITORY:?}/actions/variables/DEPLOY_AUTOMERGE" --jq .value 2>/dev/null || echo "")
  case "$RESP" in on|off) VAL="$RESP" ;; *) VAL="" ;; esac
fi
[ "$VAL" = "on" ] || bail "DEPLOY_AUTOMERGE='${VAL:-<absent>}' — switch is off by design (workflow should pass vars.DEPLOY_AUTOMERGE; absent or unreadable = off)"

say "guards GREEN — merging #$PR (squash)"
[ -n "$DRY" ] && { say "dry-run, not merged"; exit 0; }
gh pr merge "$PR" --squash --delete-branch
say "merged. Argo syncs within its poll interval; rollback = git revert + human PR."
