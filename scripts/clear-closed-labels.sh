#!/usr/bin/env bash
# Clears the loop's status labels from an issue that has closed (#118). Merging a loop
# PR closes its issue through "Closes #N", but nothing took `in-review` (or, under the
# proposal gate, `heal:proposed` and `heal:approved`) off it, so the closed-issue list
# showed finished work as still in review. Every loop query filters on open issues, so
# this is about what people see, not what the loop does.
#
# Only the labels that describe an open issue's state go. Priority (P0-P3), type
# (bug, enhancement), needs-infra (an infra change can still be waiting for a human
# after the merge) and no-auto-heal stay. A reopened issue comes back without status
# labels, so the loop can select it again. An issue that is open again by the time
# this runs (reopened quickly) keeps them all: they describe it once more.
#
# Run by .github/workflows/clear-closed-labels.yml; safe to run by hand.
# Usage: scripts/clear-closed-labels.sh <issue-number>   (gh authenticated for the repo)
# Exit: 0 cleared, or nothing to clear · 1 a gh call failed · 2 usage.
set -uo pipefail

# The labels this clears: the open-issue states in docs/ISSUE_GUIDE.md. The script's
# only list; the docs name the same set, and the test checks both against ISSUE_GUIDE.
STATUS_LABELS="in-progress in-review blocked needs-attention heal:proposed heal:approved"

usage() { echo "usage: $0 <issue-number>" >&2; exit 2; }
die() { echo "clear-closed-labels: $*" >&2; exit 1; }

[ $# -eq 1 ] || usage
case "$1" in ''|*[!0-9]*) usage ;; esac
n="$1"

# The state and the labels in one read: the state first, then a label per line.
if ! out="$(gh issue view "$n" --json state,labels --jq '.state, .labels[].name')"; then
  die "could not read #$n's state and labels"
fi
state="${out%%$'\n'*}"
labels=""
[ "$out" = "$state" ] || labels="${out#*$'\n'}"

if [ "$state" != CLOSED ]; then
  echo "clear-closed-labels: #$n is ${state:-in an unknown state}, not closed: its labels stay"
  exit 0
fi

# Matched whole, so a label that merely contains a status name stays.
remove=""
for l in $STATUS_LABELS; do
  # A here-string, not a pipe: grep -q exiting early cannot fail a printf under pipefail.
  if grep -qxF -- "$l" <<<"$labels"; then remove="${remove:+$remove,}$l"; fi
done

if [ -z "$remove" ]; then
  echo "clear-closed-labels: #$n has no status labels to clear"
  exit 0
fi

# One edit for all of them, so a failure leaves the labels as they were.
gh issue edit "$n" --remove-label "$remove" >/dev/null || die "could not remove $remove from #$n"
echo "clear-closed-labels: cleared $remove from #$n"
