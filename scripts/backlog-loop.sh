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
#
set -uo pipefail

# Move to the repo root (parent of this script's directory).
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1

MAX_ITEMS="${MAX_ITEMS:-25}"
PACE_SECONDS="${PACE_SECONDS:-5}"
MAX_RETRIES="${MAX_RETRIES:-3}"
BACKOFF_SECONDS="${BACKOFF_SECONDS:-300}"
LOG_DIR="${LOG_DIR:-.loop-logs}"

# /work-next-item stops at once without a Verify section; fail here instead of
# spending MAX_ITEMS invocations discovering that one at a time.
scripts/check-verify-section.sh CLAUDE.md || exit 1

# A missing tool would otherwise look like a usage limit: run_item fails, and the
# driver backs off for MAX_RETRIES rounds before giving up.
for tool in claude gh; do
  command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH. Install it, then re-run." >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "✗ gh is not authenticated. Run: gh auth login" >&2; exit 1; }

mkdir -p "$LOG_DIR"

# Single-instance lock so this driver and an interactive /loop can't double-claim.
LOCK="$LOG_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "✗ Another backlog-loop run holds the lock ($LOCK). Exiting." >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Count open, prioritized issues that still need loop work. in-progress counts
# (Step 0 recovers it); blocked / needs-attention / in-review do not.
work_remaining() {
  gh issue list --state open --limit 1000 --json labels --jq '
    [ .[] | ([.labels[].name]) as $l
      | select( ($l | any(. == "P0" or . == "P1" or . == "P2"))
            and (($l | any(. == "blocked" or . == "needs-attention" or . == "in-review")) | not) )
    ] | length'
}

# One cold-context invocation. acceptEdits auto-approves file writes; bash is still
# governed by permissions: the committed .claude/settings.json denies merges and
# main pushes, and .claude/settings.local.json must allow every gh/git command
# /work-next-item runs plus the Verify commands (see README), or items stop early.
run_item() {
  if [ -n "${MODEL:-}" ]; then
    claude -p "/work-next-item" --permission-mode acceptEdits --model "$MODEL" >"$1" 2>&1
  else
    claude -p "/work-next-item" --permission-mode acceptEdits >"$1" 2>&1
  fi
}

count=0
while [ "$count" -lt "$MAX_ITEMS" ]; do
  if ! remaining="$(work_remaining)"; then
    echo "✗ gh query failed — is gh authenticated? Stopping." >&2
    exit 1
  fi
  if [ "$remaining" -eq 0 ]; then
    echo "✅ Backlog drained — no actionable issues remain. Completed $count item(s) this run."
    exit 0
  fi
  # Every productive iteration moves one issue out of the count (PR opened →
  # in-review, gave up → needs-attention, premise false → closed). An unchanged
  # count means the command stopped early (dirty tree, bad Verify, ...) and will
  # stop again, so don't spend a cold session per MAX_ITEMS finding that out.
  # Issues filed mid-run can mask progress; stopping then is safe — just re-run.
  if [ -n "${previous:-}" ] && [ "$remaining" -ge "$previous" ]; then
    echo "✗ The last item made no progress ($remaining actionable before and after)." >&2
    echo "  Read its log in $LOG_DIR, fix the cause, and re-run." >&2
    exit 3
  fi
  previous="$remaining"

  count=$((count + 1))
  ts="$(date +%Y%m%d-%H%M%S)"
  log="$LOG_DIR/item-$ts.log"
  echo "▶ [$count/$MAX_ITEMS] $remaining actionable item(s) remain → /work-next-item (log: $log)"

  attempt=0
  while :; do
    attempt=$((attempt + 1))
    if run_item "$log"; then
      break
    fi
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      echo "⚠ claude exited non-zero ${attempt}× (often an account usage limit)." >&2
      echo "  The loop is resumable — re-run this script later to continue." >&2
      exit 2
    fi
    backoff=$(( BACKOFF_SECONDS * attempt ))
    echo "  attempt ${attempt} failed; backing off ${backoff}s before retry…" >&2
    sleep "$backoff"
  done

  echo "  ─ last lines of this item:"
  tail -n 3 "$log" | sed 's/^/    /'
  sleep "$PACE_SECONDS"
done

echo "⏸ Reached MAX_ITEMS=${MAX_ITEMS}. Re-run to continue (the loop is resumable)."
