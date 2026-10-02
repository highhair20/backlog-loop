#!/usr/bin/env bash
# Tests for scripts/protect-main.sh, with a fake `gh` on PATH that records each
# call and its request body. Usage: scripts/test-protect-main.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake gh. EXISTING: JSON list returned for GET .../rulesets. FAIL_WITH: if set,
# write it to stderr and exit 1 on POST/PUT. Records calls and bodies in $WORK.
cat >"$WORK/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$WORK/calls"
case "\$*" in
  *"-X POST"*|*"-X PUT"*)
    cat >"$WORK/body.json"
    if [ -n "\${FAIL_WITH:-}" ]; then echo "\$FAIL_WITH" >&2; exit 1; fi
    echo '{"id": 99, "name": "protect-main", "enforcement": "active", "current_user_can_bypass": "pull_requests_only"}' ;;
  *) echo "\${EXISTING:-[]}" ;;
esac
FAKE
chmod +x "$WORK/bin/gh"

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
run() { rm -f "$WORK/calls" "$WORK/body.json"; PATH="$WORK/bin:$PATH" "$HERE/protect-main.sh" "$@" >"$WORK/out" 2>&1; }

run o/r test lint; rc=$?
check "creates a ruleset when none exists" "[ $rc -eq 0 ] && grep -q -- '-X POST repos/o/r/rulesets' '$WORK/calls'"
check "targets the default branch" "jq -e '.conditions.ref_name.include == [\"~DEFAULT_BRANCH\"]' '$WORK/body.json' >/dev/null"
check "requires a PR with zero approvals" "jq -e '.rules[] | select(.type == \"pull_request\") | .parameters.required_approving_review_count == 0' '$WORK/body.json' >/dev/null"
check "requires every named check" "jq -e '[.rules[] | select(.type == \"required_status_checks\") | .parameters.required_status_checks[].context] == [\"test\", \"lint\"]' '$WORK/body.json' >/dev/null"
check "blocks force pushes and deletion" "jq -e '[.rules[].type] | index(\"non_fast_forward\") and index(\"deletion\")' '$WORK/body.json' >/dev/null"
check "admins bypass only through a PR" "jq -e '.bypass_actors == [{\"actor_id\": 5, \"actor_type\": \"RepositoryRole\", \"bypass_mode\": \"pull_request\"}]' '$WORK/body.json' >/dev/null"
check "reports the caller's bypass level" "grep -q pull_requests_only '$WORK/out'"

EXISTING='[{"id": 7, "name": "other"}, {"id": 42, "name": "protect-main"}]' run o/r test; rc=$?
check "updates the existing ruleset in place" "[ $rc -eq 0 ] && grep -q -- '-X PUT repos/o/r/rulesets/42' '$WORK/calls' && ! grep -q -- '-X POST' '$WORK/calls'"
check "looks up only the repo's own rulesets, not inherited org ones" "grep -q 'repos/o/r/rulesets?includes_parents=false' '$WORK/calls'"

run o/r; rc=$?
check "works without required checks" "[ $rc -eq 0 ] && ! jq -e '.rules[] | select(.type == \"required_status_checks\")' '$WORK/body.json' >/dev/null"
check "warns when no checks are required" "grep -qi 'no required checks' '$WORK/out'"

FAIL_WITH='HTTP 403: Upgrade to GitHub Pro or make this repository public to enable this feature.' run o/r test; rc=$?
check "fails on a plan error" "[ $rc -ne 0 ]"
check "explains the plan requirement" "grep -q 'GitHub Pro' '$WORK/out'"

run; rc=$?
check "refuses a missing repo argument" "[ $rc -ne 0 ] && [ ! -e '$WORK/calls' ]"
run not-a-repo; rc=$?
check "refuses a malformed repo argument" "[ $rc -ne 0 ] && [ ! -e '$WORK/calls' ]"

# --strict: a branch must be up to date with main before it merges (#43).
run o/r test; rc=$?
check "by default, a branch need not be up to date to merge" "[ $rc -eq 0 ] && jq -e '.rules[] | select(.type == \"required_status_checks\") | .parameters.strict_required_status_checks_policy == false' '$WORK/body.json' >/dev/null"
run --strict o/r test; rc=$?
check "--strict requires a branch to be up to date before merging" "[ $rc -eq 0 ] && jq -e '.rules[] | select(.type == \"required_status_checks\") | .parameters.strict_required_status_checks_policy == true' '$WORK/body.json' >/dev/null"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
