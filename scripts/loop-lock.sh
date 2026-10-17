#!/usr/bin/env bash
# The backlog loop's single-instance lock: a directory in the repo's git directory
# naming the run that took it. It lives there, not in LOG_DIR, so every run in this
# clone (and its worktrees, which share one backlog) meets the same lock, and git
# never offers it for commit.
#
# Two kinds of run take it (#108):
# - scripts/backlog-loop.sh, for as long as it runs. The lock records its PID and
#   is stale once that process has gone.
# - a /work-next-item session started any other way (by hand, /loop). A Claude
#   session has no stable PID, so the lock records its run ID and the time it took
#   it. The session renews it before each commit, so a run still at work never lapses,
#   and releases it when the run ends; one that dies without releasing holds it for
#   SESSION_TTL seconds (3 hours) from its last renewal, then any run may reclaim it.
# A session the driver started takes nothing: the driver exports its PID as
# BACKLOG_LOOP_PID, and its lock covers the session.
#
# The git directory also holds this clone's ID: random, made on first use, shared by
# the clone's worktrees. Claims name it, so a run can tell its own clone's claims
# (#108). A fresh clone, such as each cloud run's, gets a new one.
#
# Usage:
#   scripts/loop-lock.sh acquire <pid>              take the lock for the driver <pid>
#   scripts/loop-lock.sh release <pid>              drop the lock, if <pid> holds it
#   scripts/loop-lock.sh acquire-session <run-id>   take the lock for a session's run
#   scripts/loop-lock.sh renew-session <run-id>     refresh <run-id>'s lock; fail if it lost it
#   scripts/loop-lock.sh release-session <run-id>   drop the lock, if <run-id> holds it
#   scripts/loop-lock.sh check                      may a run start here? (a dry run asks)
#   scripts/loop-lock.sh clone-id                   print this clone's ID
#   scripts/loop-lock.sh path                       print the lock's absolute path
#
# `check` and `acquire-session` pass when the lock is free, stale, or held by the
# driver that started this session (BACKLOG_LOOP_PID).
#
# Exit: 0 ok · 1 another run holds the lock · 2 usage or environment error.
# Anything but 0 means "do not start".
set -uo pipefail

# How long a session's lock lasts if the session never releases it: the same three
# hours a GitHub claim lasts (Step 0 of /work-next-item).
SESSION_TTL=10800

usage() {
  echo "usage: $0 {acquire <pid>|release <pid>|acquire-session <run-id>|renew-session <run-id>|release-session <run-id>|check|clone-id|path}" >&2
  exit 2
}
die() { echo "loop-lock: $*" >&2; exit 2; }
is_pid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
# A run ID as /work-next-item makes one (20261006T171119Z-3fa9c1): letters, digits, -.
is_run() { case "$1" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac; }
is_clone_id() {
  case "$1" in ????????????????) ;; *) return 1 ;; esac
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

