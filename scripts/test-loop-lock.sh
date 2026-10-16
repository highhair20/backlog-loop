#!/usr/bin/env bash
# Tests for scripts/loop-lock.sh, in throwaway git repos so the real lock is never
# touched. Usage: scripts/test-loop-lock.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
LIVE=""     # a live process standing in for another run
HOLDERS=""  # more of them, for the race test
# shellcheck disable=SC2086  # $HOLDERS is a list of PIDs
trap '[ -z "$LIVE$HOLDERS" ] || { kill $LIVE $HOLDERS; wait $LIVE $HOLDERS; } 2>/dev/null; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# When the loop itself runs these tests, the driver's PID is in the environment.
unset BACKLOG_LOOP_PID BACKLOG_LOOP_STAGED BACKLOG_LOOP_ROOT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# A throwaway repo holding a committed copy of the script. Prints its path.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts"
  git -C "$dir" init -q -b main
  cp "$HERE/loop-lock.sh" "$dir/scripts/"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m init
  echo "$dir"
}

# A PID that is not running: a child that has already exited and been reaped.
dead_pid() { (exit 0) & local p=$!; wait "$p"; echo "$p"; }

# A lock left by $2 (a PID, or any other text) in repo $1; no pid file if $2 is empty.
plant_lock() {
  mkdir "$1/.git/backlog-loop.lock"
  [ -z "$2" ] || echo "$2" >"$1/.git/backlog-loop.lock/pid"
}

# A second live process, to stand in for another run.
sleep 300 &
LIVE=$!

# --- a free lock ---
R="$(new_repo free)"
LOCK="$R/.git/backlog-loop.lock"
check "the lock lives in the git directory" "[ \"\$('$R/scripts/loop-lock.sh' path)\" = '$LOCK' ]"
check "the lock path ignores LOG_DIR" "[ \"\$(LOG_DIR=/elsewhere '$R/scripts/loop-lock.sh' path)\" = '$LOCK' ]"
out="$("$R/scripts/loop-lock.sh" check 2>&1)"; rc=$?
check "check passes quietly when the lock is free" "[ $rc -eq 0 ] && [ -z '$out' ]"
"$R/scripts/loop-lock.sh" acquire $$ >"$R/out" 2>&1; rc=$?
check "acquire takes a free lock" "[ $rc -eq 0 ] && [ \"\$(cat '$LOCK/pid')\" = $$ ]"

# --- a lock held by a live process ---
"$R/scripts/loop-lock.sh" acquire "$LIVE" >"$R/out" 2>&1; rc=$?
check "acquire refuses a lock a live process holds" "[ $rc -eq 1 ]"
check "a refused acquire leaves the holder's lock alone" "[ \"\$(cat '$LOCK/pid')\" = $$ ]"
check "the refusal names the holder" "grep -q 'holds the lock' '$R/out' && grep -q 'PID $$' '$R/out'"
# The path in the hint is absolute, so it is safe to paste from any directory.
check "the refusal says how to clear a stale lock" "grep -qF 'rm -rf $LOCK' '$R/out'"
"$R/scripts/loop-lock.sh" check >"$R/out" 2>&1; rc=$?
check "check fails while another run holds the lock" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$R/out'"
check "a failed check says how to clear a stale lock" "grep -qF 'rm -rf $LOCK' '$R/out'"
check "a failed check leaves the lock alone" "[ \"\$(cat '$LOCK/pid')\" = $$ ]"
BACKLOG_LOOP_PID=$$ "$R/scripts/loop-lock.sh" check >"$R/out" 2>&1; rc=$?
check "check passes for the session the holder started" "[ $rc -eq 0 ]"
BACKLOG_LOOP_PID=$LIVE "$R/scripts/loop-lock.sh" check >"$R/out" 2>&1; rc=$?
check "check fails for a session another driver started" "[ $rc -eq 1 ]"
(cd "$R/scripts" && ./loop-lock.sh check >"$R/out" 2>&1); rc=$?
check "check works when run from another directory" "[ $rc -eq 1 ]"

