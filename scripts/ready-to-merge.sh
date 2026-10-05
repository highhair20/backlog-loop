#!/usr/bin/env bash
# Tells the maintainer when one of the loop's PRs is ready to merge (#88). A loop PR
# (branch <type>/<N>-<slug>) is ready when its issue is in-review (the loop is done
# with it), it has no changes-requested label, and GitHub's mergeStateStatus is CLEAN:
# required checks pass and, under a strict ruleset, it is up to date with main.
#
# A ready PR gets the ready-to-merge label and one comment mentioning its assignees,
# once per head commit (marked, so a rerun does not repeat it). A labelled PR that is
# no longer ready loses the label. UNKNOWN (GitHub still computing) changes nothing.
#
# Run by .github/workflows/ready-to-merge.yml; safe to run by hand.
# Usage: scripts/ready-to-merge.sh   (gh must be authenticated for the repo)
set -uo pipefail

LABEL='ready-to-merge'
MARK='<!-- backlog-loop:ready'
failures=0
fail() { echo "ready-to-merge: $1" >&2; failures=$((failures + 1)); }

prs="$(gh pr list --state open --limit 1000 --json number,headRefName,headRefOid,mergeStateStatus,assignees,labels)" \
  || { echo "ready-to-merge: could not list open PRs" >&2; exit 1; }
issues="$(gh issue list --state open --label in-review --limit 1000 --json number,labels)" \
  || { echo "ready-to-merge: could not list in-review issues" >&2; exit 1; }

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  n="$(jq -r .number <<<"$pr")"
  ref="$(jq -r .headRefName <<<"$pr")"
  sha="$(jq -r .headRefOid <<<"$pr")"
  state="$(jq -r .mergeStateStatus <<<"$pr")"
  issue="$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$ref")"
  [ -n "$issue" ] || continue
  [ "$state" != UNKNOWN ] || continue
  labelled=0; jq -e --arg l "$LABEL" '[.labels[].name] | index($l)' <<<"$pr" >/dev/null && labelled=1

  ready=0
  if [ "$state" = CLEAN ] \
    && ! jq -e '[.labels[].name] | index("changes-requested")' <<<"$pr" >/dev/null \
    && jq -e --argjson i "$issue" 'any(.[]; .number == $i and ([.labels[].name] | index("in-progress") | not))' <<<"$issues" >/dev/null; then
    ready=1
  fi

  if [ "$ready" -eq 0 ]; then
    if [ "$labelled" -eq 1 ]; then
      gh pr edit "$n" --remove-label "$LABEL" >/dev/null || fail "could not remove $LABEL from #$n"
    fi
    continue
  fi
  if [ "$labelled" -eq 0 ]; then
    gh pr edit "$n" --add-label "$LABEL" >/dev/null || fail "could not add $LABEL to #$n"
  fi
  if ! bodies="$(gh pr view "$n" --json comments -q '.comments[].body')"; then
    fail "could not read #$n's comments"; continue
  fi
  grep -qF "$MARK $sha" <<<"$bodies" && continue
  who="$(jq -r '[.assignees[].login | "@" + .] | join(" ")' <<<"$pr")"
  gh pr comment "$n" --body "$MARK $sha -->
${who:+$who }Ready to merge: the loop is done with #$issue, required checks pass, and the branch is up to date with main (head ${sha:0:7})." >/dev/null \
    || fail "could not comment on #$n"
done < <(jq -c '.[]' <<<"$prs")

[ "$failures" -eq 0 ] || exit 1
