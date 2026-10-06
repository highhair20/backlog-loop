#!/usr/bin/env bash
#
# scripts/backlog-loop.sh — external driver for the autonomous backlog loop.
#
# Runs ONE `/work-next-item` per `claude -p` invocation, so every item starts with
# a COLD context. Nothing accumulates across items, so the loop never drifts toward
# the context limit — which is why no "pause at X% usage" logic is needed here.
#
# All loop state lives in git + GitHub labels (never in a session), so this script
# is safe to stop and re-run at any time. If `claude` exits non-zero (typically an
# account usage limit), the driver backs off and retries; if it still fails it exits
# so you can simply re-run later — the next run's Step 0 recovers any half-done item.
#
# Usage:
#   scripts/backlog-loop.sh
#
# Tunables (environment variables):
#   MAX_ITEMS        hard cap on iterations per run        (default 25)
#   PACE_SECONDS     pause between items                   (default 5)
#   MAX_RETRIES      retries when claude exits non-zero    (default 3)
#   BACKOFF_SECONDS  base backoff between retries          (default 300)
#   MODEL            optional model for claude -p          (default: inherit config)
#   LOG_DIR          per-item log directory                (default .loop-logs)
#   BG_WAIT_SECONDS  how long claude -p waits for background agents (the
#                    specialist reviewers, the PR review) before killing them
#                                                          (default 2700 = 45 min)
#
set -uo pipefail

# Run from a private copy (#25). The sessions this driver starts switch branches in
# this checkout, which can delete these scripts or replace this one under a running
# driver: bash reads a script as it goes, and the exit trap runs loop-lock.sh. So
# copy the driver and the helpers it calls to a temp dir and re-run from there,
# with the repo root passed explicitly. The copy is removed on exit.
if [ "${BACKLOG_LOOP_STAGED:+$BACKLOG_LOOP_STAGED/backlog-loop.sh}" != "$0" ]; then
  root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
  # An explicit template: macOS's bare `mktemp -d` ignores TMPDIR.
  stage="$(mktemp -d "${TMPDIR:-/tmp}/backlog-loop.XXXXXX")" || { echo "✗ could not create a temp dir for the driver" >&2; exit 1; }
  if ! cp "$root/scripts/backlog-loop.sh" "$root/scripts/loop-lock.sh" \
          "$root/scripts/check-verify-section.sh" "$root/scripts/gh-auth-check.sh" \
          "$root/scripts/gh-repo.sh" "$root/scripts/missing-allow-rules.sh" \
          "$root/scripts/template-version.sh" "$stage/"; then
    rm -rf "$stage"
    echo "✗ could not copy the driver's scripts from $root/scripts" >&2
    exit 1
  fi
  # execfail: if the re-exec itself fails, fall through and clean up.
  shopt -s execfail
  # shellcheck disable=SC2093  # deliberate: with execfail, a failed exec falls through to the cleanup below
  BACKLOG_LOOP_STAGED="$stage" BACKLOG_LOOP_ROOT="$root" exec bash "$stage/backlog-loop.sh" "$@"
  rm -rf "$stage"
  echo "✗ could not re-run the driver from $stage" >&2
  exit 1
fi
HERE="$BACKLOG_LOOP_STAGED"
# Remove the private copy on any exit from here on, early ones included; the lock
# release is added to this trap once the lock is taken.
trap 'rm -rf "$HERE"' EXIT
cd "$BACKLOG_LOOP_ROOT" || exit 1

MAX_ITEMS="${MAX_ITEMS:-25}"
PACE_SECONDS="${PACE_SECONDS:-5}"
MAX_RETRIES="${MAX_RETRIES:-3}"
BACKOFF_SECONDS="${BACKOFF_SECONDS:-300}"
DEFAULT_LOG_DIR=.loop-logs
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
BG_WAIT_SECONDS="${BG_WAIT_SECONDS:-2700}"
case "$BG_WAIT_SECONDS" in
  ''|*[!0-9]*) echo "✗ BG_WAIT_SECONDS must be a whole number of seconds, got: $BG_WAIT_SECONDS" >&2; exit 1 ;;
