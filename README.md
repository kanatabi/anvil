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
  next-version.sh     semver arithmetic for the release flow: newest v-tag +
                      patch|minor|major → next vX.Y.Z. No tags yet:
                      major→v1.0.0, minor|patch→v0.1.0. --current prints the
                      newest tag (or nothing). Garbage in → exit 2.
  validate-all.sh     kustomize build of every applications/ + overlays/ dir,
                      kind-count assertions (expected-kinds.txt), config-shape
                      assertions (zero inline config literals; envFrom present;
                      PreSync hook on the lumen chains). --update regenerates
                      the table: a manifest PR MUST bring its truth update.
  expected-kinds.txt  the assertion table. Lives HERE, reviewed like code.
  diff-render.sh      renders every dir at two refs, emits a unified diff of
                      the RENDERED manifests — what Argo will apply, not the
                      YAML you wrote.
  push-release.sh     the cascade key: push refs/tags/vX.Y.Z with
                      RELEASE_BOT_PAT (a GITHUB_TOKEN-pushed tag never
                      triggers a workflow — the silent no-deploy trap), then
                      gh release create. Refuses to run without the PAT.
  set-image-pr.sh     the bump flow: clone vortex (PAT — it is PRIVATE),
                      kustomize edit set image, branch bump/<app>-<tag>,
                      PR `deploy: bump …` labelled deploy-bump; dedupes
                      against an open PR; --dry-run.
  auto-merge.sh       the conditional merger. Merges iff: author == bot,
                      label deploy-bump, every file ∈
                      applications/*/kustomization.yaml, every changed diff
                      line lives in the images: block, validate-manifests
                      green, and the VARIABLE DEPLOY_AUTOMERGE == "on"
                      (absent means off — fail-safe).
actions/
  validate-manifests/ installs pinned helm (v3.22.1) then runs the scripts
  semver-release/     the approval-gated release job: fetch --tags →
                      bin/next-version.sh → annotated tag → push-release.sh
                      (PAT cascade) → gh release. `with: bump:` in,
                      `version` out (outputs: value wired to the compute
                      step — read it as needs.<job>.outputs.version).
  publish-image/      build → push ghcr.io/<owner>/<app>:<tag> (+ optional
                      alias tag; :latest is for tests/tooling, deploys pin
                      v-tags). Raw docker + the workflow token.
  deploy-bump/        bin/set-image-pr.sh for an already-pushed tag — the
                      PR half, split from publishing so the deploy job can
                      gate independently.
                      Deliberately ZERO third-party actions everywhere, so
                      the pinning question is only ever about anvil itself.
```

## Consumption — pin by SHA, never by tag

```yaml
- uses: kanatabi/anvil/actions/semver-release@<40-char-commit-sha>
```

Renovate-style auto-bumps of these refs are a hard NO (the renovate lesson):
anvil changes are deploy-capable code, reviewed as such. To upgrade a
consumer, bump the SHA in a PR a human merges.

## The release contract (end-to-end) — approval-gated, release-only deploys

Branch merges gate and NEVER deploy. A release exists only because a human
approved one of three waiting bump jobs; the tag that approval pushes is the
only deployable artifact:

```
merge to main → ci.yml: gates (+ contract on earendil)
  → THREE waiting jobs on the PROTECTED `release` environment:
      semver-patch | semver-minor | semver-major
    the human reviews the run and approves EXACTLY ONE (declines the other
    two; un-touched ones expire at 24h). Approving a job IS the release
    decision — the bump level is the literal `with: bump:` of that job, no
    derivation, full human control.
  → anvil semver-release: fetch --tags → next-version.sh → annotated tag
    → push via RELEASE_BOT_PAT (bin/push-release.sh — REFUSES with the
    default token: GITHUB_TOKEN-created events never cascade, so a
    "successful" tag would silently never deploy) → gh release create
  → the tag push TRIGGERS release.yml (build → deploy):
      publish-image: ghcr.io/kanatabi/<app>:vX.Y.Z (+ :latest alias)
      deploy-bump → set-image-pr: bump branch + deploy-bump PR in vortex
  → vortex CI: validate-manifests + rendered diff
  → auto-merge ONLY if every guard holds AND DEPLOY_AUTOMERGE=on (absent = off)
  → Argo (targetRevision: HEAD) syncs within its poll interval
  → rollback = git revert the bump commit — a human PR, human-merged, by
    design (or re-dispatch release.yml with an older tag: redeploy = release)
```

**The fail-open trap, in permanent ink:** a job referencing an environment
that does not exist gets it auto-created UNPROTECTED — the job then runs
without waiting, and every merge fires all three bump jobs (three tags,
three deploys). The `release` environment MUST exist with required reviewers
before these workflows land on main, and the first merge after landing gets
WATCHED: three amber "Waiting" badges or it's broken.

**Double-approve = double-release:** two approvals push two valid tags and
two bump PRs; nothing corrupts (immutable tags, last merge wins the deploy),
but the habit is approve-one, decline-two.

Tag doctrine:

- Deploy pins MUST be `vX.Y.Z` — an immutable release identity. The `:latest`
  alias exists for tests and tooling only; a manifest referencing an alias
  is a bug the fence will not catch, so reviewers must.
- From a tagless repo the line is born at `v0.1.0` (minor|patch); only
  `major` jumps straight to `v1.0.0`.

Human PRs to vortex are untouched: author≠bot fails the first condition gate.

### Why bump diffs are exactly the `images:` stanza

vortex checks every `applications/*/kustomization.yaml` in
kustomize-canonical form — the shape `kustomize edit` itself would write.
So `kustomize edit set image` rewrites ONLY the entry it owns: a bump diff is
2–3 lines inside `images:`, which is exactly what the auto-merge line fence
admits. A non-canonicalized file would be silently reformatted by the edit
and trip the fence — fail-safe, but the PR lands on a human instead.

### Cross-repo checkout of a PRIVATE repo

`kanatabi/vortex` is private, and GitHub answers **404 — not 403 — for
private repos you cannot see** (it hides existence). "Repo not found" in CI
is therefore usually a missing token, not a missing repo: a cross-repo
checkout/clone of a private repo MUST pass an explicit token (set-image-pr.sh
clones with `x-access-token:${VORTEX_BOT_PAT}`); public repos are fine with
the default `GITHUB_TOKEN`.

## Secrets & variables referenced (never stored here)

- `VORTEX_BOT_PAT` — fine-grained PAT (`vortex-bot-ci`): contents +
  pull-requests write, scoped to `kanatabi/vortex` ONLY. 90-day expiry; a
  lapsed token surfaces as 401/403 on the bump step and nothing else breaks.
- `RELEASE_BOT_PAT` — fine-grained PAT, Contents:RW on lumen/earendil/mellon
  ONLY (not vortex — compartmentalized from the bump hand). Pushes release
  tags so the cascade fires; push-release.sh refuses without it. 90-day
  expiry: an approved bump job dies at the push with 403 — the last step,
  the reddest, never a half-release. Revocation = the emergency brake on
  all releasing. Caveat as old as fine-grained PATs: it acts as its owner
  account.
- `DEPLOY_AUTOMERGE` — repo or org VARIABLE, `on|off`, absent = off.

## Local testing

```
bin/next-version.sh minor            # inside any repo: prints next vX.Y.Z
DRY_RUN=1 GITHUB_REPOSITORY=kanatabi/lumen bin/push-release.sh v1.2.3
bin/validate-all.sh <path-to-vortex> [--update]
bin/diff-render.sh  <path-to-vortex> <base-ref>
VORTX=<path-to-vortex> bin/set-image-pr.sh --app lumen \
    --image ghcr.io/kanatabi/lumen --tag v9.9.9-test --dry-run
    # needs no token, pushes nothing — prepares the bump branch in a temp copy
```
