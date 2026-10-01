#!/usr/bin/env bash
#
# Iteration state for the PR review loop. One JSON file per PR under
# .claude/state/pr-review/ (gitignored — it is per-machine, per-moment scratch).
#
# The loop it drives: review -> adjudicate -> fix -> re-review, until no
# CRITICAL/HIGH findings remain or the round cap is hit. Both halves matter.
# Without re-review, a fix that introduces a new defect ships unnoticed (that is
# exactly what happened in practice before this loop existed). Without a cap, it never terminates — a
# high-effort reviewer nearly always emits *something*.
#
# Usage:
#   pr-review-state.sh seed <pr> <url> [session]  open a loop (exit 3 if already open)
#   pr-review-state.sh reviewing <pr>             a review is in flight; gate goes quiet
#   pr-review-state.sh record <pr> <blocking>     finish a round; 0 blocking => done
#   pr-review-state.sh reject <pr> <what> <why>   remember a finding judged wrong
#   pr-review-state.sh clear <pr>                 abandon the loop for this PR
#   pr-review-state.sh status [session]           print unresolved state (READ-ONLY)
#   pr-review-state.sh gate-tick [session]        status, count a block, run cleanup
#
# Output from status/gate-tick is line-prefixed so the gate can classify it:
#   BLOCK|  the turn must not end
#   WARN|   tell the user, but do not block (a loop that ended badly)
#
# "blocking" is the count of CONFIRMED CRITICAL/HIGH findings from that round.
# MEDIUM and LOW are reported once and never looped on — per code-review.md only
# CRITICAL blocks and HIGH warns, and looping on nits does not converge.

set -uo pipefail

MAX_ROUNDS=3
# If the gate blocks this many times without a round being recorded, the loop is
# stuck (review tool unavailable, protocol being ignored) and it gives up rather
# than wedging the session. This is THE wedge guard, so nothing may reset it
# except an actually recorded round.
MAX_GATE_BLOCKS=6
# A review may be declared in-flight at most this many times per round. Without a
# cap, answering every block with `reviewing` would extend the quiet period
# indefinitely and defeat MAX_GATE_BLOCKS.
MAX_REVIEWING_PER_ROUND=2
TTL_SECONDS=$((24 * 60 * 60))
# How long a review may be in flight before the gate stops believing in it. The
# observed reviews took 6-9 minutes, so this is generous but not open-ended.
REVIEW_GRACE_SECONDS=$((20 * 60))

# Derived from this script's own location, never from the environment or cwd.
# CLAUDE_PROJECT_DIR is set only for hook processes, so `seed` (a hook) resolved
# one directory while `record`/`clear` (run by the model through Bash, where the
# variable is unset) fell back to `git rev-parse` of whatever the cwd happened to
# be. From a worktree or another repo that silently pointed at a different tree:
# the model could not close the loop, and the gate went on demanding an action
# that could never succeed until the wedge guard gave up six turns later.
state_dir() {
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  printf '%s/.claude/state/pr-review' "$root"
}

# PR ids are interpolated into a path, and they arrive from a model-authored
# command line where pasting the URL instead of the number is an easy slip.
require_pr() {
  case "${1:-}" in
    '' | *[!0-9]*)
      echo "expected a numeric PR id, got '${1:-}'" >&2
      exit 2 ;;
  esac
}

now_epoch() { date -u +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
file_for() { printf '%s/%s.json' "$(state_dir)" "$1"; }

# Every state write goes through here. The bare `jq > tmp && mv` idiom silently
# leaves the file unchanged when jq fails, which let a failed `record` report
# success and would let a failed block-increment disable the wedge guard.
write_state() {
  f=$1; shift
  tmp="$f.tmp.$$"
  if jq "$@" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    echo "pr-review-state: failed to update $(basename "$f")" >&2
    exit 1
  fi
}

# The PR's state on GitHub, looked up by the URL the loop was seeded with, so it
# names the right repo even from another repo's session. Prints OPEN, MERGED, or
# CLOSED; FAIL if the lookup failed; NOGH where there is no gh (cloud sessions).
# A PR merged while its review ran must close the loop: fixes pushed to its
# branch after the merge never reach main (#19, where PR #8's fixes were lost).
pr_state() {
  command -v gh >/dev/null 2>&1 || { echo NOGH; return; }
  local s
  s=$(gh pr view "$1" --json state --jq .state 2>/dev/null) || { echo FAIL; return; }
  case "$s" in OPEN | MERGED | CLOSED) echo "$s" ;; *) echo FAIL ;; esac
}