esac
# Force base 10: bash arithmetic reads a leading zero as octal (0600 → 384, 08 → error).
BG_WAIT_SECONDS=$((10#$BG_WAIT_SECONDS))

# /work-next-item stops at once without a Verify section; fail here instead of
# spending MAX_ITEMS invocations discovering that one at a time.
"$HERE/check-verify-section.sh" CLAUDE.md || exit 1

# A missing tool would otherwise look like a usage limit: run_item fails, and the
# driver backs off for MAX_RETRIES rounds before giving up.
for tool in claude gh jq; do
  command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH. Install it, then re-run." >&2; exit 1; }
done
# Only the login for origin's host counts; a stale token for another host must not
# stop the loop (#15).
if ! gh_host="$("$HERE/gh-auth-check.sh")"; then
  echo "✗ gh is not authenticated${gh_host:+ to $gh_host}. Run: gh auth login${gh_host:+ --hostname $gh_host}" >&2
  exit 1
fi
# The sessions run gh without --repo and without a terminal, so with several remotes
# and no gh default gh would pick the repo itself, often a fork's upstream (#17).
# The helper prints its reason on stderr.
if ! gh_repo="$("$HERE/gh-repo.sh" --with-host)"; then
  echo "✗ cannot tell which GitHub repository the loop would act on (see above)." >&2
  exit 1
fi
echo "Working the backlog of ${gh_repo#*/}"
# Pin every session's gh to that repo, so a remote or default changed mid-run cannot
# move the loop to another one. The host is gh's, not origin's, so a GitHub
# Enterprise repo on another remote stays on its own host.
export GH_REPO="$gh_repo"

# Sync updates the allowlist example but never this machine's own copy, so a rule
# added later (report-drained.sh, gh pr diff) is missing until someone copies it,
# and every session stops at the command it needs (#81). Warn, but run: the operator
# may have dropped a rule on purpose. Same comparison as setup.sh's.
allow_rc=0
allow_out="$("$HERE/missing-allow-rules.sh" 2>&1)" || allow_rc=$?
case "$allow_rc" in
  0) ;;
  1)
    echo "⚠ .claude/settings.local.json is missing $(printf '%s\n' "$allow_out" | grep -c .) allow rule(s) the example has; a session stops at a command it is not allowed:" >&2
    printf '%s\n' "$allow_out" | sed 's/^/    /' >&2
    ;;
  *) echo "⚠ ${allow_out:-could not compare .claude/settings.local.json with its example}" >&2 ;;
esac

# A repo that runs the loop unattended may never run setup.sh again, so it would
# never hear that its managed files are behind the template (#73). Say so here,
# but run: the update needs a human to review it. Same check as setup.sh's.
tv_rc=0
tv_out="$("$HERE/template-version.sh" 2>&1)" || tv_rc=$?
case "$tv_rc" in
  0|4) ;;
  1)
    echo "⚠ ${tv_out}" >&2
    echo "    Update: /backlog-loop:update with the plugin, or scripts/sync-guardrails.sh $BACKLOG_LOOP_ROOT from a clone of the template." >&2
    ;;
  *) echo "⚠ ${tv_out:-could not compare this repo with the template}" >&2 ;;
esac

# The logs hold whole session transcripts (issue text, code, command output), so
# only this user may read them (#99). A LOG_DIR the driver creates is mode 700, and
# so is the default one this user owns, which earlier runs created with the default
# umask. A LOG_DIR the operator chose and already has keeps its mode, and so do a
# symlinked default's target and a default another user owns (a shared checkout
# must still run); each log is still mode 600 (new_log).
if [ ! -e "$LOG_DIR" ] && [ ! -L "$LOG_DIR" ]; then
  { mkdir -p -- "$(dirname -- "$LOG_DIR")" && mkdir -m 700 -- "$LOG_DIR"; } || { echo "✗ cannot create the log directory $LOG_DIR. Stopping." >&2; exit 1; }
