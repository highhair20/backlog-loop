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
check "a resumed branch is first brought up to its own pushed copy" "printf '%s' \"\$step0\" | grep -q 'git pull --ff-only origin'"

# Give up must never commit a half-done merge: conflict markers would be saved as
# if they were work (#26 review).
check_line="$(line_of 'git diff --check')"
abort_line="$(line_of 'git merge --abort')"
commit_line="$(line_of 'git add -A')"
check "Give up checks for a half-done merge before committing" "[ -n '$check_line' ] && [ -n '$abort_line' ] && [ -n '$commit_line' ] && [ '$check_line' -lt '$commit_line' ] && [ '$abort_line' -lt '$commit_line' ]"

# Step 0 must not mistake a preserved branch for work in flight.
check "Step 0 always ignores abandoned/ branches" "section 'Step 0' | grep -q 'always ignore them'"
# An abandoned/ branch outlives its attempt, so it cannot signal an interrupted
# give-up: acting on it would delete a later retry's unsaved work (#24 review).
check "Step 0 never resumes a give-up from an abandoned/ branch" "! section 'Step 0' | grep -qi 'finish it from'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
