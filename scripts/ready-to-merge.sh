#!/usr/bin/env bash
# Tells the maintainer when one of the loop's PRs is ready to merge (#88). A loop PR
# (branch <type>/<N>-<slug>) is ready when its issue is in-review (the loop is done
# with it), it has no changes-requested label, and GitHub's mergeStateStatus is CLEAN:
# required checks pass and, under a strict ruleset, it is up to date with main.
#
# A ready PR gets the ready-to-merge label and one comment mentioning its assignees,
# once per head commit (marked, so a rerun does not repeat it). The comment says the
# branch is up to date with its base only when the compare API shows it is: without a
# strict ruleset GitHub reads a behind branch as CLEAN. A labelled PR that is no
# longer ready loses the label, and so does one still UNKNOWN (GitHub still
# computing) after the retries: a missing label costs a run, a false one a bad merge.
#
# READY_REMOVE_ONLY=true (the workflow's pull_request run, #110) only removes the
# label, judged on labels alone: that run's own check is on the PR, so its merge
# state may not read as mergeable.
#
# Run by .github/workflows/ready-to-merge.yml; safe to run by hand.
# Usage: scripts/ready-to-merge.sh   (gh must be authenticated for the repo)
set -uo pipefail

LABEL='ready-to-merge'
MARK='<!-- backlog-loop:ready'
# GitHub computes mergeStateStatus lazily, so right after an event a PR can read
# UNKNOWN: list again, a few times, before taking it as not ready.
RETRIES=3
RETRY_SECONDS="${READY_RETRY_SECONDS:-10}"
REMOVE_ONLY="${READY_REMOVE_ONLY:-false}"
case "$REMOVE_ONLY" in
  true|false) ;;
  *) echo "ready-to-merge: READY_REMOVE_ONLY must be true or false, not '$REMOVE_ONLY'" >&2; exit 1 ;;
esac
failures=0
fail() { echo "ready-to-merge: $1" >&2; failures=$((failures + 1)); }
: "${GH_REPO:=$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

list_prs() {
  gh pr list --state open --limit 1000 \
    --json number,headRefName,headRefOid,baseRefName,mergeStateStatus,isCrossRepository,assignees,labels
}
# Loop PRs (branch <type>/<N>-<slug>) from this repo, never a fork's: a fork's PR is
# not the loop's, and the workflow's token could not label it.
loop_prs='[.[] | select((.isCrossRepository | not) and (.headRefName | test("^[a-z]+/[0-9]+-")))]'

prs=""
for attempt in $(seq 1 "$RETRIES"); do
  prs="$(list_prs | jq -c "$loop_prs")" || { echo "ready-to-merge: could not list open PRs" >&2; exit 1; }
  [ "$REMOVE_ONLY" = false ] || break  # it never reads the merge state
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
  if ! fields="$(jq -r '[.number, .headRefName, .headRefOid, .baseRefName, .mergeStateStatus, ([.labels[].name] | join(",")), ([.assignees[].login | "@" + .] | join(" "))] | join("\u001f")' <<<"$pr")"; then
    fail "could not read a PR's fields"; continue
  fi
  # The unit separator, not a tab: read collapses runs of whitespace separators, so
  # an empty field (no labels) would shift the ones after it.
  IFS=$'\x1f' read -r n ref sha base state labels who <<<"$fields"
  issue="$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$ref")"
  labelled=0; case ",$labels," in *",$LABEL,"*) labelled=1 ;; esac

  labels_ok=0
  case ",$labels," in
    *,changes-requested,*) ;;
    # The issue must be in-review and free of every label Step 1.5 skips:
    # needs-attention also marks a review loop that hit its cap unresolved.
    *) jq -e --argjson i "$issue" 'any(.[]; .number == $i and ([.labels[].name] | any(. == "in-progress" or . == "needs-attention" or . == "blocked" or . == "no-auto-heal") | not))' <<<"$issues" >/dev/null && labels_ok=1 ;;
  esac

  if [ "$REMOVE_ONLY" = true ]; then
    if [ "$labels_ok" -eq 0 ] && [ "$labelled" -eq 1 ]; then
      remove_label "$n" || fail "could not remove $LABEL from #$n"
    fi
    continue
  fi

  # Anything but a mergeable state is not ready, UNKNOWN after the retries included.
  ready=0
  if [ "$labels_ok" -eq 1 ] && { [ "$state" = CLEAN ] || [ "$state" = HAS_HOOKS ]; }; then
    ready=1
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

  # Claim "up to date" only when checked: CLEAN alone does not mean it without a
  # strict ruleset. An unchecked branch is announced without the claim.
  done_with="the loop is done with #$issue and required checks pass"
  if behind="$(gh api "repos/$GH_REPO/compare/$base...$sha" --jq .behind_by)" && [[ "$behind" =~ ^[0-9]+$ ]]; then
    [ "$behind" -ne 0 ] || done_with="the loop is done with #$issue, required checks pass, and the branch is up to date with $base"
  else
    fail "could not compare #$n with $base; announcing it without saying it is up to date"
  fi
  gh pr comment "$n" --body "$MARK $sha -->
${who:+$who }Ready to merge: $done_with (head ${sha:0:7})." >/dev/null \
    || fail "could not comment on #$n"
done < <(jq -c '.[]' <<<"$prs")

[ "$failures" -eq 0 ] || exit 1