elif [ "$LOG_DIR" = "$DEFAULT_LOG_DIR" ] && [ -d "$LOG_DIR" ] && [ ! -L "$LOG_DIR" ] && [ -O "$LOG_DIR" ]; then
  # No `--`: macOS chmod rejects it, and this path is always .loop-logs.
  chmod 700 "$LOG_DIR" || { echo "✗ cannot make $LOG_DIR private (mode 700). Stopping." >&2; exit 1; }
fi
[ -d "$LOG_DIR" ] || { echo "✗ the log directory $LOG_DIR is not a directory. Stopping." >&2; exit 1; }
# A directory left as it was may still let others in: say so, but run.
log_dir_mode="$(ls -ldL -- "$LOG_DIR" | cut -c5-10)"
if [ "$log_dir_mode" != ------ ]; then
  echo "⚠ the log directory $LOG_DIR is not private to you (group/other bits: ${log_dir_mode:-unknown}); the driver left its mode as it was. New logs are still mode 600." >&2
fi

# Single-instance lock, so two drivers can't double-claim, and so a /work-next-item
# started by hand while this runs stops at its own lock check. It reclaims a lock a
# crashed run left behind. The sessions this driver starts run that same check;
# BACKLOG_LOOP_PID tells them the lock they find is their own driver's.
"$HERE/loop-lock.sh" acquire $$ || exit 1
trap '"$HERE/loop-lock.sh" release $$; rm -rf "$HERE"' EXIT
export BACKLOG_LOOP_PID=$$

