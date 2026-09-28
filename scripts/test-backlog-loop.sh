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
  if [ "$2" = progress ]; then
    printf '#!/usr/bin/env bash\necho x >>"%s/calls"\necho $(( $(cat "%s/count") - 1 )) >"%s/count"\n' "$dir" "$dir" "$dir" >"$dir/bin/claude"
  else
    printf '#!/usr/bin/env bash\necho x >>"%s/calls"\n' "$dir" >"$dir/bin/claude"
  fi
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
