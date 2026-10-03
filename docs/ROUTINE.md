# Running the loop as a scheduled routine

A Claude Code [routine](https://code.claude.com/docs/en/routines) can run
`/work-next-item` on a schedule in Anthropic's cloud, so the backlog is worked
without anyone starting the loop. Each run is a fresh cloud session with its own
clone, and works at most one issue under the same command and guardrails as a local
run. It is scheduling around the loop, not a second engine.

## Before you start

- **`scripts/setup.sh` passes**: a real `## Verify`, the labels (including the
  proposal labels), and the `protect-main` ruleset. The ruleset matters most here:
  GitHub enforces it whatever the session does, while the repo's deny rules may not
  apply in a routine at all (see the first dry run).
- **Turn the proposal gate on** in `CLAUDE.md`, so no hand-written issue becomes a PR
  before you have read its plan:
  ```markdown
  ## Proposal gate

  - Gate: on
  - Machine-filed label: none
  ```
  Name a machine-filed label only for issues your own automation files with evidence
  attached (a triage agent, say); those skip the proposal.
- **Label what it must never touch** `no-auto-heal`: infrastructure, secrets, the
  loop's own plumbing.
- **Give the cloud environment what Verify needs.** The session has a fresh clone
  and the environment's tools. Install anything else (a linter, a toolchain) in the
  environment's setup script; a Verify command that cannot run makes every
  implement run give up.
- **Grant GitHub access.** A routine reaches GitHub as you, through the Claude GitHub
  App. Its installation must cover this repository with access to contents, issues,
  and pull requests. A 403 in the first run means it does not.

## Create the routine

Routines are created interactively, so `setup.sh` cannot do this for you. Run
`/schedule` in a Claude Code session in the repo, or use claude.ai/code/routines:

| Setting | Value |
|---|---|
| Repository | this repository |
| Prompt | `/work-next-item --dry-run` |
| Schedule | hourly (`0 * * * *`), the shortest interval routines allow |
| Model | the model you run the loop with locally |

## The first dry run

Start one with **Run now** and read the session. Then check the repository: a dry
run writes nothing, so there must be no new comment, label, branch, or PR. Confirm
what the routines documentation does not promise:

- [ ] **The command ran.** The session followed `/work-next-item` rather than reading
  it as plain text. If it did not, make the prompt: "Follow
  .claude/commands/work-next-item.md with the arguments --dry-run".
- [ ] **GitHub access works.** It listed issues, through `gh` or the GitHub MCP tools,
  without a 403.
- [ ] **The deny rules apply.** Start a separate one-off run with the prompt "Run
  `git push --dry-run origin HEAD:main` and report whether permission settings
  denied it". The push sends nothing either way. If it was not denied, the repo's
  `.claude/settings.json` is not in effect: GitHub sees the routine as you, so only
  the command's own instructions stop it merging its PRs. Do not go live in that
  case.
- [ ] **It picked the right issue**: the one you would pick, skipping `no-auto-heal`,
  `blocked`, and unapproved proposals.
- [ ] **Its proposal is worth approving.** The dry-run report includes the full text
  it would post.
- [ ] **How long a run takes.** Runs must not overlap (below).

## Go live

After a few dry runs look right, change the prompt to `/work-next-item`. Keep the
gate on.

## While it runs

- **One runner per repository.** Step 0 treats any `in-progress` issue as a run that
  died, and recovers it. It cannot tell a run still working in another session from a
  dead one, and `backlog-loop.sh`'s lock is a local file no cloud session sees. So do
  not run the loop locally while the routine is live, and keep runs well inside the
  interval. If runs approach an hour, schedule every two hours or more.
- **Approve a proposal** by adding `heal:approved`. The next run implements it and
  opens a PR assigned to you. For a fresh proposal instead, edit the issue and remove
  `heal:proposed`.
- **Hold back one issue** with `no-auto-heal` or `blocked`. **Stop everything** by
  pausing the routine on claude.ai/code/routines.
- **Ask for changes on a PR** by commenting on it and adding `changes-requested` to
  the PR. A later run makes them on the same branch. Runs also fix a PR's failing
  checks and merge conflicts before starting new work. After three follow-ups with no
  word from you, the issue is handed back as `needs-attention`; the PR stays open.
- **Merging stays yours**, as with every other way of running the loop.

## Cadence and usage

Hourly is the default. The schedule lives in the routine, not the repository, so
change it there, with `/schedule` or on claude.ai/code/routines. Each run counts
against your Claude plan's usage like an interactive session. A run that finds
nothing actionable stops after a few listings; one that implements an issue costs
about what working it locally does. Routines also have per-account caps on runs per
hour.
