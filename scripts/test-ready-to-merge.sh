#!/usr/bin/env bash
# Tests for scripts/ready-to-merge.sh (#88), with a fake `gh` on PATH: it reads the
# fixture's prs.json, issues.json and comments-<n>.json, and logs every write.
# Usage: scripts/test-ready-to-merge.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# $1 = fixture name. Writes a fake gh that serves the fixture's JSON and logs writes.
setup() {
  local dir="$WORK/$1"
  mkdir -p "$dir/bin"
  echo '[]' >"$dir/issues.json"
  : >"$dir/writes"
  cat >"$dir/bin/gh" <<FAKE
#!/usr/bin/env bash
d="$dir"
case "\$*" in
  "pr list "*) [ -f "\$d/fail-pr-list" ] && exit 1
    case "\$*" in *statusCheckRollup*) [ -f "\$d/no-checks-permission" ] && { echo 'GraphQL: Resource not accessible by integration (repository.pullRequests.nodes.0.statusCheckRollup)' >&2; exit 1; } ;; esac
    k=\$(( \$(cat "\$d/lists" 2>/dev/null || echo 0) + 1 )); echo "\$k" >"\$d/lists"
    if [ -f "\$d/prs-\$k.json" ]; then f="\$d/prs-\$k.json"; else f="\$d/prs.json"; fi
    # Like gh, only the fields asked for: no checks unless statusCheckRollup is named.
    case "\$*" in *statusCheckRollup*) cat "\$f" ;; *) jq 'map(del(.statusCheckRollup))' "\$f" ;; esac ;;
  "api -X POST "*"/labels "*|"api -X DELETE "*"/labels/"*) echo "\$*" >>"\$d/writes" ;;
  "api repos/"*"/compare/"*) echo "\$2" >>"\$d/compares"; [ -f "\$d/fail-compare" ] && exit 1
    cat "\$d/behind" 2>/dev/null || echo 0 ;;
  "issue list "*) cat "\$d/issues.json" ;;
  # The re-read: the listed PR's head and labels, unless comments-<n>.json overrides them.
  "pr view "*" --json comments"*) n=\$3; [ -f "\$d/fail-view-\$n" ] && exit 1
    listed=\$(jq -c --argjson n "\$n" '[.[] | select(.number == \$n) | {headRefOid, labels}][0] // {}' "\$d/prs.json")
    file=\$(cat "\$d/comments-\$n.json" 2>/dev/null || echo '{"comments": []}')
    jq -n --argjson a "\$listed" --argjson b "\$file" '\$a + \$b' ;;
  "pr edit "*|"pr comment "*) echo "\$*" >>"\$d/writes" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$dir/bin/gh"
  echo "$dir"
}
# GITHUB_WORKFLOW is emptied: under Actions it names the workflow running these tests.
run() { PATH="$1/bin:$PATH" GH_REPO=o/r READY_RETRY_SECONDS=0 GITHUB_WORKFLOW='' "$HERE/ready-to-merge.sh" >"$1/out" 2>&1; }
DEFAULT_ASSIGNEES='[{"login": "maint"}]'
pr() { # pr <number> <branch> <mergeStateStatus> [labels...]; ASSIGNEES, CROSS, BASE and ROLLUP override
  local n="$1" ref="$2" st="$3" who="${ASSIGNEES-$DEFAULT_ASSIGNEES}"; shift 3
  printf '{"number": %s, "headRefName": "%s", "headRefOid": "abc123%s0000000000000000000000000000000", "baseRefName": "%s", "mergeStateStatus": "%s", "isCrossRepository": %s, "assignees": %s, "statusCheckRollup": %s, "labels": [%s]}' \
    "$n" "$ref" "$n" "${BASE:-main}" "$st" "${CROSS:-false}" "$who" "${ROLLUP:-[]}" "$(for l in "$@"; do printf '{"name": "%s"},' "$l"; done | sed 's/,$//')"
}
in_review='[{"number": 7, "labels": [{"name": "in-review"}]}]'

