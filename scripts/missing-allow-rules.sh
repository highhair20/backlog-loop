#!/usr/bin/env bash
# Prints each allow rule in .claude/settings.local.json.example that this machine's
# .claude/settings.local.json lacks, one per line. Sync updates the example but never
# the local file, so a rule the loop gained later (a new helper, a new git command)
# is missing until someone copies it, and an unattended run stops at the command it
# needs (#81). scripts/setup.sh and scripts/backlog-loop.sh both call this, so they
# cannot disagree about what is missing.
#
# Usage: scripts/missing-allow-rules.sh [local-settings-file]   (from the repo root)
#   The example is the same path with .example appended.
# Exits 0 when nothing is missing (or there is no example to compare with), 1 when
# rules are missing (printed on stdout), 2 when the files cannot be compared (a
# missing local file or invalid JSON; the reason, one line, on stderr).
set -uo pipefail

local_file="${1:-.claude/settings.local.json}"
example="$local_file.example"

[ -f "$example" ] || exit 0
if [ ! -f "$local_file" ]; then
  echo "no $local_file to compare with its example" >&2
  exit 2
fi
if ! missing="$(jq -r --slurpfile mine "$local_file" \
    '(.permissions.allow // []) - ($mine[0].permissions.allow // []) | .[]' \
    "$example" 2>/dev/null)"; then
  echo "could not compare $local_file with its example (invalid JSON?)" >&2
  exit 2
fi
[ -n "$missing" ] || exit 0
printf '%s\n' "$missing"
exit 1
