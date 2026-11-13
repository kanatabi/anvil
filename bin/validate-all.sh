#!/usr/bin/env bash
# validate-all.sh — the truth table for vortex manifests.
#
# Builds EVERY applications/ and overlays/ dir with kustomize (helm enabled —
# the ESO wrapper needs it), then asserts three classes of facts the estate's
# history paid for:
#   1. kind counts (the empty-base bug built successfully and rendered NOTHING;
#      exit-0 is not evidence — a table of expected counts is);
#   2. config shape (deployment CRs carry ZERO config literals; envFrom is the
#      only config surface; owner ruling 2026-11-11);
#   3. the PreSync migrate hook exists on every lumen chain (schema-gates-deploy,
#      owner ruling 2026-11-11).
#
#   usage: validate-all.sh [vortex-path] [--update]
#          --update regenerates bin/expected-kinds.txt from reality — a PR
#          that legitimately changes manifests MUST carry its table update.
set -uo pipefail

VORTEX="."
UPDATE=""
for a in "$@"; do
  case "$a" in
    --update) UPDATE=1 ;;
    *) VORTEX="$a" ;;
  esac
done
TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/expected-kinds.txt"

command -v kubectl >/dev/null || { echo "kubectl required (provides kustomize)"; exit 2; }
HELM_OK=$(command -v helm >/dev/null 2>&1 && echo 1 || echo 0)

cd "$VORTEX"

dirs=()
for d in applications/*/ overlays/*/*/; do
  [ -f "$d/kustomization.yaml" ] && dirs+=("$d")
done
# helm-free fast path when the ESO wrapper is not in scope? no — silence IS the
# empty-base bug's voice; if helm is missing, dirs needing it FAIL, loudly.

declare -A got
fail=0
for d in "${dirs[@]}"; do
  # dir text mentioning the chart wrapper or helmCharts ⇒ the build needs --enable-helm
  need_helm=0
  grep -q "helmCharts\|external-secrets" "$d"/*.yaml 2>/dev/null && need_helm=1
  if [ "$need_helm" = 1 ] && [ "$HELM_OK" = 0 ]; then
    echo "FAIL $d — requires helm (--enable-helm); install helm v3.22.1"; fail=1; continue
  fi
  args=(kustomize "$d"); [ "$need_helm" = 1 ] && args+=(--enable-helm)
  out=$(kubectl "${args[@]}" 2>&1)
  if [ $? -ne 0 ]; then echo "FAIL build $d"; echo "$out" | head -3; fail=1; continue; fi
  got[$d]=$(printf '%s\n' "$out" | grep -c '^kind:')
  # ---- class 2: config shape ----
  case "$d" in
    applications/earendil|applications/mellon|overlays/*/earendil|overlays/*/mellon)
      if printf '%s\n' "$out" | grep -qE 'value: "http://lumen-http-server|value: "x-forwarded'; then
        echo "FAIL shape $d — inline config literal found (everything lives in Bao)"; fail=1
      fi
      printf '%s\n' "$out" | grep -q 'configMapRef' || { echo "FAIL shape $d — envFrom app-config missing"; fail=1; }
      ;;
    applications/lumen|overlays/*/lumen)
      printf '%s\n' "$out" | grep -q 'lumen-secrets' || { echo "FAIL shape $d — envFrom lumen-secrets missing"; fail=1; }
      ;;
  esac
  # ---- class 3: migrate hook on lumen chains ----
  case "$d" in
    applications/lumen|overlays/*/lumen)
      printf '%s\n' "$out" | grep -q 'argocd.argoproj.io/hook: PreSync' ||
        { echo "FAIL hook $d — PreSync migrate Job vanished"; fail=1; }
      ;;
  esac
done

if [ -n "$UPDATE" ]; then
  { for d in "${!got[@]}"; do printf '%s\t%s\n' "$d" "${got[$d]}"; done; } | sort > "$TABLE"
  echo "table updated: $(wc -l < "$TABLE") dirs"; exit 0
fi

[ -f "$TABLE" ] || { echo "no $TABLE — run validate-all.sh --update and COMMIT it"; exit 1; }
for d in "${!got[@]}"; do
  want=$(awk -F'\t' -v k="$d" '$1==k{print $2}' "$TABLE")
  if [ -z "$want" ]; then echo "UNLISTED $d (count ${got[$d]}) — new dir? update the table"; fail=1
  elif [ "$want" != "${got[$d]}" ]; then echo "COUNT $d: got ${got[$d]} want $want"; fail=1; fi
done
while IFS=$'\t' read -r d want; do
  [ -z "$d" ] && continue
  [ -n "${got[$d]:-}" ] || { echo "MISSING $d — in table, not on disk"; fail=1; }
done < "$TABLE"

# raw Application CRs (apps/, bootstrap/) are not kustomize dirs — parse-check
for f in apps/*.yaml apps/single-node/*.yaml apps/production/*.yaml bootstrap/*.yaml; do
  [ -f "$f" ] || continue
  if command -v js-yaml >/dev/null 2>&1; then js-yaml "$f" >/dev/null 2>&1 || { echo "PARSE $f"; fail=1; }
  elif command -v npx >/dev/null 2>&1; then npx --yes js-yaml "$f" >/dev/null 2>&1 || { echo "PARSE $f"; fail=1; }
  fi
done

[ "$fail" = 0 ] && echo "validate-all: ${#dirs[@]} dirs, table + shape + hooks GREEN"
exit "$fail"
