#!/usr/bin/env bash
# validate-all.sh — the truth table for vortex manifests.
#
# Builds EVERY kustomize dir with kustomize (helm enabled — the ESO wrapper
# needs it), then asserts four classes of facts the estate's history paid for:
#   1. kind counts (the empty-base bug built successfully and rendered NOTHING;
#      exit-0 is not evidence — a table of expected counts is);
#   2. config shape, STRUCTURAL rules over the RENDERED output — never keyed on
#      dir or service names (the old case-statement folklore named every app
#      and silently skipped every app it didn't name):
#        a. any rendered Deployment doc must carry ZERO inline config literals
#           (value: http://…, *.svc.cluster.local…, x-forwarded values — the
#           doctrine says everything lives in Bao, mounted via envFrom);
#        b. if the dir renders any ExternalSecret, envFrom must appear among
#           its resources (the Secret ESO materializes must actually be
#           consumed — a Deployment reading it env-by-env is the bug this
#           catches);
#   3. the PreSync migrate hook: generic and name-free — if the DIR contains a
#      file matching *migrate*, its rendered output must carry
#      'argocd.argoproj.io/hook: PreSync' (schema-gates-deploy, owner ruling
#      2026-11-11, de-folklorized 2026-11-13);
#   4. EPOCH TRIO CONSISTENCY (config-gate pair rule, grown to a TRIO by the
#      env-model ruling): the epoch is THREE values per dir —
#        P  omicron/config.epoch on the pod templates   (Deployment docs)
#        D  the gate Job's --declared arg
#        S  omicron/config.epoch on the ExternalSecret's metadata
#      Where the rendered output mentions ANY of them, ALL THREE must be
#      present and form the SAME value set — a half/2-of-3 flip is a
#      half-bump: the PreSync gate vetoes the sync forever, or worse,
#      certifies a config the pods (or the secret refresh) don't declare.
#
# Extraction for class 4 (and the line-splitting for class 2) is plain
# sed/awk/grep over the RENDERED YAML — deliberately NO node/js-yaml
# dependency: runners and laptops both have coreutils+awk; the only optional
# node use in this script stays the `npx --yes js-yaml` FALLBACK for raw-CR
# parse checks (skipped when neither js-yaml nor node are present).
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

# Dir discovery must survive folder reorgs: enumerate the known roots (bases,
# the env-model environments/<env>/<app> tree, the legacy overlays/<env>/<app>
# tree, and the apps/ tree in case bases ever move under the hub split) — a
# candidate only counts when it holds a kustomization.yaml. The overlays/ glob
# is TRANSITION (drop when the vortex env-model PR deletes the tree); both
# globs are env-agnostic — no environment name appears here, and a pattern for
# a tree that doesn't (yet) exist simply expands to nothing. Deliberately NOT
# a repo-wide find: platform/ (remote-pinned vendor manifests) and nested
# sub-kustomizations are not in the validated set by contract, and the table
# keys pin the exact dir names anyway (UNLISTED/MISSING catch drift).
dirs=()
for d in applications/*/ environments/*/*/ overlays/*/*/ apps/*/; do
  [ -f "$d/kustomization.yaml" ] && dirs+=("$d")
done
# helm-free fast path when the ESO wrapper is not in scope? no — silence IS the
# empty-base bug's voice; if helm is missing, dirs needing it FAIL, loudly.

# ---- class 2a: inline-config detector over Deployment docs (stdin: render) --
# awk doc-splits on ^---$ and flags value: lines carrying URL/forwarding
# literals inside kind: Deployment docs. Line-anchored regexes, so a ConfigMap
# value quoting an http:// URL elsewhere in the stream cannot false-positive.
check_deployment_literals() {
  awk -v d="$1" '
    function flushdoc(   n, L, i) {
      if (isdep) {
        n = split(doc, L, "\n")
        for (i = 1; i <= n; i++) {
          if (L[i] ~ /^[[:space:]-]*value:[[:space:]]*"?[^"[:space:]]*http:\/\// ||
              L[i] ~ /^[[:space:]-]*value:[[:space:]].*svc\.cluster\.local/ ||
              L[i] ~ /^[[:space:]-]*value:[[:space:]].*x-forwarded/) {
            print "FAIL shape " d " — inline config literal in a Deployment: " L[i]
            bad = 1
          }
        }
      }
      doc = ""; isdep = 0
    }
    BEGIN { bad = 0; doc = ""; isdep = 0 }
    /^---[[:space:]]*$/ { flushdoc(); next }
    { doc = doc $0 "\n"; if ($0 ~ /^kind:[[:space:]]*Deployment[[:space:]]*$/) isdep = 1 }
    END { flushdoc(); exit bad }
  '
}

# ---- class 4: epoch TRIO extraction (stdin: render) -------------------------
# Prints "KIND<TAB>value" lines, KIND ∈ P|S|D:
#   P — omicron/config.epoch inside a NON-ExternalSecret doc (pod-template
#       annotations live under kind: Deployment docs)
#   S — omicron/config.epoch inside a kind: ExternalSecret doc (the ES
#       metadata annotation — the trio's third side)
#   D — the gate's --declared arg, in BOTH rendered shapes: same-line flow
#       (`--declared", "N"` / `--declared[= ]N`) and the block-sequence form
#       kustomize renders (`- --declared` + `- "N"` next line).
# Classification is by DOCUMENT KIND over the render, never by dir or file
# name — the same shape rule as class 2.
extract_epoch_trio() {
  awk '
    BEGIN { kind = ""; pending = 0; consumed = 0 }
    /^---[[:space:]]*$/ { kind = ""; next }
    {
      consumed = 0
      if ($0 ~ /^kind:[[:space:]]*/) {
        kind = $0; sub(/^kind:[[:space:]]*/, "", kind); gsub(/[[:space:]]/, "", kind)
      }
      if ($0 ~ /omicron\/config\.epoch[[:space:]]*:/) {
        v = $0; sub(/.*omicron\/config\.epoch[[:space:]]*:[[:space:]]*"?/, "", v)
        sub(/[^0-9].*/, "", v)
        if (v != "") print (kind == "ExternalSecret" ? "S\t" : "P\t") v
      }
      if (pending && $0 ~ /^[[:space:]]*-[[:space:]]*"?[0-9]+"?[[:space:]]*$/) {
        v = $0; gsub(/[^0-9]/, "", v); print "D\t" v; pending = 0; consumed = 1
      }
      if ($0 ~ /--declared/) {
        consumed = 1
        if (match($0, /--declared["=:,[:space:]]*"?[0-9]+/)) {
          v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); print "D\t" v
        } else { pending = 1 }
      }
      if (!consumed) pending = 0
    }
  '
}

