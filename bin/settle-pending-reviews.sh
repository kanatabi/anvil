#!/usr/bin/env bash
# settle-pending-reviews.sh — after a SUCCESSFUL release, decline this run's
# sibling bump reviews so the pipeline goes terminal immediately (owner
# ruling 2026-11-13: one click must complete the run; un-settled siblings
# held the run Waiting 24h and stalled the ci concurrency queue).
#
# Fences, hard-coded:
#   • ONLY entries whose environment matches ^release-(patch|minor|major)$
#   • NEVER the current bump's own environment, NEVER anything else —
#     `deploy` and any future environment are physically unreachable here
#   • run-scoped API path: another run's reviews cannot be touched
# Auth: RELEASE_BOT_PAT acts as the owner — the configured reviewer.
#
# FAILURE POLICY: warn-only, exit 0 ALWAYS. The release already happened;
# a red settle step would claim otherwise. On warn, the humans decline by
# hand (documented fallback).
#
#   usage: settle-pending-reviews.sh <current-bump>
#   env:   RELEASE_BOT_PAT · GITHUB_REPOSITORY · GITHUB_RUN_ID
set -uo pipefail
BUMP="${1:?usage: settle-pending-reviews.sh patch|minor|major}"
SELF_ENV="release-${BUMP}"

warn() { echo "settle: WARNING — $* — release SUCCEEDED; siblings stay Waiting; decline them by hand" >&2; exit 0; }

[ -n "${RELEASE_BOT_PAT:-}" ] || warn "RELEASE_BOT_PAT is empty"
[ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ] || warn "no repository/run context"
command -v gh >/dev/null || warn "gh CLI missing"
command -v jq >/dev/null || warn "jq missing"
export GH_TOKEN="$RELEASE_BOT_PAT"
API="repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/pending_deployments"

PENDING=$(gh api "$API" 2>/dev/null) || warn "cannot list pending reviews"
DECLINE=$(printf '%s' "$PENDING" \
  | jq -r '[.[].environment.name? // empty]
           | map(select(test("^release-(patch|minor|major)$")))
           | map(select(. != "'"$SELF_ENV"'"))' \
  2>/dev/null) || warn "cannot parse pending-review response"
[ "$DECLINE" = "[]" ] && { echo "settle: no sibling bump reviews to decline"; exit 0; }

BODY=$(jq -nc --argjson envs "$DECLINE" --arg self "$SELF_ENV" \
  '{environment_names: $envs, state: "rejected", comment: ("sibling bump declined by anvil settle: " + $self + " released successfully")}')

echo "settle: declining sibling reviews: $(printf '%s' "$DECLINE" | jq -r 'join(", ")')"
printf '%s' "$BODY" | gh api -X POST "$API" --input - >/dev/null 2>&1 \
  || warn "reject POST failed"
echo "settle: siblings declined — the run completes now"
