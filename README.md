# anvil — the estate's deployment toolkit

Scripts and composite Actions shared by `lumen`, `earendil`, `mellon`, and
`vortex` CI. Nothing here holds secrets or values — doctrine applies to the
tooling itself: this repo is safe to publish, and it is published (public).

## Scope rule (what earns a home here)

Anything with **≥2 consumers** across the estate, or belonging to the
deploy/ops lifecycle. Per-repo gates (gofmt, vitest, svelte-check…) stay in
their own repos — YAGNI is a feature.

## Contents

```
bin/
  validate-all.sh     kustomize build of every applications/ + overlays/ dir,
                      kind-count assertions (expected-kinds.txt), config-shape
                      assertions (zero inline config literals; envFrom present;
                      PreSync hook on the lumen chains). --update regenerates
                      the table: a manifest PR MUST bring its truth update.
  expected-kinds.txt  the assertion table. Lives HERE, reviewed like code.
  diff-render.sh      renders every dir at two refs, emits a unified diff of
                      the RENDERED manifests — what Argo will apply, not the
                      YAML you wrote.
  set-image-pr.sh     the bump flow: clone vortex, kustomize edit set image,
                      branch bump/<app>-<sha>, PR `deploy: bump …` labelled
                      deploy-bump; dedupes against an open PR; --dry-run.
  auto-merge.sh       the conditional merger. Merges iff: author == bot,
                      label deploy-bump, every file ∈
                      applications/*/kustomization.yaml, every changed diff
                      line lives in the images: block, validate-manifests
                      green, and the VARIABLE DEPLOY_AUTOMERGE == "on"
                      (absent means off — fail-safe).
actions/
  validate-manifests/ installs pinned helm (v3.22.1) then runs the scripts
  publish-and-pin/    build → push ghcr (sha tag + optional `main` alias for
                      test consumers) → set-image-pr. Raw docker + gh:
                      deliberately ZERO third-party actions, so the pinning
                      question is only ever about anvil itself.
```

## Consumption — pin by SHA, never by tag

```yaml
- uses: kanatabi/anvil/actions/publish-and-pin@<40-char-commit-sha>
```

Renovate-style auto-bumps of these refs are a hard NO (the renovate lesson):
anvil changes are deploy-capable code, reviewed as such. To upgrade a
consumer, bump the SHA in a PR a human merges.

## The bump contract (end-to-end)

```
app main merged (human review — the gate NEVER moved)
  → publish-and-pin: ghcr.io/kanatabi/<app>:sha-<short> (+ :main alias)
  → set-image-pr: bump branch + deploy-bump PR in vortex (VORTEX_BOT_PAT)
  → vortex CI: validate-manifests + rendered diff
  → auto-merge ONLY if every guard holds AND DEPLOY_AUTOMERGE=on
  → Argo (targetRevision: HEAD) syncs within its poll interval
  → rollback = git revert the bump commit — a human PR, human-merged, by design
```

Human PRs to vortex are untouched: author≠bot fails the first condition gate.

## Secrets & variables referenced (never stored here)

- `VORTEX_BOT_PAT` — fine-grained PAT (`vortex-bot-ci`): contents +
  pull-requests write, scoped to `kanatabi/vortex` ONLY. 90-day expiry; a
  lapsed token surfaces as 401/403 on the bump step and nothing else breaks.
- `DEPLOY_AUTOMERGE` — repo or org VARIABLE, `on|off`, absent = off.

## Local testing

```
bin/validate-all.sh <path-to-vortex> [--update]
bin/diff-render.sh  <path-to-vortex> <base-ref>
bin/set-image-pr.sh --app lumen --image ghcr.io/kanatabi/lumen --tag sha-x \
                    <path-to-vortex> --dry-run     # needs no token, pushes nothing
```
