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
# This workflow's own run puts a check on the PR it judges, so while it runs (or once
# a newer run has replaced it) GitHub reads the PR UNSTABLE. That check is set aside:
# UNSTABLE with every other check passing counts as CLEAN (#110). The PR is read
# again just before anything is written, so a label or push since the listing wins.
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
# The workflow whose checks are this run's own: Actions sets GITHUB_WORKFLOW to its name.
SELF_WORKFLOW="${GITHUB_WORKFLOW:-Ready to merge}"
failures=0
fail() { echo "ready-to-merge: $1" >&2; failures=$((failures + 1)); }
: "${GH_REPO:=$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# With "checks", the PRs' checks too (statusCheckRollup), which the workflow token can
# read only with checks: read and statuses: read. A workflow seeded before #110 lacks
# them, and sync never updates a seeded file, so without them this lists PRs bare.
list_prs() {
  gh pr list --state open --limit 1000 \
    --json "number,headRefName,headRefOid,baseRefName,mergeStateStatus,isCrossRepository,assignees,labels${1:+,statusCheckRollup}"
}
with_checks=1
# Loop PRs (branch <type>/<N>-<slug>) from this repo, never a fork's: a fork's PR is
# not the loop's, and the workflow's token could not label it.
loop_prs='[.[] | select((.isCrossRepository | not) and (.headRefName | test("^[a-z]+/[0-9]+-")))]'

prs=""
for attempt in $(seq 1 "$RETRIES"); do
  if [ "$with_checks" -eq 1 ] && raw="$(list_prs checks)"; then
    :
  elif raw="$(list_prs)"; then
    if [ "$with_checks" -eq 1 ]; then
      with_checks=0
      echo "ready-to-merge: could not read the PRs' checks, so this run cannot set its own aside and reads such a PR as not ready. Give .github/workflows/ready-to-merge.yml checks: read and statuses: read (the template's copy has them)." >&2
    fi
  else
    echo "ready-to-merge: could not list open PRs" >&2; exit 1
  fi
  prs="$(jq -c "$loop_prs" <<<"$raw")" || { echo "ready-to-merge: could not list open PRs" >&2; exit 1; }
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
  # others_pass: every check but this workflow's own has passed (a commit status
  # reads SUCCESS; a check run completed as SUCCESS, SKIPPED, or NEUTRAL). Never
  # true when the checks could not be read.
  if ! fields="$(jq -r --arg self "$SELF_WORKFLOW" '[.number, .headRefName, .headRefOid, .baseRefName, .mergeStateStatus, ([.labels[].name] | join(",")), ([.assignees[].login | "@" + .] | join(" ")),
      (if has("statusCheckRollup") | not then "false" else [.statusCheckRollup[]? | select(.__typename == "StatusContext" or (.workflowName // "") != $self)
        | if .__typename == "StatusContext" then .state == "SUCCESS"
          else .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") end] | all | tostring end)] | join("\u001f")' <<<"$pr")"; then
    fail "could not read a PR's fields"; continue
  fi
  # The unit separator, not a tab: read collapses runs of whitespace separators, so
  # an empty field (no labels) would shift the ones after it.
  IFS=$'\x1f' read -r n ref sha base state labels who others_pass <<<"$fields"
  # Only this workflow's own check is not passing: GitHub would read it CLEAN.
  [ "$state" != UNSTABLE ] || [ "$others_pass" != true ] || state=CLEAN
  issue="$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$ref")"
  labelled=0; case ",$labels," in *",$LABEL,"*) labelled=1 ;; esac

  # Anything but a mergeable state is not ready, UNKNOWN after the retries included.
  ready=0
  if [ "$state" = CLEAN ] || [ "$state" = HAS_HOOKS ]; then
    case ",$labels," in
      *,changes-requested,*) ;;
      # The issue must be in-review and free of every label Step 1.5 skips:
      # needs-attention also marks a review loop that hit its cap unresolved.
      *) jq -e --arg i "$issue" 'any(.[]; .number == ($i | tonumber) and ([.labels[].name] | any(. == "in-progress" or . == "needs-attention" or . == "blocked" or . == "no-auto-heal") | not))' <<<"$issues" >/dev/null && ready=1 ;;
    esac
  fi

  if [ "$ready" -eq 0 ]; then
    if [ "$state" = UNKNOWN ] && [ "$labelled" -eq 1 ]; then
      echo "ready-to-merge: #$n's merge state is still UNKNOWN after $RETRIES reads; taking it as not ready" >&2
    fi
    [ "$labelled" -eq 0 ] || remove_label "$n" || fail "could not remove $LABEL from #$n"
    continue
  fi
  # Read it again just before writing: changes-requested added, or a push, since the
  # listing wins, and the run that event queued judges the PR afresh.
  if ! view="$(gh pr view "$n" --json comments,labels,headRefOid)" \
     || ! bodies="$(jq -r '.comments[].body' <<<"$view")"; then
    fail "could not read #$n's comments"; continue
  fi
  if ! jq -e --arg sha "$sha" '.headRefOid == $sha and ([.labels[].name] | index("changes-requested") | not)' <<<"$view" >/dev/null; then
    echo "ready-to-merge: #$n changed since it was listed; leaving it to the run that change started" >&2
    continue
  fi
  [ "$labelled" -eq 1 ] || add_label "$n" || fail "could not add $LABEL to #$n"
  grep -qF "$MARK $sha" <<<"$bodies" && continue

  # Claim "up to date" only when checked: CLEAN alone does not mean it without a
  # strict ruleset. A failed compare holds the comment back, so a later run retries it.
  if ! behind="$(gh api "repos/$GH_REPO/compare/$base...$sha" --jq .behind_by)" || ! [[ "$behind" =~ ^[0-9]+$ ]]; then
    fail "could not compare #$n with $base; not announcing it yet"; continue
  fi
  done_with="the loop is done with #$issue and required checks pass"
  [ "$behind" -ne 0 ] || done_with="the loop is done with #$issue, required checks pass, and the branch is up to date with $base"
  gh pr comment "$n" --body "$MARK $sha -->
${who:+$who }Ready to merge: $done_with (head ${sha:0:7})." >/dev/null \
    || fail "could not comment on #$n"
done < <(jq -c '.[]' <<<"$prs")

[ "$failures" -eq 0 ] || exit 1
