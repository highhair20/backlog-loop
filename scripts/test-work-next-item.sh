#!/usr/bin/env bash
# Structural checks on .claude/commands/work-next-item.md, the prompt the backlog
# loop runs. Behaviour lives in prose there, so these pin the parts that have
# broken before: every way of giving up goes through one procedure (#4), and
# that procedure saves work before it deletes anything.
# Usage: scripts/test-work-next-item.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$ROOT/.claude/commands/work-next-item.md"
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The text of one "## <heading>" section, up to the next "## " heading.
section() { awk -v h="$1" '/^## /{ on = (index($0, "## " h) == 1); next } on' "$CMD"; }
give_up="$(section 'Give up')"
# shellcheck disable=SC2034  # read inside check's eval strings
step5="$(section 'Step 5')"
# shellcheck disable=SC2034  # read inside check's eval strings
step65="$(section 'Step 6.5')"

check "has one Give up section" "[ \"\$(grep -c '^## Give up' '$CMD')\" = 1 ]"
check "Step 5 gives up through it" "printf '%s' \"\$step5\" | grep -q 'Give up'"
check "Step 6.5 gives up through it" "printf '%s' \"\$step65\" | grep -q 'Give up'"

# Deleting the issue's branch, locally or on the remote, happens only in Give up.
for pattern in 'git branch -D' 'git push origin --delete'; do
  check "'$pattern' appears only in Give up" \
    "[ \"\$(grep -c -- '$pattern' '$CMD')\" -ge 1 ] && [ \"\$(grep -c -- '$pattern' '$CMD')\" = \"\$(printf '%s\n' \"\$give_up\" | grep -c -- '$pattern')\" ]"
done

# A stash stays on one machine, and a cloud session's clone is thrown away.
check "nothing is stashed on give-up" "! printf '%s' \"\$give_up\" | grep -q 'git stash'"

# Order inside Give up: save the work, then release the issue, then delete branches.
# Releasing before deleting means an interruption can only leave a stray branch.
line_of() { printf '%s\n' "$give_up" | grep -n -m1 -- "$1" | cut -d: -f1; }
save="$(line_of 'refs/heads/abandoned/')"
del_remote="$(line_of 'git push origin --delete')"
del_local="$(line_of 'git branch -D')"
labels="$(line_of '--add-label needs-attention')"
check "pushes the work to an abandoned/ branch" "[ -n '$save' ]"
check "saves the work before deleting any branch" "[ -n '$save' ] && [ -n '$del_remote' ] && [ -n '$del_local' ] && [ '$save' -lt '$del_remote' ] && [ '$save' -lt '$del_local' ]"
check "releases the issue after saving, before deleting" "[ -n '$labels' ] && [ '$labels' -gt '$save' ] && [ '$labels' -lt '$del_remote' ] && [ '$labels' -lt '$del_local' ]"
stop="$(line_of 'push fails')"
rule="$(line_of 'Check every command')"
check "states the failure rule before any step" "[ -n '$rule' ] && [ '$rule' -lt '$save' ]"
check "the rule stops deleting when a save fails" "printf '%s' \"\$give_up\" | grep -q 'If step 1 or 2 fails, the work is not saved'"
check "a failed delete is reported in a comment" "printf '%s' \"\$give_up\" | grep -q 'add a comment naming what is left'"
check "a failed release (step 3) deletes nothing" "printf '%s' \"\$give_up\" | grep -q 'step 3 fails (the comment or the label swap), delete nothing'"
check "the comment never says a branch is being deleted after a failed save" "printf '%s' \"\$give_up\" | grep -q 'the save failed: nothing was deleted'"
check "the comment tells a retry to remove a leftover branch" "printf '%s' \"\$give_up\" | grep -q 'delete it before retrying'"
check "the comment gives the blocker and where the work is" "printf '%s' \"\$give_up\" | grep -q 'Blocker: <concise reason>. Work: <where it is>'"
check "the comment never claims an unsaved cloud checkout is safe" "printf '%s' \"\$give_up\" | grep -q 'will be lost'"
check "stops without deleting if the save fails, before any delete" "[ -n '$stop' ] && [ '$stop' -lt '$del_remote' ] && [ '$stop' -lt '$del_local' ]"