case "${1:-}" in
  acquire|release) { [ $# -eq 2 ] && is_pid "$2"; } || usage ;;
  acquire-session|renew-session|release-session) { [ $# -eq 2 ] && is_run "$2"; } || usage ;;
  check|clone-id|path) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

# Move to the repo root (parent of this script's directory): the lock is this repo's,
# wherever the script is called from.
# The repo root: backlog-loop.sh passes it explicitly, because it runs this script
# from a private copy outside the repo (#25). Trust that only when this script IS
# that copy, so a leaked variable cannot retarget a run from the repo. Otherwise,
# the parent of this script's directory.
if [ -n "${BACKLOG_LOOP_STAGED:-}" ] && [ "$(dirname -- "$0")" = "$BACKLOG_LOOP_STAGED" ]; then
  root="${BACKLOG_LOOP_ROOT:-}"
else
  root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
fi
cd "$root" 2>/dev/null || die "cannot find the repo root"
git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not a git repository: $PWD"
# Absolute, so the `rm -rf` in the messages below is safe to paste from any directory.
case "$git_dir" in /*) ;; *) git_dir="$PWD/$git_dir" ;; esac
LOCK="$git_dir/backlog-loop.lock"
CLONE_ID="$git_dir/backlog-loop.clone-id"

# Set while this run holds the reclaim marker in a lock, so a run killed meanwhile
# removes it on the way out; a marker left behind would block the lock until a human
# cleared it. A signal exits through the EXIT trap. (SIGKILL cannot be caught.)
MARKER_HELD=0
trap '[ "$MARKER_HELD" = 1 ] && rmdir "$LOCK/reclaiming" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The driver PID recorded in the lock; nothing if there is none or it is not a number.
owner() {
  local pid=""
  [ -f "$LOCK/pid" ] && read -r pid <"$LOCK/pid"
  is_pid "$pid" && echo "$pid"
}

# Who holds the lock: "pid <pid>" for a driver, "run <run-id> <epoch>" for a session,
# or nothing when it records neither (not yet written, or unreadable).
holder() {
  local pid run="" since="" rest
  pid="$(owner)"
  if [ -n "$pid" ]; then echo "pid $pid"; return; fi
  [ -f "$LOCK/run" ] && read -r run since rest <"$LOCK/run"
  if is_run "$run" && is_pid "$since" && [ -z "${rest:-}" ]; then echo "run $run $since"; fi
}

# The run ID in holder $1 ("run <id> <epoch>"), or nothing for a driver's lock.
run_of() { case "$1" in run\ *) local r="${1#run }"; echo "${r%% *}" ;; esac; }
# The epoch in a session holder $1.
since_of() { echo "${1##* }"; }

# The holder, $1, in words.
describe() {
  case "$1" in
    pid\ *) echo "PID ${1#pid }" ;;
    *) echo "the /work-next-item session for run $(run_of "$1")" ;;
  esac
}

# True if process $1 exists. `kill -0` alone also fails for a live process owned by
# another user, which would get its lock reclaimed; `ps` sees those.
is_running() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

# The time now, in epoch seconds; fails if the clock cannot be read.
now_epoch() {
  local now
  now="$(date +%s 2>/dev/null)" && is_pid "$now" && echo "$now"
}

# Seconds since session holder $1 last renewed its lock, at time $2. Its time is read
# as decimal (10#): a damaged time with a leading zero would otherwise be octal, or an error.
age_of() { echo $(( $2 - 10#$(since_of "$1") )); }

# True while holder $1 may still be at work: a driver whose process exists, or a
# session whose lock is younger than SESSION_TTL. If the clock cannot be read, live.
# A lock dated more than CLOCK_SLACK seconds ahead is stale, not live forever: the
# clock was wrong when it was taken, or the file was damaged.
CLOCK_SLACK=300
is_live() {
  local now age
  case "$1" in
    pid\ *) is_running "${1#pid }" ;;
    *)
      now="$(now_epoch)" || return 0
      age="$(age_of "$1" "$now")"
      [ "$age" -gt "-$CLOCK_SLACK" ] && [ "$age" -lt "$SESSION_TTL" ]
      ;;
  esac
}

how_to_clear() { echo "  If no backlog loop is running here, clear it: rm -rf $LOCK" >&2; }

# Remove a lock whose holder, $1, is no longer live. Two runs may try at once, and a
# plain remove-then-take would let the slower one delete the lock the faster one had
# just taken. So a run first claims the removal with a marker directory (mkdir is
# atomic, one run wins), then confirms the lock under the marker is still that
# holder's (and still stale: a new driver could have been given the same PID).
# Returns 1, removing nothing, if another run got there first.
reclaim() {
  # Checked before the marker too, so a lock that has changed hands or been renewed
  # since settle judged it never gets a passing marker from this run.
  { [ "$(holder)" = "$1" ] && ! is_live "$1"; } || return 1
  mkdir "$LOCK/reclaiming" 2>/dev/null || return 1
  MARKER_HELD=1
  if [ "$(holder)" != "$1" ] || is_live "$1"; then
    # The marker landed in a lock someone has since taken: remove it, or that run's
    # renew and release would take it for a reclaim under way and stop.
    rmdir "$LOCK/reclaiming" 2>/dev/null
    MARKER_HELD=0
    return 1
  fi
  MARKER_HELD=0
  remove_lock stale || { rmdir "$LOCK/reclaiming" 2>/dev/null; return 1; }
}

# Delete the lock, renamed first (to $LOCK.$1.<pid>), so no run ever sees it
# half-deleted. Called with the reclaim marker held.
remove_lock() {
  local aside="$LOCK.$1.$$"
  rm -rf "$aside"
  mv "$LOCK" "$aside" || return 1
  # The lock is gone once moved; a leftover copy only needs tidying.
  rm -rf "$aside" || echo "loop-lock: could not delete $aside; remove it by hand" >&2
  return 0
}

# True if the lock is held by $1 (a driver PID) or $2 (a session's run ID), either of
# which may be empty: the holders a caller may go on under. By identity only, never by
# whether the driver is running: a session sandboxed from other processes would see a
# live driver as dead and remove its lock. Once another run takes the lock, it no
# longer records the driver, so the session's next renew fails and it stops.
held_by() {
  local h
  h="$(holder)"
  { [ -n "${1:-}" ] && [ "$h" = "pid $1" ]; } || { [ -n "${2:-}" ] && [ "$(run_of "$h")" = "$2" ]; }
}

# Deal with an existing lock. Returns 0 when it is gone, or held_by $1 or $2, so the
# caller may go on. Returns 1, after saying why, when the lock must be respected.
settle() {
  local h
  [ -d "$LOCK" ] || return 0
  h="$(holder)"
  # A run that has only just created the lock has not written its owner yet.
  if [ -z "$h" ]; then sleep 1; h="$(holder)"; fi
  [ -d "$LOCK" ] || return 0
  if [ -z "$h" ]; then
    # Never reclaimed: with no owner there is no telling whether it is alive.
    echo "✗ The backlog-loop lock ($LOCK) does not record which run holds it." >&2
    how_to_clear
    return 1
  fi
  held_by "${1:-}" "${2:-}" && return 0
  if is_live "$h"; then
    say_held "$h"
    return 1
  fi
  if reclaim "$h"; then
    case "$h" in
      pid\ *) echo "↻ Reclaimed a stale backlog-loop lock: its owner, $(describe "$h"), is no longer running." >&2 ;;
      *) echo "↻ Reclaimed a stale backlog-loop lock: $(describe "$h") took it more than 3 hours ago." >&2 ;;
    esac
    return 0
  fi
  [ -d "$LOCK" ] || return 0
  # It changed hands while this run judged it: judge the new holder instead of
  # reporting a stuck reclaim (whose advice, rm -rf, would remove a live run's lock).
  if [ "$(holder)" != "$h" ]; then settle "${1:-}" "${2:-}"; return; fi
  reclaim_blocked "$(describe "$h")"
  return 1
}

# Say who holds the live lock $1, and how to clear it if that is wrong.
say_held() {
  local now age
  case "$1" in
    pid\ *)
      echo "✗ Another backlog-loop run holds the lock ($LOCK): $(describe "$1") is running." >&2
      echo "  If $(describe "$1") is not a backlog loop (a crashed run's PID can be reused)," >&2
      echo "  the lock is stale; clear it: rm -rf $LOCK" >&2
      ;;
    *)
      echo "✗ Another backlog-loop run holds the lock ($LOCK): $(describe "$1")," >&2
      if now="$(now_epoch)"; then
        age=$(( $(age_of "$1" "$now") / 60 )); [ "$age" -ge 0 ] || age=0
        echo "  renewed $age minutes ago. It lapses 3 hours after that." >&2
      else
        echo "  taken at $(since_of "$1") (epoch seconds); the clock cannot be read, so it is treated as live." >&2
      fi
      how_to_clear
      ;;
  esac
}

# Either another run is reclaiming the lock right now, or one died part-way through.
reclaim_blocked() {
  echo "✗ A stale backlog-loop lock ($LOCK, from $1) could not be reclaimed:" >&2
  echo "  another run has started reclaiming it, and may have crashed before finishing." >&2
  how_to_clear
}

# A lock that records the caller's own PID, $1. No earlier holder can still be
# running under that PID, so the lock is stale, and the liveness test cannot say so:
# it would find the caller. This is the normal case where a driver gets the same PID
# on every start (a container's entrypoint), and a killed run would otherwise block
# every restart. Claimed through the reclaim marker, so a run that judged the lock
# stale before this process started cannot remove it afterwards.
adopt() {
  mkdir "$LOCK/reclaiming" 2>/dev/null || { reclaim_blocked "PID $1"; return 1; }
  rmdir "$LOCK/reclaiming"
  echo "↻ Reclaimed a stale backlog-loop lock: an earlier run left it under this PID ($1)." >&2
}

# Create the lock, writing $2 to the file $1 (pid or run). Returns 1 if it exists.
take() {
  mkdir "$LOCK" 2>/dev/null || return 1
  echo "$2" >"$LOCK/$1" || { rm -rf "$LOCK"; die "could not write $LOCK/$1"; }
}

# Settle the lock that is there, then take it as `take $1 $2`. $3 and $4 are the
# driver PID and session run that may already hold it for this caller (see held_by).
settle_then_take() {
  if [ -d "$LOCK" ]; then settle "$3" "$4" || return 1; fi
  held_by "$3" "$4" && return 0
  take "$1" "$2" && return 0
  [ -d "$LOCK" ] || die "could not create $LOCK (is the git directory writable?)"
  # Freed and taken again in between: whoever took it holds it now.
  settle "$3" "$4" && echo "✗ Another run took the backlog-loop lock ($LOCK) first. Re-run to try again." >&2
  return 1
}

acquire() {
  take pid "$1" && return 0
  if [ "$(owner)" = "$1" ]; then adopt "$1"; return; fi
  settle_then_take pid "$1" "" ""
}

now_or_die() { now_epoch || die "cannot read the clock (date +%s)"; }

acquire_session() {
  local now
  now="$(now_or_die)" || exit 2
  # Held already by this run: renew it, so it has its full 3 hours from now.
  if held_by "" "$1"; then renew_session "$1"; return; fi
  settle_then_take run "$1 $now" "${BACKLOG_LOOP_PID:-}" "$1"
}

# Take the reclaim marker in run $1's own lock. A run tries only while the lock names
# it, which keeps most runs that lost their lock out of others' locks; the lock can
# still change hands between that check and the mkdir, and a reclaimer's marker can be
# in the way, so a marker found there ("File exists") is waited out. Returns 0 when
# taken; 1 when the lock is gone, is not run $1's, or a marker stays (another run is
# reclaiming it); 3 when mkdir fails for any other reason: the lock cannot be written
# (the OS reason is printed).
MARKER_TRIES=10
MARKER_WAIT=0.2
take_marker() {
  local i=1 err
  while :; do
    held_by "" "$1" || return 1
    if err="$(LC_ALL=C mkdir "$LOCK/reclaiming" 2>&1)"; then
      MARKER_HELD=1
      return 0
    fi
    case "$err" in
      *"File exists"*) ;;
      *)
        [ -d "$LOCK" ] || return 1
        echo "loop-lock: $err" >&2
        return 3
        ;;
    esac
    [ "$i" -ge "$MARKER_TRIES" ] && return 1
    i=$((i + 1))
    sleep "$MARKER_WAIT"
  done
}

# Run "$2..." with the reclaim marker held, if the lock is still run $1's; reclaim()
# takes the same marker, so the lock cannot be reclaimed (or taken) part-way through.
# Returns take_marker's 1 or 3, changing nothing, when it cannot take the marker;
# otherwise what "$2..." returns.
as_holder() {
  local run="$1" rc
  shift
  take_marker "$run"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! held_by "" "$run"; then rmdir "$LOCK/reclaiming" 2>/dev/null; MARKER_HELD=0; return 1; fi
  "$@"; rc=$?
  rmdir "$LOCK/reclaiming" 2>/dev/null
  MARKER_HELD=0
  return "$rc"
}

lost_lock() {
  echo "✗ Run $1 no longer holds the backlog-loop lock ($LOCK): it lapsed and another run" >&2
  echo "  took it, was released, or another run is reclaiming it. Stop: another run may be" >&2
  echo "  working this clone." >&2
}

# Write a fresh time into run $1's lock. Replaced by a rename, so no reader sees it half-written.
# Returns 3 if it cannot write, after printing why.
refresh() {
  local err
  err="$({ echo "$1 $2" >"$LOCK/run.new" && mv "$LOCK/run.new" "$LOCK/run"; } 2>&1)" && return 0
  rm -f "$LOCK/run.new"
  [ -z "$err" ] || echo "loop-lock: $err" >&2
  return 3
}

renew_session() {
  local now
  # A session the driver started holds nothing to renew: the driver's lock covers it.
  held_by "${BACKLOG_LOOP_PID:-}" "" && return 0
  now="$(now_or_die)" || exit 2
  as_holder "$1" refresh "$1" "$now"
  case $? in
    0) return 0 ;;
    3) echo "✗ Run $1 holds the backlog-loop lock but could not write $LOCK to renew it. Stop." >&2; return 2 ;;
  esac
  lost_lock "$1"
  return 1
}

release() {
  [ -d "$LOCK" ] || return 0
  if [ "$(owner)" != "$1" ]; then
    echo "loop-lock: not releasing $LOCK: PID $1 does not hold it" >&2
    return 1
  fi
  rm -rf "$LOCK"
}

release_session() {
  [ -d "$LOCK" ] || return 0
  # A session the driver started took no lock: the driver releases its own.
  held_by "${BACKLOG_LOOP_PID:-}" "" && return 0
  # Not as_holder: the marker leaves with the lock, and removing it afterwards could
  # remove a marker in a new lock another run has taken since.
  take_marker "$1"
  case $? in
    0) ;;
    3) echo "loop-lock: not releasing $LOCK: could not write it" >&2; return 2 ;;
    *)
      [ -d "$LOCK" ] || return 0
      if held_by "" "$1"; then
        echo "loop-lock: not releasing $LOCK: another run is reclaiming it" >&2
        return 1
      fi
      ;;
  esac
  if ! held_by "" "$1"; then
    [ "$MARKER_HELD" = 1 ] && rmdir "$LOCK/reclaiming" 2>/dev/null
    MARKER_HELD=0
    echo "loop-lock: not releasing $LOCK: run $1 does not hold it" >&2
    return 1
  fi
  MARKER_HELD=0
  remove_lock released && return 0
  rmdir "$LOCK/reclaiming" 2>/dev/null
  echo "loop-lock: could not remove $LOCK" >&2
  return 2
}

# Print this clone's ID, making it on first use. Several runs may make one at once:
# each writes its own candidate, and `ln` (which fails if the name exists) lets the
# first one stand, so all of them print the same ID.
clone_id() {
  local id tmp="$CLONE_ID.$$"
  if [ ! -e "$CLONE_ID" ]; then
    id="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    is_clone_id "$id" || die "could not generate a clone ID from /dev/urandom"
    echo "$id" >"$tmp" 2>/dev/null || die "could not write $tmp (is the git directory writable?)"
    # Fails when another run made it first, which is fine; any other failure is not.
    if ! ln "$tmp" "$CLONE_ID" 2>/dev/null && [ ! -e "$CLONE_ID" ]; then
      rm -f "$tmp"
      die "could not create $CLONE_ID (does the git directory's filesystem allow hard links?)"
    fi
    rm -f "$tmp"
  fi
  id=""
  [ -f "$CLONE_ID" ] && read -r id <"$CLONE_ID"
  is_clone_id "$id" || die "$CLONE_ID does not hold a clone ID; remove it, and the next run makes a new one"
  echo "$id"
}

case "$1" in
  acquire) acquire "$2" ;;
  release) release "$2" ;;
  acquire-session) acquire_session "$2" ;;
  renew-session) renew_session "$2" ;;
  release-session) release_session "$2" ;;
  check) settle "${BACKLOG_LOOP_PID:-}" "" ;;
  clone-id) clone_id ;;
  path) echo "$LOCK" ;;
esac
