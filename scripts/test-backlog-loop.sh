#!/usr/bin/env bash
# Tests for scripts/backlog-loop.sh, with fake `gh` and `claude` on PATH so no
# network or model is involved. Usage: scripts/test-backlog-loop.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# A throwaway repo with the driver, the checker, and a CLAUDE.md.
# $1 = name, $2 = claude fake behaviour: "progress" (decrements the count) or "stall".
setup() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/bin"
  cp "$HERE/backlog-loop.sh" "$HERE/check-verify-section.sh" "$dir/scripts/"
  printf '## Verify\n```sh\nmake test\n```\n' >"$dir/CLAUDE.md"
  echo 3 >"$dir/count"
  : >"$dir/calls"
  # gh: `issue list ... --jq ...` prints the remaining count.
  printf '#!/usr/bin/env bash\ncat "%s/count"\n' "$dir" >"$dir/bin/gh"
  local record="echo \"\${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}\" >>\"$dir/bgwait\""
  case "$2" in
    progress)
      printf '#!/usr/bin/env bash\n%s\necho x >>"%s/calls"\necho $(( $(cat "%s/count") - 1 )) >"%s/count"\n' "$record" "$dir" "$dir" "$dir" >"$dir/bin/claude" ;;
    flaky)
      printf '#!/usr/bin/env bash\n%s\necho x >>"%s/calls"\nif [ "$(wc -l <"%s/calls")" -eq 1 ]; then echo "first attempt boom"; exit 1; fi\necho "second attempt ok"\necho $(( $(cat "%s/count") - 1 )) >"%s/count"\n' "$record" "$dir" "$dir" "$dir" "$dir" >"$dir/bin/claude" ;;
    *)
      printf '#!/usr/bin/env bash\n%s\necho x >>"%s/calls"\n' "$record" "$dir" >"$dir/bin/claude" ;;
  esac
  chmod +x "$dir/bin/"* "$dir/scripts/"*
  echo "$dir"
}

run() { PATH="$1/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-$(basename "$1")" "$1/scripts/backlog-loop.sh" >"$1/out" 2>&1; }

P="$(setup progress progress)"
run "$P"; rc=$?
check "drains the backlog and exits 0" "[ $rc -eq 0 ]"
check "runs one item per remaining issue" "[ \$(wc -l <'$P/calls') -eq 3 ]"

S="$(setup stall stall)"
run "$S"; rc=$?
check "stops when an iteration makes no progress" "[ $rc -ne 0 ]"
check "does not retry a stalled loop" "[ \$(wc -l <'$S/calls') -eq 1 ]"
check "explains the no-progress stop" "grep -q 'no progress' '$S/out'"

check "gives claude a 45-minute background-wait ceiling by default" "[ \"\$(head -1 '$P/bgwait')\" = 2700000 ]"

W="$(setup bgwait progress)"
BG_WAIT_SECONDS=60 run "$W"
check "BG_WAIT_SECONDS sets the ceiling (in ms)" "[ \"\$(head -1 '$W/bgwait')\" = 60000 ]"

# Bash arithmetic reads a leading zero as octal: 0600 would become 384s, 08 an error.
Z="$(setup zeropad progress)"
BG_WAIT_SECONDS=0600 run "$Z"
check "reads a zero-padded BG_WAIT_SECONDS as decimal" "[ \"\$(head -1 '$Z/bgwait')\" = 600000 ]"
E="$(setup eight progress)"
BG_WAIT_SECONDS=08 run "$E"; rc=$?
check "accepts 08 (not a bad octal number)" "[ $rc -eq 0 ] && [ \"\$(head -1 '$E/bgwait')\" = 8000 ]"

X="$(setup badwait progress)"
BG_WAIT_SECONDS=soon run "$X"; rc=$?
check "rejects a non-numeric BG_WAIT_SECONDS before any item" "[ $rc -ne 0 ] && [ ! -s '$X/calls' ]"

F="$(setup flaky flaky)"
BACKOFF_SECONDS=0 run "$F"; rc=$?
flogs="$WORK/logs-flaky"
check "a retried item still completes" "[ $rc -eq 0 ]"
check "keeps the failed attempt's log" "grep -l 'first attempt boom' '$flogs'/item-*.log >/dev/null"
check "writes the retry to its own log" "grep -l 'second attempt ok' '$flogs'/item-*.attempt2.log >/dev/null"
check "names the failed attempt's log in the retry message" "grep -q 'attempt 1 failed (log: ' '$F/out'"

N="$(setup noverify progress)"
printf '## Verify\n```sh\n# test:\n```\n' >"$N/CLAUDE.md"
run "$N"; rc=$?
check "refuses to start without Verify commands" "[ $rc -ne 0 ] && [ ! -s '$N/calls' ]"

# Preflight: a missing tool or a logged-out gh fails fast instead of backing off.
C="$(setup noclaude progress)"
rm "$C/bin/claude"
PATH="$C/bin:/usr/bin:/bin" PACE_SECONDS=0 BACKOFF_SECONDS=60 LOG_DIR="$WORK/logs-noclaude" \
  "$C/scripts/backlog-loop.sh" >"$C/out" 2>&1; rc=$?
check "refuses to start without claude on PATH" "[ $rc -ne 0 ] && grep -q 'claude not found' '$C/out'"

A="$(setup noauth progress)"
printf '#!/usr/bin/env bash\n[ "$1" = auth ] && exit 1\ncat "%s/count"\n' "$A" >"$A/bin/gh"
run "$A"; rc=$?
check "refuses to start when gh is not authenticated" "[ $rc -ne 0 ] && [ ! -s '$A/calls' ] && grep -q 'gh auth login' '$A/out'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
