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

# The template repo's own CLAUDE.md starts with this marker. In any other repo it
# is the wrong file: its Verify would make the template's tests this repo's
# definition of green. The repo is recognised by its origin's name, as CI does.
TEMPLATE_MARKER='claude-code-repo-template: own instructions'
TEMPLATE_ORIGIN_RE='[/:]claude-code-repo-template(\.git)?/?$'
if grep -qF "$TEMPLATE_MARKER" "$file"; then
  origin="$(git -C "$(dirname "$file")" remote get-url origin 2>/dev/null || true)"
  if ! printf '%s' "$origin" | grep -qE "$TEMPLATE_ORIGIN_RE"; then
    echo "check-verify-section: $file is claude-code-repo-template's own CLAUDE.md, not this project's. Run scripts/setup.sh --fix to replace it with the project skeleton." >&2
    exit 1
  fi
fi

awk '
  /^```/ { in_code = !in_code; next }
  !in_code && /^## / { in_verify = ($0 ~ /^## Verify[[:space:]]*$/); next }
  in_verify && in_code && $0 !~ /^[[:space:]]*(#|$)/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$file" || { echo "check-verify-section: no Verify commands in $file (see the repo contract in .claude/commands/work-next-item.md)" >&2; exit 1; }
