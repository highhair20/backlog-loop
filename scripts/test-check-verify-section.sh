#!/usr/bin/env bash
# Tests for scripts/check-verify-section.sh. Usage: scripts/test-check-verify-section.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-verify-section.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
expect() { # expect <description> <want-exit: 0|1> <file-content>
  printf '%s' "$3" >"$WORK/CLAUDE.md"
  "$CHECK" "$WORK/CLAUDE.md" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (exit $got, want $2)" >&2; failures=$((failures + 1)); fi
}

expect "accepts a Verify section with a command" 0 $'# x\n\n## Verify\n\n```sh\ngo test ./...\n```\n'
expect "accepts commands after comments" 0 $'## Verify\n```sh\n# test:\nnpm test\n```\n'
expect "rejects a missing Verify section" 1 $'# x\n\n## Build\n```sh\nmake\n```\n'
expect "rejects the template placeholder" 1 $'## Verify\n\n```sh\n# build:\n# lint:\n# test:\n```\n'
expect "rejects a Verify section with no code block" 1 $'## Verify\n\nRun the tests.\n'
expect "ignores commands in a later section" 1 $'## Verify\n```sh\n# test:\n```\n\n## Other\n```sh\nmake\n```\n'
expect "treats ## inside a code block as a comment" 0 $'## Verify\n```sh\n## unit tests\ngo test ./...\n```\n'
expect "does not match ## Verify as a prefix" 1 $'## Verifying things\n```sh\nmake\n```\n'

# The template repo's own CLAUDE.md carries a marker. In a repo created from the
# template it is the wrong file: its Verify runs the template's tests, not yours.
own_md() { # own_md <dir> <origin-url> [repo name in the marker]: a git repo holding the template's own CLAUDE.md
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" remote add origin "$2"
  printf '<!-- %s: own instructions -->\n# x\n\n## Verify\n\n```sh\nmake test\n```\n' "${3:-backlog-loop}" >"$1/CLAUDE.md"
}
own_md "$WORK/copy" https://github.com/acme/my-app.git
out="$("$CHECK" "$WORK/copy/CLAUDE.md" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'setup.sh --fix'; then echo "ok   rejects the template's own CLAUDE.md in another repo"; else echo "FAIL rejects the template's own CLAUDE.md in another repo" >&2; failures=$((failures + 1)); fi

own_md "$WORK/tmpl" git@github.com:highhair20/backlog-loop.git
"$CHECK" "$WORK/tmpl/CLAUDE.md" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "ok   accepts it in the template repo itself"; else echo "FAIL accepts it in the template repo itself" >&2; failures=$((failures + 1)); fi

# The repo was renamed from claude-code-repo-template (#68). Repos made before the
# rename carry the old marker, and a clone may still use the old URL.
own_md "$WORK/oldcopy" https://github.com/acme/my-app.git claude-code-repo-template
"$CHECK" "$WORK/oldcopy/CLAUDE.md" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "ok   rejects the old marker in another repo"; else echo "FAIL rejects the old marker in another repo" >&2; failures=$((failures + 1)); fi
own_md "$WORK/oldurl" https://github.com/highhair20/claude-code-repo-template
"$CHECK" "$WORK/oldurl/CLAUDE.md" >/dev/null 2>&1
if [ $? -eq 0 ]; then echo "ok   accepts it in the template under its old name"; else echo "FAIL accepts it in the template under its old name" >&2; failures=$((failures + 1)); fi

"$CHECK" "$WORK/missing.md" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "ok   rejects a missing file"; else echo "FAIL rejects a missing file" >&2; failures=$((failures + 1)); fi

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
