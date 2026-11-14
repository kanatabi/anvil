#!/usr/bin/env bash
# set-image-pr.sh — the ONLY mechanism that moves a deployed version.
# Opens (or reuses) a bump PR in vortex that does exactly one thing: pin
# `kustomize edit set image <app>=<image>:<tag>` in
# environments/<env>/<app>/ — plus, when asked, the epoch TRIO and the
# same-env lockstep (below).
#
#   usage: set-image-pr.sh --app lumen --image ghcr.io/kanatabi/lumen \
#             --tag v1.5.0 [--env production] [--config-epoch N] \
#             [--dry-run] [--plan] [--skip-validate] \
#             [--no-await-merge] [--await-timeout SECONDS]
#
#   --env E    target environment ∈ foundation|staging|production (default
#              production). Selects the dir the pin + trio live in and the
#              branch grammar; the script never enumerates envs beyond this
#              validation and the ${ENV} interpolation.
#   --dry-run  offline rehearsal on a LOCAL vortex copy (VORTX=<path>), no token
#   --plan     the evidence half of the deploy decision: apply the bump against
#              the REAL remote main state, validate the render, print
#              current-pin → proposed-pin and the exact diff — push NOTHING.
#              A human reads this before approving the open step. Under
#              GITHUB_STEP_SUMMARY the evidence ALSO lands as markdown
#              (pin table + fenced diff + verdict) — the log keeps the raw
#              detail, the summary is the review surface.
#   normal     the open half: same rehearsal FIRST, then push + PR, then
#              AWAIT THE MERGE: the merge rides vortex's own auto-merge
#              workflow asynchronously, so a green "PR opened" was a lie
#              when vortex CI flaked or a guard failed. The job's green now
#              means THE PIN IS ON vortex main. Poll is bounded by
#              --await-timeout (default 1800s); timeout or a closed-without-
#              merging PR is RED with the pin's true state stated.
#              --no-await-merge restores fire-and-forget.
#              Validation failure refuses to push (--skip-validate to override,
#              emergency only — a bump PR that cannot render is a lie).
#   --config-epoch N
#              flip the EPOCH TRIO in the same commit: the pod-template
#              `omicron/config.epoch: "…"` annotation, the gate
#              `--declared` arg, AND the ExternalSecret metadata
#              `omicron/config.epoch: "…"` annotation under
#              environments/<env>/<app>/ all become N (validate-all's
#              class-4 rule asserts the trio stays EQUAL — a bump that
#              flips less than all three is refused before the PR opens).
#              Plus the LOCKSTEP that rides EVERY bump: any `name: <app>`
#              images stanza in ANY environments/<env>/* dir (the config-gate
#              pins living in the SAME env's other overlays — bumping lumen
#              is the canonical case: every gate decodes epochs with it)
#              moves to the same TAG — a gate decoding epochs with a stale
#              image is how drift starts. All edits are generic line rules
#              parameterized on --app/--env/--tag/--config-epoch: this shared
#              script holds ZERO estate app names and NO env list.
#
#   env: VORTEX_BOT_PAT  fine-grained PAT scoped to kanatabi/vortex (clone is
#        PAT-authenticated because the push and the PR need the credentials
#        anyway; vortex went public 2026-11-13 so an anonymous https clone
#        would work too — the PAT-clone behaves identically for any visibility)
#        VORTX           local clone path for --dry-run (and offline --plan tests)
set -uo pipefail

APP="" IMAGE="" TAG="" DRY="" PLAN="" SKIP_VALIDATE="" EPOCH="" ENV="production" AWAIT=1 AWAIT_TIMEOUT=1800 URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app)   APP="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --tag)   TAG="$2"; shift 2 ;;
    --env)   ENV="$2"; shift 2 ;;
    --config-epoch) EPOCH="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --plan)  PLAN=1; shift ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    --no-await-merge) AWAIT=""; shift ;;
    --await-timeout) AWAIT_TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done
[ -n "$APP" ] && [ -n "$IMAGE" ] && [ -n "$TAG" ] || { echo "need --app --image --tag"; exit 2; }
[[ "$AWAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "--await-timeout must be a positive integer (seconds), got: $AWAIT_TIMEOUT"; exit 2; }
case "$ENV" in
  foundation|staging|production) ;;
  *) echo "--env must be foundation|staging|production, got: $ENV"; exit 2 ;;