# --- release ---
"$R/scripts/loop-lock.sh" release "$LIVE" >"$R/out" 2>&1; rc=$?
check "release by a non-owner fails and keeps the lock" "[ $rc -ne 0 ] && [ \"\$(cat '$LOCK/pid')\" = $$ ]"
"$R/scripts/loop-lock.sh" release $$ >"$R/out" 2>&1; rc=$?
check "release by the owner removes the lock" "[ $rc -eq 0 ] && [ ! -e '$LOCK' ]"
"$R/scripts/loop-lock.sh" release $$ >"$R/out" 2>&1; rc=$?
check "release with no lock is a quiet no-op" "[ $rc -eq 0 ] && [ ! -s '$R/out' ]"

# --- a stale lock: its owner is no longer running ---
S="$(new_repo stale)"
DEAD="$(dead_pid)"
plant_lock "$S" "$DEAD"
"$S/scripts/loop-lock.sh" acquire $$ >"$S/out" 2>&1; rc=$?
check "acquire reclaims a lock whose owner is dead" "[ $rc -eq 0 ] && [ \"\$(cat '$S/.git/backlog-loop.lock/pid')\" = $$ ]"
check "reclaiming says so, naming the dead owner" "grep -qi 'stale' '$S/out' && grep -q 'PID $DEAD' '$S/out'"
check "reclaiming leaves nothing else behind" "[ \"\$(ls '$S/.git' | grep -c backlog-loop)\" = 1 ] && [ \"\$(ls '$S/.git/backlog-loop.lock')\" = pid ]"

C="$(new_repo stalecheck)"
plant_lock "$C" "$DEAD"
"$C/scripts/loop-lock.sh" check >"$C/out" 2>&1; rc=$?
check "check passes over a stale lock and clears it" "[ $rc -eq 0 ] && [ ! -e '$C/.git/backlog-loop.lock' ]"
check "check reports the stale lock it cleared" "grep -qi 'stale' '$C/out' && grep -q 'PID $DEAD' '$C/out'"

# A reclaim another run has already begun is not repeated: that run is starting.
B="$(new_repo reclaiming)"
plant_lock "$B" "$DEAD"
mkdir "$B/.git/backlog-loop.lock/reclaiming"
"$B/scripts/loop-lock.sh" acquire $$ >"$B/out" 2>&1; rc=$?
check "acquire yields to a reclaim already under way" "[ $rc -eq 1 ] && [ \"\$(cat '$B/.git/backlog-loop.lock/pid')\" = '$DEAD' ]"
check "yielding says how to clear the lock" "grep -qF 'rm -rf $B/.git/backlog-loop.lock' '$B/out'"

# A lock left under the caller's own PID. A driver that gets the same PID on every
# start (a container's entrypoint) meets this after a kill; the liveness test alone
# would find the caller itself and refuse forever.
O="$(new_repo ownpid)"
plant_lock "$O" $$
"$O/scripts/loop-lock.sh" acquire $$ >"$O/out" 2>&1; rc=$?
check "acquire takes over a lock left under its own PID" "[ $rc -eq 0 ] && [ \"\$(cat '$O/.git/backlog-loop.lock/pid')\" = $$ ] && [ \"\$(ls '$O/.git/backlog-loop.lock')\" = pid ]"
check "taking it over says the lock was stale" "grep -qi 'stale' '$O/out' && grep -q '$$' '$O/out'"
mkdir "$O/.git/backlog-loop.lock/reclaiming"
"$O/scripts/loop-lock.sh" acquire $$ >"$O/out" 2>&1; rc=$?
check "but yields if another run is already reclaiming it" "[ $rc -eq 1 ] && grep -qF 'rm -rf $O/.git/backlog-loop.lock' '$O/out'"

# Several runs starting at once after a crash: one takes the lock, the rest are refused.
# Each racer acquires for a different long-lived process, as real drivers would.
Q="$(new_repo race)"
plant_lock "$Q" "$DEAD"
racers=""
for i in 1 2 3 4 5 6; do
  sleep 300 &
  HOLDERS="$HOLDERS $!"
  "$Q/scripts/loop-lock.sh" acquire $! >"$Q/race-$i" 2>&1 &
  racers="$racers $!"
