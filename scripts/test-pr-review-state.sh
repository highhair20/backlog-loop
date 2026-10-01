#!/usr/bin/env bash
# Tests for the PR review loop's PR-state check (.claude/hooks/pr-review-state.sh
# and pr-review-gate.sh): a loop must close, loudly, when its PR was merged or
# closed while the review ran, so fixes are never reported as landed on a PR whose
# branch no longer reaches main. A failed or impossible lookup must warn, never
# block or wedge.
# Usage: scripts/test-pr-review-state.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

URL=https://github.com/o/r/pull/12

# A fake gh that reports $FAKE_GH_STATE, or fails when it is "fail", and logs its
# arguments so a test can see which PR it was asked about.
mkdir -p "$WORK/fake"
cat >"$WORK/fake/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
if [ "$FAKE_GH_STATE" = fail ]; then echo "HTTP 502" >&2; exit 1; fi
if [ "$FAKE_GH_STATE" = hang ]; then sleep 30; echo OPEN; exit 0; fi
echo "$FAKE_GH_STATE"
EOF
chmod +x "$WORK/fake/gh"

# A PATH with the tools the hooks use but no gh, as in a cloud session.
mkdir -p "$WORK/nogh"
for tool in bash sh jq date dirname basename cat rm mv mkdir sed tr; do
  ln -s "$(command -v "$tool")" "$WORK/nogh/$tool"
done

# Each case gets a fresh copy of the hooks with a loop seeded for PR 12, so state
# from one cannot leak into the next.
setup() { # setup <case>
  local dir="$WORK/$1"
  mkdir -p "$dir/.claude"
  cp -R "$ROOT/.claude/hooks" "$dir/.claude/"
  "$dir/.claude/hooks/pr-review-state.sh" seed 12 "$URL" s
}
state_file() { printf '%s/.claude/state/pr-review/12.json' "$WORK/$1"; }
# run <case> <gh-state|nogh> <command...>  → stdout+stderr in $WORK/<case>/out, exit in .../rc
run() {
  local name=$1 gh=$2; shift 2
  local path="$WORK/fake:$PATH"
  [ "$gh" = nogh ] && path="$WORK/nogh"
  PATH="$path" FAKE_GH_STATE="$gh" FAKE_GH_LOG="$WORK/$name/gh.log" "$@" >"$WORK/$name/out" 2>&1
  echo $? >"$WORK/$name/rc"
}
record() { run "$1" "$2" "$WORK/$1/.claude/hooks/pr-review-state.sh" record 12 "$3"; }
gate() { run "$1" "$2" sh -c "printf '{\"session_id\":\"s\"}' | '$WORK/$1/.claude/hooks/pr-review-gate.sh'"; }
out_has() { grep -q -- "$2" "$WORK/$1/out"; }
rc_is() { [ "$(cat "$WORK/$1/rc")" = "$2" ]; }
blocks() { jq -e '.decision == "block"' "$WORK/$1/out" >/dev/null 2>&1; }

# --- record ---------------------------------------------------------------

setup rec-open
record rec-open OPEN 1
check "record, OPEN: records the round as today" "rc_is rec-open 0 && [ \"\$(jq -r '.round' '$(state_file rec-open)')\" = 1 ] && out_has rec-open 'round 1 recorded'"
check "record: looks up the PR by the URL the loop was seeded with" "grep -q -- '$URL' '$WORK/rec-open/gh.log'"

for st in MERGED CLOSED; do
  c=rec-$st
  setup "$c"
  record "$c" "$st" 1
  check "record, $st: closes the loop" "rc_is $c 0 && [ ! -f '$(state_file "$c")' ]"
  check "record, $st: warns loudly, naming the PR" "out_has $c WARNING && out_has $c 'PR 12' && out_has $c '$URL'"
  check "record, $st: says fixes need a new PR from main" "out_has $c 'new PR from main'"
  check "record, $st: does not report the round as recorded" "! out_has $c 'round 1 recorded'"
done

setup rec-fail
record rec-fail fail 1
check "record, failed lookup: still records the round" "rc_is rec-fail 0 && [ \"\$(jq -r '.round' '$(state_file rec-fail)')\" = 1 ]"
check "record, failed lookup: warns that the state was not checked" "out_has rec-fail 'not checked'"

