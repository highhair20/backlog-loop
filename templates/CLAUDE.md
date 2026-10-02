# <project> — Project Instructions

<!-- Replace the placeholders, then delete this comment. -->

## Repo layout

| Path | What it is |
|---|---|
| `…` | … |

## Verify

The commands that define "done" — `/work-next-item` reads this section (and refuses
to run while it holds only these placeholders). Put one command per line in the code
block; scope a command to paths with a comment above it (e.g. `# when web/ changes`).
Write every command to run from the repo root and never `cd` — the loop may run
several in one shell (use `npm --prefix web test`, `tsc -p web`, and so on).
`.github/workflows/ci.yml` must run the same ones.

```sh
# build:
# lint:
# test:
```

## Specialist reviewers

`/work-next-item` Step 6.5 runs each reviewer whose paths match the branch's changes
and fixes its CRITICAL/HIGH findings before opening the PR. The agents live in
`.claude/agents/`, built by `scripts/vendor-agents.sh`; give each one this repo's
context in `.claude/agent-context/`.

To enable a stack reviewer (`go-reviewer`, `database-reviewer`,
`typescript-reviewer`, `python-reviewer`), copy its context from
`.claude/agent-context/optional/` into `.claude/agent-context/`, run
`scripts/vendor-agents.sh`, and add a row below with the paths it covers. Each one is
an extra agent run per item.

| Changed paths | Agent (`subagent_type`) | Focus |
|---|---|---|
| any source or test file | `pr-test-analyzer` | each acceptance criterion has a test that reaches its real failure case |
| any source file | `silent-failure-hunter` | swallowed errors and fallbacks that hide failure |

## Proposal gate

`/work-next-item` Step 3.7 reads this. With the gate on, a hand-written issue gets a
four-part proposal comment and `heal:proposed` instead of code, and the loop opens a
PR only after a human adds `heal:approved`. Issues carrying the machine-filed label
skip the proposal. Turn it on before running the loop on a schedule: see
`docs/ROUTINE.md`.

- Gate: off
- Machine-filed label: none

<!-- Optional sections read by /work-next-item. Delete any you don't need.

## Testing notes
How tests run here: frameworks, fixtures, what to mock and what must be real (for
example, a real database for anything that depends on constraints).

## Definition of done
Checks beyond Verify that a green build can't prove (deploy wiring, infra, docs).
docs/BACKLOG.md shows the pattern: turn each one into a test where you can.

## Scope map
Where to enumerate the real affected surface: route tables, handler dirs, page
registries, and what each scope label means.
-->

## GitHub flow guardrails

- Claude works on feature branches named `<type>/<issue>-<slug>`, one issue per
  branch and one branch per PR, and opens PRs with `Closes #N`, assigned to the maintainer.
- **Claude never merges and never pushes to `main`.** Merge is the maintainer's step. The
  committed `.claude/settings.json` denies merges, `main`/force/tag pushes, and the
  GitHub MCP file-write tools, so cloud sessions enforce this too.
- Those deny rules match command text, so they are a filter, not a wall. The hard
  block is a GitHub ruleset on `main` that only the maintainer can bypass.
- After `gh pr create`, the PR review hooks open a `/code-review` loop and hold the
  turn open until it passes. Run `gh pr create` without capturing its stdout, or
  the hook cannot see the PR URL.
- Issue structure and labels: [`docs/ISSUE_GUIDE.md`](docs/ISSUE_GUIDE.md).
