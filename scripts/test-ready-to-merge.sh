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
    k=\$(( \$(cat "\$d/lists" 2>/dev/null || echo 0) + 1 )); echo "\$k" >"\$d/lists"
    if [ -f "\$d/prs-\$k.json" ]; then cat "\$d/prs-\$k.json"; else cat "\$d/prs.json"; fi ;;
  "api -X POST "*"/labels "*|"api -X DELETE "*"/labels/"*) echo "\$*" >>"\$d/writes" ;;
  "issue list "*) cat "\$d/issues.json" ;;
  "pr view "*" --json comments"*) n=\$3; [ -f "\$d/fail-view-\$n" ] && exit 1; cat "\$d/comments-\$n.json" 2>/dev/null || echo '{"comments": []}' ;;
  "pr edit "*|"pr comment "*) echo "\$*" >>"\$d/writes" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$dir/bin/gh"
  echo "$dir"
}
run() { PATH="$1/bin:$PATH" GH_REPO=o/r READY_RETRY_SECONDS=0 "$HERE/ready-to-merge.sh" >"$1/out" 2>&1; }
DEFAULT_ASSIGNEES='[{"login": "maint"}]'
pr() { # pr <number> <branch> <mergeStateStatus> [labels...]; ASSIGNEES and CROSS override
  local n="$1" ref="$2" st="$3" who="${ASSIGNEES-$DEFAULT_ASSIGNEES}"; shift 3
  printf '{"number": %s, "headRefName": "%s", "headRefOid": "abc123%s0000000000000000000000000000000", "mergeStateStatus": "%s", "isCrossRepository": %s, "assignees": %s, "labels": [%s]}' \
    "$n" "$ref" "$n" "$st" "${CROSS:-false}" "$who" "$(for l in "$@"; do printf '{"name": "%s"},' "$l"; done | sed 's/,$//')"
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

# A labelled PR that is no longer ready loses the label; UNKNOWN changes nothing.
D="$(setup notready)"
echo "[$(pr 20 feat/7-x BEHIND ready-to-merge), $(pr 21 fix/8-y UNKNOWN ready-to-merge)]" >"$D/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$D/issues.json"
run "$D"
check "a PR that stops being ready loses the label" "grep -q 'api -X DELETE repos/o/r/issues/20/labels/ready-to-merge' '$D/writes'"
check "an UNKNOWN merge state leaves the label as it is" "! grep -q 'issues/21/labels' '$D/writes'"

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
