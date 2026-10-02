#!/usr/bin/env bash
# Checks that scripts/seed-labels.sh creates exactly the labels that the Labels
# section of docs/ISSUE_GUIDE.md defines. The guide is the definition of record
# (an agent reads it, never GitHub's label list), so the two must not drift.
# Usage: scripts/test-labels.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

# The "## Labels" section, up to the next "## " heading. Fenced blocks are
# examples for a repo to copy (its own label family), not labels. An unclosed
# fence would hide every label after it, so it fails rather than passing short.
labels_section="$(awk '
  /^ ? ? ?(```|~~~)[^`]*$/ { in_fence = !in_fence; next }
  in_fence { next }
  /^## / { in_labels = ($0 ~ /^## Labels[[:space:]]*$/); next }
  in_labels
  END { if (in_fence) exit 2 }' "$ROOT/docs/ISSUE_GUIDE.md")" \
  || { echo "FAIL docs/ISSUE_GUIDE.md has an unclosed code fence; labels after it would go unchecked" >&2; failures=$((failures + 1)); }

# Backticked names in that section. Paths and file names (anything with a / or .)
# are prose references, not labels.
documented="$(printf '%s\n' "$labels_section" | grep -oE '`[^`]+`' | tr -d '`' | grep -vE '[/.]' | sort -u)"

# The name field of each "name|color|description" entry in the LABELS array.
seeded="$(sed -nE 's/^[[:space:]]*"([^|"]+)\|.*/\1/p' "$ROOT/scripts/seed-labels.sh" | sort -u)"

[ -n "$documented" ] || { echo "FAIL found no labels in docs/ISSUE_GUIDE.md; extraction is broken" >&2; failures=$((failures + 1)); }
[ -n "$seeded" ] || { echo "FAIL found no labels in scripts/seed-labels.sh; extraction is broken" >&2; failures=$((failures + 1)); }

while IFS= read -r name; do
  [ -n "$name" ] || continue
  echo "FAIL documented but not seeded: $name" >&2; failures=$((failures + 1))
done < <(comm -23 <(printf '%s\n' "$documented") <(printf '%s\n' "$seeded"))

while IFS= read -r name; do
  [ -n "$name" ] || continue
  echo "FAIL seeded but not documented: $name" >&2; failures=$((failures + 1))
done < <(comm -13 <(printf '%s\n' "$documented") <(printf '%s\n' "$seeded"))

[ "$failures" -eq 0 ] && echo "ok   $(printf '%s\n' "$seeded" | wc -l | tr -d ' ') labels match between ISSUE_GUIDE.md and seed-labels.sh"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
