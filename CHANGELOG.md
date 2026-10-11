<!-- backlog-loop: own changelog -->
# Changelog

All notable changes to the backlog-loop template are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Until 1.0.0, a minor version may change
the deny rules or the `CLAUDE.md` contract the loop reads.

Sync overwrites managed files but never touches a seeded file a repo already has.
So every release has a **Manual steps for existing repos** subsection: what to
change by hand in a repo synced from an earlier version. "None" means a re-sync is
enough.

This file describes the template, not your project: `scripts/setup.sh --fix`
removes it from a repo made with "Use this template", and sync never copies it.

## [Unreleased]

### Added

- `/file-issue <one-line idea>` (the new managed `.claude/commands/file-issue.md`)
  drafts an issue in the issue forms' format. It checks open and closed issues for
  duplicates, reads the code the idea touches, proposes one priority with a reason,
  and shows the draft. It files only after you approve it in a later message, so a
  headless run prints the draft and files nothing. `gh issue create` stays out of
  the unattended allowlist on purpose (#72).
- `scripts/backlog-loop.sh` warns at start-up when the repo is behind the template,
  as `scripts/setup.sh` does, and both now say by how many commits, with a link to
  the changes on GitHub. The check is the new managed `scripts/template-version.sh`.
- `scripts/backlog-loop.sh`: when a session makes no progress and leaves
  uncommitted edits or unpushed commits, the driver names the branch and the
  session's log, instead of only "no progress" (#85).
- `scripts/vendor-agents.sh` vendors only from the ECC commit pinned in the new
  seeded `scripts/ECC_PIN`. It refuses a checkout at any other commit and reads
  the agents and `LICENSE` from the commit, never the working tree; `--adopt`
  vendors from the checkout's commit and pins it (#97).
- A README "Security" section: what the loop can do with your credentials, what to
  set on a public repo, and why the `protect-main` ruleset is required.
  `scripts/setup.sh` warns when a public repo has the proposal gate off (#100).

### Changed

- `/work-next-item` records who holds an issue. Every claim is a comment naming the
  run and its checkout. Step 0 leaves alone a claim younger than three hours, and
  recovers an older one, or one from its own checkout, at once. Before, it treated
  every `in-progress` issue as a dead run's. A run that loses a race to claim an
  issue posts a release and backs off. One runner per repository is still the rule
  (`docs/ROUTINE.md`); claims are a backstop for when it slips (#57).

### Fixed

- `scripts/backlog-loop.sh` keeps its logs private to the user who ran it: each
  log is a new mode-600 file (it never writes through a file or symlink already at
  the log's name), a log directory it creates is mode 700, and an existing
  `.loop-logs/` the user owns is tightened to 700. A `LOG_DIR` the operator chose
  and already has keeps its mode, with a warning if other users can get into it.
  A log directory or log it cannot create now stops the run (#99).
- `scripts/sync-guardrails.sh` never writes through a symlink in the target repo.
  If a file it would write, or a directory above one, is a symlink, it names it and
  writes nothing, so a committed link cannot send the sync's writes outside the
  repo (#96).
- `scripts/sync-guardrails.sh` treats a hook as the template's only when its
  command runs a managed hook script by its path. A repo's own hook whose command
  merely contains a managed script's name (`my-setup.sh-wrapper`, `scripts/setup.sh`)
  was dropped on sync; it is now kept (#98).
- `ready-to-merge` no longer outlives a PR that stopped being ready (#110). The
  seeded workflow also runs when a PR's labels change (`pull_request_target`, which
  runs the default branch's workflow, never the PR's code), so `changes-requested`
  takes the label off at once, and removing it puts the label back. The script sets
  its own workflow's checks aside, since its run puts one on the PR it judges, and
  reads each PR again just before labelling or announcing it. `scripts/ready-to-merge.sh` takes
  the label off a PR whose merge state is still `UNKNOWN` after its retries, and its
  comment says the branch includes its base only when the compare API shows it is
  not behind; without a strict ruleset GitHub reads a behind branch as `CLEAN`.
- `scripts/ready-to-merge.sh`'s comment names the base commit it judged the branch
  against ("the branch includes main at `abc1234`") instead of saying "up to date",
  which went stale once `main` moved on and nothing re-checked it (#114).
- `/work-next-item` rewrites the PR description at handover (Step 8), before it sets
  `in-review`, so the description matches the branch the review loop left: its
  changes, its last Verify run, and a new Review section with the rounds and the
  findings fixed or rejected. Before, the description was the one Step 7 wrote ahead
  of the review, and a session that tried to update it was refused (#116).

### Manual steps for existing repos

- **PR description at handover (#116):** add `Bash(gh pr edit * --body *)` to
  `.claude/settings.local.json`'s allow list (`scripts/missing-allow-rules.sh` names
  it). Without it, a headless run cannot rewrite the description; it posts the update
  as a PR comment instead and says so.

- **`.github/workflows/ready-to-merge.yml`** (seeded, #110): for the label to come
  off as soon as a PR gains `changes-requested`, add the template's
  `pull_request_target` trigger to your copy, `actions: read`, `checks: read` and
  `statuses: read` under `permissions:`, and `persist-credentials: false` on its
  checkout. Without the three permissions the re-synced script still runs, warns, and cannot set its own
  check aside, so it reads a PR whose only pending check is its own as not ready. Keep that checkout on the default branch: under that trigger, checking
  out the PR's code would run it with a write token. Without the trigger, the re-synced script still works, and the label comes
  off at the next CI run or push to `main`. The `ready-to-merge` rows in `docs/BACKLOG.md`
  and `docs/ISSUE_GUIDE.md` (seeded) no longer promise "up to date"; copy them if
  you want them, and re-run `scripts/seed-labels.sh` to update the label's
  description.

- **`docs/ISSUE_GUIDE.md`** (seeded) gained a paragraph pointing to `/file-issue`;
  copy it from the template if you want it. A re-sync brings the command itself.
- **`scripts/ECC_PIN`:** a sync seeds the template's pin. If your reviewer agents
  were vendored from another ECC commit (the commit is in each agent's
  "Vendored from ECC" line), `vendor-agents.sh` now refuses until you either check
  out the pinned commit or run `scripts/vendor-agents.sh --adopt` from a checkout you
  have reviewed. Commit the pin with the agents.
- **`docs/BACKLOG.md`** (seeded) gained a paragraph on the pin under "Reviewers";
  copy it from the template if you want it.
- **Loop logs (#99):** the next driver run makes the default `.loop-logs/` private,
  which also hides the logs earlier runs wrote there. If you set `LOG_DIR` to a
  directory of your own, the driver leaves it as it is: run
  `chmod 700 "$LOG_DIR" && chmod 600 "$LOG_DIR"/item-*.log` to hide earlier logs.
- **Claims (#57):** add `Bash(hostname)`, `Bash(git rev-parse --show-toplevel)` and
  `Bash(date -u +%Y-%m-%dT%H:%M:%SZ)` to `.claude/settings.local.json`'s allow list
  (`scripts/missing-allow-rules.sh` names them). Without them a headless run stops
  at the identity step.
- If an earlier sync dropped one of your own hooks from `.claude/settings.json`
  (#98), restore it from that file's git history. Otherwise a re-sync is enough.

## [0.1.0] - 2026-10-04

The first tagged release. It records what the template does today.

### Added

- **Merge and push guardrails:** a committed `.claude/settings.json` that denies
  merging PRs (CLI, REST API, and GitHub MCP tools), pushing to `main`, force
  pushes, `v*` tag pushes, and the GitHub MCP file-write tools.
- **Autonomous backlog loop:** `/work-next-item` follows up on its own open PRs
  (failing checks, conflicts, `changes-requested`), then takes the highest-priority
  actionable issue, checks its premise and scope against the code, implements it
  test-first, runs the repo's `## Verify` commands, and opens a PR assigned to the
  maintainer. It never merges.
- **Drivers:** `scripts/backlog-loop.sh` runs one item per fresh `claude -p`
  session, with a lock so one loop runs per clone; `docs/ROUTINE.md` sets the loop
  up as a scheduled cloud routine, with `--dry-run` and an optional proposal gate.
- **Specialist reviewers:** `pr-test-analyzer` and `silent-failure-hunter`, vendored
  from ECC by `scripts/vendor-agents.sh`, plus optional stack reviewer contexts.
- **PR review loop:** hooks that open a `/code-review` when a PR is created and hold
  the session until its critical and high findings are resolved.
- **Ready-to-merge notice:** the seeded `ready-to-merge.yml` workflow runs
  `scripts/ready-to-merge.sh`, which labels a loop PR `ready-to-merge` and mentions
  the maintainer once the loop is done with it, its checks pass, and it is up to date
  with `main`. The loop updates a PR that is only behind `main`.
- **Issue conventions:** issue forms, `docs/ISSUE_GUIDE.md`, and
  `scripts/seed-labels.sh` for the priority, status, and proposal-gate labels.
- **CI skeleton** that fails until configured, with SHA-pinned actions and
  Dependabot; `docs/CI_HARDENING.md` and `docs/DEPLOYING.md`.
- **Setup and sync:** `scripts/setup.sh` checks a repo is ready for the loop and
  `--fix`es the safe parts, including proposing `## Verify` commands from the
  detected stack and filling them in when exactly one is found;
  `scripts/sync-guardrails.sh` brings an existing repo up
  to date, recording the template version in `.claude/template-version`: the
  commit, and on a second line the release tag when the template is on one.
- **Installer plugin:** this repo is a Claude Code plugin marketplace whose plugin
  adds `/backlog-loop:install` and `/backlog-loop:update`, so a repo can take the
  template without cloning it.
- This changelog, and release steps in the README.

### Manual steps for existing repos

- A repo synced before this release has no tag in `.claude/template-version`;
  re-sync from a checkout of `v0.1.0` to record it.
- The re-sync adds `.github/workflows/ready-to-merge.yml` if the repo lacks it. List
  the workflows a PR must pass in its `workflow_run` trigger, and run
  `scripts/seed-labels.sh` to create the `ready-to-merge` label.

[Unreleased]: https://github.com/highhair20/backlog-loop/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/highhair20/backlog-loop/releases/tag/v0.1.0
