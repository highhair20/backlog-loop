# Deploying

The template ships no deploy workflow, but its guardrails assume one shape: a
merge to `main` deploys a dev environment, and a `v*` tag pushed by a human
deploys prod. This guide describes that shape and the one test that keeps the
two environments from drifting apart. Adapt the snippets to your stack; the
units they deploy (`api`, `worker`, `scheduler`) are placeholders for your
functions, services, or containers.

**Pin every action to a commit SHA**, with the version in a comment, as in
[CI_HARDENING.md](./CI_HARDENING.md). A deploy workflow holds your cloud
credentials, so a moved tag there does the most damage.

## Dev deploys on merge to `main`

Every merge to `main` deploys to dev. The loop never merges, so nothing reaches
dev without a merge you made, and dev always runs what `main` holds.

```yaml
# .github/workflows/deploy.yml
name: deploy-dev
on:
  push:
    branches: [main]
permissions:
  contents: read
concurrency: deploy-dev
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev
    strategy:
      matrix:
        unit: [api, worker, scheduler]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: ./deploy.sh "${{ matrix.unit }}" dev
```

`deploy.sh` stands for whatever deploys one unit in your stack. If your cloud
login uses OIDC, the job also needs `id-token: write` under `permissions`.

## Prod deploys on a `v*` tag a human pushes

Prod deploys only when someone pushes a version tag such as `v1.4.0`, after
checking the same commit in dev.

```yaml
# .github/workflows/deploy-prod.yml
name: deploy-prod
on:
  push:
    tags: ['v*']
permissions:
  contents: read
concurrency: deploy-prod
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: prod
    strategy:
      matrix:
        unit: [api, worker, scheduler]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: ./deploy.sh "${{ matrix.unit }}" prod
```

**The loop cannot push tags.** `.claude/settings.json` denies `git push * v*`,
`git push --tags`, and any push to `refs/tags/`. A tag push would be a prod
deploy, and the loop's work is unreviewed until you merge it; tagging is the
step where you decide that reviewed code goes live. Like every deny rule, these
match command text, so they are a filter, not a wall (see the README's Limits).
For a hard block, add a GitHub tag ruleset on `v*` that only you can bypass, or
require a reviewer on the `prod` environment.

## Keep the workflows in step: a parity test

**Principle:** dev and prod deploy the same set of units, and a test fails when
they stop doing so.

**Prevents:** a unit that exists only in dev. Someone adds a new function to
`deploy.yml`, it works in dev, and the first prod release ships without it. The
gap shows up as a 404 or a dead queue in prod, long after the PR that caused it.

The script below reads the `unit: [...]` list from each workflow's matrix and
compares the two sets. Keep each list on one line so the script can read it; it
fails when either list is missing or empty, since two empty lists would
otherwise compare equal.

```bash
#!/usr/bin/env bash
# scripts/check-deploy-parity.sh: fails when the dev and prod deploy workflows
# would deploy different units. Each lists them on one line: `unit: [a, b]`.
# Usage: scripts/check-deploy-parity.sh [dev-workflow] [prod-workflow]
set -euo pipefail

DEV="${1:-.github/workflows/deploy.yml}"
PROD="${2:-.github/workflows/deploy-prod.yml}"

units() { # units <workflow>: its unit names, one per line, sorted
  local list
  list="$(sed -nE 's/^[[:space:]]*unit:[[:space:]]*\[(.*)\][[:space:]]*(#.*)?$/\1/p' "$1")"
  printf '%s\n' "$list" | tr ',' '\n' | tr -d "[:blank:]\"'" | awk 'NF' | sort -u
}

dev="$(units "$DEV")"
prod="$(units "$PROD")"
[ -n "$dev" ] || { echo "no 'unit: [...]' list in $DEV" >&2; exit 1; }
[ -n "$prod" ] || { echo "no 'unit: [...]' list in $PROD" >&2; exit 1; }
if [ "$dev" != "$prod" ]; then
  echo "deploy workflows differ (< $DEV, > $PROD):" >&2
  diff <(printf '%s\n' "$dev") <(printf '%s\n' "$prod") >&2 || true
  exit 1
fi
echo "deploy parity: $(printf '%s\n' "$dev" | wc -l | tr -d ' ') units in both workflows"
```

Add it to `## Verify` in `CLAUDE.md` and to your CI workflow. Because it runs in
the loop's own Verify step, a PR that adds a unit to one workflow fails before it
is opened, not after a release. If your workflows list units some other way (one
job per unit, a deploy config file), keep the principle and change `units()`:
extract a set from each, then compare.

## The dev deploy is the first real test

CI cannot run what only a real deploy does: logging in to your cloud, the
permissions of the deploy role, the deploy actions themselves. Dev is where those
run first, and that is a reason to keep it ahead of prod rather than deploying
both from one trigger.

On 2026-09-30, a Dependabot PR bumped a cloud-credentials action
(`configure-aws-credentials`) to a new major version in a repo using this
pattern. CI passed, because CI never logs in. Merging it ran the new version in
the dev deploy, where it worked, before any prod tag used it. Had it failed, prod
would still have been on the old version, and the fix would have been one more
PR, not an incident.

So: after merging a change to a deploy workflow or a bump of one of its actions,
watch the dev deploy before you push the next tag.
