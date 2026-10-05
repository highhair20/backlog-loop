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
# Usage: scripts/protect-main.sh [--strict|--no-strict] [host/]<owner/repo> [required-check-name ...]
#   With a bare owner/repo, gh picks the host as usual (GH_HOST, else github.com).
#   On GitHub Enterprise, name it instead (ghe.example.com/owner/repo, the form
#   scripts/gh-repo.sh --with-host prints), so the ruleset cannot land elsewhere.
#   Check names are the CI job names as they appear on a PR (e.g. `test`).
#   --strict: a PR's branch must be up to date with main before it can merge, so
#   its checks re-run against the latest main. Without it, two PRs that each pass
#   alone can merge into a red main (#43). The cost: every merge after another
#   needs an update and a fresh CI run. A re-run without either flag keeps the
#   existing ruleset's setting; --no-strict turns it off.
set -euo pipefail

NAME=protect-main

die() { echo "protect-main: $*" >&2; exit 1; }

# strict: "" means keep what an existing ruleset has (false for a new one), so a
# plain re-run never quietly turns it off.
strict=""
case "${1:-}" in
  --strict) strict=true; shift ;;
  --no-strict) strict=false; shift ;;
esac
[ $# -ge 1 ] || die "usage: $0 [--strict|--no-strict] [host/]<owner/repo> [required-check-name ...]"
target="$1"; shift
[[ "$target" =~ ^([A-Za-z0-9.-]+(:[0-9]+)?/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected [host/]<owner/repo>, got: $target"
# A third, leading part is the host; gh api takes it as --hostname. Without one,
# pass no --hostname, so gh's own choice (GH_HOST) still applies as before (#56).
host_args=()
case "$target" in
  */*/*) host="${target%%/*}"; repo="${target#*/}"; host_args=(--hostname "$host") ;;
  *) host="gh's default host"; repo="$target" ;;
esac
# A flag after the repo would become a required check no workflow ever reports,
# blocking every merge into main.
for check in "$@"; do
  case "$check" in -*) die "flags go before [host/]<owner/repo>; '$check' would become a required check name" ;; esac
done
# Strictness is part of the required-checks rule, which needs at least one check.
[ "$strict" != true ] || [ $# -gt 0 ] || die "--strict needs at least one required check name"
command -v gh >/dev/null || die "gh CLI not found"
command -v jq >/dev/null || die "jq not found"

[ $# -gt 0 ] || echo "protect-main: warning: no required checks named; PRs can merge with CI red. Pass your CI job names." >&2

# includes_parents=false: an org-level ruleset of the same name is listed by
# default, and its id cannot be updated through this repo's endpoint.
existing="$(gh api "repos/$repo/rulesets?includes_parents=false" --paginate ${host_args[@]+"${host_args[@]}"} | jq -r --arg name "$NAME" '.[] | select(.name == $name) | .id' | head -1)" \
  || die "could not list rulesets on $target (does it exist, are you an admin, and is gh logged in to $host?)"

# With neither --strict nor --no-strict, keep what the existing ruleset has.
if [ -z "$strict" ]; then
  strict=false
  if [ -n "$existing" ]; then
    strict="$(gh api "repos/$repo/rulesets/$existing" ${host_args[@]+"${host_args[@]}"} | jq -r '[.rules[]? | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy] | first // false')" \
      || die "could not read ruleset $existing on $target"
    [ "$strict" = true ] && echo "protect-main: keeping strict mode (branches must be up to date); pass --no-strict to turn it off" >&2
  fi
fi

body="$(jq -n --arg name "$NAME" --argjson strict "$strict" --args '
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
                strict_required_status_checks_policy: $strict,
                required_status_checks: [ $ARGS.positional[] | { context: . } ] } } ]
        else [] end)
    )
  }' "$@")"

if [ -n "$existing" ]; then
  method=PUT; path="repos/$repo/rulesets/$existing"; verb=Updated
else
  method=POST; path="repos/$repo/rulesets"; verb=Created
fi

if ! result="$(printf '%s' "$body" | gh api -X "$method" "$path" --input - ${host_args[@]+"${host_args[@]}"} 2>&1)"; then
  if printf '%s' "$result" | grep -qiE 'upgrade to github|github pro'; then
    die "GitHub refused: rulesets on a private repo need GitHub Pro (or Team). Make the repo public or upgrade. ($result)"
  fi
  die "GitHub refused the ruleset: $result"
fi

printf '%s' "$result" | jq -r --arg verb "$verb" --arg repo "$target" \
  '"\($verb) ruleset \"\(.name)\" (id \(.id), \(.enforcement)) on \($repo). Your bypass: \(.current_user_can_bypass // "unknown")."'
