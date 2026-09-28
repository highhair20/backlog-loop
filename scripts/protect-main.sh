#!/usr/bin/env bash
# Create or update a "protect-main" branch ruleset: the one guardrail that holds
# however a command is phrased, because GitHub enforces it server-side.
#
#   - changes reach the default branch only through a pull request (0 approvals,
#     since a sole maintainer cannot approve their own PR)
#   - the named CI checks must pass before merging
#   - no force pushes, no deleting the branch
#   - repository admins may bypass ONLY when merging a PR ("pull_request" mode).
#     Claude's gh and git calls run as you, so an "always" bypass would hand it
#     direct pushes to main; this mode refuses them even from an admin.
#
# Idempotent: re-running updates the existing ruleset instead of adding another.
# Needs admin on the repo. Free on public repos; private ones need a paid plan.
#
# Usage: scripts/protect-main.sh <owner/repo> [required-check-name ...]
#   Check names are the CI job names as they appear on a PR (e.g. `test`).
set -euo pipefail

NAME=protect-main

die() { echo "protect-main: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <owner/repo> [required-check-name ...]"
repo="$1"; shift
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected <owner/repo>, got: $repo"
command -v gh >/dev/null || die "gh CLI not found"
command -v jq >/dev/null || die "jq not found"

[ $# -gt 0 ] || echo "protect-main: warning: no required checks named; PRs can merge with CI red. Pass your CI job names." >&2

body="$(jq -n --arg name "$NAME" --args '
  {
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    bypass_actors: [ { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request" } ],
    rules: (
      [ { type: "deletion" },
        { type: "non_fast_forward" },
        { type: "pull_request", parameters: {
            required_approving_review_count: 0,
            dismiss_stale_reviews_on_push: false,
            require_code_owner_review: false,
            require_last_push_approval: false,
            required_review_thread_resolution: false } } ]
      + (if ($ARGS.positional | length) > 0 then
          [ { type: "required_status_checks", parameters: {
                strict_required_status_checks_policy: false,
                required_status_checks: [ $ARGS.positional[] | { context: . } ] } } ]
        else [] end)
    )
  }' "$@")"

existing="$(gh api "repos/$repo/rulesets" --paginate | jq -r --arg name "$NAME" '.[] | select(.name == $name) | .id' | head -1)" \
  || die "could not list rulesets on $repo (does it exist, and are you an admin?)"

if [ -n "$existing" ]; then
  method=PUT; path="repos/$repo/rulesets/$existing"; verb=Updated
else
  method=POST; path="repos/$repo/rulesets"; verb=Created
fi

if ! result="$(printf '%s' "$body" | gh api -X "$method" "$path" --input - 2>&1)"; then
  if printf '%s' "$result" | grep -qiE 'upgrade to github|github pro'; then
    die "GitHub refused: rulesets on a private repo need GitHub Pro (or Team). Make the repo public or upgrade. ($result)"
  fi
  die "GitHub refused the ruleset: $result"
fi

printf '%s' "$result" | jq -r --arg verb "$verb" --arg repo "$repo" \
  '"\($verb) ruleset \"\(.name)\" (id \(.id), \(.enforcement)) on \($repo). Your bypass: \(.current_user_can_bypass // "unknown")."'
