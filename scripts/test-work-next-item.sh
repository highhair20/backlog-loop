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
# backlog-loop.sh ends a drained run on the marker report-drained.sh writes, never on
# the session's words (#77 review of #80): Step 2 must run it before it stops.
check "Step 2 records a drained backlog with scripts/report-drained.sh before stopping" "printf '%s' \"\$step2\" | grep -q 'run .scripts/report-drained.sh.' && printf '%s' \"\$step2\" | grep -q 'not in a dry run'"
check "a PR Step 1.5 could not read keeps the run from recording drained" "printf '%s' \"\$step2\" | grep -q 'Step 1.5 read every PR' && printf '%s' \"\$step2\" | grep -q 'skipped one as unread'"
check "the driver no longer reads the session's words to decide it is drained" "! grep -q 'DRAINED_REPORT' '$ROOT/scripts/backlog-loop.sh'"

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
check "the retry comment naming earlier closed PRs follows the claim and the retire" "printf '%s' \"\$step3\" | grep -q 'Earlier PRs closed without merging' && [ \$(printf '%s\n' \"\$step3\" | grep -n 'gh issue comment.*Retrying this issue' | cut -d: -f1) -gt \$(printf '%s\n' \"\$step3\" | grep -n -m1 'add-label in-progress' | cut -d: -f1) ]"
check "a closed PR's url is matched whole, not as a prefix" "printf '%s' \"\$rejected_case\" | grep -q 'not a prefix'"
check "a rejection with no branch stashes a dirty tree" "printf '%s' \"\$rejected_case\" | grep -q 'stash the edits'"
check "the MCP table covers the closed-PR listing" "grep -q '^| .gh pr list --state closed' '$CMD'"

# --- The proposal gate and dry run (#13) ---
# shellcheck disable=SC2034  # read inside check's eval strings
gate="$(section 'Step 3.7')"
# shellcheck disable=SC2034  # read inside check's eval strings
dry="$(section 'Dry run')"
check "the contract table lists the Proposal gate section" "grep -q '^| .## Proposal gate. |' '$CMD'"
check "the command reads its arguments" "grep -q '\$ARGUMENTS' '$CMD'"
check "Step 2 skips no-auto-heal" "printf '%s' \"\$step2\" | grep -q 'no-auto-heal'"
check "Step 2 skips heal:proposed unless heal:approved" "printf '%s' \"\$step2\" | grep -q 'heal:proposed. unless it also has .heal:approved'"
s36="$(grep -n '^## Step 3.6' "$CMD" | cut -d: -f1)"
s37="$(grep -n '^## Step 3.7' "$CMD" | cut -d: -f1)"
s4="$(grep -n '^## Step 4' "$CMD" | cut -d: -f1)"
check "the proposal gate runs after Step 3.6 and before Step 4 branches" "[ -n '$s37' ] && [ '$s36' -lt '$s37' ] && [ '$s37' -lt '$s4' ]"
check "the gate is off unless CLAUDE.md turns it on" "printf '%s' \"\$gate\" | grep -q 'Gate: on'"
for part in 'Understanding' 'Root cause' 'Proposed solution' 'Scope delta'; do
  check "the proposal has a $part part" "printf '%s' \"\$gate\" | grep -q '\*\*$part'"
done
check "an empty scope delta is stated as none" "printf '%s' \"\$gate\" | grep -q 'none'"
check "a proposal releases the claim and marks heal:proposed" "printf '%s' \"\$gate\" | grep -q -- '--remove-label in-progress --add-label heal:proposed'"
check "a proposal stops before any branch or PR" "printf '%s' \"\$gate\" | grep -q 'no branch, no commits, no PR'"
check "heal:approved or the machine-filed label goes on to Step 4" "printf '%s' \"\$gate\" | grep -q 'heal:approved' && printf '%s' \"\$gate\" | grep -q 'Machine-filed label'"
check "under the gate, Steps 3.5 and 3.6 report in the proposal instead of editing the issue" "printf '%s' \"\$gate\" | grep -q 'do not edit the issue body'"
# shellcheck disable=SC2034  # read inside check's eval strings
step35="$(section 'Step 3.5')"
check "Step 3.5 itself holds off editing the issue when the gate will hold it" "printf '%s' \"\$step35\" | grep -q 'Step 3.7.s proposal gate will hold this issue' && printf '%s' \"\$step35\" | grep -q 'not edited, commented'"
# The skeleton must use the exact lines Step 3.7 reads.
TPL="$ROOT/templates/CLAUDE.md"
check "the CLAUDE.md skeleton has a Proposal gate section, off by default" "grep -q '^## Proposal gate\$' '$TPL' && grep -q '^- Gate: off\$' '$TPL'"
check "the skeleton's machine-filed line is the one Step 3.7 reads" "grep -q '^- Machine-filed label: ' '$TPL' && printf '%s' \"\$gate\" | grep -q 'Machine-filed label:'"
# Silent-failure review of #13: an unreadable gate fails closed, and a failed label
# edit cannot loop into a fresh proposal every run.
# Read before Step 0, so a bad setting stops the run before Step 3 claims (#53 review).
# shellcheck disable=SC2034  # read inside check's eval strings
pre0="$(awk '/^## Step 0/{ exit } { print }' "$CMD")"
check "an unreadable gate setting stops the run before anything is claimed" "printf '%s' \"\$pre0\" | grep -q 'ignoring' && printf '%s' \"\$pre0\" | grep -q 'setting is unreadable'"
check "a dry run decides later steps as if its would-be writes had happened" "printf '%s' \"\$dry\" | grep -q 'as if each would-be write had happened'"
check "the dry run's write list is a rule, not a closed list" "printf '%s' \"\$dry\" | grep -q 'not the whole rule'"
check "a failed proposal label edit marks the issue needs-attention" "printf '%s' \"\$gate\" | grep -q 'Check both results' && printf '%s' \"\$gate\" | grep -q -- '--remove-label in-progress --add-label needs-attention'"
check "--dry-run is recognised" "printf '%s' \"\$dry\" | grep -q -- '--dry-run'"
for w in 'gh issue comment' 'gh issue edit' 'gh issue close' 'gh pr create' 'git add' 'git push' 'git commit' 'git switch -c' 'git stash' 'branch -D' 'Edit' 'Write'; do
  check "a dry run never runs $w" "printf '%s' \"\$dry\" | grep -q -- '$w'"
