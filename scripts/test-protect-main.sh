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
  *"rulesets/"[0-9]*) echo "\${EXISTING_RULESET:-null}" ;;
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

# A flag after the repo would become a required check nothing reports (#44 review).
run o/r --strict test; rc=$?
check "refuses a flag placed after the repo" "[ $rc -ne 0 ] && ! grep -q -- '-X' '$WORK/calls'"
run --strict o/r; rc=$?
check "refuses --strict with no check names (it would be silently dropped)" "[ $rc -ne 0 ] && ! grep -q -- '-X' '$WORK/calls'"

# A plain re-run keeps an existing ruleset's strict mode; --no-strict turns it off.
STRICT_ON='{"rules": [{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true}}]}'
EXISTING='[{"id": 42, "name": "protect-main"}]' EXISTING_RULESET="$STRICT_ON" run o/r test; rc=$?
check "a re-run without a flag keeps strict mode on" "[ $rc -eq 0 ] && jq -e '.rules[] | select(.type == \"required_status_checks\") | .parameters.strict_required_status_checks_policy == true' '$WORK/body.json' >/dev/null"
EXISTING='[{"id": 42, "name": "protect-main"}]' EXISTING_RULESET="$STRICT_ON" run --no-strict o/r test; rc=$?
check "--no-strict turns strict mode off" "[ $rc -eq 0 ] && jq -e '.rules[] | select(.type == \"required_status_checks\") | .parameters.strict_required_status_checks_policy == false' '$WORK/body.json' >/dev/null"

# GitHub Enterprise (#56): a bare owner/repo means github.com to gh, so the host
# must reach every gh api call, or the ruleset lands on the wrong server.
EXISTING='[{"id": 42, "name": "protect-main"}]' EXISTING_RULESET="$STRICT_ON" run ghe.example.com/o/r test; rc=$?
check "HOST/OWNER/REPO: every gh api call targets that host" "[ $rc -eq 0 ] && [ \"\$(wc -l <'$WORK/calls')\" -eq 3 ] && ! grep -v -- '--hostname ghe.example.com' '$WORK/calls'"
check "HOST/OWNER/REPO: the paths name owner/repo only" "grep -q -- '-X PUT repos/o/r/rulesets/42' '$WORK/calls' && ! grep -q 'ghe.example.com/o/r' '$WORK/calls'"
check "HOST/OWNER/REPO: the report names the host" "grep -q 'on ghe.example.com/o/r' '$WORK/out'"
run ghe.example.com/o/r test; rc=$?
check "HOST/OWNER/REPO: a new ruleset is created on that host" "[ $rc -eq 0 ] && grep -q -- '-X POST repos/o/r/rulesets --input - --hostname ghe.example.com' '$WORK/calls'"
EXISTING='[{"id": 42, "name": "protect-main"}]' EXISTING_RULESET="$STRICT_ON" run o/r test; rc=$?
check "owner/repo: no call names a host, so gh's default (GH_HOST) still applies" "[ $rc -eq 0 ] && [ \"\$(wc -l <'$WORK/calls')\" -eq 3 ] && ! grep -q -- '--hostname' '$WORK/calls'"
run a/b/c/d test; rc=$?
check "refuses a repo argument with too many parts" "[ $rc -ne 0 ] && [ ! -e '$WORK/calls' ]"
run /o/r test; rc=$?
check "refuses an empty host" "[ $rc -ne 0 ] && [ ! -e '$WORK/calls' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