# A resumed branch is brought up to date with main before more work (#26): a
# branch that sat while other PRs merged can conflict, and its PR is unmergeable.
step0="$(section 'Step 0')"
merge="$(printf '%s\n' "$step0" | grep -n -m1 'git merge --no-edit origin/main' | cut -d: -f1)"
green="$(printf '%s\n' "$step0" | grep -n -m1 'bring it to green' | cut -d: -f1)"
check "Step 0 merges origin/main into a resumed branch" "[ -n '$merge' ]"
check "it merges before bringing the branch to green" "[ -n '$merge' ] && [ -n '$green' ] && [ '$merge' -lt '$green' ]"
# Only the conflict paragraph counts: Step 0 mentions Give up elsewhere too.
# shellcheck disable=SC2034  # read inside check's eval string
conflict="$(printf '%s\n' "$step0" | awk '/If the merge conflicts/{ on = 1 } on { print } on && /git merge --abort/{ exit }')"
check "a merge conflict it cannot resolve aborts and gives up" "printf '%s' \"\$conflict\" | grep -q 'git merge --abort' && printf '%s' \"\$conflict\" | grep -q 'Give up' && printf '%s' \"\$conflict\" | grep -q 'conflicting files'"
check "a resumed branch is never rebased (it may be pushed; force pushes are denied)" "! printf '%s' \"\$step0\" | grep -q 'git rebase'"

check "a failed fetch stops instead of merging a stale main" "printf '%s' \"\$step0\" | grep -q 'If the fetch fails, stop'"
check "a merge that never started is not 'aborted'" "printf '%s' \"\$step0\" | grep -q 'there is nothing to'"
# A diverged pushed copy is merged in, never required to fast-forward: Give up
# would otherwise delete the commits that exist only on the remote (#29 review).
check "a resumed branch merges its own pushed copy" "printf '%s' \"\$step0\" | grep -q 'git pull --no-rebase --no-edit origin'"
check "it never requires a fast-forward of the pushed copy" "! printf '%s' \"\$step0\" | grep -q 'ff-only'"
leftover="$(printf '%s\n' "$step0" | grep -n -m1 'wip: resumed edits' | cut -d: -f1)"
pullc="$(printf '%s\n' "$step0" | grep -n -m1 'git pull --no-rebase' | cut -d: -f1)"
check "leftover edits are committed before the pull" "[ -n '$leftover' ] && [ -n '$pullc' ] && [ '$leftover' -lt '$pullc' ]"

# Give up must never commit a half-done merge: conflict markers would be saved as
# if they were work (#26 review).
check_line="$(line_of 'MERGE_HEAD')"
abort_line="$(line_of 'git merge --abort')"
commit_line="$(line_of 'git add -A')"
check "Give up saves only commits missing from origin/main" "printf '%s' \"\$give_up\" | grep -q 'git log --oneline origin/main..HEAD'"
check "Give up checks for a half-done merge before committing" "[ -n '$check_line' ] && [ -n '$abort_line' ] && [ -n '$commit_line' ] && [ '$check_line' -lt '$commit_line' ] && [ '$abort_line' -lt '$commit_line' ]"

# Give up must not delete a remote branch that holds commits it did not save
# (#29 review, round 2): prove HEAD contains it first.
guard="$(line_of 'git log --oneline HEAD..')"
check "the remote branch is deleted only after proving HEAD contains it" "[ -n '$guard' ] && [ '$guard' -lt '$del_remote' ]"
check "a remote branch with unsaved commits is kept and reported" "printf '%s' \"\$give_up\" | grep -q 'keep the remote branch: it is the only copy'"
check "an exit of 1 from the MERGE_HEAD check is not a failure" "printf '%s' \"\$give_up\" | grep -q 'which is the normal case, not a failure'"
mh0="$(printf '%s\n' "$step0" | grep -n -m1 'MERGE_HEAD' | cut -d: -f1)"
checkout="$(printf '%s\n' "$step0" | grep -n -m1 'check out the branch' | cut -d: -f1)"
# Before the checkout, not just the commit: git refuses to switch branches mid-merge.
check "Step 0 aborts an interrupted merge before checking out the branch" "[ -n '$mh0' ] && [ -n '$checkout' ] && [ '$mh0' -lt '$checkout' ] && [ '$mh0' -lt '$leftover' ]"

# A bare `gh auth status` fails when any stored host has a stale token. The
# command uses the same helper the driver and setup.sh do (#15), so the three
# cannot disagree, and never runs gh auth status itself. Code blocks only.
# shellcheck disable=SC2034  # read inside check's eval strings
code="$(awk '/^[[:space:]]*```/{ f = !f; next } f' "$CMD")"
check "the command checks gh auth through scripts/gh-auth-check.sh" "printf '%s\n' \"\$code\" | grep -q 'scripts/gh-auth-check.sh'"
check "it never runs gh auth status itself" "! printf '%s\n' \"\$code\" | grep -q 'gh auth status'"