done
check "a dry run reports its selection and intended action" "printf '%s' \"\$dry\" | grep -q 'DRY RUN' && printf '%s' \"\$dry\" | grep -q 'would'"
check "a dry run shows the proposal it would post" "printf '%s' \"\$dry\" | grep -q 'full text of the proposal'"
check "the dry run rules come before Step 0" "[ \$(grep -n '^## Dry run' '$CMD' | cut -d: -f1) -lt \$(grep -n '^## Step 0' '$CMD' | cut -d: -f1) ]"

# --- A retry retires a leftover branch before claiming (#55) ---
retire="$(printf '%s\n' "$step3" | grep -n -m1 'Retire a leftover branch' | cut -d: -f1)"
claim="$(printf '%s\n' "$step3" | grep -n -m1 'add-label in-progress' | cut -d: -f1)"
# Since #57, a run claims and labels first (a slow label would outlast the race
# window), then retires leftover branches; only the race winner reaches the retire.
check "Step 3 retires a leftover branch only after it has claimed" "[ -n '$retire' ] && [ -n '$claim' ] && [ '$claim' -lt '$retire' ]"
check "it never treats an abandoned/ branch as leftover" "printf '%s' \"\$step3\" | grep -q 'never .abandoned/'"
check "it saves before deleting, through Give up's steps" "printf '%s' \"\$step3\" | grep -q 'Give up\*\* steps 2, 4 and 5'"
check "a failed retire releases the claim and marks the issue for a human" "printf '%s' \"\$step3\" | grep -q 'release the claim' && printf '%s' \"\$step3\" | grep -q 'add-label needs-attention'"
check "a branch with an open PR is never retired" "printf '%s' \"\$step3\" | grep -q 'open PR' && printf '%s' \"\$step3\" | grep -q 'add-label in-review'"
check "every leftover branch name is retired, not just one" "printf '%s' \"\$step3\" | grep -q 'for every leftover branch'"
check "a failed local delete or switch also stops the claim" "printf '%s' \"\$step3\" | grep -q 'step 5.s'"
check "the claim names saved branches no comment mentions yet" "printf '%s' \"\$step3\" | grep -q 'abandoned/<number>-…. branch on the remote that no'"
check "the success path is marked apart from the failure stop" "printf '%s' \"\$step3\" | grep -q '^Otherwise, once every leftover branch is retired'"
check "a branch with no commits is reported as deleted, not saved" "printf '%s' \"\$step3\" | grep -q 'no commits to keep'"
check "the claim comment says where the old branch went" "printf '%s' \"\$step3\" | grep -q 'saved as abandoned/'"
# --- A refused tool call ends in Give up, never a request for approval (#54) ---
# shellcheck disable=SC2034  # read inside check's eval strings
guard="$(section 'Hard guardrails')"
# shellcheck disable=SC2034  # read inside check's eval strings
step36="$(section 'Step 3.6')"
check "a call the permission settings refuse is a blocker that goes to Give up" "printf '%s' \"\$guard\" | grep -q 'refused by the permission settings' && printf '%s' \"\$guard\" | grep -q 'follow \*\*Give up\*\*'"
check "a refusal with a permitted way round it is not a blocker" "printf '%s' \"\$guard\" | grep -q 'only when no' && printf '%s' \"\$guard\" | grep -q 'dedicated tool instead of a shell'"
check "only Steps 3 to 3.7 skip straight to Give up's step 3; Step 0 saves its branch" "printf '%s' \"\$guard\" | grep -q 'In Steps 3 to 3.7 the issue has no branch' && printf '%s' \"\$guard\" | grep -q 'Give up in full'"
check "the run never ends its turn asking for approval" "printf '%s' \"\$guard\" | grep -q 'never end the turn'"
check "the Give up comment names what was refused" "printf '%s' \"\$guard\" | grep -q 'refused command or path in its comment'"
check "a human declining a prompt is not treated as a blocker" "printf '%s' \"\$guard\" | grep -q 'a human declining'"
check "Step 3.6 flags paths a headless run cannot edit" "printf '%s' \"\$step36\" | grep -q '\*\*5\. ' && printf '%s' \"\$step36\" | grep -q '\.claude/'"
check "Step 5 makes the at-risk edit first, so a refusal costs nothing" "printf '%s' \"\$step5\" | grep -q 'first edit'"
check "Give up lists a refused tool call among the ways in" "printf '%s' \"\$give_up\" | grep -q 'refused tool call'"
check "BACKLOG.md says .claude/ issues are better no-auto-heal" "grep -q 'no-auto-heal' '$ROOT/docs/BACKLOG.md' && grep -q 'cannot edit .\.claude/' '$ROOT/docs/BACKLOG.md'"

