# anvil — the estate's deployment toolkit

Scripts and composite Actions shared by `lumen`, `earendil`, `mellon`, and
`vortex` CI. Nothing here holds secrets or values — doctrine applies to the
tooling itself: this repo is safe to publish, and it is published (public).

**Where the depth lives:** [`AGENTS.md`](AGENTS.md) — the full action/script
catalog, the end-to-end release contract, the environment model (branch
grammar, epoch TRIO, lockstep scope), the fail-open trap ledger, secrets &
variables, and local-test recipes.

## Scope rule (what earns a home here)

Anything with **≥2 consumers** across the estate, or belonging to the
deploy/ops lifecycle. Per-repo gates (gofmt, vitest, svelte-check…) stay in
their own repos — YAGNI is a feature.

## Contents

```
bin/        next-version.sh (semver truth) · settle-pending-reviews.sh ·
            validate-all.sh (rendered-loss baseline + structural invariants +
            the epoch TRIO) · diff-render.sh · push-release.sh (the PAT
            cascade) · set-image-pr.sh (the bump flow) · auto-merge.sh
            (the conditional merger)
actions/    validate-manifests/ · semver-release/ · publish-image/ ·
            deploy-plan/ (evidence-only rehearsal) · deploy-bump/
            (born-validated bump PRs) — zero third-party actions
```

Full annotations per entry: AGENTS.md §2.

## Consumption — pin by SHA, never by tag

```yaml
- uses: kanatabi/anvil/actions/semver-release@<40-char-commit-sha>
```

Renovate-style auto-bumps of these refs are a hard NO (the renovate lesson):
anvil changes are deploy-capable code, reviewed as such. To upgrade a
consumer, bump the SHA in a PR a human merges.

## The release contract, in one breath

Branch merges gate and NEVER deploy. Merging to `main` parks THREE bump jobs
on their own protected environments (`release-patch|minor|major`); a human
approves ONE — that approval is the release decision — and pushes a `vX.Y.Z`
tag via `RELEASE_BOT_PAT` (a `GITHUB_TOKEN`-pushed tag never cascades). The
tag fires `publish-image` + `deploy-plan` (an evidence-only rehearsal the
human reads) + one `deploy-<env>` chain per environment, each parking on its
own protected `deploy-<env>` environment — the ladder is the approval order,
staging before production. Rollback is a human-merged revert. The full
diagram, the fail-open traps, and the tag doctrine: AGENTS.md §5.

## The environment model, in one breath

`bump/<app>-<env>-<tag>` carries the env; the bump touches ONLY
`environments/<env>/<app>` — images stanza lines plus (optionally) the
`omicron/config.epoch` TRIO (pod annotation + gate `--declared` + ES
annotation, byte-equal, one commit). The auto-merge fence works by pattern,
never by app/env name. Branch grammar, trio rules, transition window, and the
lockstep resolution: AGENTS.md §6.
