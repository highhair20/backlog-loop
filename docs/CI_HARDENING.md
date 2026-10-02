# CI hardening

Once `.github/workflows/ci.yml` runs your Verify commands, CI is green when those
commands pass. The patterns below close the gaps where a green check is not
evidence: a test that silently skipped, a tool CI fetched instead of the one you
declared, a coverage number that flaps or comes from a cache, a check that skipped
work a committed cache said was done. Each one is the fix for a real incident.
Take the ones that fit your stack.

Each section states the principle first, then the failure it prevents, then a
snippet for a step in your `verify` job. Snippets marked with a stack (Node, Go)
show that stack; the principle carries over to others.

**The snippets rely on GitHub Actions' default shell**, `bash -eo pipefail`: a
failing command, including one inside a pipe, fails the step. If you move a
snippet into a Makefile, a hook, or a step with another `shell:`, start it with
`set -euo pipefail`, or its failures stop counting.

**Pin every action to a commit SHA**, with the version in a comment, as the
template's own workflows do. A tag can be moved to other code; a SHA cannot.
Dependabot (`.github/dependabot.yml`) updates the SHA and the comment together.
The snippets here pin `actions/checkout`; pin `actions/setup-node`,
`actions/setup-go`, and any other action you add the same way.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

## 1. Check that test tooling is present

**Principle:** if a test needs a tool, a missing tool must fail the job, not skip
the test.

**Prevents:** suites that skip themselves when a CLI (`just`, `jq`, a database
client) is not on the runner. Most test runners count a skipped suite as a pass,
so a runner image change turns part of your suite off and CI stays green.

**Snippet (any stack):** run this before the tests. Each `--version` exits
non-zero when its tool is missing, which fails the step.

```yaml
- name: Check test tooling
  run: |
    just --version
    jq --version
```

## 2. Use the project's own binaries

**Principle:** CI runs the exact tool version the project declares, and fails if
it is not installed. It never fetches a substitute.

**Prevents:** a dropped or misspelled dev dependency going unnoticed. `npx tsc`
downloads `tsc` from the registry when it is not installed, so CI typechecks
against whatever version is current there, not the one in your lockfile.

**Snippet (Node):** install from the lockfile, then call the binary directly.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
- run: npm ci
- name: Typecheck
  run: ./node_modules/.bin/tsc --noEmit
```

If you keep `npx`, use `npx --no-install tsc`, which fails instead of fetching.

## 3. Gate coverage at two levels

**Principle:** warn below the target and fail below a floor you can hold on every
run. Set the floor below the target by at least the run-to-run variation.

**Prevents:** a hard gate that flakes. Coverage from integration tests varies
between runs (timing, retries, which branch a race takes). With about ±3%
variation, a hard 80% gate fails healthy PRs until people stop trusting it. A
76% floor with an 80% warning still catches a real drop.

**Snippet (any stack):** the gate reads the total percentage from
`coverage-total.txt`. Section 4 shows how to write that file for Go and Node.

```yaml
- name: Coverage gate
  env:
    COVERAGE_TARGET: 80
    COVERAGE_FLOOR: 76
  run: |
    total="$(cat coverage-total.txt)"
    # awk compares a non-number as a string, so "null" (what jq prints for a
    # missing field) would pass both checks below. Refuse anything else first.
    case "$total" in
      ''|*[!0-9.]*|*.*.*)
        echo "::error::coverage-total.txt holds '${total}', not a percentage."
        exit 1 ;;
    esac
    echo "Coverage: ${total}% (target ${COVERAGE_TARGET}%, floor ${COVERAGE_FLOOR}%)"
    if awk -v t="$total" -v f="$COVERAGE_FLOOR" 'BEGIN { exit !(t < f) }'; then
      echo "::error::Coverage ${total}% is below the ${COVERAGE_FLOOR}% floor."
      exit 1
    fi
    if awk -v t="$total" -v g="$COVERAGE_TARGET" 'BEGIN { exit !(t < g) }'; then
      echo "::warning::Coverage ${total}% is below the ${COVERAGE_TARGET}% target."
    fi