# --- A refusal every issue would hit stops the run instead of giving up (#60) ---
check "a refused Verify or standard command is a setup problem" "printf '%s' \"\$guard\" | grep -q 'setup problem' && printf '%s' \"\$guard\" | grep -q '## Verify'"
check "a setup problem does not follow Give up" "printf '%s' \"\$guard\" | grep -q 'follow Give up: stop and report'"
check "a setup problem names the allow rule it needs" "printf '%s' \"\$guard\" | grep -q 'allow rule'"
check "a setup problem keeps the claim, so the driver halts on no progress" "printf '%s' \"\$guard\" | grep -q 'claim and commit any work to the issue'"
check "only Steps 3 to 3.7 release the claim on a setup problem" "printf '%s' \"\$guard\" | grep -q 'If the refusal came in Steps 3 to 3.7'"
check "a command only this issue needs is not a setup problem" "printf '%s' \"\$guard\" | grep -q 'A command only this'"
check "Give up's opening keeps setup problems out" "printf '%s' \"\$give_up\" | grep -q 'a setup problem never comes here'"
check "a setup problem covers every command an iteration runs, helpers included" "printf '%s' \"\$guard\" | grep -q '.claude/hooks/. helper'"
check "a setup problem with no branch releases the claim" "printf '%s' \"\$guard\" | grep -q 'release the claim instead'"
# A headless session that ends its turn to wait for a background command ends the
# session, leaving the work unsaved (#84: run-tests.sh took 121s, past the Bash
# tool's 120s default, so it was moved to the background).
# Matched on the section with its lines joined, so the checks pin whole sentences
# rather than where a line happens to wrap.
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
# shellcheck disable=SC2034  # read inside check's eval strings
guard_flat="$(flat "$guard")"
# shellcheck disable=SC2034  # read inside check's eval strings
step5_flat="$(flat "$step5")"
check "the guardrails say to run long commands in the foreground with a raised timeout" "printf '%s' \"\$guard_flat\" | grep -q 'Run Verify and other long commands in the foreground, with the Bash tool.s timeout raised.. (up to 600000 ms, ten minutes)'"
check "the guardrails forbid ending the turn while a started command still runs, and say why" "printf '%s' \"\$guard_flat\" | grep -q 'Never end your turn while a command you started is still running:.. in a headless run' && printf '%s' \"\$guard_flat\" | grep -q 'ending the turn ends the session'"
check "a command over ten minutes is split, never backgrounded; unsplittable Verify stops, one issue's gives up" "printf '%s' \"\$guard_flat\" | grep -q 'Never run one with .run_in_background.' && printf '%s' \"\$guard_flat\" | grep -q 'longer than ten minutes, split it into parts that each finish within one call. If it cannot be split: a .## Verify. command would stop every issue, so stop and report' && printf '%s' \"\$guard_flat\" | grep -q 'a command only this issue needs is the issue.s blocker, so follow .*Give up'"
check "Step 5's gate repeats the timeout and the no-ending rule where Verify runs" "printf '%s' \"\$step5_flat\" | grep -q 'raise the Bash tool.s timeout (up to 600000 ms)' && printf '%s' \"\$step5_flat\" | grep -q 'never end the turn to wait for one'"
check "a refusal specific to the issue still follows Give up" "printf '%s' \"\$guard\" | grep -qi 'specific to this issue'"

# --- The loop follows up on its own open PRs before new work (#70) ---
# shellcheck disable=SC2034  # read inside check's eval strings
follow="$(section 'Step 1.5')"
s1="$(grep -n '^## Step 1 ' "$CMD" | cut -d: -f1)"
s15="$(grep -n '^## Step 1.5' "$CMD" | cut -d: -f1)"
s2="$(grep -n '^## Step 2' "$CMD" | cut -d: -f1)"
check "Step 1.5 runs after Step 1 and before Step 2" "[ -n '$s15' ] && [ '$s1' -lt '$s15' ] && [ '$s15' -lt '$s2' ]"
check "it takes the oldest PR that needs attention" "printf '%s' \"\$follow\" | grep -q 'oldest'"
for trigger in 'changes-requested' 'gh pr checks' 'CONFLICTING'; do
  check "a PR qualifies on $trigger" "printf '%s' \"\$follow\" | grep -q -- '$trigger'"
