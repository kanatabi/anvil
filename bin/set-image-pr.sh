#!/usr/bin/env bash
# set-image-pr.sh — the ONLY mechanism that moves a deployed version.
# Opens (or reuses) a bump PR in vortex that does exactly one thing: pin
# `kustomize edit set image <app>=<image>:<tag>` in applications/<app>/ —
# plus, when asked, the epoch PAIR and the gate-image lockstep (below).
#
#   usage: set-image-pr.sh --app lumen --image ghcr.io/kanatabi/lumen \
#             --tag v1.5.0 [--config-epoch N] [--dry-run] [--plan] [--skip-validate]
#
#   --dry-run  offline rehearsal on a LOCAL vortex copy (VORTX=<path>), no token
#   --plan     the evidence half of the deploy decision: apply the bump against
#              the REAL remote main state, validate the render, print
#              current-pin → proposed-pin and the exact diff — push NOTHING.
#              A human reads this before approving the open step.
#   normal     the open half: same rehearsal FIRST, then push + PR.
#              Validation failure refuses to push (--skip-validate to override,
#              emergency only — a bump PR that cannot render is a lie).
#   --config-epoch N
#              flip the EPOCH PAIR in the same commit: every
#              `omicron/config.epoch: "…"` annotation and every gate
#              `--declared` arg under overlays/production/<app>/ becomes N
#              (validate-all's class-4 rule asserts the pair stays EQUAL —
#              a bump that flips only one side is refused before the PR
#              opens). Plus the LOCKSTEP that rides EVERY bump regardless:
#              any `name: <app>` images stanza in ANY overlays/production/*
#              dir (the config-gate pins living in other apps' overlays)
#              moves to the same TAG — a gate decoding epochs with a stale
#              image is how drift starts. All edits are generic line rules
#              parameterized on --app/--tag/--config-epoch: this shared
#              script holds ZERO estate app names.
#
#   env: VORTEX_BOT_PAT  fine-grained PAT scoped to kanatabi/vortex (clone is
#        PAT-authenticated because the push and the PR need the credentials
#        anyway; vortex went public 2026-11-13 so an anonymous https clone
#        would work too — the PAT-clone behaves identically for any visibility)
#        VORTX           local clone path for --dry-run (and offline --plan tests)
set -uo pipefail

APP="" IMAGE="" TAG="" DRY="" PLAN="" SKIP_VALIDATE="" EPOCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app)   APP="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --tag)   TAG="$2"; shift 2 ;;
    --config-epoch) EPOCH="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --plan)  PLAN=1; shift ;;
    --skip-validate) SKIP_VALIDATE=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done
[ -n "$APP" ] && [ -n "$IMAGE" ] && [ -n "$TAG" ] || { echo "need --app --image --tag"; exit 2; }
[[ "$EPOCH" =~ ^[0-9]+$ ]] || { [ -z "$EPOCH" ] || { echo "--config-epoch must be a non-negative integer, got: $EPOCH"; exit 2; }; }
BRANCH="bump/${APP}-${TAG}"
TARGET="applications/${APP}"
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
    # dedupe: an open PR for this exact branch means "already proposed" — not an error
    if GH_TOKEN="$VORTEX_BOT_PAT" gh pr list --repo kanatabi/vortex --head "$BRANCH" --state open --json number \
         | grep -q '"number"'; then
      echo "bump PR already open for $BRANCH — skipping"; exit 0
    fi
  fi
fi

cd "$WORK"
git checkout -q -b "$BRANCH" "origin/main" 2>/dev/null || git checkout -q -b "$BRANCH" main
test -d "$TARGET" || { echo "no $TARGET in vortex — wrong app name?"; exit 1; }

echo "==== pin pre-flight ===="
echo "current pin in vortex main:"
git show "HEAD:$TARGET/kustomization.yaml" | sed -n '/^images:/,/^[^ ]/p' | sed 's/^/    /'
echo "proposed: ${APP} -> ${IMAGE}:${TAG}"
[ -n "$EPOCH" ] && echo "epoch pair: overlays/production/${APP}/ -> $EPOCH (annotation + --declared)"
echo "=========================="

cd "$TARGET"
command -v kustomize >/dev/null || { echo "kustomize binary required (runners ship it; locally: install v5.x)"; exit 1; }
kustomize edit set image "${APP}=${IMAGE}:${TAG}" || { echo "kustomize edit FAILED"; exit 1; }
cd "$WORK"

