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
  next-version.sh     semver truth: the reachable v-tag with the HIGHEST
                      VERSION (sort -V, --merged HEAD — never git describe,
                      whose equidistant tags sort by TAGGER DATE: a live-fire
                      bug 2026-11-13) bumped by the VENDORED semver-tool
                      (below). --current prints the max tag. No tags yet:
                      major->v1.0.0, minor|patch->v0.1.0. Garbage in -> exit 2.
  settle-pending-reviews.sh
                      after a successful release, declines this run's sibling
                      bump reviews (fence: release-patch|minor|major only,
                      never the current env, never `deploy`, run-scoped) so
                      ONE approval completes the pipeline. Auth rides
                      RELEASE_BOT_PAT (owner acts as the configured reviewer;
                      PAT needs Actions:RW). Warn-only by design: the release
                      already happened — a red settle would lie. Fallback:
                      decline the siblings by hand.
  validate-all.sh     kustomize build of every kustomize dir (applications/,
                      environments/<env>/<app>, and the legacy overlays/ tree
                      during the transition), kind-count assertions
                      (expected-kinds.txt), and STRUCTURAL invariants over
                      the RENDERED output — no dir-name folklore: zero
                      inline config literals in Deployment docs, envFrom
                      required wherever an ExternalSecret + Deployment
                      coexist, PreSync hook asserted from the *migrate* FILE
                      existing in a dir, and the EPOCH TRIO: wherever
                      omicron/config.epoch / --declared appear in a render,
                      ALL THREE sides (pod annotation, gate --declared, ES
                      annotation) must EXIST and be EQUAL (half/2-of-3 flip
                      = red). --update regenerates the table: a manifest PR
                      MUST bring its truth update.
  expected-kinds.txt  the assertion table. Lives HERE, reviewed like code.
  diff-render.sh      renders every dir at two refs, emits a unified diff of
                      the RENDERED manifests — what Argo will apply, not the
                      YAML you wrote.
  push-release.sh     the cascade key: push refs/tags/vX.Y.Z with
                      RELEASE_BOT_PAT (a GITHUB_TOKEN-pushed tag never
                      triggers a workflow — the silent no-deploy trap), then
                      gh release create. Refuses to run without the PAT.
  set-image-pr.sh     the bump flow: clone vortex (PAT — push+PR creds),
                      kustomize edit set image in environments/<env>/<app>/
                      (--env foundation|staging|production, default
                      production), branch bump/<app>-<env>-<tag>,
                      PR `deploy: bump …` labelled deploy-bump; dedupes
                      against an open PR; --dry-run. --config-epoch N flips
                      the epoch TRIO (pod annotation + --declared + ES
                      annotation) in the SAME commit — refuses unless all
                      three sides pre-exist (half-bump refusal by
                      construction) — and every bump locksteps the app's
                      image newTag pins across its ENV's overlay dirs
                      (one env, one commit).
  auto-merge.sh       the conditional merger. Merges iff: author == bot,
                      label deploy-bump, head ref parses an ENV
                      (bump/<app>-<env>-<tag>, or the DEPRECATED legacy
                      bump/<app>-<tag> ⇒ production; unparseable env =
                      BAIL), every file ∈ environments/<env-from-ref>/
                      (transition, legacy refs only: applications/*/kustomization.yaml ∪
                      overlays/production/*/kustomization.yaml ∪
                      overlays/production/<app-from-head-ref>/*.yaml), every
                      changed diff line is images:-stanza OR a
                      config.epoch/--declared line, validate-manifests
                      green, and the VARIABLE DEPLOY_AUTOMERGE == "on"
                      (absent means off — fail-safe).
actions/
  validate-manifests/ installs the pinned helm BINARY (v3.22.1 tarball,
                      sha256 embedded — get-helm-3's default is a MUTABLE
                      CDN pointer, verified 2026-11-13, so the old
                      "pinned" claim wasn't one) then runs the scripts
  semver-release/     the approval-gated release job: fetch --tags →
                      bin/next-version.sh (+ collision guard: refuses loudly
                      if the computed tag exists locally OR on origin) →
                      annotated tag → push-release.sh (PAT cascade) →
                      gh release → settle (siblings auto-declined; opt-out
                      `settle: false`). `with: bump:` in, `version` out.
  publish-image/      build → push ghcr.io/<owner>/<app>:<tag> (+ optional
                      alias tag; :latest is for tests/tooling, deploys pin
                      v-tags). Raw docker + the workflow token.
  deploy-plan/        evidence-only rehearsal of the bump against REAL
                    vortex main: pin pre-flight + full validation +
                    exact diff, pushes NOTHING. Takes `env:`
                    (foundation|staging|production, default production).
  deploy-bump/      bin/set-image-pr.sh for an already-pushed tag — the
                    PR half. Now validates the render BEFORE pushing
                    (a bump PR whose manifests do not build is refused;
                    --skip-validate emergency-only), so PRs arrive
                    born-validated; deploy-plan above provides the
                    evidence the human reads before approving. Takes
                    `env:` too — it selects the environments/<env>/<app>
                    target and the bump/<app>-<env>-<tag> branch.
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

## Vendored dependencies (the one exception to "write it here")

`bin/vendor/semver` — **semver-tool 3.4.0** (commit `837ad91…`, Apache-2.0,
license text beside it, sha256 in the file's provenance header). The rule:
anvil runs zero third-party ACTIONS and fetches nothing at runtime; a
third-party *algorithm* we'd otherwise invent (semver arithmetic — the
prerelease rules are subtle and I would get them wrong, cf. `check` vs
`validate`) is vendored PINNED, audited once, body byte-identical to
upstream, upgrade = a deliberate PR re-verifying sha256+license. Doctrine
selection (which tag is "newest") stays ours — the tool has no opinion
about git, and `git describe`'s date ordering is a documented live-fire bug.

## The release contract (end-to-end) — approval-gated, release-only deploys

Branch merges gate and NEVER deploy. A release exists only because a human
approved one of three waiting bump jobs; the tag that approval pushes is the
only deployable artifact:

```
merge to main → ci.yml: gates (+ contract on earendil)
  → THREE waiting jobs, EACH on its OWN PROTECTED environment:
      semver-patch [release-patch] | semver-minor [release-minor]
      | semver-major [release-major]
    the human reviews the run and approves ONE job — approving IS the
    release decision — the bump level is the literal `with: bump:` of that
    job, no derivation, full human control. ONE ENVIRONMENT PER BUMP JOB IS
    LOAD-BEARING: an environment approval releases EVERY job waiting on that
    environment in the run (proven live 2026-11-13: one approval of a shared
    `release` env pushed v0.1.0 AND v1.0.0, the patch job dying red on the
    duplicate-tag guard). Job-per-environment makes the review card == the
    choice. Un-approved siblings are DECLINED AUTOMATICALLY by the released
    job (settle — warn-only, fence: release-* envs of THIS run only), so one
    approval completes the pipeline and frees the ci concurrency queue; if
    settle ever warns, decline by hand (else they expire at 24h).
  → anvil semver-release: fetch --tags → next-version.sh → annotated tag
    → push via RELEASE_BOT_PAT (bin/push-release.sh — REFUSES with the
    default token: GITHUB_TOKEN-created events never cascade, so a
    "successful" tag would silently never deploy) → gh release create
  → the tag push TRIGGERS release.yml:
      publish-image: ghcr.io/kanatabi/<app>:vX.Y.Z (+ :latest alias)
      deploy-plan (AUTOMATIC): rehearsal against real vortex main — prints
        current-pin → proposed-pin + validated rendered diff, pushes nothing.
        THIS is what the human reads. With config-epoch set the rehearsal —
        and the eventual PR — carry the epoch TRIO flip too (per the --env
        it plans for); a bump PR may be CONFIG-ONLY (same image tags, trio
        flips, validate proves consistency).
      deploy-open (PARKS on the PROTECTED `deploy` environment — one job,
        one env, one card): approval opens the bump PR via set-image-pr,
        which re-validates BEFORE pushing (born-validated PRs).
  → vortex CI: validate-manifests + rendered diff (independent second opinion)
  → auto-merge ONLY if every guard holds AND DEPLOY_AUTOMERGE=on (absent = off)
  → Argo (targetRevision: HEAD) syncs within its poll interval
  → rollback = git revert the bump commit — a human PR, human-merged, by
    design (or re-dispatch release.yml with an older tag: redeploy = release)
```

**Two fail-open traps, in permanent ink:**
1. A job referencing an environment that does not exist gets it auto-created
   UNPROTECTED — the job then runs without waiting, and every merge fires
   every bump job. Environment protection MUST predate the workflows.
 2. A fine-grained PAT WITHOUT the `Workflow` permission pushes refs that
    NEVER trigger workflows — the tag lands, looks green, and the deploy
    pipeline silently doesn't exist. PROVEN via the events API: the
    2026-11-13 incident's pushes produced ReleaseEvents but ZERO
    PushEvents — GitHub never recorded the ref creation as an event at
    all. RELEASE_BOT_PAT needs Contents:RW, Workflow:RW **and Actions:RW**
    (Actions: is what lets the settle step post sibling-decline reviews —
    the PAT acts as you, the configured reviewer).
    Separately: trigger filters use the documented GLOB syntax
    (`v*.*.*`) — the regex-in-slashes form is not promised for
    `on.push.tags` and we don't gamble on unverified filter syntax.
    (GitHub also hides repos you can't see behind 404s — see the checkout
    lesson. That one is about the estate's still-private repos, not vortex.)

**Double-approve = double-release:** approving two bump jobs (two different
environments) pushes two valid tags and two bump PRs; nothing corrupts
(immutable tags, the duplicate guard turns a same-version race red, last
merge wins the deploy), but the habit is one card, one click.

Tag doctrine:

- Deploy pins MUST be `vX.Y.Z` — an immutable release identity. The `:latest`
  alias exists for tests and tooling only; a manifest referencing an alias
  is a bug the fence will not catch, so reviewers must.
- From a tagless repo the line is born at `v0.1.0` (minor|patch); only
  `major` jumps straight to `v1.0.0`.

Human PRs to vortex are untouched: author≠bot fails the first condition gate.

### Why bump diffs are exactly images: stanzas + the epoch trio

vortex checks every kustomization it owns in kustomize-canonical form — the
shape `kustomize edit` itself would write. So `kustomize edit set image`
rewrites ONLY the entry it owns, and a bump diff is 2–3 lines inside
`images:`. Since the config-gate landed, the bump diff may ALSO carry the
epoch TRIO — pod-template `omicron/config.epoch: "N"`, the gate's `--declared`
arg, and the ExternalSecret's `omicron/config.epoch: "N"` metadata annotation,
all flipped TOGETHER by `--config-epoch` in one commit — plus the lockstep
lines moving every `name: <app>` pin in the bump env's overlay dirs to the
new tag. A bump PR may even be CONFIG-ONLY: image tags unchanged, the epoch
trio flips, and validate-all's class-4 rule is what PROVES the trio is
consistent (a one- or two-sided flip is refused before the PR ever opens). The
auto-merge fence grew to admit exactly this and it grew **BY PATTERN, never
by app or env name**: lines containing `config.epoch`/`--declared` or living in an
images: stanza, files under the head ref's `environments/<env>/` — the
app/env in the path fence comes from the branch, not from a list. A
non-canonicalized file would be silently reformatted by the edit and trip
the fence — fail-safe, but the PR lands on a human instead. (The reflow is
not hypothetical: the env-model fixture battery showed one `set image` turns
a hand-indented overlay into whole-file churn — keep landed overlays canonical.)

## The environment model (contract)

Owner ruling: the estate has THREE environments under `environments/` —

```
environments/{foundation,staging,production}/<app>/kustomization.yaml
    + per-overlay files (externalsecret.yaml, patches…)
applications/<app>/          the bases — name unchanged, shared
apps/{foundation,staging,production}/*.yaml   per-env Argo Application CRs
bootstrap/apps-hub-{foundation,staging,production}.yaml
```

Every deploy decision is now environment-scoped. Two contracts hang off it:

**Branch grammar** — the bump branch carries the env:

| shape | meaning |
| :--- | :--- |
| `bump/<app>-<env>-<tag>` | the app's pin/trio in `environments/<env>/`; env ∈ `foundation\|staging\|production` |
| `bump/<app>-<tag>` | **DEPRECATED** legacy ⇒ production (branches minted before the restructure) |
| anything else | auto-merge **BAILS** — no silent env, no widening |

The env token matches the three literals and the LAST occurrence wins as the
app/tag separator, so an app named `x-staging` cannot steal the token
(`x-staging-production-v1.0.0` ⇒ app `x-staging`, env `production`). The tag
shape (vX.Y.Z / sha-) never selects the env.

**The epoch is a TRIO, not a pair** — per overlay dir, all three of

1. the pod-template `omicron/config.epoch: "N"` annotation (kustomization patches),
2. the gate Job's `--declared "N"` arg,
3. the ExternalSecret's `omicron/config.epoch: "N"` metadata annotation

must be byte-equal. `set-image-pr --config-epoch` refuses unless all three
sides pre-exist; `validate-all` class 4 fails any render where ANY side
appears without the other two, or where the values differ. Rationale: the ES
annotation makes the *secret refresh* declare the config epoch it shipped —
a 2-of-3 flip leaves one witness blind, the same drift class the pair rule
was minted for.

**Transition window.** Until the vortex env-model cutover PR deletes the
legacy tree, tooling ALSO accepts: the `overlays/*/*/` glob in validate-all's
discovery, the pre-restructure paths in auto-merge's fence
(`applications/<app>/kustomization.yaml`, `overlays/production/**` — legacy-
shaped branches only, marked TRANSITION in the code), and the
`overlays/${ENV}/*` leg of set-image-pr's lockstep sweep. **Removal
condition: the vortex PR-d that removes `overlays/` (the
`feat/environments-foundation` line) lands → the next reviewed anvil commit
strips these transition patterns.** Do not extend them.

**Lockstep scope (current ruling).** Every bump moves `name: <app>` images
stanzas inside the BUMP'S OWN ENV only — `environments/<env>/*` (+ the
transition `overlays/<env>/*`). That keeps the bot's PR inside the env path
fence: a production bump never re-pins staging, and each env's gate pins
move when that env bumps lumen. The sibling overlay header in vortex
(`environments/production/lumen`) words a CROSS-env sweep (one lumen bump
moving every env's gate pins + the bases); that is not expressible under the
env-scoped fence above — if the owner wants it, sweep AND fence AND the
env-mismatch bail need ONE joint re-ruling.

> TABLE STATUS (converged 2026-11-13): `bin/expected-kinds.txt` mirrors the
> post config-gate + hub-split main (+4 kinds per production app overlay:
> gate Job + RBAC, exactly as the parallel PRs promised). The lesson stands:
> while sibling manifest PRs are mid-flight, do NOT one-shot `--update` —
> it would freeze a transient reality; regenerate against the converged
> main and ship the refresh in its own reviewed commit.
>
> PENDING NOISE (env-model round, this writing): the vortex re-homing makes
> every `overlays/<env>/<app>/` key MISSING and every
> `environments/<env>/<app>/` key UNLISTED the moment the cutover merges —
> the trio lines add no KINDS, so production/staging app overlays keep
> their counts under the new key; foundation dirs re-key from
> `overlays/production/<platform-app>` at the same count unless the
> restructure also changes their bodies. The owner regenerates the table
> against converged main (its own reviewed commit), NOT from any tool here.

### The 404 lesson: cross-repo checkout of a repo you can't see

GitHub answers **404 — not 403 — for private repos you cannot see** (it hides
existence). "Repo not found" in CI is therefore usually a missing token, not a
missing repo: a cross-repo checkout/clone of a PRIVATE repo MUST pass an
explicit token. That was vortex's story during the private era — the clone fix
(59e8090) added `x-access-token:${VORTEX_BOT_PAT}` for exactly that reason —
until it went public on 2026-11-13. The PAT clone stays: pushes and PR creation
need the credentials anyway, and a PAT-authenticated clone behaves the same for
any visibility. The lesson itself still bites: `kanatabi/earendil` and
`kanatabi/mellon` are private, so their cross-repo steps pass a token too.

## Secrets & variables referenced (never stored here)

- `VORTEX_BOT_PAT` — fine-grained PAT (`vortex-bot-ci`): contents +
  pull-requests write, scoped to `kanatabi/vortex` ONLY. 90-day expiry; a
  lapsed token surfaces as 401/403 on the bump step and nothing else breaks.
- `RELEASE_BOT_PAT` — fine-grained PAT, Contents:RW + Workflow:RW +
  Actions:RW on
  lumen/earendil/mellon ONLY (not vortex — compartmentalized from the bump
  hand). Pushes release tags so the cascade fires; push-release.sh refuses
  without it. Workflow: is not optional: without it the PAT's pushes never
  trigger workflows (the 2026-11-13 incident — tags lived, release.yml
  never ran). 90-day expiry: an approved bump job dies at the push with 403
  — the last step, the reddest, never a half-release. Revocation = the
  emergency brake on all releasing. Caveat as old as fine-grained PATs: it
  acts as its owner account.
- `DEPLOY_AUTOMERGE` — repo or org VARIABLE, `on|off`, absent = off.

## Local testing

```
bin/next-version.sh minor            # inside any repo: prints next vX.Y.Z
DRY_RUN=1 GITHUB_REPOSITORY=kanatabi/lumen bin/push-release.sh v1.2.3
bin/validate-all.sh <path-to-vortex> [--update]
bin/diff-render.sh  <path-to-vortex> <base-ref>
VORTX=<path-to-vortex> bin/set-image-pr.sh --app lumen \
    --image ghcr.io/kanatabi/lumen --tag v9.9.9-test --dry-run
    # needs no token, pushes nothing — prepares bump/lumen-production-v9.9.9-test
    # in a temp copy (--env foundation|staging|production moves the target)
VORTX=<path-to-vortex> bin/set-image-pr.sh --app earendil --env staging \
    --image ghcr.io/kanatabi/earendil --tag v9.9.9-test --config-epoch 1 --plan
    # same rehearsal, printing the epoch-TRIO flip (pod annotation + --declared
    # + ES annotation, environments/staging/earendil/) and the same-env image
    # lockstep as evidence; --config-epoch refuses (exit 1) unless ALL THREE
    # sides pre-exist
```

## Backlog — centralized repo settings (deferred by the owner 2026-11-13)

Today every app repo needs manual GitHub settings: environments
(`release-patch|minor|major`, `deploy`, required-reviewer), secrets
(`VORTEX_BOT_PAT`, `RELEASE_BOT_PAT`), variables (`DEPLOY_AUTOMERGE` on
vortex), required status checks. Root cause: `kanatabi` is a PERSONAL account
— org environments/secrets/variables/rulesets exist only for organizations.

Planned fix when picked up (Path 1): `provision/settings.yaml` (the per-repo
truth: environment list, reviewers, secret NAMES only — never values) +
`bin/provision-repo.sh` (idempotent REST apply: PUT environments, required
checks, secret-presence AUDIT; the human pastes the 2 secret values, the
script reports which). Needs one `estate-provision` fine-grained PAT
(Administration+Environments+Secrets write, estate repos, laptop-only).
Safety fact: REST-created environments are byte-identical to UI-created —
no drift class introduced. Rejected at this scale: terraform-provider-github
(plaintext secret values in state for a 5-repo problem); full org migration
(Path 2 — clean but re-walks every URL, the ghcr namespace, and every pin;
revisit only for a second maintainer or >10 repos).
