#!/usr/bin/env bash
# Structural checks on .claude/commands/file-issue.md, which drafts an issue from a
# one-line idea and files it only once the user approves (#72). Behaviour lives in
# prose there, so these pin the parts that keep it safe: nothing is filed without
# approval, it never starts the work itself, and the headings come from the issue
# forms rather than a copy that can drift.
# Usage: scripts/test-file-issue.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$ROOT/.claude/commands/file-issue.md"
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The line number of the first line matching a fixed string, or empty.
line_of() { grep -n -m1 -F -- "$1" "$CMD" | cut -d: -f1; }
# The command's text on one line, so a phrase broken across lines still matches.
# shellcheck disable=SC2034  # read inside check's eval strings
flat="$( [ -f "$CMD" ] && tr '\n' ' ' <"$CMD" | tr -s ' ')"

check "the command exists, with a description" "[ -f '$CMD' ] && sed -n 1,3p '$CMD' | grep -q '^description: '"
check "it takes the idea from its arguments" "grep -qF '\$ARGUMENTS' '$CMD'"
check "it reads the issue guide and the repo's CLAUDE.md" "grep -qF 'docs/ISSUE_GUIDE.md' '$CMD' && printf '%s' \"\$flat\" | grep -q 'Scope map' && printf '%s' \"\$flat\" | grep -q 'Definition of done'"

# The headings have one place of record: the forms.
check "it reads the headings from the issue forms" "grep -qF '.github/ISSUE_TEMPLATE/' '$CMD' && printf '%s' \"\$flat\" | grep -q 'label:'"
check "it does not copy the forms' headings into a list of its own" "! grep -qE '^#+ (Context|Goal|Acceptance criteria|Implementation notes|Out of scope|Testing|Steps to reproduce|Expected vs actual)[[:space:]]*$' '$CMD'"

# Labels: one type, exactly one priority, every priority the seeder creates.
for p in $(sed -nE 's/^[[:space:]]*"(P[0-9])\|.*/\1/p' "$ROOT/scripts/seed-labels.sh"); do
  check "it names priority label $p" "grep -qF '\`$p\`' '$CMD'"
done
check "it proposes exactly one priority, with a reason" "printf '%s' \"\$flat\" | grep -q 'exactly one priority' && printf '%s' \"\$flat\" | grep -q 'one-line reason'"
check "it uses the forms' type labels" "grep -qF '\`enhancement\`' '$CMD' && grep -qF '\`bug\`' '$CMD'"
check "it adds no-auto-heal when the change touches .claude/" "printf '%s' \"\$flat\" | grep -q 'no-auto-heal. when the change touches .\.claude/.'"

# Order: duplicates before the code search and the draft; approval before filing.
dup="$(line_of 'gh issue list --state all')"
code="$(line_of '## Step 3')"
draft="$(line_of '## Step 4')"
stop="$(line_of '## Step 5')"
create="$(line_of 'gh issue create')"
check "it searches open and closed issues for duplicates first" "[ -n '$dup' ] && [ -n '$code' ] && [ '$dup' -lt '$code' ] && printf '%s' \"\$flat\" | grep -q -- '--search'"
check "a likely duplicate stops it before drafting" "printf '%s' \"\$flat\" | grep -q 'likely duplicate' && printf '%s' \"\$flat\" | grep -q 'do not draft'"
check "it shows the draft and ends its turn before any gh issue create" "[ -n '$draft' ] && [ -n '$stop' ] && [ -n '$create' ] && [ '$draft' -lt '$stop' ] && [ '$stop' -lt '$create' ] && printf '%s' \"\$flat\" | grep -q 'end your turn'"
check "gh issue create appears only once, after approval" "[ \"\$(grep -c 'gh issue create' '$CMD')\" = 1 ]"
check "it files with --body-file, never an inline --body" "grep 'gh issue create' '$CMD' | grep -q -- '--body-file -' && ! grep -qE 'gh issue create.* --body ' '$CMD'"
check "the filing command carries no-auto-heal and repo labels when the draft has them" "grep 'gh issue create' '$CMD' | grep -q -- '--label no-auto-heal' && grep 'gh issue create' '$CMD' | grep -q -- '--label <repo label>'"
check "after filing it says no-auto-heal issues are never taken by the loop" "printf '%s' \"\$flat\" | grep -q 'with .no-auto-heal., the loop never takes it' && printf '%s' \"\$flat\" | grep -q 'heal:approved'"
check "run headless, it prints the draft and files nothing" "printf '%s' \"\$flat\" | grep -q 'headless' && printf '%s' \"\$flat\" | grep -q 'files nothing'"

# It never starts the work.
for bad in 'in-progress' 'git checkout -b' 'git switch -c' 'gh pr create' 'git push' 'git commit'; do
  check "it never runs or mentions '$bad'" "! grep -qF -- '$bad' '$CMD'"
done

# Filing needs a person: the unattended allowlist must not cover it.
check "the unattended allowlist does not allow gh issue create" "! grep -q 'gh issue create' '$ROOT/.claude/settings.local.json.example'"
check "the allowlist covers the duplicate search" "grep -qF 'Bash(gh issue list *)' '$ROOT/.claude/settings.local.json.example'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
