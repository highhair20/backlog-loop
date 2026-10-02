# The Backlog Loop

This repo has an autonomous backlog loop that works GitHub issues **one at a time**
and turns each into a pull request for the maintainer to merge. This document is
for whoever operates it: how to run it, what one iteration does, and why each
guardrail exists.

To write the issues it works, see [ISSUE_GUIDE.md](./ISSUE_GUIDE.md).

## Running it

| Driver | Use it when |
|---|---|
| `/work-next-item` | You want to watch one issue done end to end. |
| `/loop /work-next-item` | You want several issues in one session. Context carries over between items. |
| `scripts/backlog-loop.sh` | Unattended runs. Each issue gets a fresh `claude -p` session, so a long backlog never fills the context window. |

`backlog-loop.sh` stops when the backlog is empty, when an item makes no progress,
or after `MAX_ITEMS`. Its settings are environment variables: `MAX_ITEMS` (25),
`PACE_SECONDS` (5), `MAX_RETRIES` (3), `BACKOFF_SECONDS` (300), `MODEL`,
`LOG_DIR` (`.loop-logs`), and `BG_WAIT_SECONDS` (2700): how long each session waits
for its background reviewers and PR review before they are cut off. Each retry of
an item writes its own log (`item-<time>-<n>.attempt2.log`, ...). All loop state
lives in git and issue labels, so it is safe to stop at any time and re-run later:
the next iteration recovers whatever was in flight.

Only one `backlog-loop.sh` runs per clone: it holds `.git/backlog-loop.lock` while
it works, and a second one refuses to start. A lock left by a crashed run is
reclaimed on the next start. If a run is refused and no loop is running, the message
says how to clear the lock.

Before a first unattended run, `scripts/setup.sh` checks that everything the loop
needs is in place.

## One iteration

0. **Recover.** At most one issue is `in-progress`. If its PR is open, mark it
   `in-review`; if its PR was closed unmerged, hand it back as `needs-attention`;
   if only its branch exists, resume it; if neither, release it.
1. **Clean base.** Start from an up-to-date `main` with a clean working tree.
2. **Select** the highest-priority actionable issue: `P0`, then `P1`, then `P2`, then
   `P3` (only once no `P0`–`P2` issue is actionable),
   skipping anything `in-progress`, `in-review`, `blocked`, or `needs-attention`.
3. **Claim** it with `in-progress`, first naming in a comment any earlier PRs for it that were closed unmerged.
4. **Check the premise, then the scope.** Confirm the issue's claims against the
   code. Then work out what the change touches from the code itself (route tables,
   registries), not from the issue's list, and correct the issue if it is wrong or
   incomplete.
5. **Branch** as `<type>/<number>-<slug>`, and **implement test-first** until every
   `## Verify` command in `CLAUDE.md` passes. After about three failed cycles it
   gives up: any work is pushed to an `abandoned/<number>-<sha>` branch, the issue's
   own branch is deleted, and the issue gets `needs-attention` and a comment saying
   why and where the work is.
6. **Commit and push**, then run the **specialist reviewers** listed in `CLAUDE.md`
   whose paths match. CRITICAL and HIGH findings get one fix round; the rest go in
   the PR body.
7. **Open the PR** with `Closes #N`, assigned to the maintainer, and swap
   `in-progress` for `in-review`. A review loop then runs on the PR until it has no
   blocking findings.