```

## 4. Measure coverage without the test cache

**Principle:** a coverage number must come from tests that ran in this job.

**Prevents:** a pass for tests that never ran. Go caches test results keyed on
the code and the inputs it can see; a cache hit replays the old pass and its
coverage. That is sound for unchanged code, but not for tests that depend on
what the cache cannot see: a database or container, the network, the clock. A
flaky or broken integration test can stay green from a cached run, especially
when the runner restores `GOCACHE` between jobs.

**Snippet (Go):** `-count=1` disables the test cache for this run.

```yaml
- name: Test with coverage
  run: |
    go test -count=1 -coverprofile=coverage.out ./...
    go tool cover -func=coverage.out | awk '/^total:/ { sub("%", "", $3); print $3 }' > coverage-total.txt
```

**Snippet (Node, Jest):** Jest runs every test each time, so there is no result
cache to disable; this only writes the total for the gate.

```yaml
- name: Test with coverage
  run: |
    ./node_modules/.bin/jest --ci --coverage --coverageReporters=json-summary
    # -e: a missing field fails here, instead of writing "null" for the gate.
    jq -e '.total.lines.pct' coverage/coverage-summary.json > coverage-total.txt
```

## 5. Guard a single source of truth

**Principle:** a constant that must live in one file gets a CI step that fails
when it appears anywhere else.

**Prevents:** copies that drift. An id, URL, or limit gets pasted into a second
file "just for now"; later one copy changes and the other ships stale.

**Snippet (any stack):** set `VALUE` to the constant and `HOME_FILE` to the one
file it belongs in. `git grep` searches tracked files only, so build output and
dependencies are skipped. The workflow holding this step is excluded, since it
names the value; every other file, other workflows included, is searched.

```yaml
- name: Single source of truth
  env:
    VALUE: "the-constant-value"
    HOME_FILE: src/config/constants.ts
  run: |
    files="$(git grep -lF -- "$VALUE" -- ':!.github/workflows/ci.yml' || true)"
    if [ "$files" != "$HOME_FILE" ]; then
      echo "::error::'$VALUE' must appear only in $HOME_FILE. Found in:"
      printf '%s\n' "${files:-<nowhere>}"
      exit 1
    fi
```

## 6. Never commit build caches

**Principle:** CI starts from source. A file in which a tool records what it has
already checked stays on the machine that made it, and never enters the repo.

**Prevents:** a check that skips itself. Section 4 covers a cache the runner
restores; this one arrives with the checkout. `tsc -b` decides from each
project's `*.tsbuildinfo` whether there is anything to check, so a stale copy
committed by mistake can make CI report a clean typecheck it never ran. pytest's
`.pytest_cache` does the same to `--lf` (rerun only the tests recorded as failing)
and `--sw` (skip ahead to the last recorded failure): a committed copy decides
which tests CI runs. Python's `__pycache__` is lower risk, since Python checks
each `.pyc` against its source by default, but it is the same kind of
machine-local state and belongs with the others.

**Snippet (any stack):** ignore the caches in `.gitignore`. Add your stack's
equivalents, such as another tool's incremental-build or test-result file.

```gitignore
*.tsbuildinfo
__pycache__/
.pytest_cache/
```

`.gitignore` does not untrack a file that is already committed, and `git add -f`
gets past it. This step fails while one is tracked. In git pathspecs `*` also
matches `/`, so each pattern finds the cache at any depth.

```yaml
- name: No committed build caches
  run: |
    tracked="$(git ls-files -- '*.tsbuildinfo' '*__pycache__/*' '*.pytest_cache/*')"
    if [ -n "$tracked" ]; then
      echo "::error::Build caches are committed. Untrack them with 'git rm --cached', then ignore them:"
      printf '%s\n' "$tracked"
      exit 1
    fi
```
