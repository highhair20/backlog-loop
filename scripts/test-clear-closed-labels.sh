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
  "issue view "*) [ -f "\$d/fail-view" ] && { echo "HTTP 502" >&2; exit 1; }; cat "\$d/state" "\$d/labels" ;;
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
for args in "" "abc" "5 6" "-1"; do
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
check "its job runs only for a closed issue" "grep -qE \"^    if: github.event.issue.state == 'closed'\\\$\" '$WF'"
check "runs for one issue queue rather than race" "grep -q 'group: clear-closed-labels-\${{ github.event.issue.number }}' '$WF' && grep -q 'cancel-in-progress: false' '$WF'"
check "it runs for every close reason, not planned included (no state_reason filter, and its one if: checks only the state)" "! grep -q 'state_reason' '$WF' && [ \$(grep -cE '^ +if:' '$WF') -eq 1 ]"
check "it can write issues and read contents, nothing more" "[ \"\$(sed -n '/^permissions:/,/^[a-z]/p' '$WF' | grep -cE '^  [a-z-]+:')\" -eq 2 ] && grep -qE '^  issues: write' '$WF' && grep -qE '^  contents: read' '$WF'"
check "it checks out the default branch, pinned by SHA, without persisting credentials" "grep -qE 'actions/checkout@[0-9a-f]{40}' '$WF' && grep -q 'default_branch' '$WF' && grep -q 'persist-credentials: false' '$WF'"
check "the issue number reaches the script through the environment, not the run line" "grep -q 'ISSUE: \${{ github.event.issue.number }}' '$WF' && grep -q 'scripts/clear-closed-labels.sh \"\$ISSUE\"' '$WF'"

# The guide tells people.
check "ISSUE_GUIDE's Lifecycle says closing clears the status labels, and names the GITHUB_TOKEN exception" "sed -n '/^## Lifecycle/,/^## /p' '$ROOT/docs/ISSUE_GUIDE.md' | tr '\\n' ' ' | grep -q 'Closing an issue, for any reason, clears its status labels' && sed -n '/^## Lifecycle/,/^## /p' '$ROOT/docs/ISSUE_GUIDE.md' | grep -q 'GITHUB_TOKEN'"
check "the backfill in the CHANGELOG reads only issues that carry a status label" "grep -q \"gh issue list --state closed --search 'label:in-progress,in-review,blocked,needs-attention,heal:proposed,heal:approved'\" '$ROOT/CHANGELOG.md'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