declare -A got
fail=0
# render values for FAIL messages: one-line bracketed lists
fmt() { printf '[%s]' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ $//')"; }
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

  # ---- class 2: config shape, structural over the render ----
  check_deployment_literals "$d" <<<"$out" || fail=1
  # ES + Deployment in one dir ⇒ some resource must consume config via envFrom.
  # (ES-only dirs like the certificates feeds land secrets for secretRef
  # consumers in OTHER dirs — no Deployment here, no pairing to assert.)
  if printf '%s\n' "$out" | grep -q '^kind: ExternalSecret$' &&
     printf '%s\n' "$out" | grep -q '^kind: Deployment$'; then
    printf '%s\n' "$out" | grep -q 'envFrom:' ||
      { echo "FAIL shape $d — renders an ExternalSecret + Deployment but no envFrom consumes it"; fail=1; }
  fi

  # ---- class 3: migrate hook, name-free ----
  if find "$d" -maxdepth 2 -iname '*migrate*' -print 2>/dev/null | grep -q .; then
    printf '%s\n' "$out" | grep -q 'argocd.argoproj.io/hook: PreSync' ||
      { echo "FAIL hook $d — dir ships a *migrate* file but the PreSync hook is gone"; fail=1; }
  fi

  # ---- class 4: epoch TRIO consistency ----
  # ANY mention of the epoch machinery in a render arms the rule; the three
  # sides must then ALL be present (absence of a side is a 2-of-3 flip — the
  # silence-is-the-bug class) and byte-equal as value SETS.
  if printf '%s\n' "$out" | grep -q 'omicron/config.epoch\|--declared'; then
    trio=$(extract_epoch_trio <<<"$out")
    pod=$(printf '%s\n' "$trio" | sed -n 's/^P\t//p' | sort -u)
    es=$(printf '%s\n' "$trio" | sed -n 's/^S\t//p' | sort -u)
    decl=$(printf '%s\n' "$trio" | sed -n 's/^D\t//p' | sort -u)
    if [ -z "$pod" ] || [ -z "$es" ] || [ -z "$decl" ]; then
      echo "FAIL epoch-trio $d — INCOMPLETE TRIO: pod-annotation $(fmt "$pod") --declared $(fmt "$decl") es-annotation $(fmt "$es") — when the epoch exists, ALL THREE sides must exist; the bump edits all three lines in one commit"
      fail=1
    elif [ "$pod" != "$decl" ] || [ "$es" != "$decl" ]; then
      echo "FAIL epoch-trio $d — HALF-BUMP: pod-annotation $(fmt "$pod") --declared $(fmt "$decl") es-annotation $(fmt "$es") must be byte-equal; the bump edits all three lines in one commit"
      fail=1
    fi
  fi
  # ---- class 4b: placeholder survival & gate orphans (the vacuous-pass hole,
  # found by the epoch round's own author): an overlay that includes
  # components/config-gate but forgets the full-args replace ships
  # OVERLAY-MUST-REPLACE (prod would die at sync exit-2 — too late); an
  # overlay that ships the Job WITHOUT the epoch annotation passes class 4
  # vacuously — silence is exactly the bug class this battery exists to catch.
  if printf '%s\n' "$out" | grep -q 'OVERLAY-MUST-REPLACE'; then
    echo "FAIL placeholder $d — OVERLAY-MUST-REPLACE survived into the render; the overlay must replace the gate args array wholly"; fail=1
  fi
  if printf '%s\n' "$out" | grep -q 'name: config-gate' &&
     ! printf '%s\n' "$out" | grep -q 'omicron/config.epoch'; then
    echo "FAIL gate-orphan $d — renders a config-gate Job with no omicron/config.epoch annotation in sight"; fail=1
  fi
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

# raw Application CRs are not kustomize dirs — parse-check. Globs cover the
# env-model hub trio (apps/foundation + apps/staging + apps/production), the
# pre-split flat apps/ and apps/applications/, and the legacy single-node
# tree; patterns for dirs that don't (yet) exist expand to literals the
# [ -f ] guard skips — every layout validates on the same tool pin.
for f in apps/*.yaml apps/foundation/*.yaml apps/applications/*.yaml \
         apps/staging/*.yaml apps/production/*.yaml apps/single-node/*.yaml \
         bootstrap/*.yaml; do
  [ -f "$f" ] || continue
  if command -v js-yaml >/dev/null 2>&1; then js-yaml "$f" >/dev/null 2>&1 || { echo "PARSE $f"; fail=1; }
  elif command -v npx >/dev/null 2>&1; then npx --yes js-yaml "$f" >/dev/null 2>&1 || { echo "PARSE $f"; fail=1; }
  fi
done

[ "$fail" = 0 ] && echo "validate-all: ${#dirs[@]} dirs, table + shape + hooks + epoch-trio GREEN"
exit "$fail"
