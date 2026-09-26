#!/usr/bin/env bash
# Exit 0 if CLAUDE.md has a `## Verify` section containing at least one real
# command in a fenced code block; exit 1 otherwise (missing file, missing section,
# or only the template's commented placeholders). /work-next-item treats Verify as
# the definition of green, so the loop must not start without one.
#
# Usage: scripts/check-verify-section.sh [path/to/CLAUDE.md]   (default: CLAUDE.md)
set -euo pipefail

file="${1:-CLAUDE.md}"
[ -f "$file" ] || { echo "check-verify-section: $file not found" >&2; exit 1; }

awk '
  /^## / { in_verify = ($0 ~ /^## Verify[[:space:]]*$/); in_code = 0; next }
  in_verify && /^```/ { in_code = !in_code; next }
  in_verify && in_code && $0 !~ /^[[:space:]]*(#|$)/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$file" || { echo "check-verify-section: no Verify commands in $file (see the repo contract in .claude/commands/work-next-item.md)" >&2; exit 1; }
