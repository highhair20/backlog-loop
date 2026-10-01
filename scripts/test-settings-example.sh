#!/usr/bin/env bash
# Checks .claude/settings.local.json.example against the command it exists for:
# every gh/git command /work-next-item tells Claude to run must match an allow
# rule, or an unattended run stops at the first unmatched one. Also checks that
# no allow rule re-opens what the committed deny list closes.
# Usage: scripts/test-settings-example.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/.claude/settings.local.json.example"
COMMAND="$ROOT/.claude/commands/work-next-item.md"
failures=0
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

# Claude Code permission rules are globs over the command text; bash's own
# pattern matching (`[[ x == $glob ]]`, unquoted) is a close enough model.
matches_any() { # matches_any <command> <glob>...
  local cmd="$1" g; shift
  for g in "$@"; do
    # The legacy "prefix:*" form means "the command starts with prefix". Only a
    # literal trailing ":*" counts; ":main" in "git push *:main" is a real colon.
    case "$g" in *':*') g="${g%:\*}*" ;; esac
    # shellcheck disable=SC2053
    [[ "$cmd" == $g ]] && return 0
  done
  return 1
}

# macOS ships bash 3.2, which has no mapfile.
read_lines() { local _l; while IFS= read -r _l; do printf "%s\0" "$_l"; done; }

jq -e . "$EXAMPLE" >/dev/null 2>&1 || { fail "example is not valid JSON"; echo "1 test(s) failed" >&2; exit 1; }
echo "ok   example is valid JSON"

ALLOW=(); while IFS= read -r -d "" l; do ALLOW+=("$l"); done < <(jq -r '.permissions.allow[] | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$EXAMPLE" | read_lines)
DENY=(); while IFS= read -r -d "" l; do DENY+=("$l"); done < <(jq -r '.permissions.deny[] | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$ROOT/.claude/settings.json" | read_lines)

# Commands the loop runs: gh/git lines inside fenced blocks, plus inline `gh …` /
# `git …` spans in prose. Placeholders (<number>, ${N}) are made concrete.
CMDS=(); while IFS= read -r -d "" l; do CMDS+=("$l"); done < <(
  {
    # Fences may be indented (code blocks inside list items, as in Give up).
    awk '/^[[:space:]]*```/ { f = !f; next } f { sub(/^[[:space:]]+/, "") } f && /^(gh |git |scripts\/)/ { sub(/[[:space:]]*\\$/, ""); print }' "$COMMAND"
    grep -oE '`(gh|git) [^`]+`' "$COMMAND" | tr -d '`'
  } | sed -E 's/<[a-z/ -]+>/x/g; s/\$\{N\}/1/g; s/\$N/1/g' | sort -u | read_lines
)
[ "${#CMDS[@]}" -gt 10 ] || fail "extracted only ${#CMDS[@]} commands from the loop; extraction is broken"

for cmd in "${CMDS[@]}"; do
  # A command the deny list blocks on purpose needs no allow rule.
  matches_any "$cmd" "${DENY[@]}" && continue
  if matches_any "$cmd" "${ALLOW[@]}"; then echo "ok   allowed: $cmd"; else fail "not allowed: $cmd"; fi
done

# Every way of running the loop must refuse a CLAUDE.md the checker rejects (such as
# the template repo's own), not just backlog-loop.sh.
if grep -qF 'scripts/check-verify-section.sh CLAUDE.md' "$COMMAND"; then echo "ok   the loop command runs check-verify-section.sh"; else fail "the loop command does not run check-verify-section.sh"; fi

# Every way of running the loop must also yield to a run that holds the lock. The
# command checks it; only backlog-loop.sh takes it, so nothing else may be allowed.
if grep -qx 'scripts/loop-lock.sh check' "$COMMAND"; then echo "ok   the loop command runs loop-lock.sh check"; else fail "the loop command does not run loop-lock.sh check"; fi
for cmd in "scripts/loop-lock.sh acquire 1" "scripts/loop-lock.sh release 1"; do
  if matches_any "$cmd" "${ALLOW[@]}"; then fail "allowed, but only the driver should run it: $cmd"; else echo "ok   not allowed: $cmd"; fi
done

# The deny list must still win for the pushes that matter, even with the allow rules.
# A pushed release tag (v1.2.3) often triggers a deploy, so it counts as one of them.
for cmd in "git push origin main" "git push -u origin HEAD:main" "git push --force origin x" "gh pr merge 1" "git push origin v1.2.3" "git push --follow-tags" "git push origin +v1.4.0"; do
  if matches_any "$cmd" "${DENY[@]}"; then echo "ok   still denied: $cmd"; else fail "not denied: $cmd"; fi
done

# The test above skips any loop command the deny list matches, so a deny rule that
# grew too broad would silently stop the loop. Pin the pushes the loop needs (#41).
for cmd in "git push -u origin fix/1-x" "git push origin fix/1-x" "git push origin --delete fix/1-x" "git push origin HEAD:refs/heads/abandoned/1-abc1234"; do
  if matches_any "$cmd" "${DENY[@]}"; then fail "denied, but the loop needs it: $cmd"; else echo "ok   not denied: $cmd"; fi
done

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