esac
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { [ -z "$EPOCH" ] || { echo "--config-epoch must be a non-negative integer, got: $EPOCH"; exit 2; }; }
BRANCH="bump/${APP}-${ENV}-${TAG}"
TARGET="environments/${ENV}/${APP}"
ANVIL_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -n "$DRY" ] || { [ -n "$PLAN" ] && [ -n "${VORTX:-}" ]; }; then
  SRC="${VORTX:?dry-run/offline-plan needs VORTX=path to local vortex clone}"
  WORK=$(mktemp -d)/vortex
  cp -r "$SRC" "$WORK"; rm -rf "$WORK/.git/hooks"
else
  [ -n "${VORTEX_BOT_PAT:-}" ] || { echo "VORTEX_BOT_PAT required"; exit 2; }
  command -v gh >/dev/null || { echo "gh required on the runner"; exit 2; }
  WORK=$(mktemp -d)/vortex
  git clone -q "https://x-access-token:${VORTEX_BOT_PAT}@github.com/kanatabi/vortex.git" "$WORK"
  if [ -z "$PLAN" ]; then
    # dedupe: an open PR for this exact branch means "already proposed" — not
    # an error. REUSE it and fall through to the await loop: a re-run must not
    # report green on "PR opened" — the evidence is the merge.
    URL=$(GH_TOKEN="$VORTEX_BOT_PAT" gh pr list --repo kanatabi/vortex --head "$BRANCH" \
            --state open --json url --jq '.[0].url' 2>/dev/null || true)
    if [ -n "$URL" ]; then echo "bump PR already open for $BRANCH — reusing: $URL"; fi
  fi
fi

cd "$WORK"
git checkout -q -b "$BRANCH" "origin/main" 2>/dev/null || git checkout -q -b "$BRANCH" main
test -d "$TARGET" || { echo "no $TARGET in vortex — wrong app or env name?"; exit 1; }

# markdown summary helper — appends ONLY when running under Actions (the
# deploy-plan summary is the review surface a human reads before the approve
# click; the stdout log keeps the raw detail for the job-log tab).
sum() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY" || true; }