# The loud message for a PR that left OPEN while its loop ran.
gone_message() { # gone_message <pr> <url> <MERGED|CLOSED>
  local how; how=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  printf 'WARNING: PR %s (%s) was %s while its review loop was open. Fixes pushed to its branch after that do not reach main: put them in a new PR from main. Review loop closed.\n' "$1" "$2" "$how"
}

require_state() {
  [ -f "$1" ] || { echo "no review loop open for PR $2" >&2; exit 1; }
}

cmd_seed() {
  pr=$1 url=$2 session=${3:-}
  mkdir -p "$(state_dir)"
  f=$(file_for "$pr")
  # Exit 3, not 0: re-running the create command on an open loop must NOT make
  # the caller re-emit the round-1 protocol text in the middle of round 2.
  [ -f "$f" ] && exit 3
  # Atomic, like every other write. A plain redirect could leave a truncated or
  # unparseable file behind if jq failed or the process died mid-write — and
  # since seed refuses to overwrite an existing file, that state would disable
  # enforcement for this PR permanently.
  tmp="$f.tmp.$$"
  if jq -n --arg pr "$pr" --arg url "$url" --arg session "$session" --arg now "$(now_iso)" \
        --argjson epoch "$(now_epoch)" --argjson max "$MAX_ROUNDS" '{
    pr: ($pr | tonumber), url: $url, session: $session,
    round: 0, status: "needs_review",
    max_rounds: $max, gate_blocks: 0, reviewing_count: 0,
    created_epoch: $epoch, updated_at: $now,
    rejected: []
  }' > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; exit 1
  fi
}

# Waiting on a background review REQUIRES letting the turn end — that is how the
# task notification wakes Claude back up. So while a review is in flight the gate
# goes quiet instead of blocking; blocking here would guarantee a spin for the
# whole length of the review. The gate is for when Claude COULD act and is not.
#
# Quiet is bounded twice: REVIEW_GRACE_SECONDS and MAX_REVIEWING_PER_ROUND.
# gate_blocks is deliberately NOT reset here.
cmd_reviewing() {
  pr=$1
  f=$(file_for "$pr"); require_state "$f" "$pr"
  used=$(jq -r '.reviewing_count // 0' "$f")
  if [ "$used" -ge "$MAX_REVIEWING_PER_ROUND" ]; then
    echo "PR $pr: already declared in-flight $used times this round — record the round instead" >&2
    exit 1
  fi
  write_state "$f" --arg now "$(now_iso)" --argjson epoch "$(now_epoch)" \
    '.status = "reviewing" | .reviewing_epoch = $epoch
     | .reviewing_count = ((.reviewing_count // 0) + 1) | .updated_at = $now'
  echo "PR $pr: review in flight (gate quiet for up to $((REVIEW_GRACE_SECONDS / 60))m)"
}

cmd_record() {
  pr=$1 blocking=${2:-}
  case "$blocking" in
    '' | *[!0-9]*)
      echo "record: <blocking> must be a non-negative integer (got '${blocking}')" >&2
      exit 2 ;;
  esac
  f=$(file_for "$pr"); require_state "$f" "$pr"
  url=$(jq -r '.url // ""' "$f")
  state=$(pr_state "$url")
  case "$state" in
    MERGED | CLOSED)
      rm -f "$f"
      gone_message "$pr" "$url" "$state"
      return 0 ;;
  esac
  write_state "$f" --argjson blocking "$blocking" --arg now "$(now_iso)" '
    .round += 1
    | .gate_blocks = 0
    | .reviewing_count = 0
    | .last_blocking = $blocking
    | .updated_at = $now
    | .status = (if $blocking == 0 then "done"
                 elif .round >= .max_rounds then "capped"
                 else "needs_review" end)
  '
  jq -r '"PR \(.pr): round \(.round) recorded, \(.last_blocking) blocking -> \(.status)"' "$f"
  case "$state" in
    FAIL) echo "Note: PR $pr's state was not checked (the gh lookup failed); recorded as if it is still open." ;;
    NOGH) echo "Note: gh is not available, so PR $pr's state was not checked; recorded as if it is still open." ;;
  esac
}