# A ready PR is labelled and the assignee told, once.
A="$(setup ready)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$A/prs.json"; echo "$in_review" >"$A/issues.json"
run "$A"; rc=$?
check "a ready loop PR gets the ready-to-merge label" "[ $rc -eq 0 ] && grep -q 'api -X POST repos/o/r/issues/20/labels' '$A/writes'"
check "and one comment that mentions the assignee and the head" "grep -q 'pr comment 20' '$A/writes' && grep -q '@maint' '$A/writes' && grep -q 'backlog-loop:ready abc12320' '$A/writes'"

# Already labelled and already told about this head: nothing is written.
B="$(setup already)"
echo "[$(pr 20 feat/7-x CLEAN ready-to-merge)]" >"$B/prs.json"; echo "$in_review" >"$B/issues.json"
echo '{"comments": [{"body": "<!-- backlog-loop:ready abc123200000000000000000000000000000000 --> ready"}]}' >"$B/comments-20.json"
run "$B"; rc=$?
check "the same head is never announced twice" "[ $rc -eq 0 ] && [ ! -s '$B/writes' ]"

# A new head on a ready PR is announced again.
C="$(setup newhead)"
echo "[$(pr 20 feat/7-x CLEAN ready-to-merge)]" >"$C/prs.json"; echo "$in_review" >"$C/issues.json"
echo '{"comments": [{"body": "<!-- backlog-loop:ready 0000000000000000000000000000000000000000 --> ready"}]}' >"$C/comments-20.json"
run "$C"
check "a new head on a ready PR is announced again" "grep -q 'pr comment 20' '$C/writes' && ! grep -q 'X POST' '$C/writes'"

# A labelled PR that is no longer ready loses the label, and so does one whose merge
# state is still UNKNOWN after the retries: it is never kept on a state not read (#110).
D="$(setup notready)"
echo "[$(pr 20 feat/7-x BEHIND ready-to-merge), $(pr 21 fix/8-y UNKNOWN ready-to-merge)]" >"$D/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$D/issues.json"
run "$D"; rc=$?
check "a PR that stops being ready loses the label" "grep -q 'api -X DELETE repos/o/r/issues/20/labels/ready-to-merge' '$D/writes'"
check "a merge state still UNKNOWN after the retries loses the label, with a note" "[ $rc -eq 0 ] && [ \$(cat '$D/lists') -eq 3 ] && grep -q 'api -X DELETE repos/o/r/issues/21/labels/ready-to-merge' '$D/writes' && grep -q '#21.*still UNKNOWN' '$D/out'"
check "and is never labelled or announced" "! grep -q 'X POST repos/o/r/issues/21' '$D/writes' && ! grep -q 'pr comment 21' '$D/writes'"
# A later run that reads it CLEAN adds the label back.
echo "[$(pr 21 fix/8-y CLEAN)]" >"$D/prs.json"; : >"$D/writes"; rm -f "$D/lists"
run "$D"
check "a later run adds the label back once the state reads CLEAN" "grep -q 'api -X POST repos/o/r/issues/21/labels' '$D/writes' && grep -q 'pr comment 21' '$D/writes'"

