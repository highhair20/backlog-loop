#!/usr/bin/env bash
# Tests for scripts/clear-closed-labels.sh (#118), with a fake `gh` on PATH: it serves
# the fixture's labels and logs every edit.
# Usage: scripts/test-clear-closed-labels.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# $1 = fixture name, then the issue's labels. Writes a fake gh that serves the state
# (CLOSED unless the fixture's state file says otherwise) and then the labels, one per
# line as `--jq '.state, .labels[].name'` prints them, and logs every call.
setup() {
  local dir="$WORK/$1" l
  shift
  mkdir -p "$dir/bin"
  : >"$dir/labels" && : >"$dir/calls" && echo CLOSED >"$dir/state"
  for l in "$@"; do echo "$l" >>"$dir/labels"; done
  cat >"$dir/bin/gh" <<FAKE
#!/usr/bin/env bash
d="$dir"
echo "\$*" >>"\$d/calls"
case "\$*" in
  "issue view "*) n=\$3
    [ -f "\$d/fail-view" ] || [ -f "\$d/fail-view-\$n" ] && { echo "HTTP 502" >&2; exit 1; }
    if [ -f "\$d/labels-\$n" ]; then echo CLOSED; cat "\$d/labels-\$n"; else cat "\$d/state" "\$d/labels"; fi ;;
  "issue list "*) [ -f "\$d/fail-list" ] && { echo "HTTP 502" >&2; exit 1; }
    l=\$(printf '%s\n' "\$@" | grep -A1 -x -- --label | tail -1); cat "\$d/list-\$l" 2>/dev/null || true ;;
  "issue edit "*) [ -f "\$d/fail-edit" ] && { echo "HTTP 403: Resource not accessible" >&2; exit 1; }; exit 0 ;;
  *) echo "unexpected gh call: \$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$dir/bin/gh"
  echo "$dir"
}
run() { local d="$1"; shift; PATH="$d/bin:$PATH" GH_REPO=o/r "$HERE/clear-closed-labels.sh" "$@" >"$d/out" 2>&1; }
edits() { grep -c '^issue edit ' "$1/calls"; }

# Mixed labels: only the status labels go, in one edit.
A="$(setup mixed P2 bug in-review heal:approved needs-infra no-auto-heal)"
run "$A" 42; rc=$?
check "a closed issue loses its status labels, in a single edit" "[ $rc -eq 0 ] && [ \$(edits '$A') -eq 1 ] && grep -q '^issue edit 42 --remove-label in-review,heal:approved\$' '$A/calls'"
check "priority, type, needs-infra and no-auto-heal are left alone" "! grep '^issue edit' '$A/calls' | grep -qE 'P2|bug|needs-infra|no-auto-heal'"
check "it says what it cleared" "grep -q 'in-review,heal:approved' '$A/out' && grep -q '#42' '$A/out'"

# Every status label at once.
B="$(setup all P1 enhancement in-progress in-review blocked needs-attention heal:proposed heal:approved)"
run "$B" 7; rc=$?
check "all six status labels are removed together" "[ $rc -eq 0 ] && [ \$(edits '$B') -eq 1 ] && grep -q '^issue edit 7 --remove-label in-progress,in-review,blocked,needs-attention,heal:proposed,heal:approved\$' '$B/calls'"

# Nothing to clear: no edit at all.
C="$(setup noop P3 enhancement needs-infra)"
run "$C" 9; rc=$?
check "an issue with no status labels is a no-op with no edit call" "[ $rc -eq 0 ] && [ \$(edits '$C') -eq 0 ]"
D="$(setup none)"
run "$D" 9; rc=$?
check "an issue with no labels at all is a no-op too" "[ $rc -eq 0 ] && [ \$(edits '$D') -eq 0 ]"

# An issue reopened before the run reaches it keeps its labels: they are an open
# issue's state again, blocked and needs-attention holds included.
H="$(setup reopened P2 blocked needs-attention)"
echo OPEN >"$H/state"
run "$H" 11; rc=$?
check "an issue reopened before the run keeps every label" "[ $rc -eq 0 ] && [ \$(edits '$H') -eq 0 ] && grep -q 'is OPEN, not closed' '$H/out'"
check "the state and the labels come from one read" "[ \$(grep -c '^issue view ' '$H/calls') -eq 1 ] && grep -q 'state' '$H/calls'"

# Only OPEN keeps the labels; a state that is neither closed nor open is an error, never
# a quiet success.
J="$(setup oddstate P2 in-review)"
: >"$J/state"
run "$J" 13; rc=$?
check "an empty or unknown state fails the run, editing nothing" "[ $rc -eq 1 ] && [ \$(edits '$J') -eq 0 ] && grep -q 'unexpected state' '$J/out'"

