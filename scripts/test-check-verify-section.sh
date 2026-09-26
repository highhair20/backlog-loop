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

"$CHECK" "$WORK/missing.md" >/dev/null 2>&1
if [ $? -ne 0 ]; then echo "ok   rejects a missing file"; else echo "FAIL rejects a missing file" >&2; failures=$((failures + 1)); fi

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
