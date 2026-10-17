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
#        scripts/clear-closed-labels.sh --all-closed     every closed issue at once
# Run from a terminal, each removal is an `unlabeled` event that starts a
# ready-to-merge run; the workflow's manual run (workflow_dispatch) starts none.
# Exit: 0 cleared, or nothing to clear · 1 a gh call failed, an unexpected state, or
# (--all-closed) a listing with more issues than its limit · 2 usage.
set -uo pipefail

# The labels this clears: the open-issue states in docs/ISSUE_GUIDE.md. The script's
# only list; the docs name the same set, and the test checks both against ISSUE_GUIDE.
STATUS_LABELS="in-progress in-review blocked needs-attention heal:proposed heal:approved"

# A backfill lists this many closed issues per status label at most.
LIMIT="${CLEAR_CLOSED_LIMIT:-1000}"

usage() { echo "usage: $0 <issue-number> | --all-closed" >&2; exit 2; }
say() { echo "clear-closed-labels: $*"; }
err() { echo "clear-closed-labels: $*" >&2; }

# Clear issue $1's status labels if it is closed. Returns 1, after saying why, when a gh
# call fails or the state is neither closed nor open.
clear_one() {
  local n="$1" out state labels l remove=""
  # The state and the labels in one read: the state first, then a label per line.
  if ! out="$(gh issue view "$n" --json state,labels --jq '.state, .labels[].name')"; then
    err "could not read #$n's state and labels"; return 1
  fi
  state="${out%%$'\n'*}"
  labels=""
  [ "$out" = "$state" ] || labels="${out#*$'\n'}"
  case "$state" in
    CLOSED) ;;
    OPEN) say "#$n is OPEN, not closed: its labels stay"; return 0 ;;
    *) err "#$n has an unexpected state '${state}': nothing cleared"; return 1 ;;
  esac
  # Matched whole, so a label that merely contains a status name stays.
  for l in $STATUS_LABELS; do
    # A here-string, not a pipe: grep -q exiting early cannot fail a printf under pipefail.
    if grep -qxF -- "$l" <<<"$labels"; then remove="${remove:+$remove,}$l"; fi
  done
  if [ -z "$remove" ]; then
    say "#$n has no status labels to clear"
    return 0
  fi
  # One edit for all of them, so a failure leaves the labels as they were.
  gh issue edit "$n" --remove-label "$remove" >/dev/null || { err "could not remove $remove from #$n"; return 1; }
  say "cleared $remove from #$n"
}

# Every closed issue that still carries a status label: listed one label at a time (a
# search on several labels would have to spell heal:proposed's colon), each issue once.
# Goes on past a failure, then exits 1 if there was one, or if a listing had more
# issues than LIMIT (it asks for one more, to tell "exactly LIMIT" from "more").
all_closed() {
  local l nums="" got n count=0 failed=0 full=0
  for l in $STATUS_LABELS; do
    got="$(gh issue list --state closed --label "$l" --limit "$((LIMIT + 1))" --json number --jq '.[].number')" ||
      { err "could not list closed issues labelled $l"; exit 1; }
    [ "$(printf '%s\n' "$got" | grep -c .)" -le "$LIMIT" ] || full=1
    nums="$nums $got"
  done
  # shellcheck disable=SC2086  # $nums is a list of issue numbers
  for n in $(printf '%s\n' $nums | sort -nu); do
    count=$((count + 1))
    clear_one "$n" || failed=$((failed + 1))
  done
  say "looked at $count closed issue(s) with a status label; $failed failed"
  # A listing that reached its limit may have left issues labelled: fail, so the run
  # is not mistaken for a complete one.
  [ "$full" -eq 0 ] || err "a listing reached its limit of $LIMIT issues and may have more: run it again for the rest"
  [ "$failed" -eq 0 ] && [ "$full" -eq 0 ] || exit 1
}

[ $# -eq 1 ] || usage
case "$LIMIT" in ''|*[!0-9]*|0) echo "clear-closed-labels: CLEAR_CLOSED_LIMIT must be a positive number, not '$LIMIT'" >&2; exit 2 ;; esac
case "$1" in
  --all-closed) all_closed ;;
  ''|*[!0-9]*) usage ;;
  *) clear_one "$1" || exit 1 ;;
esac
