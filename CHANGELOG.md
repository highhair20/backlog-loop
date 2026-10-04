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

### Manual steps for existing repos

- None.

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
- **Issue conventions:** issue forms, `docs/ISSUE_GUIDE.md`, and
  `scripts/seed-labels.sh` for the priority, status, and proposal-gate labels.
- **CI skeleton** that fails until configured, with SHA-pinned actions and
  Dependabot; `docs/CI_HARDENING.md` and `docs/DEPLOYING.md`.
- **Setup and sync:** `scripts/setup.sh` checks a repo is ready for the loop and
  `--fix`es the safe parts; `scripts/sync-guardrails.sh` brings an existing repo up
  to date, recording the template version in `.claude/template-version`: the
  commit, and on a second line the release tag when the template is on one.
- This changelog, and release steps in the README.

### Manual steps for existing repos

- None. A repo synced before this release has no tag in `.claude/template-version`;
  re-sync from a checkout of `v0.1.0` to record it.

[Unreleased]: https://github.com/highhair20/backlog-loop/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/highhair20/backlog-loop/releases/tag/v0.1.0
