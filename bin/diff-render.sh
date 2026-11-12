#!/usr/bin/env bash
# diff-render.sh — the diff REVIEWERS deserve for manifest changes: render
# every kustomize dir at two refs and diff the OUTPUT (what Argo applies),
# never the authoring YAML. Informational: it prints; the pass/fail authority
# stays with validate-all.sh.
#
#   usage: diff-render.sh [vortex-path] [base-ref]   (head = working tree/HEAD)
set -uo pipefail
VORTEX="${1:-.}"; BASE="${2:-origin/main}"
cd "$VORTEX"
command -v kubectl >/dev/null || { echo "kubectl required"; exit 2; }
HELM=""
command -v helm >/dev/null 2>&1 && HELM="--enable-helm"

WT=$(mktemp -d)
trap 'git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"' EXIT
git fetch -q origin "$BASE" 2>/dev/null || true
git worktree add --detach "$WT" "$BASE" >/dev/null 2>&1 || { echo "cannot check out $BASE"; exit 2; }

render() { # $1 dir-root  $2 out
  (cd "$1" && for d in applications/*/ overlays/*/*/; do
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
