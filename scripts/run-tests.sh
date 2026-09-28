#!/usr/bin/env bash
# Run every scripts/test-*.sh and fail if any fails. This template repo's Verify
# command, and what template-self-test.yml runs, so a new test is picked up by
# both without editing either. Template-only: it is not synced into repos.
#
# Usage: scripts/run-tests.sh          (a failing suite's output is shown)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
count=0

for t in "$here"/test-*.sh; do
  [ -e "$t" ] || continue
  count=$((count + 1))
  name="${t##*/}"
  if out="$("$t" 2>&1)"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | sed 's/^/     /'
    failed+=("$name")
  fi
done

[ "$count" -gt 0 ] || { echo "run-tests: no scripts/test-*.sh found" >&2; exit 1; }
echo
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all $count test suites passed"
else
  echo "${#failed[@]} of $count test suites failed: ${failed[*]}" >&2
  exit 1
fi
