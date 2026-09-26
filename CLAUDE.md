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

<!-- Optional sections read by /work-next-item. Delete any you don't need.

## Definition of done
Checks beyond Verify that a green build can't prove (deploy wiring, infra, docs).

## Scope map
Where to enumerate the real affected surface: route tables, handler dirs, page
registries, and what each scope label means.

## Specialist reviewers
| Changed paths | Agent (`subagent_type`) | Focus |
|---|---|---|
| `…` | `…` | … |
-->

## GitHub flow guardrails

- Claude works on feature branches named `<type>/<issue>-<slug>`, one issue per
  branch and one branch per PR, and opens PRs with `Closes #N`, assigned to Jason.
- **Claude never merges and never pushes to `main`.** Merge is Jason's step. The
  committed `.claude/settings.json` denies merges, `main`/force/tag pushes, and the
  GitHub MCP file-write tools, so cloud sessions enforce this too.
- Those deny rules match command text, so they are a filter, not a wall. The hard
  block is a GitHub ruleset on `main` that only Jason can bypass.
- After `gh pr create`, the PR review hooks open a `/code-review` loop and hold the
  turn open until it passes. Run `gh pr create` without capturing its stdout, or
  the hook cannot see the PR URL.
- Issue structure and labels: [`docs/ISSUE_GUIDE.md`](docs/ISSUE_GUIDE.md).
