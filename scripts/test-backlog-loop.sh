#!/usr/bin/env bash
# Tests for scripts/backlog-loop.sh, with fake `gh` and `claude` on PATH so no
# network or model is involved. Usage: scripts/test-backlog-loop.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_OF_TEMPLATE="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
BG=""
trap '[ -z "$BG" ] || kill "$BG" 2>/dev/null; touch "$WORK"/*/go 2>/dev/null; rm -rf "$WORK"' EXIT

# When the loop itself runs these tests, the driver's PID is in the environment.
unset BACKLOG_LOOP_PID BACKLOG_LOOP_STAGED BACKLOG_LOOP_ROOT
# The driver's settings too: a loop started as `MAX_ITEMS=2 scripts/backlog-loop.sh`
# passes them to every session, and its Verify then ran these nested drivers
# with a cap of 2 against 3-issue fixtures (#41).
unset MAX_ITEMS PACE_SECONDS MAX_RETRIES BACKOFF_SECONDS MODEL LOG_DIR BG_WAIT_SECONDS

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# A throwaway repo with the driver, its helper scripts, and a CLAUDE.md.
# $1 = name, $2 = claude fake behaviour: "progress" (decrements the count), "stall",
# or "block" (progress, but the first call waits for a `go` file, so a test can act
# while the driver is mid-item).
# Every fake claude also runs the lock check /work-next-item runs, recording its
# exit code, since the driver's own session must pass it.
setup() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/bin"
  git -C "$dir" init -q -b main
  cp "$HERE/backlog-loop.sh" "$HERE/check-verify-section.sh" "$HERE/loop-lock.sh" "$HERE/gh-auth-check.sh" "$dir/scripts/"
  printf '## Verify\n```sh\nmake test\n```\n' >"$dir/CLAUDE.md"
  echo 3 >"$dir/count"
  : >"$dir/calls"
  # gh: `issue list ... --jq ...` prints the remaining count.
  printf '#!/usr/bin/env bash\ncat "%s/count"\n' "$dir" >"$dir/bin/gh"
  {
    printf '#!/usr/bin/env bash\ncd "%s" || exit 1\necho x >>calls\n' "$dir"
    # The background-wait ceiling this session was given (#22).
    printf 'echo "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}" >>bgwait\n'
    printf 'echo "${BACKLOG_LOOP_STAGED:-unset} ${BACKLOG_LOOP_ROOT:-unset}" >>staging-env\n'
    printf 'scripts/loop-lock.sh check >>check-out 2>&1; echo $? >>check-rc\n'
    if [ "$2" = block ]; then
      # Gives up after 30s so a failed test cannot leave it running.
      printf ': >started\ni=0; while [ ! -e go ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n'
    fi
    if [ "$2" = flaky ]; then
      # Fails its first call with recognisable output, then makes progress.
      printf 'if [ "$(wc -l <calls)" -eq 1 ]; then echo "first attempt boom"; exit 1; fi\necho "second attempt ok"\n'
    fi
    if [ "$2" = sabotage ]; then
      # What a branch switch can do to the checkout under a running driver (#25):
      # remove a script the driver needs and replace the driver itself.
      printf 'rm -f scripts/loop-lock.sh scripts/check-verify-section.sh\nprintf "#!/usr/bin/env bash\\nexit 99\\n" >scripts/backlog-loop.sh\n'
    fi
    [ "$2" = stall ] || printf 'echo $(( $(cat count) - 1 )) >count\n'
    printf ': >finished\n'
  } >"$dir/bin/claude"
  chmod +x "$dir/bin/"* "$dir/scripts/"*
  echo "$dir"
}

run() { PATH="$1/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-$(basename "$1")" "$1/scripts/backlog-loop.sh" >"$1/out" 2>&1; }

# Wait up to 10s for file $1 to appear.
wait_for() {
  local i=0
  while [ ! -e "$1" ]; do
    [ "$i" -lt 100 ] || { echo "FAIL timed out waiting for $1" >&2; failures=$((failures + 1)); return 1; }
    sleep 0.1; i=$((i + 1))
  done
}

# A PID that is not running: a child that has already exited and been reaped.
dead_pid() { (exit 0) & local p=$!; wait "$p"; echo "$p"; }

P="$(setup progress progress)"
run "$P"; rc=$?
check "drains the backlog and exits 0" "[ $rc -eq 0 ]"
check "runs one item per remaining issue" "[ \$(wc -l <'$P/calls') -eq 3 ]"
check "the driver's own sessions pass the lock check" "[ \"\$(sort -u '$P/check-rc')\" = 0 ]"
check "releases the lock when it exits" "[ ! -e '$P/.git/backlog-loop.lock' ]"

S="$(setup stall stall)"
run "$S"; rc=$?
check "stops when an iteration makes no progress" "[ $rc -ne 0 ]"
check "does not retry a stalled loop" "[ \$(wc -l <'$S/calls') -eq 1 ]"
check "explains the no-progress stop" "grep -q 'no progress' '$S/out'"
check "releases the lock when it stops early" "[ ! -e '$S/.git/backlog-loop.lock' ]"

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

# The driver must not depend on the checkout its sessions change (#25).
B="$(setup sabotage sabotage)"
mkdir -p "$B/tmp"
TMPDIR="$B/tmp" run "$B"; rc=$?
check "survives its sessions replacing or deleting its scripts" "[ $rc -eq 0 ] && [ \$(wc -l <'$B/calls') -eq 3 ]"
check "releases the lock after its scripts vanished from the checkout" "[ ! -e '$B/.git/backlog-loop.lock' ]"
check "removes its private copy on exit" "[ -z \"\$(ls -A '$B/tmp')\" ]"
check "its sessions do not inherit the staging variables" "[ \"\$(sort -u '$B/staging-env')\" = 'unset unset' ]"