# P3 is the last tier, tried only when P0-P2 have no actionable issue (#45).
# shellcheck disable=SC2034  # read inside check's eval string
step2="$(section 'Step 2')"
check "Step 2 tries P3 after P2" "printf '%s' \"\$step2\" | grep -q 'then .P3.'"

# Step 0 must not mistake a preserved branch for work in flight.
check "Step 0 always ignores abandoned/ branches" "printf '%s' \"\$step0\" | grep -q 'always ignore them'"
# An abandoned/ branch outlives its attempt, so it cannot signal an interrupted
# give-up: acting on it would delete a later retry's unsaved work (#24 review).
check "Step 0 never resumes a give-up from an abandoned/ branch" "! section 'Step 0' | grep -qi 'finish it from'"

# A PR a human closed unmerged is a rejection, whatever the label (#5). Step 0
# must neither resume it (opening a new PR) nor release it (Step 2 re-selects it).
closed_list="$(printf '%s\n' "$step0" | grep -n -m1 'gh pr list --state closed' | cut -d: -f1)"
rejected="$(printf '%s\n' "$step0" | grep -n -m1 'closed, unmerged PR' | cut -d: -f1)"
resume="$(printf '%s\n' "$step0" | grep -n -m1 'work was underway' | cut -d: -f1)"
release="$(printf '%s\n' "$step0" | grep -n -m1 'release the claim' | cut -d: -f1)"
# shellcheck disable=SC2034  # read inside check's eval strings
rejected_case="$(printf '%s\n' "$step0" | awk '/closed, unmerged PR/{ on = 1 } on && /^[0-9]+\. / && !/closed, unmerged PR/{ exit } on')"
check "Step 0 lists closed PRs" "[ -n '$closed_list' ]"
check "it skips merged PRs" "printf '%s\n' \"\$step0\" | grep 'gh pr list --state closed' -A2 | grep -q 'mergedAt == null'"
# By name, not --head: a human who deleted the branch has still rejected the work.
check "it finds the closed PR by branch name, not by an existing branch" "! printf '%s' \"\$step0\" | grep -q -- '--state closed --head'"
check "a rejection is handled before resume and release" "[ -n '$rejected' ] && [ -n '$resume' ] && [ -n '$release' ] && [ '$rejected' -lt '$resume' ] && [ '$rejected' -lt '$release' ]"
check "a rejection swaps in-progress for needs-attention" "printf '%s' \"\$rejected_case\" | grep -q -- '--remove-label in-progress --add-label needs-attention'"
check "a rejection comments linking the closed PR" "printf '%s' \"\$rejected_case\" | grep -q 'gh issue comment' && printf '%s' \"\$rejected_case\" | grep -q '<closed PR url>'"
# Review of #47: a rejection is handed back once per closed PR, and a remaining
# branch goes through Give up (saved, then deleted) so no retry reuses it.
check "a closed PR already named in a comment is not rejected again" "printf '%s' \"\$rejected_case\" | grep -q 'json comments' && printf '%s' \"\$rejected_case\" | grep -q 'no comment on .#N. names yet'"
check "a rejected PR's remaining branch goes through Give up" "printf '%s' \"\$rejected_case\" | grep -q 'follow \\*\\*Give up\\*\\*'"
check "the closed listing is not cut short by merged PRs" "grep 'gh pr list --state closed' '$CMD' | grep -q -- '--limit 1000'"
check "the MCP closed listing pages" "grep '^| .gh pr list --state closed' '$CMD' | grep -q 'page until a short page'"
# Review round 4 of #47.
# shellcheck disable=SC2034  # read inside check's eval strings
step3="$(section 'Step 3 ')"
check "the claim names earlier closed PRs before adding in-progress" "printf '%s' \"\$step3\" | grep -q 'Earlier PRs closed without merging' && [ \$(printf '%s\n' \"\$step3\" | grep -n 'gh issue comment' | cut -d: -f1) -lt \$(printf '%s\n' \"\$step3\" | grep -n 'add-label in-progress' | cut -d: -f1) ]"
check "a closed PR's url is matched whole, not as a prefix" "printf '%s' \"\$rejected_case\" | grep -q 'not a prefix'"
check "a rejection with no branch stashes a dirty tree" "printf '%s' \"\$rejected_case\" | grep -q 'stash the edits'"
check "the MCP table covers the closed-PR listing" "grep -q '^| .gh pr list --state closed' '$CMD'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
