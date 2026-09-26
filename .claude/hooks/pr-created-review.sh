#!/usr/bin/env bash
#
# PostToolUse / Bash hook.
#
# After a `gh pr create` that actually produced a PR, open a review loop for that
# PR and tell Claude the protocol. This hook only SEEDS the loop — it fires once
# and cannot fire again, so it cannot enforce anything. The Stop hook
# (pr-review-gate.sh) is what keeps the loop running.
#
# Detection keys off the RESPONSE, not the command, because the command cannot be
# matched reliably without a shell parser. Two rounds of review proved that:
#
#   - a loose substring match fired for a `jq` call that merely quoted the words
#   - anchoring to command boundaries then UNDER-matched the most natural idiom,
#     `PR_URL=$(gh pr create --fill)`, so the hook silently never armed at all
#   - the boundary chars still matched inside quoted literals, so it over-matched
#     and under-matched simultaneously
#
# What is reliable: a successful `gh pr create` prints the new PR's URL as a line
# on STDOUT, by itself. So the response must contain a line that is *exactly* a
# PR URL, and the command match is only a cheap prefilter. Reading stdout alone
# also rejects the failure case, where `gh` reports "a pull request for branch X
# already exists: <url>" on STDERR — that must not open a loop on someone else's PR.
#
# KNOWN LIMITATION, stated plainly because an earlier version of this comment
# claimed a fix it did not have: if the command captures or redirects gh's stdout
# (`PR_URL=$(gh pr create --fill)`, or a pipe), the tool response carries no URL
# and no loop opens. That is not fixable from the payload — the URL never reaches
# the tool. The repo's own `/work-next-item` uses the uncaptured form, so the
# primary path arms; a hand-written capturing variant silently will not, and you
# must open the loop yourself with `pr-review-state.sh seed <pr> <url>`.

set -uo pipefail

input=$(cat)

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
printf '%s' "$command" | grep -qE 'gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

out=$(printf '%s' "$input" \
  | jq -r '[.tool_response.stdout?, .tool_response.output?] | map(select(type == "string" and . != "")) | first // empty' 2>/dev/null \
  | tr -d '\r')

# Relying on stderr staying separate is relying on the CALLER. `gh pr create
# --fill 2>&1` is a habitual idiom, and it puts the failure text —
#   a pull request for branch "x" into branch "main" already exists:
#   https://github.com/o/r/pull/2001
# — on stdout, where the URL sits on its own line and is indistinguishable from
# success. That armed a loop against an existing, unrelated PR. Reject the
# failure text explicitly rather than trusting the stream separation.
printf '%s' "$out" | grep -qiE 'already exists|^error[: ]|failed to create|could not create' && exit 0

# A bare PR URL on its own stdout line — anchored, so a URL merely mentioned in
# other output cannot qualify.
url=$(printf '%s' "$out" \
  | grep -E '^[[:space:]]*https://[^[:space:]]+/pull/[0-9]+[[:space:]]*$' \
  | head -1 | tr -d '[:space:]')
[ -n "$url" ] || exit 0

pr=${url##*/}
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Exit 3 means a loop is already open for this PR — a legitimate silent no-op.
# Any OTHER failure (unwritable state dir, jq missing, full disk) means the
# enforcement mechanism did not arm, and that must not pass unremarked: the gate
# holds itself to "fail open, but never silently", and so should this.
# `rc=$?` must come from the command itself. Inside `if ! cmd; then rc=$?` it
# would capture the negation's status (always 0) and report "exited 0".
"$here/pr-review-state.sh" seed "$pr" "$url" "$session" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$rc" -eq 3 ] && exit 0
  jq -n --arg url "$url" --arg rc "$rc" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: (
        "A pull request was created (\($url)) but the review loop could NOT be " +
        "opened (pr-review-state.sh seed exited \($rc)). Nothing will enforce a " +
        "review for it. Check .claude/state/pr-review/ is writable, then either " +
        "seed the loop by hand or run the review without it."
      )
    }
  }'
  exit 0
fi

jq -n --arg url "$url" --arg pr "$pr" --arg helper "$here/pr-review-state.sh" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: (
      "A pull request was just created: \($url)\n\n" +
      "A review loop is now open for PR \($pr). The Stop hook will not let this " +
      "turn end until the loop closes, so work it rather than deferring it.\n\n" +
      "Each round:\n" +
      "1. Start the review with `/code-review \($pr)`, then IMMEDIATELY run:\n" +
      "     \($helper) reviewing \($pr)\n" +
      "   The review is a background agent that takes several minutes, and it can " +
      "only report back if the turn is allowed to end. This tells the gate to go " +
      "quiet and wait instead of blocking. Skip it and the gate spins.\n" +
      "2. ADJUDICATE every finding before acting on it. Reviewers are wrong a " +
      "meaningful fraction of the time — verify each claim against the code, and " +
      "prefer a measurement over an argument. For each finding you reject, run:\n" +
      "     \($helper) reject \($pr) \"<finding>\" \"<why it is wrong>\"\n" +
      "   so later rounds do not re-raise it.\n" +
      "3. Fix what survives, then close the round with the number of CONFIRMED " +
      "CRITICAL/HIGH findings it produced:\n" +
      "     \($helper) record \($pr) <count>\n" +
      "4. Zero blocking findings closes the loop. Otherwise push the fixes and " +
      "review again — a fix can introduce a new defect, which is the whole reason " +
      "the loop exists. It caps at 3 rounds either way.\n\n" +
      "MEDIUM and LOW findings are reported to the user, not looped on.\n\n" +
      "If the user has said to skip review for this PR, run " +
      "`\($helper) clear \($pr)` and tell them you skipped it."
    )
  }
}'
