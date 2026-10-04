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
   is exactly what the sync changed. If it fails, show its own message and stop.
   Only when that message is about uncommitted changes, tell the user to commit
   or stash them first. Any other failure (`jq` not found, an error part way
   through) may leave some files copied: show `git status --short`, and say that
   the tree was clean before the sync, so those changes are the sync's alone and
   can be discarded once the cause is fixed. Do not discard them yourself.

4. **Show the diff for review.** From the repository root, run `git status --short`
   and `git diff --stat`, then `git diff` for the changed files, and summarise it:
   which managed files the template changed, what was added to
   `.claude/settings.json` and `.gitignore`, and the template version now in
   `.claude/template-version`. If it reads `unknown`, say so plainly: the repo can
   no longer tell how far behind the template it is, and the sync's warning says
   why. Seeded files the
   repository already had are never touched, so a new file appearing means the
   template added it.

5. **Next steps:** review the diff, commit it on a branch and open a PR, and run
   `scripts/setup.sh` to check whether the new template needs anything else (a new
   label, or allow rules the local allowlist lacks).
