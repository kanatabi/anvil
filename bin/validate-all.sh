#!/usr/bin/env bash
# validate-all.sh — the truth battery for vortex manifests.
#
# Builds EVERY kustomize dir with kustomize (helm enabled — the ESO wrapper
# needs it), then asserts classes of fact the estate's history paid for:
#   1. RENDERED-LOSS BASELINE (stateless — the expectation is DERIVED at run
#      time, never stored): render every dir at HEAD and at the MERGE-BASE
#      with the base ref, and assert every doc present at the base
#      (apiVersion/kind/namespace/name) is still present at HEAD. Why: the
#      empty-base bug built successfully and rendered NOTHING (exit-0 is not
#      evidence), and a silently dropped doc in a pruned sync is a LIVE
#      DELETION — every Application CR carries prune:true. Additions are INFO
#      (review-visible, never blocking — growth is a review question, loss is
#      an incident). Dirs with a vendored charts/ subtree are REPORT-ONLY for
#      losses: doc churn is legitimate when a pinned chart version moves.
#      When no baseline resolves (no base ref; shallow clone, no network)
#      the fallback assertion is: a render must not be EMPTY — silence is
#      the empty-base bug's voice. This replaces the stored kind-count table
#      (bin/expected-kinds.txt, retired 2026-11-14): a stored snapshot made
#      anvil's SHA a four-repo coordination point and aged into phantom
#      MISSING reds; the merge-base baseline is always current, and a
#      name-level diff even catches same-count substitutions a count table
#      cannot see.
#   2. config shape, STRUCTURAL rules over the RENDERED output — never keyed
#      on dir or service names (the old case-statement folklore named every
#      app and silently skipped every app it didn't name):
#        a. any rendered Deployment doc must carry ZERO inline config literals
#           (value: http://…, *.svc.cluster.local…, x-forwarded values — the
#           doctrine says everything lives in Bao, mounted via envFrom);
#        b. if the dir renders any ExternalSecret, envFrom must appear among
#           its resources (the Secret ESO materializes must actually be
#           consumed — a Deployment reading it env-by-env is the bug this
#           catches);
#   3. the wave contract: ES (wave 0) -> migrate (wave 1) -> Deployments
#      (wave 2), asserted from the RENDERED sync-waves — generic and
#      name-free (if the DIR contains a file matching *migrate*, the render
#      must ride the wave order; schema gates deploy, nothing boots dark);
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
#   usage: validate-all.sh [vortex-path] [--base <ref>]
#          --base <ref>  derive the baseline from THIS ref (default:
#                        origin/main, then main; neither resolvable ->
#                        baseline-less mode). The MERGE-BASE with HEAD is
#                        used, never the ref tip — main may have moved.
set -uo pipefail

VORTEX="."
BASE_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    *) VORTEX="$1"; shift ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl required (provides kustomize)"; exit 2; }
HELM_OK=$(command -v helm >/dev/null 2>&1 && echo 1 || echo 0)

cd "$VORTEX"

# ---- baseline resolution -----------------------------------------------------
# A shallow checkout (actions/checkout depth 1) cannot compute a merge-base;
# self-heal by unshallowing when we can, and fall back to baseline-less mode
# when we can't — loudly noted, with the non-empty-render floor below.
if [ -f .git/shallow ]; then
  git fetch --unshallow -q origin 2>/dev/null || true
fi
[ -n "$BASE_REF" ] || BASE_REF=origin/main
if ! git rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1; then
  [ -n "$(git remote 2>/dev/null)" ] && git fetch -q origin 2>/dev/null || true
fi
BASE_COMMIT=""
if git rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1; then
  BASE_COMMIT=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || true)
fi
MODE="baseline-less"
if [ -n "$BASE_COMMIT" ]; then
  MODE="baseline($(git log -1 --format=%h "$BASE_COMMIT" 2>/dev/null || echo "$BASE_COMMIT"))"
fi

WT=""
cleanup() { [ -n "$WT" ] && git worktree remove --force "$WT" 2>/dev/null; }
trap cleanup EXIT
if [ -n "$BASE_COMMIT" ]; then
  WT=$(mktemp -d)
  git worktree add --detach -q "$WT" "$BASE_COMMIT" || { echo "cannot check out baseline $BASE_COMMIT"; exit 2; }
fi