echo "==== pin pre-flight ===="
echo "current pin in vortex main ($TARGET):"
# the images: stanza in BOTH authoring shapes — canonical kustomize puts list
# items flush-left (`- name:`), hand-form indents them (`  - name:`) — so the
# range ends only at a top-level KEY line (col-0, not a dash/comment), which
# the old `/^[^ ]/` end-pattern got wrong for the canonical form.
STANZA=$(git show "HEAD:$TARGET/kustomization.yaml" | awk '
  !p && /^images:[[:space:]]*$/ { p = 1; print; next }
  p && (/^[[:space:]]+/ || /^-/) { print; next }
  p { exit }
')
printf '%s\n' "$STANZA" | sed 's/^/    /'
echo "proposed: ${APP} -> ${IMAGE}:${TAG} (env: ${ENV})"
[ -n "$EPOCH" ] && echo "epoch trio: $TARGET/ -> $EPOCH (pod annotation + --declared + ES annotation)"
echo "=========================="

# the summary: pin table (every stanza of the lockstep, the proposed one bold),
# epoch note, bump diff, verdicts — filled in as the plan proceeds.
PIN_TABLE=$(printf '%s\n' "$STANZA" | awk -v app="$APP" -v img="$IMAGE" -v tag="$TAG" '
  function row() {
    if (cn == "") return
    if (cn == app) printf "| %s | %s:%s | **%s:%s** |\n", cn, (cnew == "" ? "?" : cnew), (ctag == "" ? "?" : ctag), img, tag
    else printf "| %s | %s:%s | unchanged (same-env lockstep) |\n", cn, (cnew == "" ? "?" : cnew), (ctag == "" ? "?" : ctag)
    cn = ""
  }
  { v = $0
    if (v ~ /^[[:space:]]*-?[[:space:]]*name:/) { row(); sub(/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*/, "", v); cn = v }
    else if (v ~ /^[[:space:]]*newName:/) { sub(/^[[:space:]]*newName:[[:space:]]*/, "", v); cnew = v }
    else if (v ~ /^[[:space:]]*newTag:/)  { sub(/^[[:space:]]*newTag:[[:space:]]*/, "", v);  ctag = v }
  }
  END { row() }
')
sum "## deploy plan — ${APP} · ${ENV} · ${TAG}"
sum ""
sum "| image | pin in vortex main | proposed |"
sum "|---|---|---|"
sum "$PIN_TABLE"
sum ""
[ -n "$EPOCH" ] && { sum "Config epoch flip → \`$EPOCH\` (pod-template annotation + gate \`--declared\` + ES annotation, one commit)."; sum ""; }

cd "$TARGET"
command -v kustomize >/dev/null || { echo "kustomize binary required (runners ship it; locally: install v5.x)"; exit 1; }
kustomize edit set image "${APP}=${IMAGE}:${TAG}" || { echo "kustomize edit FAILED"; exit 1; }
# kustomize edit's round-trip can DUPLICATE a comment attached to a list item
# (walked 2026-11-14: the full-args-replacement note emitted twice, and the
# fence rightly refused the PR). Drop an exact-duplicate comment line that
# directly follows its twin:
for f in ./kustomization.yaml ./*/kustomization.yaml; do
  [ -f "$f" ] || continue
  awk 'BEGIN{prev=""} { if ($0 ~ /^[[:space:]]*#/ && $0 == prev) next; print; prev=$0 }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
cd "$WORK"

# ---- app-image LOCKSTEP (rides EVERY bump): every `name: ${APP}` images
# stanza in the bump env's overlay dirs moves to ${TAG} in this same commit.
# The config-gate pins live in OTHER apps' overlays of the SAME env — bumping
# lumen is the canonical case (every env's gate ships in the lumen image and
# a gate decoding epochs with a stale binary is how drift starts), so the
# pins travel as one. Scoping to ${ENV} keeps the PR inside what auto-merge's
# env path fence admits: a production bump never re-pins staging. Generic
# adjacency rule — no estate app names in this script, only ${APP}; no env
# list, only the ${ENV} from --env.
#   overlays/${ENV}/* is TRANSITION (the same lockstep walk on the legacy
#   tree) — drop with the tree when the vortex env-model PR lands.
for kf in environments/"${ENV}"/*/kustomization.yaml \
          overlays/"${ENV}"/*/kustomization.yaml; do
  [ -f "$kf" ] || continue
  awk -v app="$APP" -v tag="$TAG" '
    /^[[:space:]]*-[[:space:]]*name:/ {
      n = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", n)
      gsub(/[^A-Za-z0-9._-]/, "", n)          # strips indent/quotes/trailing ws
      hit = (n == app); print; next
    }
    hit && /^[[:space:]]*newTag:/ { sub(/newTag:.*/, "newTag: " tag); hit = 0; print; next }
    hit && /^[[:space:]]*(newName:|digest:)/ { print; next }   # stay inside the stanza
    { hit = 0; print }
  ' "$kf" > "$kf.anvil" && mv "$kf.anvil" "$kf"
done