The command is [`.claude/commands/work-next-item.md`](../.claude/commands/work-next-item.md).
It, the hooks, and the loop scripts are **managed** by
[claude-code-repo-template](https://github.com/highhair20/claude-code-repo-template):
`sync-guardrails.sh` overwrites them, so change them there. Everything specific to
this repo belongs in `CLAUDE.md`.

## Definition of done

Passing Verify commands are necessary but not sufficient. The loop never deploys,
so a change that only breaks once deployed looks finished to it. List those checks
under `## Definition of done` in `CLAUDE.md`; the loop records each outcome in the
PR body. Typical ones:

- **A new route** must also be registered wherever the gateway or router config
  lives, or it will 404 in production.
- **A new service, function, or worker** must be added to every deploy workflow,
  not just one environment's.
- **A new cloud API call** may need a permission the runtime role lacks. Label the
  issue `needs-infra`, write the change, and put the exact apply steps in the PR.
- **A migration** needs both directions and a test against realistic data, not an
  empty table.

**Turn each check into a test where you can.** A test that asserts two
configurations agree (router against gateway config, dev deploy workflow against
prod) fails inside the loop's own Verify step, before a PR exists. A checklist item
only fails if someone reads it. [DEPLOYING.md](./DEPLOYING.md) has a parity test for
the deploy workflows.

### Tests must exercise the acceptance criteria

Write at least one test per acceptance criterion, and make it set up the state the
criterion describes. A delete test once passed CI using a record with no children;
in production, deleting a record that had children hit a foreign-key violation. The
failing case was never exercised. The `pr-test-analyzer` reviewer checks for
exactly this.

## Task runners

If the repo has a task runner (`just`, `make`, `npm` scripts), three conventions
make it safe for an unattended loop to use. The examples use `just`, and each is
followed by a one-line version for another runner. The template ships no runner
file: the conventions are what matter, not the tool.

**One entry point.** People, CI, and the loop's `## Verify` run the same named
recipes. Verify then cannot drift from how the project is really built and tested,
so a green Verify means what a green local run means.

```just
# CLAUDE.md's Verify runs `just verify`, and so does CI.
verify: lint test
```

In make, the same target is `verify: lint test`, and Verify runs `make verify`.

**Guard recipes.** A private recipe checks one precondition, such as a credential
or an environment variable, and other recipes depend on it. A missing one then
fails first, with a message that says what to set, instead of halfway through with
an error the loop has to guess at.

```just
deploy-dev: _require-env
    ./scripts/deploy.sh dev

_require-env:
    @[ -n "${API_TOKEN:-}" ] || { echo "API_TOKEN is not set; see README" >&2; exit 1; }
```

In make, the guard is a prerequisite target: `deploy-dev: require-env`.

**Confirm destructive recipes.** A recipe that changes a live environment makes
you type the target's name first. A slip of the keyboard, or an agent that picked
the wrong recipe, stops at the prompt. A headless session has no terminal, so the
recipe refuses and changes nothing. `$env` makes `just` pass the argument as an
environment variable, so a name holding quotes cannot rewrite the script.

```just
reset-db $env: _require-env
    #!/usr/bin/env bash
    set -euo pipefail
    [ -t 0 ] || { echo "reset-db needs a terminal to confirm; nothing changed." >&2; exit 1; }
    read -r -p "This deletes every row in $env. Type '$env' to continue: " answer
    [ -n "$env" ] && [ "$answer" = "$env" ] || { echo "Not confirmed; nothing changed." >&2; exit 1; }
    ./scripts/reset-db.sh "$env"
```

With npm scripts, which pass arguments only to the last command in a chain, write
one script per target: `"reset-db:dev": "./scripts/confirm.sh dev && ./scripts/reset-db.sh dev"`.

The prompt is a speed bump, not a lock: an agent could pipe the answer in. Also
deny the recipe in `.claude/settings.json` (for example `Bash(just reset-db*)`), so
the loop never runs it.

## Guardrails, and why

- **One issue, one branch, one PR.** A PR that bundles issues cannot be reviewed or
  reverted cleanly.
- **Never merge, never push to `main`.** If a push to `main` deploys, the loop
  would be deploying unreviewed code. Merging is the maintainer's step.
- **PRs are assigned, not review-requested.** GitHub does not let an author request
  their own review, and the loop acts as the maintainer.
- **`blocked` issues are skipped; `needs-infra` changes are written, never
  applied.** Infrastructure is applied by hand, from the steps in the PR.
- **Premise and scope checks come before code.** A wrong diagnosis implemented
  faithfully produces a green PR over a live bug.

## Permissions

- `.claude/settings.json` is committed, so every session sees its deny rules,
  including cloud sessions. They block merging, pushes to `main`, force and tag
  pushes, and GitHub MCP tools that write files. Deny beats any allow rule. Tag
  pushes are blocked because a `v*` tag deploys prod in the pattern
  [DEPLOYING.md](./DEPLOYING.md) describes.
- `.claude/settings.local.json` is per-machine and gitignored. It allows the
  commands an unattended run needs; start from `.claude/settings.local.json.example`
  and add the Verify commands.
- **The deny rules are a filter, not a wall.** They match command text, so an
  unusual spelling can get past them. The hard block is the `protect-main` branch
  ruleset (`scripts/protect-main.sh`), which GitHub enforces whatever the command.

## Reviewers

The reviewers in `.claude/agents/` are committed because cloud sessions do not load
plugins. They are vendored from [ECC](https://github.com/affaan-m/ECC) (MIT) by
`scripts/vendor-agents.sh`, which adds this repo's context from
`.claude/agent-context/`. To change what a reviewer is told, edit its context file
and re-run the script. To add one, add a context file named after the ECC agent,
re-run, and add a row to `## Specialist reviewers` in `CLAUDE.md`.

Ready-made contexts for stack reviewers (`go-reviewer`, `database-reviewer`,
`typescript-reviewer`, `python-reviewer`) are in `.claude/agent-context/optional/`. None is
active until you enable it:

```sh
cp .claude/agent-context/optional/go-reviewer.md .claude/agent-context/
scripts/vendor-agents.sh
```

Then add a row to `## Specialist reviewers` naming the paths it covers (for example,
`**/*.go`). Each enabled reviewer is one more agent run per loop item, so enable
only the ones your stack needs. Enable them by hand: headless loop sessions cannot
write to `.claude/`.
