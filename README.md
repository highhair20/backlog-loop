# repo-template

Jason's starting point for a new repo: the GitHub-flow guardrails, PR review
loop, and issue conventions extracted from `happyhour`.

## Use it

```sh
gh repo create <name> --private --template highhair20/repo-template --clone
```

Then, in the new repo:

1. Fill in `CLAUDE.md` — especially **Verify** (build / lint / test).
2. Replace the failing placeholder step in `.github/workflows/ci.yml` with those
   same Verify commands.
3. Create the standard labels: `scripts/seed-labels.sh` (safe to re-run).
4. Add a ruleset on `main` (require a PR + passing CI; only the owner may bypass).
   Private repos need GitHub Pro for this.

## What's in it

| Path | Purpose |
|---|---|
| `.claude/settings.json` | Denies merges, `main`/force/tag pushes, and GitHub MCP file writes. Committed so cloud sessions, which see only the repo, are covered. Also wires the PR review hooks. |
| `.claude/hooks/pr-*.sh` | After `gh pr create`, open a `/code-review` loop and block the turn from ending until it passes (round cap + TTL prevent wedging). Needs `jq` and the `code-review` plugin. |
| `.github/ISSUE_TEMPLATE/` | Feature and Bug templates: Context / Goal / Acceptance criteria / Implementation notes / Out of scope / Testing. |
| `.github/workflows/ci.yml` | Runs on non-`main` branches and PRs with read-only permissions. **Fails until configured**, so a new repo never shows a green check that tests nothing. |
| `docs/ISSUE_GUIDE.md` | Issue anatomy, title convention, and the label set (priority P0–P3, type, status). |
| `CLAUDE.md` | Skeleton with the Verify section and the guardrail summary. |

## Keeping repos in sync

Files copied from a template drift. To bring an existing repo up to date, from a
clone of this template:

```sh
scripts/sync-guardrails.sh ../<repo>     # target must have a clean working tree
scripts/seed-labels.sh highhair20/<repo>
```

The sync never commits; review `git diff` in the target, then commit on a branch.

| Kind | Files | On re-run |
|---|---|---|
| managed | `.claude/hooks/pr-*.sh` | overwritten (local edits are drift) |
| seeded | `CLAUDE.md`, CI, issue templates, `docs/ISSUE_GUIDE.md` | copied only if missing |
| merged | `.claude/settings.json`, `.gitignore` | template deny rules and hooks added; the repo's own kept |

`scripts/test-sync-guardrails.sh` tests the sync; CI runs it here via
`template-self-test.yml` (inert in repos made from the template, safe to delete).

## Known limits

- Deny rules match command text: a filter, not a wall. Only a GitHub ruleset is a
  hard block.
- The review hook reads the PR URL from `gh pr create`'s stdout; capturing it
  (`URL=$(gh pr create …)`) means no loop opens. Seed it manually with
  `.claude/hooks/pr-review-state.sh seed <pr> <url>`.