# ---- EPOCH TRIO flip (--config-epoch): pod annotation AND --declared AND
# ExternalSecret annotation together, or not at all. All three pre-must
# exist — flipping part of a trio that isn't there is the half-bump this
# whole mechanism exists to prevent. ----
if [ -n "$EPOCH" ]; then
  EDIR="$TARGET"
  # The three sides are counted BY FILE KIND in the raw overlay, mirroring
  # validate-all's BY-DOCUMENT-KIND extraction over the render: a file that
  # declares `kind: ExternalSecret` carries the ES side; the pod side rides
  # the kustomization patches; --declared is the gate arg.
  es_files=$(grep -l 'kind:[[:space:]]*ExternalSecret' "$EDIR"/*.yaml 2>/dev/null || true)
  pod_ann=0 es_ann=0
  for f in "$EDIR"/*.yaml; do
    [ -f "$f" ] || continue
    n=$(grep 'omicron/config.epoch' "$f" 2>/dev/null | grep -c '[0-9]' || true)
    if [ -n "$es_files" ] && printf '%s\n' "$es_files" | grep -qxF -- "$f"; then
      es_ann=$((es_ann + n))
    else
      pod_ann=$((pod_ann + n))
    fi
  done
  dec=$(grep -h -- '--declared' "$EDIR"/*.yaml 2>/dev/null | grep -c '[0-9]' || true)
  if [ "${pod_ann:-0}" -eq 0 ] || [ "${es_ann:-0}" -eq 0 ] || [ "${dec:-0}" -eq 0 ]; then
    echo "--config-epoch $EPOCH requested, but $EDIR/ is not a complete TRIO: pod-annotations=$pod_ann es-annotations=$es_ann declared-lines=$dec — all three must exist before they can be flipped; refusing" >&2
    exit 1
  fi
  echo "---- epoch trio: $pod_ann pod + $dec declared + $es_ann ES line(s) -> $EPOCH ----"
  for f in "$EDIR"/*.yaml; do
    [ -f "$f" ] || continue
    # (a) annotation side — quoted value is the k8s norm; bare digits
    # tolerated. This one line rule serves BOTH annotation homes: the
    # pod-template patch (kustomization.yaml) and the ES metadata block
    # (externalsecret.yaml) carry the identical `omicron/config.epoch: "N"`
    # shape, so the trio's two annotation sides flip from one generic pattern.
    sed -E -i \
      -e 's|(omicron/config\.epoch"?[[:space:]]*:[[:space:]]*")[0-9]+(")|\1'"$EPOCH"'\2|g' \
      -e 's|(omicron/config\.epoch"?[[:space:]]*:[[:space:]]*)[0-9]+([[:space:]]*)$|\1'"$EPOCH"'\2|' \
      "$f"
    # (b) --declared side — same-line flow (`"--declared", "N"`, --declared=N)
    # and block-pair (`--declared` line + bare value line) forms
    awk -v ep="$EPOCH" '
      {
        line = $0
        if (pend) {
          pend = 0
          if (line ~ /^[[:space:]]*-[[:space:]]*"?[0-9]+"?[[:space:]]*$/) { sub(/[0-9]+/, ep, line); print line; next }
        }
        if (line ~ /--declared["=:,[:space:]]*"?[0-9]+/) {
          if (match(line, /--declared["=:,[:space:]]*"?[0-9]+/)) {
            seg = substr(line, RSTART, RLENGTH)
            sub(/[0-9]+$/, ep, seg)
            line = substr(line, 1, RSTART - 1) seg substr(line, RSTART + RLENGTH)
          }
          print line; next
        }
        if (line ~ /--declared/) pend = 1
        print line
      }
    ' "$f" > "$f.anvil" && mv "$f.anvil" "$f"
  done
fi

if git diff --quiet; then echo "no change ($APP already at $TAG${EPOCH:+ with epoch $EPOCH}) — nothing to propose"; exit 0; fi
SUBJ="deploy: bump ${APP} (${ENV}) → ${TAG}${EPOCH:+ + config epoch ${EPOCH}}"
MSG="$SUBJ

machine-generated by anvil/set-image-pr from ${IMAGE}@${TAG}
(app commit already human-reviewed;"
if [ -n "$EPOCH" ]; then
  MSG="$MSG
this PR flips the epoch TRIO — pod-template omicron/config.epoch + the gate's
--declared arg + the ExternalSecret's omicron/config.epoch annotation — in
$EDIR, locksteps the ${APP} image pins across environments/${ENV}/*, and
validate-all asserts trio equality after)"
else
  MSG="$MSG
this PR changes only images: lines)"
fi
git -c user.name=vortex-bot-ci -c user.email=vortex-bot-ci@users.noreply.github.com \
  commit -aqm "$MSG"

DIFF=$(git diff "HEAD^" HEAD)
echo "---- bump diff ----"; printf '%s\n' "$DIFF"; echo "-------------------"
sum ""
sum "### bump diff (authoring YAML — fence-checked lines only)"
sum '```diff'
sum "$DIFF"
sum '```'

# ---- validate-before-open: the render must survive the bump, always ----
if [ -z "$SKIP_VALIDATE" ]; then
  echo "---- validate render of the bump branch ----"
  if bash "$ANVIL_BIN/validate-all.sh" "$WORK"; then
    echo "---- validation GREEN ----"
    sum ""
    sum "### validation"
    sum "✅ render GREEN — loss baseline + shape + hooks + epoch-trio"
  else
    sum ""; sum "### validation"
    sum "❌ render RED — refusing to ${PLAN:+plan-and-}push a bump PR whose manifests do not build (a reviewable-looking PR that deploys a lie)"
    echo "set-image-pr: RENDER VALIDATION FAILED — refusing to ${PLAN:+plan-and-}push a bump PR whose manifests do not build. The PR would look reviewable and deploy a lie. (--skip-validate is for emergencies only.)" >&2
    exit 1
  fi
fi

if [ -n "$PLAN" ]; then
  echo "PLAN: evidence above is complete — branch $BRANCH was NOT pushed, no PR opened."
  sum ""
  sum "> **PLAN:** evidence above is complete — branch \`$BRANCH\` was **NOT** pushed, no PR opened."
  exit 0
fi
if [ -n "$DRY" ]; then echo "DRY-RUN: branch $BRANCH prepared in $WORK — nothing pushed"; exit 0; fi

if [ -z "$URL" ]; then
  git push -q "https://vortex-bot-ci:${VORTEX_BOT_PAT}@github.com/kanatabi/vortex.git" "$BRANCH"
  export GH_TOKEN="$VORTEX_BOT_PAT"
  gh label create deploy-bump --repo kanatabi/vortex --color 7CFC8A \
    --description "automated image bump — auto-merge eligible" >/dev/null 2>&1 || true
  PR_TITLE="deploy: bump ${APP} (${ENV}) → ${TAG}${EPOCH:+ + config epoch ${EPOCH}}"
  PR_BODY="Automated deploy bump for \`${IMAGE}:${TAG}\` in the **${ENV}** environment (source commit already human-reviewed in kanatabi/${APP})."
  PR_BODY+=$'\n'"Files touched (fence-checked: images: stanzas and the epoch trio only, under environments/${ENV}/):"
  PR_BODY+=$'\n'"$(git diff --name-only 'HEAD^' HEAD | sed 's|^|- \`|; s|$|`|')"
  if [ -n "$EPOCH" ]; then
    PR_BODY+=$'\n\n'"Config epoch TRIO (`omicron/config.epoch` pod annotation + gate `--declared` + ExternalSecret annotation) flipped to \`${EPOCH}\` in lockstep with the ${APP} image pins across environments/${ENV}/*."
  fi
  PR_BODY+=$'\n'"Rendered validation ran BEFORE this PR opened (anvil deploy-plan/deploy gates, incl. epoch-trio consistency)."
  PR_BODY+=$'\n'"Merges automatically iff DEPLOY_AUTOMERGE=on and validate-manifests is green."
  URL=$(gh pr create --repo kanatabi/vortex --base main --head "$BRANCH" \
    --title "$PR_TITLE" --label deploy-bump --body "$PR_BODY")
fi
echo "bump PR: $URL"

# ---- AWAIT THE MERGE: the deploy job's green must mean the pin LANDED ----
# The merge rides vortex's own auto-merge workflow, asynchronously from THIS
# run — a green "PR opened" was a lie whenever vortex CI flaked or a guard
# failed. Bounded poll; timeout or closed-unmerged is RED stating the pin's
# true state. (Owner doctrine 2026-11-14: pipelines never queue behind each
# other — but a chain that claims green owes the merge.)
if [ -n "$AWAIT" ]; then
  sum ""
  sum "### bump PR"
  sum "open: ${URL} — awaiting merge; green here means the pin LANDED on vortex main."
  DEADLINE=$((SECONDS + AWAIT_TIMEOUT))
  while :; do
    ST=$(gh pr view "$URL" --repo kanatabi/vortex --json state --jq .state 2>/dev/null || echo UNKNOWN)
    case "$ST" in
      MERGED)
        echo "bump PR MERGED — ${IMAGE}:${TAG} is pinned on vortex main"
        sum ""
        sum "✅ **merged** — \`${IMAGE}:${TAG}\` pin is on vortex main"
        exit 0 ;;
      CLOSED)
        echo "bump PR CLOSED without merging — pin NOT on main (superseded by a newer chain, or closed by hand)" >&2
        sum ""
        sum "❌ **closed unmerged** — the pin is NOT on vortex main"
        exit 1 ;;
    esac
    [ $SECONDS -lt $DEADLINE ] || {
      echo "bump PR did not merge within ${AWAIT_TIMEOUT}s — vortex CI green? DEPLOY_AUTOMERGE=on? The pin is NOT on main." >&2
      sum ""
      sum "❌ **not merged after ${AWAIT_TIMEOUT}s** — vortex CI green? \`DEPLOY_AUTOMERGE=on\`? The pin is NOT on vortex main."
      exit 1 ; }
    sleep 30
  done
fi