done
wins=0
for p in $racers; do wait "$p" && wins=$((wins + 1)); done
check "of several runs reclaiming one stale lock, exactly one takes it" "[ $wins -eq 1 ]"
# shellcheck disable=SC2086  # $HOLDERS is a list of PIDs
check "and the lock records one of them" "printf '%s\n' $HOLDERS | grep -qx \"\$(cat '$Q/.git/backlog-loop.lock/pid')\""
check "racing reclaims leave nothing else behind" "[ \"\$(ls '$Q/.git' | grep -c backlog-loop)\" = 1 ] && [ \"\$(ls '$Q/.git/backlog-loop.lock')\" = pid ]"

# --- a lock that cannot be judged is respected, never reclaimed ---
for spec in "no PID|" "a garbage PID|not-a-pid"; do
  what="${spec%%|*}"
  U="$(new_repo "unjudged-${what// /-}")"
  plant_lock "$U" "${spec#*|}"
  "$U/scripts/loop-lock.sh" acquire $$ >"$U/out" 2>&1; rc=$?
  check "acquire refuses a lock with $what" "[ $rc -eq 1 ] && [ -d '$U/.git/backlog-loop.lock' ] && ! grep -qx $$ '$U/.git/backlog-loop.lock/pid' 2>/dev/null"
  check "refusing a lock with $what says how to clear it" "grep -qF 'rm -rf $U/.git/backlog-loop.lock' '$U/out'"
  "$U/scripts/loop-lock.sh" check >"$U/out" 2>&1; rc=$?
  check "check fails on a lock with $what" "[ $rc -eq 1 ] && [ -d '$U/.git/backlog-loop.lock' ]"
done

# --- worktrees of one repo share the backlog, so they share the lock ---
W="$(new_repo worktrees)"
git -C "$W" worktree add -q "$WORK/worktree-b" -b other >/dev/null 2>&1
"$W/scripts/loop-lock.sh" acquire $$ >/dev/null 2>&1
"$WORK/worktree-b/scripts/loop-lock.sh" check >"$W/out" 2>&1; rc=$?
check "a second worktree sees the first one's lock" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$W/out'"

# --- the clone ID: random, made once, shared by the clone's worktrees (#108) ---
I="$(new_repo cloneid)"
id1="$("$I/scripts/loop-lock.sh" clone-id 2>"$I/out")"; rc=$?
check "clone-id prints a 16-hex-digit ID" "[ $rc -eq 0 ] && printf '%s' '$id1' | grep -qxE '[0-9a-f]{16}'"
check "clone-id keeps it in the git directory" "[ \"\$(cat '$I/.git/backlog-loop.clone-id')\" = '$id1' ]"
check "clone-id prints the same ID every time" "[ \"\$('$I/scripts/loop-lock.sh' clone-id)\" = '$id1' ]"
git -C "$I" worktree add -q "$WORK/cloneid-wt" -b wt >/dev/null 2>&1
check "a worktree of the clone has the same ID" "[ \"\$('$WORK/cloneid-wt/scripts/loop-lock.sh' clone-id)\" = '$id1' ]"
I2="$(new_repo cloneid2)"
check "another clone gets another ID" "[ \"\$('$I2/scripts/loop-lock.sh' clone-id)\" != '$id1' ]"
echo "not-an-id" >"$I2/.git/backlog-loop.clone-id"
"$I2/scripts/loop-lock.sh" clone-id >"$I2/out" 2>&1; rc=$?
check "a corrupt clone ID is an error, naming the file to remove" "[ $rc -eq 2 ] && grep -qF '$I2/.git/backlog-loop.clone-id' '$I2/out'"
I3="$(new_repo cloneidrace)"
racers=""
for i in 1 2 3 4 5 6; do
  "$I3/scripts/loop-lock.sh" clone-id >"$I3/id-$i" 2>&1 &
  racers="$racers $!"
done
# shellcheck disable=SC2086  # $racers is a list of PIDs
wait $racers
check "clones racing to make the ID all get the same one" "[ \"\$(cat '$I3'/id-* | sort -u | wc -l | tr -d ' ')\" = 1 ] && [ \"\$(cat '$I3/id-1')\" = \"\$(cat '$I3/.git/backlog-loop.clone-id')\" ] && [ \"\$(ls '$I3/.git' | grep -c clone-id)\" = 1 ]"

# --- a /work-next-item session takes the lock too, by run ID, for at most 3 hours (#108) ---
# A session lock as a session would leave it: run $2 took it at epoch $3.
plant_session() {
  mkdir "$1/.git/backlog-loop.lock"
  echo "$2 $3" >"$1/.git/backlog-loop.lock/run"
}
NOW="$(date +%s)"
E="$(new_repo session)"
ELOCK="$E/.git/backlog-loop.lock"
"$E/scripts/loop-lock.sh" acquire-session run-a >"$E/out" 2>&1; rc=$?
check "acquire-session takes a free lock, recording the run and the time" "[ $rc -eq 0 ] && [ \"\$(cut -d' ' -f1 '$ELOCK/run')\" = run-a ] && [ \"\$(cut -d' ' -f2 '$ELOCK/run')\" -ge $NOW ] && [ ! -e '$ELOCK/pid' ]"
"$E/scripts/loop-lock.sh" acquire-session run-a >"$E/out" 2>&1; rc=$?
check "acquire-session passes again for the run that holds it" "[ $rc -eq 0 ] && [ \"\$(cut -d' ' -f1 '$ELOCK/run')\" = run-a ]"
"$E/scripts/loop-lock.sh" acquire-session run-b >"$E/out" 2>&1; rc=$?
check "acquire-session refuses another run while the session's lock is live" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$E/out' && grep -q 'run-a' '$E/out' && [ \"\$(cut -d' ' -f1 '$ELOCK/run')\" = run-a ]"
check "the refusal says how to clear it" "grep -qF 'rm -rf $ELOCK' '$E/out'"
"$E/scripts/loop-lock.sh" acquire $$ >"$E/out" 2>&1; rc=$?
check "a driver is refused while a session holds the lock" "[ $rc -eq 1 ] && grep -q 'run-a' '$E/out' && [ ! -e '$ELOCK/pid' ]"
"$E/scripts/loop-lock.sh" check >"$E/out" 2>&1; rc=$?
check "check fails while a session holds the lock" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$E/out'"
"$E/scripts/loop-lock.sh" release-session run-b >"$E/out" 2>&1; rc=$?
check "release-session by another run fails and keeps the lock" "[ $rc -eq 1 ] && [ \"\$(cut -d' ' -f1 '$ELOCK/run')\" = run-a ]"
"$E/scripts/loop-lock.sh" release-session run-a >"$E/out" 2>&1; rc=$?
check "release-session by its run removes the lock" "[ $rc -eq 0 ] && [ ! -e '$ELOCK' ]"
"$E/scripts/loop-lock.sh" release-session run-a >"$E/out" 2>&1; rc=$?
check "release-session with no lock is a quiet no-op" "[ $rc -eq 0 ] && [ ! -s '$E/out' ]"

# Expiry: a session that died never releases, so its lock lasts 3 hours from when it was taken.
F="$(new_repo session-young)"
plant_session "$F" run-old $((NOW - 10700))
"$F/scripts/loop-lock.sh" acquire-session run-new >"$F/out" 2>&1; rc=$?
check "a session lock just under 3 hours old is still respected" "[ $rc -eq 1 ] && grep -q 'run-old' '$F/out'"
G="$(new_repo session-stale)"
plant_session "$G" run-old $((NOW - 10900))
"$G/scripts/loop-lock.sh" acquire-session run-new >"$G/out" 2>&1; rc=$?
check "a session lock over 3 hours old is reclaimed by a session" "[ $rc -eq 0 ] && [ \"\$(cut -d' ' -f1 '$G/.git/backlog-loop.lock/run')\" = run-new ]"
check "reclaiming it says so, naming the old run" "grep -qi 'stale' '$G/out' && grep -q 'run-old' '$G/out'"
check "reclaiming it leaves nothing else behind" "[ \"\$(ls '$G/.git' | grep -c backlog-loop.lock)\" = 1 ] && [ \"\$(ls '$G/.git/backlog-loop.lock')\" = run ]"
H="$(new_repo session-stale-driver)"
plant_session "$H" run-old $((NOW - 10900))
"$H/scripts/loop-lock.sh" acquire $$ >"$H/out" 2>&1; rc=$?
check "a session lock over 3 hours old is reclaimed by a driver" "[ $rc -eq 0 ] && [ \"\$(cat '$H/.git/backlog-loop.lock/pid')\" = $$ ] && [ ! -e '$H/.git/backlog-loop.lock/run' ]"
J="$(new_repo session-garbage)"
plant_session "$J" run-old not-a-time
"$J/scripts/loop-lock.sh" acquire-session run-new >"$J/out" 2>&1; rc=$?
check "a session lock with no readable time is refused, never reclaimed" "[ $rc -eq 1 ] && grep -qF 'rm -rf $J/.git/backlog-loop.lock' '$J/out' && grep -q 'run-old' '$J/.git/backlog-loop.lock/run'"

K2="$(new_repo session-future)"
plant_session "$K2" run-future $((NOW + 3600))
"$K2/scripts/loop-lock.sh" acquire-session run-new >"$K2/out" 2>&1; rc=$?
check "a session lock dated an hour ahead is stale, not live forever" "[ $rc -eq 0 ] && grep -q '^run-new ' '$K2/.git/backlog-loop.lock/run'"
K3="$(new_repo session-skew)"
plant_session "$K3" run-skew $((NOW + 60))
"$K3/scripts/loop-lock.sh" acquire-session run-new >"$K3/out" 2>&1; rc=$?
check "a session lock a minute ahead (clock correction) is still live" "[ $rc -eq 1 ] && grep -q 'run-skew' '$K3/.git/backlog-loop.lock/run'"
K4="$(new_repo session-extra)"
plant_session "$K4" run-old "$NOW extra"
"$K4/scripts/loop-lock.sh" acquire-session run-new >"$K4/out" 2>&1; rc=$?
check "a session lock with extra fields is refused, never reclaimed" "[ $rc -eq 1 ] && grep -qF 'rm -rf $K4/.git/backlog-loop.lock' '$K4/out' && grep -q 'run-old' '$K4/.git/backlog-loop.lock/run'"
K5="$(new_repo session-over-dead-driver)"
plant_lock "$K5" "$DEAD"
"$K5/scripts/loop-lock.sh" acquire-session run-new >"$K5/out" 2>&1; rc=$?
check "a session reclaims a lock whose driver is dead" "[ $rc -eq 0 ] && grep -q '^run-new ' '$K5/.git/backlog-loop.lock/run' && [ ! -e '$K5/.git/backlog-loop.lock/pid' ] && grep -q 'PID $DEAD' '$K5/out'"

# Several sessions reclaiming one expired session lock at once: one takes it.
K6="$(new_repo session-stale-race)"
plant_session "$K6" run-old $((NOW - 10900))
racers=""
for i in 1 2 3 4 5 6; do
  "$K6/scripts/loop-lock.sh" acquire-session "run-$i" >"$K6/race-$i" 2>&1 &
  racers="$racers $!"
done
wins=0
for p in $racers; do wait "$p" && wins=$((wins + 1)); done
check "of several sessions reclaiming one expired lock, exactly one takes it" "[ $wins -eq 1 ] && grep -qxE 'run-[1-6] [0-9]+' '$K6/.git/backlog-loop.lock/run' && [ \"\$(ls '$K6/.git' | grep -c backlog-loop.lock)\" = 1 ] && [ \"\$(ls '$K6/.git/backlog-loop.lock')\" = run ]"

# A session the driver started: the driver's lock covers it, and it takes no lock of its own.
D="$(new_repo session-driver)"
"$D/scripts/loop-lock.sh" acquire $$ >/dev/null 2>&1
BACKLOG_LOOP_PID=$$ "$D/scripts/loop-lock.sh" acquire-session run-d >"$D/out" 2>&1; rc=$?
check "acquire-session passes in a session the lock's driver started" "[ $rc -eq 0 ] && [ \"\$(cat '$D/.git/backlog-loop.lock/pid')\" = $$ ] && [ ! -e '$D/.git/backlog-loop.lock/run' ]"
BACKLOG_LOOP_PID=$$ "$D/scripts/loop-lock.sh" release-session run-d >"$D/out" 2>&1; rc=$?
check "release-session leaves the driver's lock alone, quietly" "[ $rc -eq 0 ] && [ \"\$(cat '$D/.git/backlog-loop.lock/pid')\" = $$ ] && [ ! -s '$D/out' ]"
"$D/scripts/loop-lock.sh" acquire-session run-d >"$D/out" 2>&1; rc=$?
check "acquire-session outside the driver is refused" "[ $rc -eq 1 ] && grep -q 'PID $$' '$D/out'"
BACKLOG_LOOP_PID=$LIVE "$D/scripts/loop-lock.sh" acquire-session run-d >"$D/out" 2>&1; rc=$?
check "acquire-session started by another driver is refused" "[ $rc -eq 1 ]"
"$D/scripts/loop-lock.sh" release-session run-d >"$D/out" 2>&1; rc=$?
check "release-session outside the driver leaves the driver's lock" "[ $rc -eq 1 ] && [ \"\$(cat '$D/.git/backlog-loop.lock/pid')\" = $$ ]"
BACKLOG_LOOP_PID=$LIVE "$D/scripts/loop-lock.sh" release-session run-d >"$D/out" 2>&1; rc=$?
check "release-session under another driver leaves the lock" "[ $rc -eq 1 ] && [ \"\$(cat '$D/.git/backlog-loop.lock/pid')\" = $$ ]"

# Several sessions starting at once: exactly one takes the lock.
V="$(new_repo session-race)"
racers=""
for i in 1 2 3 4 5 6; do
  "$V/scripts/loop-lock.sh" acquire-session "run-$i" >"$V/race-$i" 2>&1 &
  racers="$racers $!"
done
wins=0
for p in $racers; do wait "$p" && wins=$((wins + 1)); done
check "of several sessions starting at once, exactly one takes the lock" "[ $wins -eq 1 ] && grep -qxE 'run-[1-6] [0-9]+' '$V/.git/backlog-loop.lock/run'"

# --- errors are not reported as "held", and never pass ---
N="$WORK/not-a-repo"
mkdir -p "$N/scripts" && cp "$HERE/loop-lock.sh" "$N/scripts/"
for sub in "acquire $$" check "acquire-session run-n" clone-id; do
  # shellcheck disable=SC2086  # $sub is a subcommand plus its argument
  "$N/scripts/loop-lock.sh" $sub >"$N/out" 2>&1; rc=$?
  check "${sub%% *} outside a git repo is an error, not a pass" "[ $rc -eq 2 ] && grep -q 'not a git repository' '$N/out'"
done

# root ignores directory permissions, so this case cannot be set up as root.
if [ "$(id -u)" -ne 0 ]; then
  X="$(new_repo readonly)"
  chmod a-w "$X/.git"
  "$X/scripts/loop-lock.sh" acquire $$ >"$X/out" 2>&1; rc=$?
  chmod u+w "$X/.git"
  check "a lock that cannot be created is an error, not 'held'" "[ $rc -eq 2 ] && grep -q 'could not create' '$X/out' && ! grep -q 'holds the lock' '$X/out'"
fi

for args in "" "bogus" "acquire" "acquire abc" "release" "release 1x" "check extra" \
    "acquire-session" "acquire-session bad/run" "acquire-session a b" "release-session" \
    "release-session bad;run" "clone-id extra"; do
  # shellcheck disable=SC2086  # $args is zero or more words
  "$R/scripts/loop-lock.sh" $args >"$R/out" 2>&1; rc=$?
  check "rejects bad usage: '${args}'" "[ $rc -eq 2 ] && grep -q 'usage' '$R/out'"
done
check "bad usage takes no lock" "[ ! -e '$LOCK' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
