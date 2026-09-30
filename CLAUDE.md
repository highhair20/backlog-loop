<!-- claude-code-repo-template: own instructions -->
# claude-code-repo-template — Project Instructions

> **In a repo created from this template, this is the wrong file.** It holds the
> template repo's own instructions, and its Verify runs the template's tests, not
> yours. Stop and run `scripts/setup.sh --fix`, which replaces it with the project
> skeleton in `templates/CLAUDE.md`. `scripts/check-verify-section.sh` refuses to
> start the loop until you do.

## Repo layout

| Path | What it is |
|---|---|
| `.claude/` | Settings (deny rules, hooks), the `/work-next-item` command, the PR review hooks, and the vendored reviewer agents with their context |
| `.github/` | Issue forms, PR template, Dependabot, the placeholder `ci.yml` for new repos, and `template-self-test.yml`, this repo's CI |
| `docs/` | `ISSUE_GUIDE.md`, `BACKLOG.md`, and `CI_HARDENING.md`, all seeded into repos |
| `scripts/` | The loop and setup scripts, and a `test-*.sh` for each |
| `templates/CLAUDE.md` | The project skeleton that new and synced repos get as their `CLAUDE.md` |

## Verify

```sh
scripts/run-tests.sh
# needs shellcheck (brew install shellcheck); if this runner lacks it, say so in the PR body, since CI runs it
shellcheck --severity=warning scripts/*.sh .claude/hooks/*.sh
```

`.github/workflows/template-self-test.yml` runs the same two commands.

## Testing notes

- Every script has a `scripts/test-<name>.sh`: plain bash, fakes for `gh` and
  `claude` on `PATH`, throwaway repos under `mktemp -d`. No network.
- Scripts must run on macOS's bash 3.2: no `mapfile`, no associative arrays, and
  guard empty arrays under `set -u` (`${a[@]+"${a[@]}"}`).
- A new test script is picked up by `run-tests.sh` automatically if it is named
  `test-*.sh`.

## Definition of done

- **User-facing change:** the README says so, in the capability table, the
  getting-started steps, the sync table, or the file list, whichever applies.
- **New or renamed file that repos should get:** it is in the right list in
  `scripts/sync-guardrails.sh` (MANAGED or SEEDED), with a check in
  `scripts/test-sync-guardrails.sh`.
- **Changed a seeded file:** existing repos keep their old copy. If they need the
  change, say how to apply it in the PR body.

## Scope map

- What repos receive: the MANAGED and SEEDED lists in `scripts/sync-guardrails.sh`,
  and everything at the repo root (what "Use this template" copies).
- What the loop reads from a repo's `CLAUDE.md`: the contract table in
  `.claude/commands/work-next-item.md`.
- Labels: `docs/ISSUE_GUIDE.md` and `scripts/seed-labels.sh`, kept equal by
  `scripts/test-labels.sh`.

## Specialist reviewers

| Changed paths | Agent (`subagent_type`) | Focus |
|---|---|---|
| any script or test | `pr-test-analyzer` | each acceptance criterion has a test that reaches its real failure case |
| any script or hook | `silent-failure-hunter` | swallowed errors and fallbacks that hide failure |

## GitHub flow guardrails

- Claude works on feature branches named `<type>/<issue>-<slug>`, one issue per
  branch and one branch per PR, and opens PRs with `Closes #N`, assigned to the maintainer.
- **Claude never merges and never pushes to `main`.** Merge is the maintainer's step.
  The `protect-main` ruleset enforces this on GitHub.
- After `gh pr create`, the PR review hooks open a `/code-review` loop and hold the
  turn open until it passes. Run `gh pr create` without capturing its stdout.
- Issue structure and labels: [`docs/ISSUE_GUIDE.md`](docs/ISSUE_GUIDE.md).
