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
  "pr list "*) [ -f "\$d/fail-pr-list" ] && exit 1; cat "\$d/prs.json" ;;
  "issue list "*) cat "\$d/issues.json" ;;
  "pr view "*" --json comments"*) n=\$3; cat "\$d/comments-\$n.json" 2>/dev/null || echo '{"comments": []}' ;;
  "pr edit "*|"pr comment "*) echo "\$*" >>"\$d/writes" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$dir/bin/gh"
  echo "$dir"
}
run() { PATH="$1/bin:$PATH" "$HERE/ready-to-merge.sh" >"$1/out" 2>&1; }
pr() { # pr <number> <branch> <mergeStateStatus> [labels...]
  local n="$1" ref="$2" st="$3"; shift 3
  printf '{"number": %s, "headRefName": "%s", "headRefOid": "abc123%s0000000000000000000000000000000", "mergeStateStatus": "%s", "assignees": [{"login": "maint"}], "labels": [%s]}' \
    "$n" "$ref" "$n" "$st" "$(for l in "$@"; do printf '{"name": "%s"},' "$l"; done | sed 's/,$//')"
}
in_review='[{"number": 7, "labels": [{"name": "in-review"}]}]'

# A ready PR is labelled and the assignee told, once.
A="$(setup ready)"
echo "[$(pr 20 feat/7-x CLEAN)]" >"$A/prs.json"; echo "$in_review" >"$A/issues.json"
run "$A"; rc=$?
check "a ready loop PR gets the ready-to-merge label" "[ $rc -eq 0 ] && grep -q 'pr edit 20 --add-label ready-to-merge' '$A/writes'"
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
check "a new head on a ready PR is announced again" "grep -q 'pr comment 20' '$C/writes' && ! grep -q 'add-label' '$C/writes'"

# A labelled PR that is no longer ready loses the label; UNKNOWN changes nothing.
D="$(setup notready)"
echo "[$(pr 20 feat/7-x BEHIND ready-to-merge), $(pr 21 fix/8-y UNKNOWN ready-to-merge)]" >"$D/prs.json"
echo '[{"number": 7, "labels": [{"name": "in-review"}]}, {"number": 8, "labels": [{"name": "in-review"}]}]' >"$D/issues.json"
run "$D"
check "a PR that stops being ready loses the label" "grep -q 'pr edit 20 --remove-label ready-to-merge' '$D/writes'"
check "an UNKNOWN merge state leaves the label as it is" "! grep -q 'pr edit 21' '$D/writes'"

# Not the loop's to announce: no loop branch, issue not in-review, changes requested.
E="$(setup skipped)"
echo "[$(pr 30 dependabot/actions-x CLEAN), $(pr 31 feat/9-z CLEAN), $(pr 32 feat/7-x CLEAN changes-requested)]" >"$E/prs.json"
echo '[{"number": 9, "labels": [{"name": "in-progress"}, {"name": "in-review"}]}, {"number": 7, "labels": [{"name": "in-review"}]}]' >"$E/issues.json"
run "$E"; rc=$?
check "non-loop, in-progress and changes-requested PRs are left alone" "[ $rc -eq 0 ] && [ ! -s '$E/writes' ]"

# A gh failure is reported and fails the run, never read as "nothing ready".
F="$(setup ghfail)"
echo '[]' >"$F/prs.json"; : >"$F/fail-pr-list"
run "$F"; rc=$?
check "a gh failure fails the run with a message" "[ $rc -ne 0 ] && grep -q 'could not list' '$F/out'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