# An early exit (a bad setting, before the lock) must not leave the copy behind.
Q="$(setup earlyexit progress)"
mkdir -p "$Q/tmp"
TMPDIR="$Q/tmp" BG_WAIT_SECONDS=soon run "$Q"; rc=$?
check "an early exit removes the private copy too" "[ $rc -ne 0 ] && [ -z \"\$(ls -A '$Q/tmp')\" ]"

# Variables inherited from an outer driver must not skip staging or retarget it.
I="$(setup inherited progress)"
BACKLOG_LOOP_STAGED="$WORK" BACKLOG_LOOP_ROOT="$ROOT_OF_TEMPLATE" run "$I"; rc=$?
check "inherited staging variables do not redirect a nested driver" "[ $rc -eq 0 ] && [ \$(wc -l <'$I/calls') -eq 3 ] && [ ! -e '$I/.git/backlog-loop.lock' ]"

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

# Only the host origin points at counts (#15): bare `gh auth status` fails when any
# stored host has a stale token.
G="$(setup stalehost progress)"
git -C "$G" remote add origin https://ghe.example.com/o/r.git
printf '#!/usr/bin/env bash\n[ "$*" = "auth status --hostname ghe.example.com" ] && exit 0\n[ "$1" = auth ] && exit 1\ncat "%s/count"\n' "$G" >"$G/bin/gh"
run "$G"; rc=$?
check "a stale token for another host does not stop the loop" "[ $rc -eq 0 ] && [ \$(wc -l <'$G/calls') -eq 3 ]"

H="$(setup hostloggedout progress)"
git -C "$H" remote add origin https://ghe.example.com/o/r.git
printf '#!/usr/bin/env bash\n[ "$*" = "auth status" ] && exit 0\n[ "$1" = auth ] && exit 1\ncat "%s/count"\n' "$H" >"$H/bin/gh"
run "$H"; rc=$?
check "refuses to start when the repo's own host is logged out" "[ $rc -ne 0 ] && [ ! -s '$H/calls' ] && grep -q 'gh auth login --hostname ghe.example.com' '$H/out'"

# --- the single-instance lock ---
# A lock a live process holds (this test script stands in for the other run).
L="$(setup livelock progress)"
mkdir "$L/.git/backlog-loop.lock" && echo $$ >"$L/.git/backlog-loop.lock/pid"
run "$L"; rc=$?
check "refuses to start while a live run holds the lock" "[ $rc -ne 0 ] && [ ! -s '$L/calls' ] && grep -q 'holds the lock' '$L/out'"
check "the refusal says how to clear a stale lock" "grep -qF 'rm -rf $L/.git/backlog-loop.lock' '$L/out'"
check "a refused run leaves the holder's lock in place" "[ \"\$(cat '$L/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $$ ]"

# A lock whose owner is gone.
D="$(setup deadlock progress)"
DEAD="$(dead_pid)"
mkdir "$D/.git/backlog-loop.lock" && echo "$DEAD" >"$D/.git/backlog-loop.lock/pid"
run "$D"; rc=$?
check "reclaims a lock whose owner is dead and runs" "[ $rc -eq 0 ] && [ \$(wc -l <'$D/calls') -eq 3 ]"
check "says it reclaimed the stale lock" "grep -qi 'stale' '$D/out' && grep -q 'PID $DEAD' '$D/out'"

# Two drivers with different LOG_DIRs, and a session started outside the driver.
T="$(setup twodirs block)"
PATH="$T/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-twodirs-a" "$T/scripts/backlog-loop.sh" >"$T/out-a" 2>&1 &
BG=$!
wait_for "$T/started"
check "the first driver is mid-item" "[ -e '$T/started' ] && [ ! -e '$T/finished' ]"
PATH="$T/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-twodirs-b" "$T/scripts/backlog-loop.sh" >"$T/out-b" 2>&1; rc=$?
check "a second driver with another LOG_DIR is refused" "[ $rc -ne 0 ] && grep -q 'holds the lock' '$T/out-b' && [ \$(wc -l <'$T/calls') -eq 1 ]"
check "the refused driver leaves the first one's lock in place" "[ \"\$(cat '$T/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $BG ]"
"$T/scripts/loop-lock.sh" check >"$T/out-i" 2>&1; rc=$?
check "a session outside the driver fails the lock check" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$T/out-i'"
touch "$T/go"
wait "$BG"; rc=$?
BG=""
check "the first driver is unaffected and drains the backlog" "[ $rc -eq 0 ] && [ \$(wc -l <'$T/calls') -eq 3 ] && [ \"\$(sort -u '$T/check-rc')\" = 0 ]"

# kill -9 gives the driver no chance to release its lock.
K="$(setup hardkill block)"
PATH="$K/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-hardkill" "$K/scripts/backlog-loop.sh" >"$K/out-killed" 2>&1 &
BG=$!
wait_for "$K/started"
kill -9 "$BG"
wait "$BG" 2>/dev/null
check "a hard-killed driver leaves its lock behind" "[ \"\$(cat '$K/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $BG ]"
KILLED=$BG
BG=""
# Let the orphaned fake claude finish, so the next run starts from a settled count.
touch "$K/go"
wait_for "$K/finished"
run "$K"; rc=$?
check "the next run reclaims a hard-killed driver's lock" "[ $rc -eq 0 ] && grep -qi 'stale' '$K/out' && grep -q 'PID $KILLED' '$K/out'"
check "and works the rest of the backlog" "[ \"\$(cat '$K/count')\" = 0 ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