setup rec-nogh
record rec-nogh nogh 0
check "record, no gh: still records the round" "rc_is rec-nogh 0 && [ \"\$(jq -r '.status' '$(state_file rec-nogh)')\" = done ]"
check "record, no gh: notes that the check was skipped" "out_has rec-nogh 'gh is not available'"

# --- gate -----------------------------------------------------------------

setup gate-open
gate gate-open OPEN
check "gate, OPEN: blocks as today" "blocks gate-open && [ \"\$(jq -r '.gate_blocks' '$(state_file gate-open)')\" = 1 ]"
check "gate, OPEN: adds no warning" "! jq -e '.reason | test(\"not checked\")' '$WORK/gate-open/out' >/dev/null"

for st in MERGED CLOSED; do
  c=gate-$st
  setup "$c"
  gate "$c" "$st"
  check "gate, $st: does not block" "rc_is $c 0 && ! blocks $c"
  check "gate, $st: closes the loop" "[ ! -f '$(state_file "$c")' ]"
  check "gate, $st: tells the user, naming the PR and the new-PR step" "jq -e '.systemMessage | test(\"PR 12\") and test(\"new PR from main\")' '$WORK/$c/out' >/dev/null"
done

setup gate-fail
gate gate-fail fail
check "gate, failed lookup: warns that the state was not checked" "jq -e '.reason | test(\"not checked\")' '$WORK/gate-fail/out' >/dev/null"
check "gate, failed lookup: keeps the loop, treating the PR as open" "blocks gate-fail && [ -f '$(state_file gate-fail)' ]"

setup gate-nogh
gate gate-nogh nogh
check "gate, no gh: notes the skipped check instead of erroring" "rc_is gate-nogh 0 && jq -e '.reason | test(\"gh is not available\")' '$WORK/gate-nogh/out' >/dev/null"
check "gate, no gh: still enforces the loop" "blocks gate-nogh"

setup gate-reviewing
"$WORK/gate-reviewing/.claude/hooks/pr-review-state.sh" reviewing 12 >/dev/null
gate gate-reviewing MERGED
check "gate, review in flight: stays quiet without calling gh" "rc_is gate-reviewing 0 && [ ! -s '$WORK/gate-reviewing/out' ] && [ ! -f '$WORK/gate-reviewing/gh.log' ]"

# --- review findings (#19 PR review) -------------------------------------

# A stalled gh must not eat the gate's 10s hook budget: the hook would be killed
# before it could warn, and enforcement would drop silently every turn.
setup gate-hang
start=$(date +%s)
gate gate-hang hang
took=$(( $(date +%s) - start ))
check "gate, gh hangs: returns well inside the hook's 10s timeout" "[ $took -lt 8 ]"
check "gate, gh hangs: warns that the state was not checked" "jq -e '.reason | test(\"not checked\")' '$WORK/gate-hang/out' >/dev/null"
check "gate, gh hangs: still enforces the loop" "blocks gate-hang"

# An empty URL must never reach gh: 'gh pr view \"\"' resolves the PR of whatever
# branch is checked out, which can be an unrelated PR.
setup gate-nourl
jq '.url = ""' "$(state_file gate-nourl)" >"$WORK/gate-nourl/s.tmp" && mv "$WORK/gate-nourl/s.tmp" "$(state_file gate-nourl)"
gate gate-nourl MERGED
check "gate, no URL: does not call gh" "[ ! -f '$WORK/gate-nourl/gh.log' ]"
check "gate, no URL: treats the state as unchecked and keeps enforcing" "blocks gate-nourl && jq -e '.reason | test(\"not checked\")' '$WORK/gate-nourl/out' >/dev/null"

# status is read-only: it must not call gh, and must not close the loop.
setup status-merged
run status-merged MERGED "$WORK/status-merged/.claude/hooks/pr-review-state.sh" status s
check "status: makes no network call" "[ ! -f '$WORK/status-merged/gh.log' ]"
check "status: leaves the loop in place" "[ -f '$(state_file status-merged)' ] && out_has status-merged 'BLOCK|'"

# --- instructions ---------------------------------------------------------

check "pr-created-review tells Claude to check the PR is open before pushing fixes" \
  "grep -q 'still open' '$ROOT/.claude/hooks/pr-created-review.sh'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
