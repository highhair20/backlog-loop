#!/usr/bin/env bash
#
# Stop hook.
#
# Refuses to end the turn while a PR review loop is still open. This is the only
# part of the mechanism with teeth: PostToolUse fires once on `gh pr create` and
# cannot re-fire, so a nudge there can start a loop but never sustain one.
#
# Silent — exit 0, no output — when no loop is open, which is the overwhelmingly
# common case. Also silent while a review is actually in flight: waiting on a
# background agent requires the turn to END so its notification can arrive, so
# blocking then would just spin. The gate is for when Claude COULD act and is not.
#
# `stop_hook_active` is deliberately NOT honoured as a re-entrancy guard. It is
# true on every continuation caused by a Stop block, so gating on it would let
# this block exactly once and never again — which defeats multi-round
# enforcement, the entire point. MAX_GATE_BLOCKS in pr-review-state.sh is the
# wedge guard instead, alongside the round cap and the TTL.

set -uo pipefail

# Drain stdin even though only session_id is needed, so the caller never sees a
# short read.
input=$(cat)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Keep the output even on a non-zero exit. `write_state` exits 1 mid-loop when a
# state write fails, and discarding stdout there made the gate fail OPEN and
# silent — an enforcement mechanism that gives up quietly on a full disk is worse
# than none. Any BLOCK already emitted still counts; the failure is surfaced.
out=$("$here/pr-review-state.sh" gate-tick "$session" 2>/dev/null)
rc=$?
[ -n "$out" ] || [ "$rc" -ne 0 ] || exit 0
if [ "$rc" -ne 0 ]; then
  out="${out}
WARN|The review-loop state could not be updated (exit $rc); its self-limiting counters may not have advanced."
fi

blocking=$(printf '%s\n' "$out" | sed -n 's/^BLOCK|//p')
warnings=$(printf '%s\n' "$out" | sed -n 's/^WARN|//p')

# A loop that ended badly (round cap, expiry, gave up) must not look identical to
# one that passed — say so, but do not block on it.
if [ -z "$blocking" ]; then
  [ -n "$warnings" ] || exit 0
  # Deliberately does NOT block on a state-write failure. gate_blocks cannot
  # advance when writes fail, so MAX_GATE_BLOCKS could never trip and the TTL
  # could never delete the file — blocking would wedge the session with no way
  # out. Fail open, but never silently.
  jq -n --arg w "$warnings" --arg rc "$rc" \
    '{systemMessage: ((if $rc == "0" then "PR review loop ended without clearing: "
                       else "PR review loop NOT enforced this turn: " end) + $w)}'
  exit 0
fi

jq -n --arg blocking "$blocking" --arg warnings "$warnings" --arg helper "$here/pr-review-state.sh" '{
  decision: "block",
  reason: (
    (if $warnings == "" then "" else $warnings + "\n\n" end) +
    "An open PR review loop is not finished:\n\n" + $blocking + "\n\n" +
    "Do the next step above now. If you start a review, immediately run " +
    "`\($helper) reviewing <pr>` so this gate waits quietly instead of blocking " +
    "while it runs. Adjudicate findings before fixing them — verify each claim " +
    "against the code rather than trusting it. Close the round with " +
    "`\($helper) record <pr> <confirmed-crit-high-count>`.\n\n" +
    "To stop the loop instead: this gate holds the turn, so the user cannot reply " +
    "between blocks — they must interrupt (Esc). If they have already asked to skip " +
    "review, run `\($helper) clear <pr>` now. If the review tool is unavailable, say " +
    "so and clear the loop rather than burning its remaining continuations."
  )
}'
