Bring the current repository up to the backlog-loop template: copy the template's
files into it, then check and fix its setup. The files land in the repository, so
local, headless, and cloud sessions all see them once they are committed. This
plugin adds nothing else: the hooks, reviewer agents, and `/work-next-item` all
come from the repository's own copies.

Never commit, stage, or push anything, and never stash or discard the user's
changes. The user reviews the result and commits it.

1. **Find the repository.** Run `git rev-parse --show-toplevel`. If it fails, stop
   and say this command must run inside a git repository.

2. **Sync the template into it:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync-guardrails.sh" "<repository root>"
   ```

   It refuses a repository with uncommitted changes, so that the diff afterwards
   is exactly what the sync changed. If it refuses or fails, show its message,
   say what the user must do (commit or stash their changes first), and stop.

3. **Check and fix the setup.** From the repository root, run:

   ```bash
   scripts/setup.sh --fix
   ```

   It creates the loop's labels and the local allowlist, swaps in the `CLAUDE.md`
   skeleton when needed, and checks the rest. Exit 1 means some items still need
   the user, not that this command failed.

4. **Report**, briefly:
   - What the sync changed (`git status --short`).
   - Each `✗` and `⚠` line from `setup.sh`, with the fix it gives. The usual ones
     for a new adopter: fill in `## Verify` in `CLAUDE.md`, make CI run the same
     commands, and protect `main` with `scripts/protect-main.sh`.
   - Next steps: review the diff, commit it on a branch and open a PR, then re-run
     `scripts/setup.sh` until it reports no problems. Later, `/backlog-loop:update`
     brings the repository up to date with a newer template.
