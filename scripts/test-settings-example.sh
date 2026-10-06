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

# The PR review hooks start /code-review, a built-in command this test cannot read, so
# its commands are pinned here as measured: `claude -p "/code-review <pr-url>"
# --output-format stream-json --verbose` with this example as the allowlist, Claude
# Code 2.1.289 (#78). Without gh pr diff, an unattended review sees no diff. Re-measure
# after a Claude Code upgrade (docs/BACKLOG.md, "Reviews in unattended runs").
for cmd in "gh pr view 3 --json title,body,headRefName,baseRefName,state" "gh pr view 3 --repo o/r --json title,body,headRefName,baseRefName,state,files" "gh pr diff 3" "gh pr diff 3 --repo o/r"; do
  if matches_any "$cmd" "${ALLOW[@]}"; then echo "ok   review command allowed: $cmd"; else fail "review command not allowed: $cmd"; fi
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

# A deny rule ending in ":*" is Claude Code's legacy prefix form ("starts with"), so
# "git push * :*" would deny every push. None may end that way except whole commands.
if jq -r '.permissions.deny[]' "$ROOT/.claude/settings.json" | grep -E '^Bash\(git push .* :\*\)$' >/dev/null; then fail "a git push deny rule ends in ' :*', which denies every push"; else echo "ok   no git push deny rule ends in ' :*'"; fi

# The git commands whose options can run a program are allowed only in the forms the
# loop writes (#95): a broad glob would admit --upload-pack and friends.
for broad in "git fetch *" "git pull *" "git ls-remote *"; do
  if printf '%s\n' "${ALLOW[@]}" | grep -qxF "$broad"; then fail "allows the broad form, which admits options that run a program: $broad"; else echo "ok   not allowed broadly: $broad"; fi
done

# The deny list must still win for the pushes that matter, even with the allow rules.
# A pushed release tag (v1.2.3) often triggers a deploy, so it counts as one of them.
for cmd in "git push origin main" "git push -u origin HEAD:main" "git push --force origin x" "gh pr merge 1" "gh api repos/{owner}/{repo}/pulls/1/merge -X PUT" "gh api repos/{owner}/{repo}/pulls/1/merge -X PUT -f a=/comments --paginate" "git push origin v1.2.3" "git push --follow-tags" "git push --follow origin x" "git push --tag origin x" "git push --ta origin x" "git push --foll origin x" "git push origin +v1.4.0" \
  "git push origin HEAD:refs/heads/main" "git push origin :refs/heads/main" "git push origin :main" "git push origin fix/1-x:refs/heads/main" \
  "git fetch --upload-pack=x ." "git pull --upload-pack=x ." "git ls-remote --upload-pack=x ." "git push --receive-pack=x origin fix/1-x" "git push --exec=x origin fix/1-x" \
  "git diff --output=/tmp/x" "git log --oneline --output=/tmp/x" \
  "git -c core.sshCommand=x fetch origin" "git --config-env=core.sshCommand=X fetch origin" "git config core.sshCommand x" "git config alias.st !x" \
  "git pull --no-rebase --no-edit origin --upload-p=x" "git ls-remote --heads origin --upload-p=x" "git ls-remote --heads origin --u=x" "git fetch origin --upl=x" \
  "git push origin x --receive=x" "git push origin x --rece=x" "git push origin x --exe=x" "git push origin x --e=x" \
  "git diff --out=/tmp/x" "git log --outp=/tmp/x" "git show --output=/tmp/x" "git show HEAD --ou=/tmp/x" \
  "git config" "git -C . config k v" "git push origin :refs/heads/abandoned/1-x" "git ls-remote --heads origin --exec=x" "git fetch origin --exe=x" "git pull --no-rebase --no-edit origin --exec=x" "git fetch origin main --upload-pack=x" \
  "git push origin HEAD:heads/main" "git push origin fix/1-x:heads/main" \
  "git -C . fetch --upload-pack=x ." "git -C . ls-remote --upl=x ." "git -C . pull --exec=x ." "git -C . push --receive-pack=x origin x" "git --no-pager diff --output=x" "git -C . log --outp=/tmp/x" "git --no-pager show --ou=x" \
  "git -C . -c core.sshCommand=x fetch origin" "git --no-pager -c core.fsmonitor=x status" "git -C . --config-env=core.pager=X log"; do
  if matches_any "$cmd" "${DENY[@]}"; then echo "ok   still denied: $cmd"; else fail "not denied: $cmd"; fi
done

# The test above skips any loop command the deny list matches, so a deny rule that
# grew too broad would silently stop the loop. Pin the pushes the loop needs (#41).
for cmd in "git push -u origin fix/1-x" "git push origin fix/1-x" "git push origin --delete fix/1-x" "git push origin HEAD:refs/heads/abandoned/1-abc1234" "git push origin fix/1-x:refs/heads/abandoned/1-abc1234" "git fetch origin" "git fetch origin main" "git -C . status --short" "git --no-pager log --oneline -3" "git -C . diff --name-only main...HEAD" "git push origin feat/7-heads-up" "git pull --ff-only" "git pull --no-rebase --no-edit origin fix/1-x" "git ls-remote --heads origin" "git ls-remote --heads origin fix/1-x" "git diff --name-only main...HEAD" "git log --oneline origin/main..HEAD" "git commit -m fix: deny --upload-pack, --receive-pack, --exec and --output (#95)" "git commit -m docs: git -c and git config are denied, as is refs/heads/main"; do
  if matches_any "$cmd" "${DENY[@]}"; then fail "denied, but the loop needs it: $cmd"; else echo "ok   not denied: $cmd"; fi
done

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
