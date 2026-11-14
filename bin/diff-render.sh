#!/usr/bin/env bash
# diff-render.sh — the diff REVIEWERS deserve for manifest changes: render
# every kustomize dir at two refs and diff the OUTPUT (what Argo applies),
# never the authoring YAML. Informational: it prints; the pass/fail authority
# stays with validate-all.sh (whose loss-baseline shares this machinery).
#
#   usage: diff-render.sh [vortex-path] [base-ref]   (head = working tree/HEAD)
set -uo pipefail
VORTEX="${1:-.}"; BASE="${2:-origin/main}"
cd "$VORTEX"
command -v kubectl >/dev/null || { echo "kubectl required"; exit 2; }
HELM=""
command -v helm >/dev/null 2>&1 && HELM="--enable-helm"
if [ -f .git/shallow ]; then git fetch --unshallow -q origin 2>/dev/null || true; fi
git fetch -q origin "$BASE" 2>/dev/null || true
# MERGE-BASE, never the ref tip: main may have moved past the branch point,
# and dirs untouched by this change would render differently at the tip —
# phantom diffs mislead the review this summary feeds. (Globs fixed
# 2026-11-14: applications/overlays were the pre-env-model tree — the script
# rendered NOTHING and silently reported "no rendered differences".)
BC=$(git merge-base HEAD "$BASE" 2>/dev/null) || BC="$BASE"
WT=$(mktemp -d)
trap 'git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"' EXIT
git worktree add --detach "$WT" "$BC" >/dev/null 2>&1 || { echo "cannot check out $BC"; exit 2; }

render() { # $1 dir-root  $2 out
  (cd "$1" && for d in bases/*/ environments/*/*/ overlays/*/*/ apps/*/; do
    [ -f "$d/kustomization.yaml" ] || continue
    echo "### $d"
    kubectl kustomize "$d" ${HELM:+$HELM} 2>&1 || true
  done) > "$2"
}

A="$WT/.render-base"; B="$WT/.render-head"
render "$WT" "$A"; render "$(pwd)" "$B"
if cmp -s "$A" "$B"; then
  echo "no rendered differences"
else
  diff -u "$A" "$B" > "$WT/.diff" || true
  echo "## Rendered diff (base → HEAD)"
  echo '```diff'
  head -400 "$WT/.diff"
  echo '```'
fi
