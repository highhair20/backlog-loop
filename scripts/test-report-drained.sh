#!/usr/bin/env bash
# Tests for scripts/report-drained.sh, which tells backlog-loop.sh a session found the
# backlog drained by writing a marker in the git directory (#77 review of #80).
# Usage: scripts/test-report-drained.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

git -C "$WORK" init -q -b main repo
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
(cd "$WORK/repo" && "$HERE/report-drained.sh" >/dev/null); rc=$?
check "writes the marker in the repo's git directory" "[ $rc -eq 0 ] && [ -s '$WORK/repo/.git/backlog-loop.drained' ]"

# A linked worktree shares the main checkout's marker, as it shares the lock.
git -C "$WORK/repo" worktree add -q "$WORK/wt" -b side
rm -f "$WORK/repo/.git/backlog-loop.drained"
(cd "$WORK/wt" && "$HERE/report-drained.sh" >/dev/null); rc=$?
check "from a linked worktree it writes to the common git directory" "[ $rc -eq 0 ] && [ -s '$WORK/repo/.git/backlog-loop.drained' ]"

mkdir -p "$WORK/plain"
(cd "$WORK/plain" && GIT_CEILING_DIRECTORIES="$WORK" "$HERE/report-drained.sh" >"$WORK/out" 2>&1); rc=$?
check "outside a git repository it fails with a message and writes nothing" "[ $rc -eq 1 ] && grep -q 'not a git repository' '$WORK/out' && [ ! -e '$WORK/plain/backlog-loop.drained' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