# --all-closed: every closed issue still carrying a status label, each cleared once.
K="$(setup backfill)"
printf '3\n5\n' >"$K/list-in-review"; printf '5\n8\n' >"$K/list-blocked"
printf 'P2\nin-review\n' >"$K/labels-3"; printf 'in-review\nblocked\n' >"$K/labels-5"; printf 'bug\nblocked\n' >"$K/labels-8"
run "$K" --all-closed; rc=$?
check "--all-closed clears each closed issue with a status label once" "[ $rc -eq 0 ] && [ \$(edits '$K') -eq 3 ] && grep -q '^issue edit 3 --remove-label in-review\$' '$K/calls' && grep -q '^issue edit 5 --remove-label in-review,blocked\$' '$K/calls' && grep -q '^issue edit 8 --remove-label blocked\$' '$K/calls'"
check "it lists closed issues one status label at a time" "[ \$(grep -c '^issue list --state closed --label ' '$K/calls') -eq 6 ] && grep -q -- '--label heal:proposed' '$K/calls'"
check "and says how many it looked at" "grep -q 'looked at 3 closed issue' '$K/out'"
L="$(setup backfill-fail)"
printf '3\n5\n' >"$L/list-in-review"; printf 'in-review\n' >"$L/labels-3"; printf 'in-review\n' >"$L/labels-5"
: >"$L/fail-view-3"
run "$L" --all-closed; rc=$?
check "--all-closed goes on past one failure, then exits non-zero" "[ $rc -eq 1 ] && grep -q '^issue edit 5 ' '$L/calls' && grep -q '1 failed' '$L/out'"
M="$(setup backfill-listfail)"
: >"$M/fail-list"
run "$M" --all-closed; rc=$?
check "--all-closed fails when it cannot list the closed issues" "[ $rc -eq 1 ] && [ \$(edits '$M') -eq 0 ] && grep -q 'could not list' '$M/out'"
N="$(setup backfill-limit)"
printf '3\n5\n7\n' >"$N/list-in-review"; printf 'in-review\n' >"$N/labels-3"; printf 'in-review\n' >"$N/labels-5"; printf 'in-review\n' >"$N/labels-7"
PATH="$N/bin:$PATH" GH_REPO=o/r CLEAR_CLOSED_LIMIT=2 "$HERE/clear-closed-labels.sh" --all-closed >"$N/out" 2>&1; rc=$?
check "--all-closed fails, saying so, when a listing has more than its limit" "[ $rc -eq 1 ] && grep -q 'may have more' '$N/out'"
check "it asks for one more than the limit, to tell 'exactly the limit' from 'more'" "grep -q -- '--limit 3 ' '$N/calls'"
P="$(setup backfill-exact)"
printf '3\n5\n' >"$P/list-in-review"; printf 'in-review\n' >"$P/labels-3"; printf 'in-review\n' >"$P/labels-5"
PATH="$P/bin:$PATH" GH_REPO=o/r CLEAR_CLOSED_LIMIT=2 "$HERE/clear-closed-labels.sh" --all-closed >"$P/out" 2>&1; rc=$?
check "a listing of exactly the limit is complete, not a failure" "[ $rc -eq 0 ] && ! grep -q 'may have more' '$P/out' && [ \$(edits '$P') -eq 2 ]"
PATH="$N/bin:$PATH" GH_REPO=o/r CLEAR_CLOSED_LIMIT=abc "$HERE/clear-closed-labels.sh" --all-closed >"$N/out" 2>&1; rc=$?
check "a CLEAR_CLOSED_LIMIT that is not a number is a usage error" "[ $rc -eq 2 ] && grep -q 'CLEAR_CLOSED_LIMIT' '$N/out'"
O="$(setup backfill-none)"
run "$O" --all-closed; rc=$?
check "--all-closed with nothing to clear succeeds and edits nothing" "[ $rc -eq 0 ] && [ \$(edits '$O') -eq 0 ] && grep -q 'looked at 0 closed issue' '$O/out'"

# Names are matched whole: a label that only contains a status name stays.
E="$(setup lookalike in-review-later blocked-by-infra P2)"
run "$E" 3; rc=$?
check "labels that merely contain a status name are left alone" "[ $rc -eq 0 ] && [ \$(edits '$E') -eq 0 ]"

# Failures are loud: a non-zero exit and a message, never a quiet success.
F="$(setup editfails P2 in-review)"
: >"$F/fail-edit"
run "$F" 5; rc=$?
check "a failed label edit exits non-zero" "[ $rc -ne 0 ]"
check "and names the issue and the labels it could not remove, with gh's reason" "grep -q '#5' '$F/out' && grep -q 'in-review' '$F/out' && grep -q 'HTTP 403' '$F/out'"
G="$(setup viewfails P2 in-review)"
: >"$G/fail-view"
run "$G" 5; rc=$?
check "a failed label read exits non-zero and edits nothing" "[ $rc -ne 0 ] && [ \$(edits '$G') -eq 0 ] && grep -q '#5' '$G/out'"