# The announcement says "up to date" only when the compare API shows the branch is not
# behind its base; GitHub reads CLEAN on a behind branch without a strict ruleset (#110).
U="$(setup uptodate)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$U/prs.json"; echo "$in_review" >"$U/issues.json"; echo 0 >"$U/behind"
run "$U"; rc=$?
check "a branch not behind its base is announced as up to date" "[ $rc -eq 0 ] && grep -q 'up to date with main' '$U/writes' && grep -qx 'repos/o/r/compare/main...abc123200000000000000000000000000000000' '$U/compares'"
V="$(setup behind)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$V/prs.json"; echo "$in_review" >"$V/issues.json"; echo 3 >"$V/behind"
run "$V"; rc=$?
check "a CLEAN branch behind its base is announced without 'up to date'" "[ $rc -eq 0 ] && grep -q 'pr comment 20' '$V/writes' && grep -q 'required checks pass' '$V/writes' && ! grep -q 'up to date' '$V/writes'"
W="$(setup comparefail)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$W/prs.json"; echo "$in_review" >"$W/issues.json"; : >"$W/fail-compare"
run "$W"; rc=$?
check "a failed compare is reported and holds the announcement back for a later run" "[ $rc -ne 0 ] && grep -q 'could not compare #20' '$W/out' && grep -q 'X POST repos/o/r/issues/20/labels' '$W/writes' && ! grep -q 'pr comment' '$W/writes'"
Y="$(setup otherbase)"
echo "[$(BASE=release pr 20 feat/7-x CLEAN)]" >"$Y/prs.json"; echo "$in_review" >"$Y/issues.json"; echo 0 >"$Y/behind"
run "$Y"
check "the branch is compared with, and named as up to date with, the PR's own base" "grep -q 'up to date with release' '$Y/writes' && grep -q '^repos/o/r/compare/release\\.\\.\\.' '$Y/compares'"
X="$(setup comparejunk)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$X/prs.json"; echo "$in_review" >"$X/issues.json"; echo null >"$X/behind"
run "$X"; rc=$?
check "a compare that returns no count is treated as unchecked" "[ $rc -ne 0 ] && ! grep -q 'pr comment' '$X/writes'"

# An UNKNOWN PR without the label changes nothing, so it is not noted either.
N="$(setup unknownunlabelled)"
echo "[$(pr 20 feat/7-x UNKNOWN)]" >"$N/prs.json"; echo "$in_review" >"$N/issues.json"
run "$N"; rc=$?
check "an UNKNOWN PR without the label is left alone, with no note" "[ $rc -eq 0 ] && [ ! -s '$N/writes' ] && ! grep -q 'UNKNOWN' '$N/out'"

# A branch number with a leading zero still names its issue.
L="$(setup leadingzero)"
echo "[$(pr 20 feat/07-x CLEAN)]" >"$L/prs.json"; echo "$in_review" >"$L/issues.json"
run "$L"; rc=$?
check "a branch feat/07-x is matched to issue 7" "[ $rc -eq 0 ] && grep -q 'X POST repos/o/r/issues/20/labels' '$L/writes'"

# Not the loop's to announce: no loop branch, issue not in-review, changes requested.
E="$(setup skipped)"
echo "[$(pr 30 dependabot/actions-x CLEAN), $(pr 31 feat/9-z CLEAN), $(pr 32 feat/7-x CLEAN changes-requested)]" >"$E/prs.json"
echo '[{"number": 9, "labels": [{"name": "in-progress"}, {"name": "in-review"}]}, {"number": 7, "labels": [{"name": "in-review"}]}]' >"$E/issues.json"
run "$E"; rc=$?
check "non-loop, in-progress and changes-requested PRs are left alone" "[ $rc -eq 0 ] && [ ! -s '$E/writes' ]"

# Every way a labelled PR stops being ready takes the label off.
G="$(setup stopsready)"
echo "[$(pr 40 feat/7-x CLEAN ready-to-merge changes-requested), $(pr 41 feat/9-z CLEAN ready-to-merge), $(pr 42 feat/11-w CLEAN ready-to-merge)]" >"$G/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 9, "labels": [{"name": "in-review"}, {"name": "in-progress"}]}]' >"$G/issues.json"
run "$G"
for n in 40 41 42; do
  check "a labelled PR that stopped being ready loses the label (#$n)" "grep -q 'api -X DELETE repos/o/r/issues/$n/labels/ready-to-merge' '$G/writes'"
done