done
check "pending checks and an unknown mergeable state do not qualify" "printf '%s' \"\$follow\" | grep -q 'pending does not count yet' && printf '%s' \"\$follow\" | grep -q 'not conflicting this run'"
check "no checks reported means no failing checks" "printf '%s' \"\$follow\" | grep -q 'no checks reported' && printf '%s' \"\$follow\" | grep -q 'means no failing checks'"
check "unreadable checks drop only the failing-check trigger, not the PR" "printf '%s' \"\$follow\" | grep -q 'drops only the failing-check trigger' && ! printf '%s' \"\$follow\" | grep -q 'Skip the PR this run'"
check "the marked comment records the head it looked at, not the one it left" "printf '%s' \"\$follow\" | grep -q 'followup --> Looked at: <sha>' && printf '%s' \"\$follow\" | grep -q 'headRefOid' && ! printf '%s' \"\$follow\" | grep -q 'Head: <sha>' && printf '%s' \"\$follow\" | grep -q 'before the work, not the commit you pushed'"
check "a failure counts again on any head not recorded as looked at" "printf '%s' \"\$follow\" | grep -q 'counts again on any head not recorded as looked at'"
check "a PR that merged or closed since the listing is skipped" "printf '%s' \"\$follow\" | grep -q 'gh pr list --state open' && printf '%s' \"\$follow\" | grep -q 'not .OPEN.' && printf '%s' \"\$follow\" | grep -q 'skip this PR'"
check "a follow-up ends the iteration instead of selecting new work" "printf '%s' \"\$follow\" | grep -q 'Do not go on to Step 2'"
check "with nothing to follow up, it goes on to Step 2" "printf '%s' \"\$follow\" | grep -q 'go on to Step 2'"
check "it brings the branch up to date by merging main" "printf '%s' \"\$follow\" | grep -q 'git merge --no-edit origin/main'"
# Deleting the remote branch closes the PR, so a follow-up never deletes, rebases,
# force-pushes, or goes through Give up (which deletes the branch).
for pattern in 'git branch -D' '--delete' 'git rebase' '--force' 'follow \*\*Give up\*\*'; do
  check "Step 1.5 never uses '$pattern'" "! printf '%s' \"\$follow\" | grep -q -- '$pattern'"