# ---- dir discovery must survive folder reorgs --------------------------------
# enumerate the known roots (bases, the env-model environments/<env>/<app>
# tree, the legacy overlays/<env>/<app> tree, and the apps/ tree) in BOTH
# trees — a dir present at the base but gone at HEAD is exactly the
# deleted-while-pruned deletion class, so the union is the iteration set.
# The overlays/ glob is TRANSITION (drop when the vortex env-model PR deletes
# the tree); both globs are env-agnostic — no environment name appears here.
# Deliberately NOT a repo-wide find: platform/ (remote-pinned vendor
# manifests) and nested sub-kustomizations are not in the validated set by
# contract.
list_dirs() { # $1 = tree root
  (cd "$1" 2>/dev/null && {
    for d in bases/*/ environments/*/*/ overlays/*/*/ apps/*/; do
      [ -f "$d/kustomization.yaml" ] && printf '%s\n' "$d"
    done
  }) | sort -u
}

# ---- doc identity extraction (stdin: render) ---------------------------------
# One key per rendered doc: apiVersion/kind/namespace/name — the identity a
# pruned sync matches on. Name-level (not count-level): a remove-one-add-one
# change keeps counts equal and would slip past a count table.
doc_keys() {
  awk '
    function flushdoc() {
      if (kind != "")
        print av "/" kind "/" (ns == "" ? "-" : ns) "/" (nm == "" ? "-" : nm)
      av = ""; kind = ""; ns = ""; nm = ""; inmeta = 0
    }
    /^---[[:space:]]*$/ { flushdoc(); next }
    { if ($0 ~ /^apiVersion:/)      { av = $2; gsub(/"/, "", av) }
      else if ($0 ~ /^kind:/)       { kind = $2; gsub(/"/, "", kind) }
      else if ($0 ~ /^metadata:/)   inmeta = 1
      else if (inmeta && nm == "" && $0 ~ /^[[:space:]]+name:/)      { nm = $2; gsub(/"/, "", nm) }
      else if (inmeta && ns == "" && $0 ~ /^[[:space:]]+namespace:/) { ns = $2; gsub(/"/, "", ns) }
      else if (inmeta && /^[^[:space:]#-]/) inmeta = 0
    }
    END { flushdoc() }
  ' | sort
}

render_dir() { # $1 = tree root, $2 = dir -> stdout render ("" on missing), rc 0 ok / 3 missing
  local root="$1" d="$2"
  [ -d "$root/$d" ] || return 3
  local need_helm=0
  grep -q "helmCharts\|external-secrets" "$root/$d"/*.yaml 2>/dev/null && need_helm=1
  local a=(kustomize "$d")
  [ "$need_helm" = 1 ] && a+=(--enable-helm)
  (cd "$root" && kubectl "${a[@]}" 2>&1)
}

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

fail=0
# render values for FAIL messages: one-line bracketed lists
fmt() { printf '[%s]' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ $//')"; }

HEAD_ROOT="$(pwd)"
UNION=$(printf '%s\n%s\n' "$(list_dirs "$HEAD_ROOT")" "$(list_dirs "${WT:-$HEAD_ROOT}")" | sort -u | grep -v '^$')
ndirs=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  ndirs=$((ndirs + 1))
  head_out=$(render_dir "$HEAD_ROOT" "$d"); head_rc=$?
  if [ "$head_rc" -ne 0 ] && [ "$head_rc" -ne 3 ]; then
    echo "FAIL build $d"; printf '%s\n' "$head_out" | head -3; fail=1; continue
  fi
  if [ "$head_rc" -eq 3 ]; then head_out=""; fi   # dir gone at HEAD (deleted at base? see below)

  # ---- class 1: rendered-loss baseline ----
  base_out=""
  if [ -n "$WT" ]; then
    base_out=$(render_dir "$WT" "$d"); base_rc=$?
    if [ "$base_rc" -ne 0 ] && [ "$base_rc" -ne 3 ]; then
      echo "FAIL baseline $d — base render failed; the loss comparison would be a lie"; printf '%s\n' "$base_out" | head -3; fail=1; continue
    fi
    if [ "$base_rc" -eq 3 ]; then base_out=""; fi
    base_keys=$(doc_keys <<<"$base_out")
    head_keys=$(doc_keys <<<"$head_out")
    lost=$(comm -23 <(printf '%s\n' "$base_keys" | sed '/^$/d') <(printf '%s\n' "$head_keys" | sed '/^$/d') || true)
    added=$(comm -13 <(printf '%s\n' "$base_keys" | sed '/^$/d') <(printf '%s\n' "$head_keys" | sed '/^$/d') || true)
    nb=$(printf '%s\n' "$base_keys" | grep -c . || true)
    nh=$(printf '%s\n' "$head_keys" | grep -c . || true)
    echo "INFO count $d — rendered ${nh} docs (baseline ${nb})"
    if [ -n "$lost" ]; then
      if [ -d "$d/charts" ]; then
        # vendored chart: doc churn rides the chart version bump — report, never block
        echo "INFO chart-loss $d — vendored chart dir, doc churn report-only: $(fmt "$lost")"
      elif [ "$head_rc" -eq 3 ]; then
        echo "FAIL lost-dir $d — dir present at baseline, GONE at HEAD; with prune:true that is a live deletion of: $(fmt "$lost")"
        fail=1
      else
        echo "FAIL lost $d — doc(s) removed by this change: $(fmt "$lost")"
        fail=1
      fi
    fi
    [ -n "$added" ] && echo "INFO added $d — $(fmt "$added")"
  else
    # baseline-less floor: silence is the empty-base bug's voice
    if [ "$head_rc" -eq 3 ] || [ -z "$(doc_keys <<<"$head_out")" ]; then
      echo "FAIL count $d — render is EMPTY (baseline-less mode: no base ref resolvable; fix --base or fetch and re-run)"; fail=1
    else
      echo "INFO count $d — rendered $(doc_keys <<<"$head_out" | grep -c .) docs (no baseline: loss checks skipped)"
    fi
  fi

  # ---- class 2: config shape, structural over the render ----
  check_deployment_literals "$d" <<<"$head_out" || fail=1
  # ES + Deployment in one dir ⇒ some resource must consume config via envFrom.
  # (ES-only dirs like the certificates feeds land secrets for secretRef
  # consumers in OTHER dirs — no Deployment here, no pairing to assert.)
  if printf '%s\n' "$head_out" | grep -q '^kind: ExternalSecret$' &&
     printf '%s\n' "$head_out" | grep -q '^kind: Deployment$'; then
    printf '%s\n' "$head_out" | grep -q 'envFrom:' ||
      { echo "FAIL shape $d — renders an ExternalSecret + Deployment but no envFrom consumes it"; fail=1; }
  fi

  # ---- class 3: migrate + secrets-before-workloads (the wave contract) ----
  # Old shape (PreSync hook) walked into a fresh-cluster deadlock (2026-11-14):
  # hooks run before the sync applies the app's own ES, so the migrate could
  # never see its Secret. New shape: ES (wave 0) -> migrate (wave 1) ->
  # Deployments (wave 2) — Argo holds wave N until wave N-1 is Healthy, so
  # schema still gates deploy and no workload ever boots dark.
  if printf '%s\n' "$head_out" | grep -q '^kind: ExternalSecret'; then
    dep=$(printf '%s\n' "$head_out" | grep -c '^kind: Deployment$')
    waved=$(printf '%s\n' "$head_out" | grep -c 'argocd.argoproj.io/sync-wave: "[1-9]')
    [ "$dep" -le "$waved" ] ||
      { echo "FAIL hook $d — render ships an ES but a Deployment carries no sync-wave (dark-boot risk: envFrom binds once, at container start)"; fail=1; }
  fi
  if find "$d" -maxdepth 2 -iname '*migrate*' -print 2>/dev/null | grep -q .; then
    printf '%s\n' "$head_out" | grep -q 'argocd.argoproj.io/sync-wave: "1"' ||
      { echo "FAIL hook $d — dir ships a *migrate* file but it does not ride sync-wave 1 (after the ES, before the workloads)"; fail=1; }
    dep=$(printf '%s\n' "$head_out" | grep -c '^kind: Deployment$')
    w2=$(printf '%s\n' "$head_out" | grep -c 'argocd.argoproj.io/sync-wave: "2"')
    [ "$dep" -eq "$w2" ] ||
      { echo "FAIL hook $d — migrate ships but not every Deployment rides sync-wave 2 (schema must gate deploy)"; fail=1; }
  fi

  # ---- class 4: epoch TRIO consistency ----
  # ANY mention of the epoch machinery in a render arms the rule; the three
  # sides must then ALL be present (absence of a side is a 2-of-3 flip — the
  # silence-is-the-bug class) and byte-equal as value SETS.
  if printf '%s\n' "$head_out" | grep -q 'omicron/config.epoch\|--declared'; then
    trio=$(extract_epoch_trio <<<"$head_out")
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
  if printf '%s\n' "$head_out" | grep -q 'OVERLAY-MUST-REPLACE'; then
    echo "FAIL placeholder $d — OVERLAY-MUST-REPLACE survived into the render; the overlay must replace the gate args array wholly"; fail=1
  fi
  if printf '%s\n' "$head_out" | grep -q 'name: config-gate' &&
     ! printf '%s\n' "$head_out" | grep -q 'omicron/config.epoch'; then
    echo "FAIL gate-orphan $d — renders a config-gate Job with no omicron/config.epoch annotation in sight"; fail=1
  fi
done <<<"$UNION"

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

[ "$fail" = 0 ] && echo "validate-all: ${ndirs} dirs, ${MODE} + shape + hooks + epoch-trio GREEN"
exit "$fail"
