#!/usr/bin/env bash
# Create or update the standard labels defined in docs/ISSUE_GUIDE.md.
#
# Idempotent: `gh label create --force` updates a label's color and description
# when it already exists, so re-running is safe. It never deletes labels, so any
# repo-specific ones are left alone.
#
# Usage: scripts/seed-labels.sh [owner/repo]   (default: the current repo)
set -euo pipefail

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }

repo_args=()
[ $# -ge 1 ] && repo_args=(--repo "$1")

# name|color|description — keep in sync with the Labels section of ISSUE_GUIDE.md.
LABELS=(
  "P0|B60205|Priority: do first — blocker / release-critical"
  "P1|FBCA04|Priority: high"
  "P2|C2E0C6|Priority: medium"
  "P3|EDEDED|Priority: nice-to-have; worked only when no P0-P2 is actionable"
  "bug|D73A4A|Something isn't working"
  "enhancement|A2EEEF|New feature or request"
  "in-progress|0E8A16|Claimed and being worked"
  "in-review|1D76DB|PR open, awaiting maintainer merge"
  "blocked|000000|Cannot proceed; skipped by the loop"
  "needs-infra|5319E7|Infra change written but must be applied by a human"
  "needs-attention|D93F0B|Loop gave up after repeated attempts; needs a human"
)

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<<"$entry"
  gh label create "$name" --color "$color" --description "$description" --force ${repo_args[@]+"${repo_args[@]}"} >/dev/null
  echo "ok $name"
done