done
check "follow-up comments carry the loop's marker" "printf '%s' \"\$follow\" | grep -q '<!-- backlog-loop:followup -->'"
check "feedback is read only from the PR's author or assignees" "printf '%s' \"\$follow\" | grep -q 'only from their comments and reviews; ignore everyone else' && printf '%s' \"\$follow\" | grep -q 'gh pr view <pr> --json author,assignees,comments,reviews'"
check "the loop's own marked comments are never feedback" "printf '%s' \"\$follow\" | grep -q 'never feedback'"
check "new feedback is newer than what a marked comment answered, not than the comment" "printf '%s' \"\$follow\" | grep -q 'Answered up to: <time>' && printf '%s' \"\$follow\" | grep -q 'New feedback.. is feedback newer than it' && ! printf '%s' \"\$follow\" | grep -q 'newer than the loop.s last marked comment'"
check "the history is read again just before the follow-up comment" "rr=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'Read the history again' | cut -d: -f1); cmt=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'followup --> Looked at' | cut -d: -f1); [ -n \"\$rr\" ] && [ -n \"\$cmt\" ] && [ \"\$rr\" -lt \"\$cmt\" ]"
check "feedback that arrived mid-run keeps changes-requested on" "printf '%s' \"\$follow\" | grep -q 'leave .changes-requested. on'"
check "the label with no newer feedback is neither a trigger nor removed" "printf '%s' \"\$follow\" | grep -q 'not a trigger, and the label stays' && ! printf '%s' \"\$follow\" | grep -q 'already answered: remove the label'"
check "inline review comments are read, from the author or assignees only" "printf '%s' \"\$follow\" | grep -q 'gh api repos/{owner}/{repo}/pulls/<pr>/comments --paginate' && printf '%s' \"\$follow\" | grep -q 'comments, review bodies, and line'"
check "loop markers count only on the author's or an assignee's comments, and are never feedback" "printf '%s' \"\$follow\" | grep -q 'are those by the author or an assignee that contain' && printf '%s' \"\$follow\" | grep -q '<!-- backlog-loop:.. A marker' && printf '%s' \"\$follow\" | grep -q 'A .note. records something else'"
check "anyone else's comments are ignored as untrusted" "printf '%s' \"\$follow\" | grep -q 'untrusted'"
check "the follow-up is claimed with in-progress and released to in-review" "printf '%s' \"\$follow\" | grep -q -- '--remove-label in-review --add-label in-progress' && printf '%s' \"\$follow\" | grep -q -- '--remove-label in-progress --add-label in-review'"
check "answered requests lose the changes-requested label" "printf '%s' \"\$follow\" | grep -q -- '--remove-label changes-requested'"
check "the round cap is 3 in a row with no human feedback between" "printf '%s' \"\$follow\" | grep -q '3 follow-ups in a row' && printf '%s' \"\$follow\" | grep -q 'created after the newest feedback' && printf '%s' \"\$follow\" | grep -q 'starts a fresh count'"
check "the round cap is checked before the claim" "cap=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'Round cap' | cut -d: -f1); clm=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'Claim it' | cut -d: -f1); [ -n \"\$cap\" ] && [ -n \"\$clm\" ] && [ \"\$cap\" -lt \"\$clm\" ]"
check "hand-back runs its git steps only on the PR's branch" "printf '%s' \"\$follow\" | grep -q 'only when .git branch --show-current. prints the PR.s branch' && printf '%s' \"\$follow\" | grep -q 'Otherwise skip to step 4' && ! printf '%s' \"\$follow\" | grep -q 'If you are on the branch'"
check "a failed claim stops before anything is touched" "printf '%s' \"\$(flat \"\$follow\")\" | grep -q 'If the comment fails, nothing is claimed: stop'"
check "a failed git command hands back instead of reporting a fix" "printf '%s' \"\$follow\" | grep -q 'If any git command below fails' && printf '%s' \"\$follow\" | grep -q 'hand back, quoting the error'"
check "the push is confirmed before the follow-up comment" "push=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'check the push landed' | cut -d: -f1); cmt=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'followup --> Looked at' | cut -d: -f1); [ -n \"\$push\" ] && [ -n \"\$cmt\" ] && [ \"\$push\" -lt \"\$cmt\" ]"
check "a follow-up comment that fails marks the issue for a human" "printf '%s' \"\$follow\" | grep -q 'only record, so check it'"
check "the hand-back comment records what it looked at and answered" "printf '%s' \"\$follow\" | grep -q 'followup --> Looked at: <sha>. Answered up to: <time>. Handing this back' && printf '%s' \"\$follow\" | grep -q 'newest feedback this follow-up actually answered, or the'"
check "each PR's history is read before it is judged" "hist=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'Read its history' | cut -d: -f1); needs=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'needs attention.. if any of' | cut -d: -f1); [ -n \"\$hist\" ] && [ -n \"\$needs\" ] && [ \"\$hist\" -lt \"\$needs\" ]"
check "the line-comment read is run as written, placeholders included (#78)" "printf '%s' \"\$follow\" | grep -q 'Run the second exactly as written, .{owner}/{repo}. included'"
check "a history read that fails leaves the PR unjudged" "printf '%s' \"\$follow\" | grep -q 'If either command fails, the' && printf '%s' \"\$follow\" | grep -q 'PR is unread'"
check "a marker counts only on the author's or an assignee's comment" "printf '%s' \"\$follow\" | grep -q 'A marker on anyone else.s comment is ignored'"
check "rounds are the followup and note comments created after the newest feedback" "printf '%s' \"\$follow\" | grep -q 'and .note. comments created after the newest feedback' && printf '%s' \"\$follow\" | grep -q 'every one of them' && printf '%s' \"\$follow\" | grep -q '^creation time, not by .Answered up to.'"
check "an interrupted follow-up's note counts toward the cap" "printf '%s' \"\$follow\" | grep -q 'A .note. counts here because it marks a follow-up that was'"
check "a head is looked at only once its checks had finished" "printf '%s' \"\$follow\" | grep -q 'only if every check on it had finished' && printf '%s' \"\$follow\" | grep -q 'otherwise .none.: a check still pending'"
check "a followup comment from before the fields records no head and answers up to its own time" "printf '%s' \"\$follow\" | grep -q 'records no head, and its own .createdAt. as its .Answered up to.'"
check "feedback times come from each kind's own field" "printf '%s' \"\$follow\" | grep -q 'createdAt' && printf '%s' \"\$follow\" | grep -q 'submittedAt' && printf '%s' \"\$follow\" | grep -q 'created_at'"
check "a failed re-read keeps changes-requested on" "printf '%s' \"\$follow\" | grep -q 'or the re-read fails, leave .changes-requested. on'"
check "a round that answers nothing new carries the answered mark forward" "printf '%s' \"\$follow\" | grep -q 'the answered mark it started from carried forward' && printf '%s' \"\$follow\" | grep -q 'round fixing CI alone still counts'"
check "a hand-back tells the maintainer to add changes-requested when requeuing" "printf '%s' \"\$follow\" | grep -q 'add changes-requested to this PR, then swap needs-attention for in-review'"
check "a hand-back whose comment fails still swaps the labels" "printf '%s' \"\$follow\" | grep -q 'If the comment fails, still swap the labels'"
check "at the cap the issue is handed back as needs-attention, keeping the PR" "printf '%s' \"\$follow\" | grep -q -- '--add-label needs-attention' && printf '%s' \"\$follow\" | grep -q 'PR stays open'"
check "a failed follow-up saves its work under abandoned/ before resetting the branch" "save=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'refs/heads/abandoned/' | cut -d: -f1); reset=\$(printf '%s\n' \"\$follow\" | grep -n -m1 'git branch -f' | cut -d: -f1); [ -n \"\$save\" ] && [ -n \"\$reset\" ] && [ \"\$save\" -lt \"\$reset\" ]"
check "a failing check's log is read before changing code" "printf '%s' \"\$follow\" | grep -q 'gh run view .* --log-failed'"
check "a failure that is not the PR's is reported, not fixed" "printf '%s' \"\$follow\" | grep -q 'also fails on .main.'"
check "a follow-up runs the Verify gate and the specialist reviewers" "printf '%s' \"\$follow\" | grep -q 'Step 5' && printf '%s' \"\$follow\" | grep -q 'Step 6.5'"
# An interrupted follow-up's edits are unverified: saved beside the PR, never pushed into it (#75).
# shellcheck disable=SC2034  # read inside check's eval strings
case1="$(printf '%s\n' "$step0" | awk '/^1\. \*\*An open PR already exists/{ on = 1 } /^2\. /{ on = 0 } on')"
check "Step 0 finishes an interrupted follow-up before swapping the label back" "printf '%s' \"\$case1\" | grep -q 'interrupted follow-up'"
check "an interrupted follow-up's work is saved under abandoned/" "printf '%s' \"\$case1\" | grep -q 'refs/heads/abandoned/'"
check "an interrupted follow-up's work is never pushed to the PR branch" "[ \"\$(printf '%s' \"\$case1\" | grep -c 'git push')\" -ge 1 ] && [ \"\$(printf '%s' \"\$case1\" | grep 'git push' | grep -vc 'refs/heads/abandoned/')\" = 0 ]"
check "it saves and resets through Hand back when checked out" "printf '%s' \"\$case1\" | grep -q 'If the branch is checked out here' && printf '%s' \"\$case1\" | grep -q 'Hand back.. steps 1 to 3'"
check "it saves and resets a local branch that is not checked out" "printf '%s' \"\$case1\" | grep -q 'whether or not the branch is checked out' && printf '%s' \"\$case1\" | grep -q 'git branch -f <type>/'"
check "a failed save marks the issue for a human instead of stalling every run" "printf '%s' \"\$case1\" | grep -q 'If a save fails, delete and reset nothing' && printf '%s' \"\$case1\" | grep -q -- '--remove-label in-progress --add-label needs-attention'"
check "a failed note still goes on and is printed" "printf '%s' \"\$case1\" | grep -q 'If that comment fails, still go on'"
check "Step 0 always posts a note, and the note counts as a round" "printf '%s' \"\$case1\" | grep -q '<!-- backlog-loop:note -->' && printf '%s' \"\$case1\" | grep -q 'whether or not anything was saved' && printf '%s' \"\$case1\" | grep -q 'but it counts as a round' && ! printf '%s' \"\$case1\" | grep -q 'nor a round'"
check "a follow-up records none unless it read every check finished" "printf '%s' \"\$follow\" | grep -q 'none. unless its checks were read and'"
check "a dry run reports a follow-up it would make" "printf '%s' \"\$dry\" | grep -q 'follow up PR #N'"
check "a dry run stops at a follow-up before any write" "printf '%s' \"\$dry\" | grep -q 'Step 1.5 follow-up' && printf '%s' \"\$dry\" | grep -q 'gh pr comment, gh pr edit and gh pr update-branch'"
for doc in README.md docs/BACKLOG.md docs/ROUTINE.md; do
  check "$doc describes follow-ups" "grep -q 'changes-requested' '$ROOT/$doc'"