cmd_reject() {
  pr=$1 what=$2 why=$3
  f=$(file_for "$pr"); require_state "$f" "$pr"
  write_state "$f" --arg what "$what" --arg why "$why" \
    '.rejected += [{round: .round, finding: $what, why: $why}]'
  echo "recorded as rejected: $what"
}

cmd_clear() {
  rm -f "$(file_for "$1")"
  echo "review loop cleared for PR $1"
}

emit() { sed "s/^/$1|/"; }

usage() {
  echo "usage: $0 {seed <pr> <url> [session]|reviewing <pr>|record <pr> <blocking>|reject <pr> <what> <why>|clear <pr>|status [session]|gate-tick [session]}" >&2
  exit 64
}

# Print unresolved loops for this session. Entries that ended badly emit a WARN
# before removal — a loop that gave up with CRITICALs outstanding must not look
# identical to one that passed.
emit_status() {
  mode=$1 session=${2:-}
  mutate=no; [ "$mode" = "count" ] && mutate=yes
  dir=$(state_dir)
  [ -d "$dir" ] || exit 0
  now=$(now_epoch)

  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    # An unparseable file used to be skipped forever: never enforced, never
    # reported, never cleaned up. Say so and remove it, rather than leaving
    # enforcement silently off for that PR with no trace.
    if ! status=$(jq -re '.status // "needs_review"' "$f" 2>/dev/null); then
      printf 'Discarded an unreadable review-loop state file (%s).\n' "$(basename "$f")" | emit WARN
      [ "$mutate" = yes ] && rm -f "$f"
      continue
    fi
    owner=$(jq -r '.session // ""' "$f")
    created=$(jq -r '.created_epoch // 0' "$f")

    # Lifecycle cleanup runs BEFORE the session filter. Skipping it for other
    # sessions meant an orphan — one whose owning session had ended — could never
    # be removed by anyone, so the directory accumulated files forever, each of
    # them live again the moment a session_id failed to resolve.
    if [ "$status" = "done" ]; then
      [ "$mutate" = yes ] && rm -f "$f"
      continue
    fi

    mine=yes
    if [ -n "$session" ] && [ -n "$owner" ] && [ "$owner" != "$session" ]; then mine=no; fi

    # Expiry. The owner gets a full TTL window to be told; only after twice the
    # TTL may another session reap it. Deleting an expired entry immediately from
    # any session meant the owner could never learn its loop had died at round N
    # with blocking findings open — the exact case the WARN exists for.
    if [ "$((now - created))" -gt "$TTL_SECONDS" ]; then
      if [ "$mine" = yes ]; then
        jq -r '"Review loop for PR \(.pr) expired after 24h at round \(.round) — \(.url)"' "$f" | emit WARN
        [ "$mutate" = yes ] && rm -f "$f"
      elif [ "$((now - created))" -gt "$((TTL_SECONDS * 2))" ] && [ "$mutate" = yes ]; then
        rm -f "$f"
      fi
      continue
    fi

    # Terminal states are handled before the session filter, on the same
    # reasoning as `done` and expiry above: a loop that hit the cap in a session
    # that has since ended would otherwise be skipped by every later session and
    # linger for 48 hours. The owner is told; anyone else just reaps it.
    if [ "$status" = "capped" ]; then
      [ "$mine" = yes ] && jq -r '"Review loop for PR \(.pr) hit its \(.max_rounds)-round cap with \(.last_blocking // 0) blocking finding(s) still open — \(.url)"' "$f" | emit WARN
      [ "$mutate" = yes ] && rm -f "$f"
      continue
    fi

    blocks=$(jq -r '.gate_blocks // 0' "$f")
    if [ "$blocks" -ge "$MAX_GATE_BLOCKS" ]; then
      [ "$mine" = yes ] && jq -r '"Review loop for PR \(.pr) gave up: blocked \(.gate_blocks) times with no round recorded — \(.url)"' "$f" | emit WARN
      [ "$mutate" = yes ] && rm -f "$f"
      continue
    fi

    # Scope enforcement to the session that opened the loop, so one
    # conversation's loop cannot hijack the turn-ends of an unrelated one.
    [ "$mine" = no ] && continue

    # A review in flight: stay quiet so the turn can end and the notification can
    # arrive. Past the grace period, stop believing it and resume enforcing.
    #
    # The expiry also returns the reviewing credit. Without that, a second expiry
    # in one round deadlocked the loop against its own instruction: the gate said
    # "re-run the review", but `reviewing` refused, so the turn could never end
    # quietly and a legitimate re-review could never report back. gate_blocks
    # (which resumes counting here) is the real bound, not the credit.
    if [ "$status" = "reviewing" ]; then
      since=$(jq -r '.reviewing_epoch // 0' "$f")
      if [ "$((now - since))" -lt "$REVIEW_GRACE_SECONDS" ]; then continue; fi
      [ "$mutate" = yes ] && write_state "$f" --arg now "$(now_iso)" \
        '.status = "needs_review" | .reviewing_count = 0 | .updated_at = $now'
    fi

    # Right before blocking, check the PR is still open: a PR merged while its
    # review ran must not hold the turn for fixes that cannot reach main. A failed
    # or impossible lookup warns and keeps enforcing; it never blocks or wedges.
    url=$(jq -r '.url // ""' "$f")
    case "$(pr_state "$url")" in
      MERGED) gone_message "$(jq -r .pr "$f")" "$url" MERGED | emit WARN
              [ "$mutate" = yes ] && rm -f "$f"; continue ;;
      CLOSED) gone_message "$(jq -r .pr "$f")" "$url" CLOSED | emit WARN
              [ "$mutate" = yes ] && rm -f "$f"; continue ;;
      FAIL) jq -r '"PR \(.pr)'"'"'s state was not checked (the gh lookup failed); treating it as still open."' "$f" | emit WARN ;;
      NOGH) jq -r '"gh is not available, so PR \(.pr)'"'"'s state was not checked; treating it as still open."' "$f" | emit WARN ;;
    esac

    [ "$mutate" = yes ] && write_state "$f" '.gate_blocks += 1'

    jq -r '
      (if .round == 0
       then "PR \(.pr) (\(.url)) — no rounds completed yet (cap \(.max_rounds))."
       else "PR \(.pr) (\(.url)) — round \(.round) of \(.max_rounds) complete."
       end),
      (if .round > 0
       then "Next: re-review. Round \(.round) reported \(.last_blocking // 0) blocking finding(s); a fix can introduce new defects, so the re-review is the point."
       elif (.reviewing_epoch // null) != null
       then "Next: re-run the code review — one was started but never reported back."
       else "Next: run the code review."
       end),
      (if (.rejected | length) > 0
       then "Already adjudicated as NOT valid — do not re-raise or act on these:\n" +
            (.rejected | map("  - \(.finding) — \(.why)") | join("\n"))
       else empty end)
    ' "$f" | emit BLOCK
  done
}

case "${1:-}" in
  seed) require_pr "${2:-}"; [ -n "${3:-}" ] || usage; cmd_seed "$2" "$3" "${4:-}" ;;
  reviewing) require_pr "${2:-}"; cmd_reviewing "$2" ;;
  record) require_pr "${2:-}"; cmd_record "$2" "${3:-}" ;;
  reject) require_pr "${2:-}"; [ -n "${3:-}" ] && [ -n "${4:-}" ] || usage; cmd_reject "$2" "$3" "$4" ;;
  clear) require_pr "${2:-}"; cmd_clear "$2" ;;
  # status is strictly read-only. It used to delete terminal entries and rewrite
  # expired ones, so inspecting a loop by hand consumed the very WARN that told
  # the user it had been abandoned with blocking findings open.
  status) emit_status readonly "${2:-}" ;;
  gate-tick) emit_status count "${2:-}" ;;
  *) usage ;;
esac
