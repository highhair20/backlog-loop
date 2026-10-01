#!/usr/bin/env bash
# The backlog loop's single-instance lock: a directory in the repo's git directory
# holding the PID of the run that took it. It lives there, not in LOG_DIR, so every
# run in this clone (and its worktrees, which share one backlog) meets the same lock,
# and git never offers it for commit.
#
# scripts/backlog-loop.sh takes the lock for as long as it runs. /work-next-item only
# checks it: a Claude session has no stable PID to record and no reliable moment to
# release, so an interactive run yields to a driver but does not exclude one.
#
# Usage:
#   scripts/loop-lock.sh acquire <pid>   take the lock for the running process <pid>
#   scripts/loop-lock.sh release <pid>   drop the lock, if <pid> holds it
#   scripts/loop-lock.sh check           may a run start here? (what /work-next-item asks)
#   scripts/loop-lock.sh path            print the lock's absolute path
#
# `check` passes when the lock is free, stale, or held by the driver that started
# this session, which exports its PID as BACKLOG_LOOP_PID.
#
# Exit: 0 ok · 1 another run holds the lock · 2 usage or environment error.
# Anything but 0 means "do not start".
set -uo pipefail

usage() {
  echo "usage: $0 {acquire <pid>|release <pid>|check|path}" >&2
  exit 2
}
die() { echo "loop-lock: $*" >&2; exit 2; }
is_pid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

case "${1:-}" in
  acquire|release) { [ $# -eq 2 ] && is_pid "$2"; } || usage ;;
  check|path) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

# Move to the repo root (parent of this script's directory): the lock is this repo's,
# wherever the script is called from.
# The repo root: backlog-loop.sh passes it explicitly, because it runs this script
# from a private copy outside the repo (#25). Otherwise, the parent of this
# script's directory.
cd "${BACKLOG_LOOP_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}" || die "cannot find the repo root"
git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not a git repository: $PWD"
# Absolute, so the `rm -rf` in the messages below is safe to paste from any directory.
case "$git_dir" in /*) ;; *) git_dir="$PWD/$git_dir" ;; esac
LOCK="$git_dir/backlog-loop.lock"

# The PID recorded in the lock; nothing if there is none or it is not a number.
owner() {
  local pid=""
  [ -f "$LOCK/pid" ] && read -r pid <"$LOCK/pid"
  is_pid "$pid" && echo "$pid"
}

# True if process $1 exists. `kill -0` alone also fails for a live process owned by
# another user, which would get its lock reclaimed; `ps` sees those.
is_running() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

how_to_clear() { echo "  If no backlog loop is running here, clear it: rm -rf $LOCK" >&2; }

# Remove a lock whose owner, $1, is dead. Two runs may try at once, and a plain
# remove-then-take would let the slower one delete the lock the faster one had just
# taken. So a run first claims the removal with a marker directory (mkdir is atomic,
# one run wins), then confirms the lock under the marker is still the dead owner's
# (and still dead: a new run could have been given the same PID).
# Returns 1, removing nothing, if another run got there first.
reclaim() {
  local aside="$LOCK.stale.$$"
  mkdir "$LOCK/reclaiming" 2>/dev/null || return 1
  if [ "$(owner)" != "$1" ] || is_running "$1"; then
    # The marker landed in a lock someone has since taken. If it cannot be removed
    # it is harmless there: that run's release deletes the whole lock.
    rmdir "$LOCK/reclaiming" 2>/dev/null
    return 1
  fi
  # Renamed first, so no run ever sees a half-deleted lock.
  rm -rf "$aside"
  mv "$LOCK" "$aside" || return 1
  rm -rf "$aside"
}

# Deal with an existing lock. Returns 0 when it is gone or is $1's (the PID allowed
# to hold it, if any), so the caller may go on. Returns 1, after saying why, when the
# lock must be respected.
settle() {
  local pid
  [ -d "$LOCK" ] || return 0
  pid="$(owner)"
  # A run that has only just created the lock has not written its PID yet.
  if [ -z "$pid" ]; then sleep 1; pid="$(owner)"; fi
  [ -d "$LOCK" ] || return 0
  if [ -z "$pid" ]; then
    # Never reclaimed: with no PID there is no telling whether its owner is alive.
    echo "✗ The backlog-loop lock ($LOCK) does not record which process holds it." >&2
    how_to_clear
    return 1
  fi
  [ "$pid" = "${1:-}" ] && return 0
  if is_running "$pid"; then
    echo "✗ Another backlog-loop run holds the lock ($LOCK): PID $pid is running." >&2
    echo "  If PID $pid is not a backlog loop (a crashed run's PID can be reused)," >&2
    echo "  the lock is stale; clear it: rm -rf $LOCK" >&2
    return 1
  fi
  if reclaim "$pid"; then
    echo "↻ Reclaimed a stale backlog-loop lock: its owner, PID $pid, is no longer running." >&2
    return 0
  fi
  [ -d "$LOCK" ] || return 0
  reclaim_blocked "$pid"
  return 1
}

# Either another run is reclaiming the lock right now, or one died part-way through.
reclaim_blocked() {
  echo "✗ A stale backlog-loop lock ($LOCK, from PID $1) could not be reclaimed:" >&2
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
  mkdir "$LOCK/reclaiming" 2>/dev/null || { reclaim_blocked "$1"; return 1; }
  rmdir "$LOCK/reclaiming"
  echo "↻ Reclaimed a stale backlog-loop lock: an earlier run left it under this PID ($1)." >&2
}

# Create the lock for PID $1. Returns 1 if the lock already exists.
take() {
  mkdir "$LOCK" 2>/dev/null || return 1
  echo "$1" >"$LOCK/pid" || { rm -rf "$LOCK"; die "could not write $LOCK/pid"; }
}

acquire() {
  take "$1" && return 0
  if [ "$(owner)" = "$1" ]; then adopt "$1"; return; fi
  if [ -d "$LOCK" ]; then settle || return 1; fi
  take "$1" && return 0
  [ -d "$LOCK" ] || die "could not create $LOCK (is the git directory writable?)"
  # Freed and taken again in between: whoever took it holds it now.
  settle && echo "✗ Another run took the backlog-loop lock ($LOCK) first. Re-run to try again." >&2
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

case "$1" in
  acquire) acquire "$2" ;;
  release) release "$2" ;;
  check) settle "${BACKLOG_LOOP_PID:-}" ;;
  path) echo "$LOCK" ;;
esac