# Bad usage never reaches gh.
for args in "" "abc" "5 6" "-1" "--all" "--all-closed 5"; do
  U="$(setup "usage-${args// /_}" in-review)"
  # shellcheck disable=SC2086  # $args is zero or more words
  run "$U" $args; rc=$?
  check "rejects bad usage: '$args'" "[ $rc -eq 2 ] && grep -q usage '$U/out' && [ ! -s '$U/calls' ]"
done

# The script's list matches the labels the template defines, both ways: every label it
# clears exists, and every issue label in ISSUE_GUIDE is either cleared or kept on
# purpose, so a new label has to be sorted into one or the other.
STATUS="$(sed -n 's/^STATUS_LABELS="\(.*\)"$/\1/p' "$HERE/clear-closed-labels.sh")"
check "the script names its status labels in one STATUS_LABELS line" "[ -n '$STATUS' ]"
for l in $STATUS; do
  check "status label $l is one seed-labels.sh creates and ISSUE_GUIDE describes" "grep -q '\"$l|' '$ROOT/scripts/seed-labels.sh' && grep -q '^| .$l. |' '$ROOT/docs/ISSUE_GUIDE.md'"
done
# Kept on a closed issue: priority, type, policy, and the labels that live on PRs.
KEPT=" P0 P1 P2 P3 bug enhancement needs-infra no-auto-heal ready-to-merge changes-requested surface-none surface-ota surface-store "
for l in $(sed -n 's/^| `\([^`]*\)` |.*/\1/p' "$ROOT/docs/ISSUE_GUIDE.md"); do
  case " $STATUS " in *" $l "*) continue ;; esac
  check "ISSUE_GUIDE's label $l is either cleared or kept on purpose" "case '$KEPT' in *' $l '*) true ;; *) false ;; esac"
done

# The workflow: every close, whatever its reason, with the least permission it needs.
WF="$ROOT/.github/workflows/clear-closed-labels.yml"
check "the workflow runs when an issue closes, and when a closed issue is labelled again" "[ -f '$WF' ] && grep -qE '^  issues:' '$WF' && grep -qE 'types: \\[closed, labeled\\]' '$WF'"
check "its job runs only for a closed issue, or when started by hand" "grep -qE \"^    if: github.event_name == 'workflow_dispatch' \\|\\| github.event.issue.state == 'closed'\\\$\" '$WF'"
check "it can be started by hand to clear issues closed before it existed" "grep -qE '^  workflow_dispatch:' '$WF' && grep -q 'scripts/clear-closed-labels.sh --all-closed' '$WF'"
check "its concurrency group sits on the job, after the if, so skipped runs never take a slot" "awk '/^    if: /{i=NR} /^    concurrency:/{c=NR} END{exit !(i && c && i < c)}' '$WF' && ! grep -q '^concurrency:' '$WF'"
check "runs for one issue queue rather than race" "grep -qF 'group: clear-closed-labels-\${{ github.event.issue.number ||' '$WF' && grep -q 'cancel-in-progress: false' '$WF'"
check "it runs for every close reason, not planned included (no state_reason filter, and its one if: checks only the state)" "! grep -q 'state_reason' '$WF' && [ \$(grep -cE '^ +if:' '$WF') -eq 1 ]"
check "it can write issues and read contents, nothing more" "[ \"\$(sed -n '/^permissions:/,/^[a-z]/p' '$WF' | grep -cE '^  [a-z-]+:')\" -eq 2 ] && grep -qE '^  issues: write' '$WF' && grep -qE '^  contents: read' '$WF'"
check "it checks out the default branch, pinned by SHA, without persisting credentials" "grep -qE 'actions/checkout@[0-9a-f]{40}' '$WF' && grep -q 'default_branch' '$WF' && grep -q 'persist-credentials: false' '$WF'"
check "the issue number reaches the script through the environment, not the run line" "grep -q 'ISSUE: \${{ github.event.issue.number }}' '$WF' && grep -q 'scripts/clear-closed-labels.sh \"\$ISSUE\"' '$WF'"

# The guide tells people.
check "ISSUE_GUIDE's Lifecycle says closing clears the status labels, and names the GITHUB_TOKEN exception" "sed -n '/^## Lifecycle/,/^## /p' '$ROOT/docs/ISSUE_GUIDE.md' | tr '\\n' ' ' | grep -q 'Closing an issue, for any reason, clears its status labels' && sed -n '/^## Lifecycle/,/^## /p' '$ROOT/docs/ISSUE_GUIDE.md' | grep -q 'GITHUB_TOKEN'"
check "the CHANGELOG backfill runs the workflow by hand, and warns about a terminal run" "grep -q 'gh workflow run clear-closed-labels.yml' '$ROOT/CHANGELOG.md' && grep -q 'scripts/clear-closed-labels.sh --all-closed' '$ROOT/CHANGELOG.md' && grep -q 'ready-to-merge run' '$ROOT/CHANGELOG.md'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