# ---- gate-image LOCKSTEP (rides EVERY bump): any `name: ${APP}` images
# stanza in ANY overlays/production/* dir moves to ${TAG} in this same
# commit. The config-gate pins live in OTHER apps' overlays; a gate running
# a stale binary decays epochs silently, so three pins travel as one.
# Generic adjacency rule — no estate app names in this script, only ${APP}.
for kf in overlays/production/*/kustomization.yaml; do
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

# ---- EPOCH PAIR flip (--config-epoch): annotation AND --declared together,
# or not at all. Both sides pre-must exist — flipping one line of a pair that
# isn't there is the half-bump this whole mechanism exists to prevent. ----
if [ -n "$EPOCH" ]; then
  EDIR="overlays/production/${APP}"
  ann=$(grep -h 'omicron/config.epoch' "$EDIR"/*.yaml 2>/dev/null | grep -c '[0-9]' || true)
  dec=$(grep -h -- '--declared' "$EDIR"/*.yaml 2>/dev/null | wc -l || true)
  if [ "${ann:-0}" -eq 0 ] || [ "${dec:-0}" -eq 0 ]; then
    echo "--config-epoch $EPOCH requested, but $EDIR/ has annotation-lines=$ann declared-lines=$dec — the PAIR must exist before it can be flipped; refusing" >&2
    exit 1
  fi
  echo "---- epoch pair: $ann annotation + $dec declared line(s) -> $EPOCH ----"
  for f in "$EDIR"/*.yaml; do
    [ -f "$f" ] || continue
    # (a) annotation side — quoted value is the k8s norm; bare digits tolerated
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
SUBJ="deploy: bump ${APP} → ${TAG}${EPOCH:+ + config epoch ${EPOCH}}"
MSG="$SUBJ

machine-generated by anvil/set-image-pr from ${IMAGE}@${TAG}
(app commit already human-reviewed;"
if [ -n "$EPOCH" ]; then
  MSG="$MSG
this PR flips the epoch PAIR — omicron/config.epoch + the gate's --declared
arg — in $EDIR, locksteps the ${APP} gate-image newTag pins across
overlays/production/*, and validate-all asserts pair equality after)"
else
  MSG="$MSG
this PR changes only images: lines)"
fi
git -c user.name=vortex-bot-ci -c user.email=vortex-bot-ci@users.noreply.github.com \
  commit -aqm "$MSG"

echo "---- bump diff ----"; git diff "HEAD^" HEAD; echo "-------------------"

# ---- validate-before-open: the render must survive the bump, always ----
if [ -z "$SKIP_VALIDATE" ]; then
  echo "---- validate render of the bump branch ----"
  if bash "$ANVIL_BIN/validate-all.sh" "$WORK"; then
    echo "---- validation GREEN ----"
  else
    echo "set-image-pr: RENDER VALIDATION FAILED — refusing to ${PLAN:+plan-and-}push a bump PR whose manifests do not build. The PR would look reviewable and deploy a lie. (--skip-validate is for emergencies only.)" >&2
    exit 1
  fi
fi

if [ -n "$PLAN" ]; then
  echo "PLAN: evidence above is complete — branch $BRANCH was NOT pushed, no PR opened."
  exit 0
fi
if [ -n "$DRY" ]; then echo "DRY-RUN: branch $BRANCH prepared in $WORK — nothing pushed"; exit 0; fi

git push -q "https://vortex-bot-ci:${VORTEX_BOT_PAT}@github.com/kanatabi/vortex.git" "$BRANCH"
export GH_TOKEN="$VORTEX_BOT_PAT"
gh label create deploy-bump --repo kanatabi/vortex --color 7CFC8A \
  --description "automated image bump — auto-merge eligible" >/dev/null 2>&1 || true
PR_TITLE="deploy: bump ${APP} → ${TAG}${EPOCH:+ + config epoch ${EPOCH}}"
PR_BODY="Automated deploy bump for \`${IMAGE}:${TAG}\` (source commit already human-reviewed in kanatabi/${APP})."
PR_BODY+=$'\n'"Files touched (fence-checked: images: stanzas and the epoch pair only):"
PR_BODY+=$'\n'"$(git diff --name-only 'HEAD^' HEAD | sed 's|^|- `|; s|$|`|')"
if [ -n "$EPOCH" ]; then
  PR_BODY+=$'\n\n'"Config epoch pair (`omicron/config.epoch` + gate `--declared`) flipped to `${EPOCH}` in lockstep with the gate image pins."
fi
PR_BODY+=$'\n'"Rendered validation ran BEFORE this PR opened (anvil deploy-plan/deploy gates, incl. epoch-pair consistency)."
PR_BODY+=$'\n'"Merges automatically iff DEPLOY_AUTOMERGE=on and validate-manifests is green."
URL=$(gh pr create --repo kanatabi/vortex --base main --head "$BRANCH" \
  --title "$PR_TITLE" --label deploy-bump --body "$PR_BODY")
echo "bump PR: $URL"