# Count open issues a session might work. Two kinds count (#77):
# - prioritized issues Step 2 could select. in-progress counts (Step 0 recovers it).
#   P3 counts too: /work-next-item takes a P3 once no P0-P2 issue is actionable (#45).
#   A heal:proposed issue a human has not yet approved with heal:approved does not:
#   Step 2 skips it (#13).
# - in-review issues, whatever their priority: Step 1.5 may follow up their PR. Only
#   the session can tell whether a PR needs attention, so the driver starts one and
#   stops when its log says the backlog is drained (see the loop below).
# blocked, needs-attention and no-auto-heal never count: Steps 1.5 and 2 skip them.
# Filtered with jq here rather than gh --jq, so the test's fake gh exercises it.
work_remaining() {
  gh issue list --state open --limit 1000 --json labels | jq '
    [ .[] | ([.labels[].name]) as $l
      | select( (($l | any(. == "blocked" or . == "needs-attention" or . == "no-auto-heal")) | not)
            and ( ($l | any(. == "in-review"))
                  or ( ($l | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
                       and ((($l | any(. == "heal:proposed")) and (($l | any(. == "heal:approved")) | not)) | not) ) ) )
    ] | length'
}

# What GitHub shows of the loop's work, to tell whether a session changed anything:
# each open issue's number and labels, and each open PR's number, head and updatedAt.
# An issue's updatedAt is left out on purpose: a session stopped by a setup refusal
# in Steps 3-3.7 claims the issue and releases it again, which moves updatedAt but
# leaves the labels as they were, and that must still read as no progress. A
# follow-up shows on its PR instead (a comment moves updatedAt, a fix moves the head).
snapshot() {
  local issues prs
  issues="$(gh issue list --state open --limit 1000 --json number,labels \
    | jq -c 'map({number, labels: ([.labels[].name] | sort)}) | sort_by(.number)')" || return 1
  prs="$(gh pr list --state open --limit 1000 --json number,headRefOid,updatedAt \
    | jq -c 'map({number, headRefOid, updatedAt}) | sort_by(.number)')" || return 1
  printf '%s\n%s\n' "$issues" "$prs"
}

# Step 2 runs scripts/report-drained.sh when nothing is left to select or follow up,
# which writes this marker. The driver reads the marker, never the session's words:
# a model paraphrases its report (#77, measured in the review of #80). Cleared before
# every attempt, so only the session just run can leave it.
if ! git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"; then
  echo "✗ cannot find this checkout's git directory. Stopping." >&2
  exit 1
fi
DRAINED_MARK="$git_common_dir/backlog-loop.drained"

# Clears the marker, or stops the run: a marker that cannot be removed would make
# every later stall read as drained.
clear_drained_mark() {
  if ! rm -f -- "$DRAINED_MARK" || [ -e "$DRAINED_MARK" ]; then
    echo "✗ cannot remove $DRAINED_MARK. Stopping." >&2
    exit 1
  fi
}

drained() {
  echo "✅ Backlog drained — nothing left to work or follow up. Ran $count session(s) this run."
  exit 0
}

# One cold-context invocation. acceptEdits auto-approves file writes; bash is still
# governed by permissions: the committed .claude/settings.json denies merges and
# main pushes, and .claude/settings.local.json must allow every gh/git command
# /work-next-item runs plus the Verify commands (see README), or items stop early.
#
# claude -p kills background tasks 600s after the main turn by default, which cut
# the reviewers and the PR review off mid-run (#22). Give them a finite ceiling so
# a hung agent still cannot stall the driver forever. The staging variables are
# stripped (#25): a session's Verify may run nested drivers and lock checks, which
# must act on their own fixtures, not on this repo.
run_item() {
  local ceiling_ms=$(( BG_WAIT_SECONDS * 1000 ))
  if [ -n "${MODEL:-}" ]; then
    env -u BACKLOG_LOOP_STAGED -u BACKLOG_LOOP_ROOT CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$ceiling_ms" \
      claude -p "/work-next-item" --permission-mode acceptEdits --model "$MODEL" >&3 2>&3 3>&-
  else
    env -u BACKLOG_LOOP_STAGED -u BACKLOG_LOOP_ROOT CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$ceiling_ms" \
      claude -p "/work-next-item" --permission-mode acceptEdits >&3 2>&3 3>&-
  fi
}

# Opens log $1 on fd 3 as a new mode-600 file, for run_item to write to (#99). The
# session writes to that fd and never reopens the path, so a file or symlink put at
# the predictable name afterwards gets nothing. Nothing may be at $1 beforehand
# either: the -e/-L checks refuse it, and noclobber (O_CREAT|O_EXCL) refuses a
# regular file or link that appears between the check and the open. (A FIFO or
# device raced in there is not refused; that needs a LOG_DIR other users can write
# to, which the operator chose.) The umask and noclobber are restored at once: the
# session must create the repo's files as before. A log that cannot be created
# stops the run, rather than read as a failed session and be retried with backoff.
new_log() {
  local old_umask rc
  if [ -e "$1" ] || [ -L "$1" ]; then
    echo "✗ cannot create the log $1: something is already there. Stopping." >&2
    exit 1
  fi
  old_umask="$(umask)"
  umask 077
  set -C
  exec 3>"$1"
  rc=$?
  set +C
  umask "$old_umask"
  [ "$rc" -eq 0 ] || { echo "✗ cannot create the log $1. Stopping." >&2; exit 1; }
}

# A session that ends its turn while a command still runs (#84) leaves its work
# uncommitted or unpushed, and only its log said so. After a stall, name the branch
# it left that on (#85). A branch with no upstream was never pushed (Step 6 pushes
# it), so its unsaved commits are those no remote has. $1 is the session's log.
report_unsaved_work() {
  local branch changes ahead=""
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="the current branch"
  if ! changes="$(git status --porcelain)"; then
    echo "  (could not check for unsaved work: git status failed)" >&2
    return
  fi
  # No commits yet (an unborn branch): nothing committed to lose.
  if [ -z "$changes" ] && git rev-parse -q --verify HEAD >/dev/null; then
    if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
      ahead="$(git log --oneline '@{u}..')"
    else
      ahead="$(git log --oneline HEAD --not --remotes)"
    fi || { echo "  (could not check for unsaved work: git log failed)" >&2; return; }
  fi
  [ -n "$changes$ahead" ] || return 0
  echo "⚠ the session ended with unsaved work on $branch: it may have ended its turn while a command still ran (#84)" >&2
  echo "  Its log: $1" >&2
}

count=0
while [ "$count" -lt "$MAX_ITEMS" ]; do
  if ! remaining="$(work_remaining)"; then
    echo "✗ gh query failed — is gh authenticated? Stopping." >&2
    exit 1
  fi
  if [ "$remaining" -eq 0 ]; then
    drained
  fi
  if ! before="$(snapshot)"; then
    echo "✗ gh could not read the open issues and PRs — is gh authenticated? Stopping." >&2
    exit 1
  fi

  count=$((count + 1))
  ts="$(date +%Y%m%d-%H%M%S)"
  # The item number keeps names unique even when two items start in the same second,
  # and the PID when a re-run starts in the same second as the last run: new_log
  # refuses a name that is taken.
  base="$LOG_DIR/item-$ts-$$-$count"
  log="$base.log"
  echo "▶ [$count/$MAX_ITEMS] $remaining issue(s) to work or follow up → /work-next-item (log: $log)"

  attempt=0
  while :; do
    attempt=$((attempt + 1))
    # Each attempt gets its own log, so a retry cannot erase why the last one failed.
    [ "$attempt" -eq 1 ] || log="$base.attempt$attempt.log"
    clear_drained_mark
    new_log "$log"
    item_rc=0
    run_item || item_rc=$?
    exec 3>&-
    if [ "$item_rc" -eq 0 ]; then
      break
    fi
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      echo "⚠ claude exited non-zero ${attempt}× (often an account usage limit)." >&2
      echo "  The loop is resumable — re-run this script later to continue." >&2
      exit 2
    fi
    backoff=$(( BACKOFF_SECONDS * attempt ))
    echo "  attempt ${attempt} failed (log: $log); backing off ${backoff}s before retry…" >&2
    sleep "$backoff"
  done

  echo "  ─ last lines of this item:"
  tail -n 3 "$log" | sed 's/^/    /'

  # Progress is any change in what GitHub shows, not a drop in the count: a
  # follow-up leaves its issue in-review, as it found it. A session that changed
  # nothing stopped early (dirty tree, bad Verify, a refused command, ...) and will
  # stop again, so don't spend a cold session per MAX_ITEMS finding that out. An
  # edit someone else makes mid-run can mask a stall; that costs one more session.
  if ! after="$(snapshot)"; then
    echo "✗ gh could not read the open issues and PRs — is gh authenticated? Stopping." >&2
    exit 1
  fi
  if [ "$after" = "$before" ]; then
    # Unless the session found nothing to follow up and nothing to select, and said
    # so with report-drained.sh: that is how a run whose only open work is in-review
    # PRs needing nothing stops. A missing marker (the script was refused, or the
    # session stopped early) reads as no progress, the safe side.
    if [ -f "$DRAINED_MARK" ]; then
      drained
    fi
    echo "✗ The last item made no progress: it changed no issue's labels and no PR," >&2
    echo "  and did not record the backlog drained (scripts/report-drained.sh)." >&2
    echo "  Read its log in $LOG_DIR, fix the cause, and re-run." >&2
    report_unsaved_work "$log"
    exit 3
  fi
  sleep "$PACE_SECONDS"
done

echo "⏸ Reached MAX_ITEMS=${MAX_ITEMS}. Re-run to continue (the loop is resumable)."