# An in-review issue Step 1.5 also skips (needs-attention, blocked, no-auto-heal) is
# not announced: needs-attention is how Step 8 marks a review loop that hit its cap.
for skip in needs-attention blocked no-auto-heal; do
  S="$(setup "skip-$skip")"
  echo "[$(pr 20 feat/7-x CLEAN)]" >"$S/prs.json"
  echo "[{\"number\": 7, \"labels\": [{\"name\": \"in-review\"}, {\"name\": \"$skip\"}]}]" >"$S/issues.json"
  run "$S"
  check "a PR whose issue is also $skip is not announced" "[ ! -s '$S/writes' ]"
done

# A PR with no assignee is announced without a stray @.
H="$(setup noassignee)"
echo "[$(ASSIGNEES='[]' pr 20 feat/7-x CLEAN)]" >"$H/prs.json"; echo "$in_review" >"$H/issues.json"
run "$H"
check "a PR with no assignee is announced without a stray @" "grep -q 'pr comment 20' '$H/writes' && ! grep -q '@' '$H/writes'"

# One PR that cannot be read is reported; the others are still handled.
I="$(setup oneunreadable)"
echo "[$(pr 20 feat/7-x CLEAN), $(pr 21 fix/8-y CLEAN)]" >"$I/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$I/issues.json"
: >"$I/fail-view-20"
run "$I"; rc=$?
check "a PR whose comments cannot be read is reported and fails the run" "[ $rc -ne 0 ] && grep -q \"could not read #20's comments\" '$I/out'"
check "the other PRs are still handled" "grep -q 'pr comment 21' '$I/writes'"

# GitHub computes the merge state lazily: an UNKNOWN PR is listed again, and announced
# once it reads CLEAN.
J="$(setup unknownthenclean)"
echo "[$(pr 20 feat/7-x UNKNOWN)]" >"$J/prs-1.json"; echo "[$(pr 20 feat/7-x CLEAN)]" >"$J/prs.json"; echo "$in_review" >"$J/issues.json"
run "$J"
check "an UNKNOWN merge state is read again and a PR that turns CLEAN is announced" "grep -q 'pr comment 20' '$J/writes' && [ \$(cat '$J/lists') -ge 2 ]"

# The workflow's own run puts a check on the PR it judges (#110: a pull_request_target
# run's check is on the PR's head, seen in backlog-loop-e2e). While it runs, or once
# a newer run replaced it, GitHub reads the PR UNSTABLE. That check is set aside: the
# PR is ready when every other check passes.
ok='{"__typename": "CheckRun", "name": "verify", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS"}'
own_running='{"__typename": "CheckRun", "name": "label", "workflowName": "Ready to merge", "status": "IN_PROGRESS", "conclusion": ""}'
own_cancelled='{"__typename": "CheckRun", "name": "label", "workflowName": "Ready to merge", "status": "COMPLETED", "conclusion": "CANCELLED"}'
other_failed='{"__typename": "CheckRun", "name": "lint", "workflowName": "Lint", "status": "COMPLETED", "conclusion": "FAILURE"}'
status_pending='{"__typename": "StatusContext", "context": "ci/legacy", "state": "PENDING"}'
L="$(setup ownrunning)"
echo "[$(ROLLUP="[$ok, $own_running]" pr 20 feat/7-x UNSTABLE), $(ROLLUP="[$ok, $own_cancelled]" pr 21 fix/8-y UNSTABLE)]" >"$L/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$L/issues.json"
run "$L"; rc=$?
check "UNSTABLE only from this workflow's own running check is ready" "[ $rc -eq 0 ] && grep -q 'api -X POST repos/o/r/issues/20/labels' '$L/writes' && grep -q 'pr comment 20' '$L/writes'"
check "UNSTABLE only from this workflow's own cancelled check is ready" "grep -q 'api -X POST repos/o/r/issues/21/labels' '$L/writes'"
M="$(setup otherfailing)"
echo "[$(ROLLUP="[$ok, $own_running, $other_failed]" pr 20 feat/7-x UNSTABLE ready-to-merge), $(ROLLUP="[$ok, $status_pending]" pr 21 fix/8-y UNSTABLE ready-to-merge)]" >"$M/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$M/issues.json"
run "$M"
check "another workflow's failing check keeps it not ready" "grep -q 'api -X DELETE repos/o/r/issues/20/labels/ready-to-merge' '$M/writes' && ! grep -q 'pr comment 20' '$M/writes'"
check "a pending commit status keeps it not ready" "grep -q 'api -X DELETE repos/o/r/issues/21/labels/ready-to-merge' '$M/writes'"
N="$(setup renamed)"
echo "[$(ROLLUP='[{"__typename": "CheckRun", "name": "label", "workflowName": "Merge gate", "status": "IN_PROGRESS", "conclusion": ""}]' pr 20 feat/7-x UNSTABLE)]" >"$N/prs.json"; echo "$in_review" >"$N/issues.json"
PATH="$N/bin:$PATH" GH_REPO=o/r READY_RETRY_SECONDS=0 GITHUB_WORKFLOW='Merge gate' "$HERE/ready-to-merge.sh" >"$N/out" 2>&1
check "its own workflow is the one Actions names, so a renamed workflow still works" "grep -q 'api -X POST repos/o/r/issues/20/labels' '$N/writes'"
: >"$N/writes"
run "$N"
check "and a check from a workflow with another name is never set aside" "! grep -q 'X POST' '$N/writes'"

