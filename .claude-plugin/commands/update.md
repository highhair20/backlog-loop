Bring the current repository up to date with the backlog-loop template this plugin
holds, and show what changed for the user to review.

Never commit, stage, or push anything, and never stash or discard the user's
changes. The user reviews the diff and commits it.

1. **Remind first.** Plugins from this marketplace do not update themselves, and a
   session keeps the copy it loaded. To sync the latest template rather than the
   one installed, the user runs these in a shell, then `/reload-plugins` here (or
   starts a new session), then this command again:

   ```bash
   claude plugin marketplace update backlog-loop
   claude plugin update backlog-loop@backlog-loop
   ```

   Say this in one short paragraph, then go on with the copy that is loaded.

2. **Find the repository.** Run `git rev-parse --show-toplevel`. If it fails, stop
   and say this command must run inside a git repository.

3. **Re-sync:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync-guardrails.sh" "<repository root>"
   ```

   It refuses a repository with uncommitted changes, so that the diff afterwards
   is exactly what the sync changed. If it refuses or fails, show its message,
   say what the user must do (commit or stash their changes first), and stop.

4. **Show the diff for review.** From the repository root, run `git status --short`
   and `git diff --stat`, then `git diff` for the changed files, and summarise it:
   which managed files the template changed, what was added to
   `.claude/settings.json` and `.gitignore`, and the template version now in
   `.claude/template-version` (a commit, or `unknown`). Seeded files the
   repository already had are never touched, so a new file appearing means the
   template added it.

5. **Next steps:** review the diff, commit it on a branch and open a PR, and run
   `scripts/setup.sh` to check whether the new template needs anything else (a new
   label, or allow rules the local allowlist lacks).
