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
# GitHub computes mergeStateStatus lazily, so right after an event a PR can read
# UNKNOWN: list again, a few times, before leaving it for the next event.
RETRIES=3
RETRY_SECONDS="${READY_RETRY_SECONDS:-10}"
failures=0
fail() { echo "ready-to-merge: $1" >&2; failures=$((failures + 1)); }
: "${GH_REPO:=$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

list_prs() {
  gh pr list --state open --limit 1000 \
    --json number,headRefName,headRefOid,mergeStateStatus,isCrossRepository,assignees,labels
}
# Loop PRs (branch <type>/<N>-<slug>) from this repo, never a fork's: a fork's PR is
# not the loop's, and the workflow's token could not label it.
loop_prs='[.[] | select((.isCrossRepository | not) and (.headRefName | test("^[a-z]+/[0-9]+-")))]'

prs=""
for attempt in $(seq 1 "$RETRIES"); do
  prs="$(list_prs | jq -c "$loop_prs")" || { echo "ready-to-merge: could not list open PRs" >&2; exit 1; }
  jq -e 'any(.[]; .mergeStateStatus == "UNKNOWN")' <<<"$prs" >/dev/null || break
  [ "$attempt" -eq "$RETRIES" ] || sleep "$RETRY_SECONDS"
done
issues="$(gh issue list --state open --label in-review --limit 1000 --json number,labels)" \
  || { echo "ready-to-merge: could not list in-review issues" >&2; exit 1; }

# Labels go through the REST API: `gh pr edit --add-label` also queries classic
# Projects, which a workflow token is refused on some gh versions.
add_label() { gh api -X POST "repos/$GH_REPO/issues/$1/labels" -f "labels[]=$LABEL" >/dev/null; }
remove_label() { gh api -X DELETE "repos/$GH_REPO/issues/$1/labels/$LABEL" >/dev/null; }

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  if ! fields="$(jq -r '[.number, .headRefName, .headRefOid, .mergeStateStatus, ([.labels[].name] | join(",")), ([.assignees[].login | "@" + .] | join(" "))] | join("\u001f")' <<<"$pr")"; then
    fail "could not read a PR's fields"; continue
  fi
  # The unit separator, not a tab: read collapses runs of whitespace separators, so
  # an empty field (no labels) would shift the ones after it.
  IFS=$'\x1f' read -r n ref sha state labels who <<<"$fields"
  issue="$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$ref")"
  [ "$state" != UNKNOWN ] || continue
  labelled=0; case ",$labels," in *",$LABEL,"*) labelled=1 ;; esac

  ready=0
  if [ "$state" = CLEAN ] || [ "$state" = HAS_HOOKS ]; then
    case ",$labels," in
      *,changes-requested,*) ;;
      *) jq -e --argjson i "$issue" 'any(.[]; .number == $i and ([.labels[].name] | index("in-progress") | not))' <<<"$issues" >/dev/null && ready=1 ;;
    esac
  fi

  if [ "$ready" -eq 0 ]; then
    [ "$labelled" -eq 0 ] || remove_label "$n" || fail "could not remove $LABEL from #$n"
    continue
  fi
  [ "$labelled" -eq 1 ] || add_label "$n" || fail "could not add $LABEL to #$n"
  if ! bodies="$(gh pr view "$n" --json comments -q '.comments[].body')"; then
    fail "could not read #$n's comments"; continue
  fi
  grep -qF "$MARK $sha" <<<"$bodies" && continue
  gh pr comment "$n" --body "$MARK $sha -->
${who:+$who }Ready to merge: the loop is done with #$issue, required checks pass, and the branch is up to date with main (head ${sha:0:7})." >/dev/null \
    || fail "could not comment on #$n"
done < <(jq -c '.[]' <<<"$prs")

[ "$failures" -eq 0 ] || exit 1
