#!/usr/bin/env bash
# Structural checks on .claude/commands/work-next-item.md, the prompt the backlog
# loop runs. Behaviour lives in prose there, so these pin the parts that have
# broken before: every way of giving up goes through one procedure (#4), and
# that procedure saves work before it deletes anything.
# Usage: scripts/test-work-next-item.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$ROOT/.claude/commands/work-next-item.md"
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The text of one "## <heading>" section, up to the next "## " heading.
section() { awk -v h="$1" '/^## /{ on = (index($0, "## " h) == 1); next } on' "$CMD"; }
give_up="$(section 'Give up')"
# shellcheck disable=SC2034  # read inside check's eval strings
step5="$(section 'Step 5')"
# shellcheck disable=SC2034  # read inside check's eval strings
step65="$(section 'Step 6.5')"

check "has one Give up section" "[ \"\$(grep -c '^## Give up' '$CMD')\" = 1 ]"
check "Step 5 gives up through it" "printf '%s' \"\$step5\" | grep -q 'Give up'"
check "Step 6.5 gives up through it" "printf '%s' \"\$step65\" | grep -q 'Give up'"

# Deleting the issue's branch, locally or on the remote, happens only in Give up.
for pattern in 'git branch -D' 'git push origin --delete'; do
  check "'$pattern' appears only in Give up" \
    "[ \"\$(grep -c -- '$pattern' '$CMD')\" -ge 1 ] && [ \"\$(grep -c -- '$pattern' '$CMD')\" = \"\$(printf '%s\n' \"\$give_up\" | grep -c -- '$pattern')\" ]"
done

# A stash stays on one machine, and a cloud session's clone is thrown away.
check "nothing is stashed on give-up" "! printf '%s' \"\$give_up\" | grep -q 'git stash'"

# Order inside Give up: save commits, then delete branches, then swap labels.
line_of() { printf '%s\n' "$give_up" | grep -n -m1 -- "$1" | cut -d: -f1; }
save="$(line_of 'refs/heads/abandoned/')"
del_remote="$(line_of 'git push origin --delete')"
del_local="$(line_of 'git branch -D')"
labels="$(line_of '--add-label needs-attention')"
check "pushes the work to an abandoned/ branch" "[ -n '$save' ]"
check "saves the work before deleting any branch" "[ -n '$save' ] && [ -n '$del_remote' ] && [ -n '$del_local' ] && [ '$save' -lt '$del_remote' ] && [ '$save' -lt '$del_local' ]"
check "swaps the labels last" "[ -n '$labels' ] && [ '$labels' -gt '$del_remote' ] && [ '$labels' -gt '$del_local' ]"
check "stops without deleting if the save fails" "printf '%s' \"\$give_up\" | grep -qi 'push fails'"

# Step 0 must not mistake a preserved branch for work in flight.
check "Step 0 knows about abandoned/ branches" "section 'Step 0' | grep -q 'abandoned/'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