done
check "changes-requested is a seeded label" "grep -q '\"changes-requested|' '$ROOT/scripts/seed-labels.sh'"
# shellcheck disable=SC2034  # read inside check's eval strings
follow_flat="$(flat "$follow")"
check "Step 1.5's Verify step points at the same rule" "printf '%s' \"\$follow_flat\" | grep -q 'must pass, run in the foreground, as Step 5 says'"
# --- Ready to merge (#88) ---
# shellcheck disable=SC2034  # read inside check's eval strings
step8_flat="$(flat "$(section 'Step 8')")"
check "Step 8 swaps to in-review only once the review loop has closed" "printf '%s' \"\$step8_flat\" | grep -q 'only once the review loop the hooks opened for this PR has closed'"
check "a review loop that hit its cap unresolved marks the issue needs-attention, not ready" "printf '%s' \"\$step8_flat\" | grep -q 'hit its round cap with blocking findings still open' && printf '%s' \"\$step8_flat\" | grep -q -- '--add-label needs-attention'"
check "Step 1.5 lists each PR's merge state" "printf '%s' \"\$follow\" | grep -q 'gh pr list --state open --limit 1000 --json number,headRefName,url,mergeable,mergeStateStatus,labels'"
check "Step 1.5 brings a PR that is only behind up to date, by merge, without a round" "printf '%s' \"\$follow_flat\" | grep -q 'gh pr update-branch <pr>' && printf '%s' \"\$follow_flat\" | grep -q 'never a rebase' && printf '%s' \"\$follow_flat\" | grep -q 'not a follow-up: no claim, no comment, no round'"
check "a dry run never updates a branch, and reports it as a would-be write" "printf '%s' \"\$dry\" | grep -q 'gh pr update-branch' && printf '%s' \"\$follow_flat\" | grep -q 'In a dry run, note .would: gh pr update-branch <pr>. instead'"
check "ready-to-merge is a seeded label" "grep -q '\"ready-to-merge|' '$ROOT/scripts/seed-labels.sh'"
# --- Claims a live run holds are left alone (#57) ---
# shellcheck disable=SC2034  # read inside check's eval strings
step0_flat="$(flat "$step0")"
# shellcheck disable=SC2034  # read inside check's eval strings
step3_flat="$(flat "$step3")"
# shellcheck disable=SC2034  # read inside check's eval strings
pre0_flat="$(flat "$pre0")"
# shellcheck disable=SC2034  # read inside check's eval strings
dry_flat="$(flat "$dry")"
check "a claim is a marked comment naming the run and the time" "printf '%s' \"\$step3_flat\" | grep -q 'backlog-loop:claim run=<run-id> at=<time>'"
check "a follow-up claims with the same comment" "printf '%s' \"\$follow_flat\" | grep -q 'backlog-loop:claim run=<run-id>'"
check "the run ID and the clone ID are set once, before Step 0" "printf '%s' \"\$pre0_flat\" | grep -q 'run ID' && printf '%s' \"\$pre0_flat\" | grep -q 'clone ID' && printf '%s' \"\$pre0_flat\" | grep -q 'hostname' && printf '%s' \"\$pre0_flat\" | grep -q 'git rev-parse --show-toplevel'"
check "the current time comes from one exact command" "printf '%s' \"\$pre0_flat\" | grep -q 'date -u +%Y-%m-%dT%H:%M:%SZ'"
check "Step 0 leaves a claim younger than 3 hours alone and reports it" "printf '%s' \"\$step0_flat\" | grep -q 'younger than 3 hours' && printf '%s' \"\$step0_flat\" | grep -q 'leave it alone' && printf '%s' \"\$step0_flat\" | grep -q 'name it in the report'"
check "a claim's age is its comment's GitHub time, never a PR's update time" "printf '%s' \"\$step0_flat\" | grep -q 'comment.s .createdAt.' && ! printf '%s' \"\$step0_flat\" | grep -q 'PR was updated within'"
check "the lease is the same figure in Step 0 and ROUTINE.md" "a=\$(printf '%s' \"\$step0_flat\" | grep -oE 'younger than [0-9]+ hours' | grep -oE '[0-9]+' | sort -u); b=\$(grep -oE '[a-z]+ hours' '$ROOT/docs/ROUTINE.md' | sort -u); [ \"\$a\" = 3 ] && [ \"\$b\" = 'three hours' ]"
check "every claim template carries run=, at= and clone=, and none carries driver=" "[ \$(grep -c 'backlog-loop:claim run=<run-id> at=<time> clone=' '$CMD') -ge 2 ] && ! grep 'backlog-loop:claim run=' '$CMD' | grep -v 'clone=' | grep -q . && ! grep -q 'driver=' '$CMD'"
check "a rival is another runner's claim posted after you listed, or under a minute before" "printf '%s' \"\$step3_flat\" | grep -q 'posted after you listed the issues in Step 2, or less than a minute before'"
check "your own clone's claims are never rivals" "printf '%s' \"\$step3_flat\" | grep -q 'not your own clone' && printf '%s' \"\$step3_flat\" | grep -q 'its claims are never rivals'"
check "Step 2 and Step 1.5 note the time they list" "printf '%s' \"\$(flat \"\$step2\")\" | grep -q 'Note the time now' && printf '%s' \"\$follow_flat\" | grep -q 'Note the time now'"
check "Step 3 labels right after winning the race, then retires branches" "c=\$(printf '%s\n' \"\$step3\" | grep -n -m1 'If a rival came first' | cut -d: -f1); l=\$(printf '%s\n' \"\$step3\" | grep -n -m1 'add-label in-progress' | cut -d: -f1); r=\$(printf '%s\n' \"\$step3\" | grep -n -m1 'Retire a leftover branch' | cut -d: -f1); [ -n \"\$c\" ] && [ -n \"\$l\" ] && [ -n \"\$r\" ] && [ \"\$c\" -lt \"\$l\" ] && [ \"\$l\" -lt \"\$r\" ]"
check "a failed retire releases the claim it already labelled" "printf '%s' \"\$step3_flat\" | grep -q -- '--remove-label in-progress --add-label needs-attention'"
check "Step 3's own-clone exemption needs two real IDs" "printf '%s' \"\$step3_flat\" | grep -q 'both are real clone IDs, not .none.'"
check "Step 0's race-winner window is the same minute as Step 3's" "printf '%s' \"\$step0_flat\" | grep -q 'less than a minute before it' && ! printf '%s' \"\$step0_flat\" | grep -q 'less than 10 minutes before it'"
check "a failed date in Steps 2 and 1.5 stops before claiming" "printf '%s' \"\$(flat \"\$step2\")\" | grep -q 'If .date. fails, stop before claiming' && printf '%s' \"\$follow_flat\" | grep -q 'if .date. fails, stop before claiming'"
check "the race is ordered by GitHub's time, ties to the smaller run ID" "printf '%s' \"\$step3_flat\" | grep -q 'by .createdAt.' && printf '%s' \"\$step3_flat\" | grep -q 'smaller .run=.'"
check "the loser has touched no label or branch, and writes nothing more" "printf '%s' \"\$step3_flat\" | grep -q 'write nothing more, touch no label or branch'"
check "a failed re-read stops and leaves the claim to expire" "printf '%s' \"\$step3_flat\" | grep -q 'If the re-read fails'"
check "the claim comment is posted before the label" "c=\$(printf '%s\n' \"\$step3\" | grep -n -m1 'backlog-loop:claim run=' | cut -d: -f1); l=\$(printf '%s\n' \"\$step3\" | grep -n -m1 'add-label in-progress' | cut -d: -f1); [ -n \"\$c\" ] && [ -n \"\$l\" ] && [ \"\$c\" -lt \"\$l\" ]"
check "a follow-up that loses a race looks at the next PR" "printf '%s' \"\$follow_flat\" | grep -q 'as you found it, and look at the next PR'"
check "the same-clone rule needs two real clone IDs, never none" "printf '%s' \"\$step0_flat\" | grep -q 'both are real clone IDs, not .none.'"
check "a resume posts a fresh claim and runs the race check before resuming" "printf '%s' \"\$step0_flat\" | grep -q 'Before resuming, claim it afresh'"
check "the holding claim is the race winner, not the newest comment" "printf '%s' \"\$step0_flat\" | grep -q 'won its race and holds the issue'"
check "a follow-up that loses backs off before its label edit, leaving in-review" "printf '%s' \"\$follow_flat\" | grep -q 'back off before the label edit, so the issue stays .in-review.' && ! printf '%s' \"\$follow_flat\" | grep -q 'earlier live claim'"
check "a follow-up's failed claim comment and failed label edit are both handled" "printf '%s' \"\$follow_flat\" | grep -q 'If the comment fails, nothing is claimed' && printf '%s' \"\$follow_flat\" | grep -q 'If the label edit fails, stop and report' && ! printf '%s' \"\$follow_flat\" | grep -q 'nothing has been touched yet'"
check "Step 0 resumes at most one item, consistently" "printf '%s' \"\$step0_flat\" | grep -q 'Resume at most one item, the lowest-numbered' && ! printf '%s' \"\$step0_flat\" | grep -q 'only once no resumable'"
check "with several stale issues, only the lowest-numbered one is resumed" "printf '%s' \"\$step0_flat\" | grep -q 'resume only the lowest-numbered'"
check "if the time cannot be read, every claim is treated as live" "printf '%s' \"\$step0_flat\" | grep -q 'If .date. fails'"
check "a claim from this same clone is dead at once, once the lock check passed" "printf '%s' \"\$step0_flat\" | grep -q 'same clone ID as yours' && printf '%s' \"\$step0_flat\" | grep -q 'lock check' && printf '%s' \"\$step0_flat\" | grep -q 'recover it now'"
check "a claim with no claim comment is stale, as before" "printf '%s' \"\$step0_flat\" | grep -q 'no claim comment at all.*it is stale'"
check "Step 0 handles every in-progress issue, not just one" "! printf '%s' \"\$step0_flat\" | grep -q 'There should be at most one' && printf '%s' \"\$step0_flat\" | grep -q 'For each .in-progress. issue'"
check "a claim race goes to the earliest live claim, and the loser backs off" "printf '%s' \"\$step3_flat\" | grep -q 'If a rival came first, back off'"
check "a dry run reports live and stale claims" "printf '%s' \"\$dry_flat\" | grep -q 'Claims: '"
check "ROUTINE.md no longer requires one runner per repository" "! grep -q 'One runner per repository' '$ROOT/docs/ROUTINE.md' && grep -q 'claim' '$ROOT/docs/ROUTINE.md'"

for row in 'gh pr checks|mcp__github__pull_request_read' 'gh pr view N --json|mcp__github__pull_request_read' 'gh run view|mcp__github__get_job_logs' 'gh pr comment|mcp__github__add_issue_comment' 'gh pr edit|mcp__github__issue_write' 'gh pr update-branch|mcp__github__update_pull_request_branch' 'gh api repos/{owner}/{repo}/pulls|mcp__github__pull_request_read' 'gh api repos/{owner}/{repo}/pulls|get_review_comments'; do
  check "the MCP table maps ${row%%|*} to ${row#*|}" "grep '^| .${row%%|*}' '$CMD' | grep -q -- '${row#*|}'"
done

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