# The PR is read again just before anything is written: changes-requested added, or a
# push, since the listing wins, and the run that event queued judges it (#110).
O="$(setup changedsince)"
echo "[$(pr 20 feat/7-x CLEAN), $(pr 21 fix/8-y CLEAN)]" >"$O/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$O/issues.json"
echo '{"comments": [], "headRefOid": "abc123200000000000000000000000000000000", "labels": [{"name": "changes-requested"}]}' >"$O/comments-20.json"
echo '{"comments": [], "headRefOid": "fffffff00000000000000000000000000000000", "labels": []}' >"$O/comments-21.json"
run "$O"; rc=$?
check "changes-requested added since the listing: no label, no comment" "[ $rc -eq 0 ] && ! grep -q 'issues/20/labels' '$O/writes' && ! grep -q 'pr comment 20' '$O/writes'"
check "a push since the listing: no label, no comment" "! grep -q 'issues/21/labels' '$O/writes' && ! grep -q 'pr comment 21' '$O/writes'"

# A repo whose seeded workflow predates checks: read (sync never updates it) still
# works: the listing falls back to one without checks, with a warning (#110).
P="$(setup nochecks)"
echo "[$(pr 20 feat/7-x CLEAN), $(ROLLUP="[$own_running]" pr 21 fix/8-y UNSTABLE ready-to-merge)]" >"$P/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$P/issues.json"
: >"$P/no-checks-permission"
run "$P"; rc=$?
check "without checks permission it still labels a CLEAN PR" "[ $rc -eq 0 ] && grep -q 'api -X POST repos/o/r/issues/20/labels' '$P/writes'"
check "and warns how to fix the workflow" "grep -q 'checks: read' '$P/out'"
check "and, unable to set its own check aside, reads UNSTABLE as not ready" "grep -q 'api -X DELETE repos/o/r/issues/21/labels/ready-to-merge' '$P/writes'"

# A PR from a fork is never the loop's, and its token could not label it anyway.
K="$(setup fork)"
echo "[$(CROSS=true pr 20 feat/7-x CLEAN)]" >"$K/prs.json"; echo "$in_review" >"$K/issues.json"
run "$K"; rc=$?
check "a PR from a fork is left alone" "[ $rc -eq 0 ] && [ ! -s '$K/writes' ]"

# A gh failure is reported and fails the run, never read as "nothing ready".
F="$(setup ghfail)"
echo '[]' >"$F/prs.json"; : >"$F/fail-pr-list"
run "$F"; rc=$?
check "a gh failure fails the run with a message" "[ $rc -ne 0 ] && grep -q 'could not list' '$F/out'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
