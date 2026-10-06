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

### Fixed

- `scripts/backlog-loop.sh` keeps its logs private to the user who ran it: each
  log is mode 600, a log directory it creates is mode 700, and an existing
  `.loop-logs/` is tightened to 700. A `LOG_DIR` the operator chose and already has
  keeps its mode. A log directory or log it cannot create now stops the run (#99).
- `scripts/sync-guardrails.sh` never writes through a symlink in the target repo.
  If a file it would write, or a directory above one, is a symlink, it names it and
  writes nothing, so a committed link cannot send the sync's writes outside the
  repo (#96).

### Manual steps for existing repos

- **`scripts/ECC_PIN`:** a sync seeds the template's pin. If your reviewer agents
  were vendored from another ECC commit (the commit is in each agent's
  "Vendored from ECC" line), `vendor-agents.sh` now refuses until you either check
  out the pinned commit or run `scripts/vendor-agents.sh --adopt` from a checkout you
  have reviewed. Commit the pin with the agents.
- **`docs/BACKLOG.md`** (seeded) gained a paragraph on the pin under "Reviewers";
  copy it from the template if you want it.

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
