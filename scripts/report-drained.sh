#!/usr/bin/env bash
# Tells scripts/backlog-loop.sh that this session found the backlog drained: nothing
# to select in Step 2 and no PR to follow up. The driver reads this marker, never the
# session's words, because a model paraphrases its report (#77, measured in the
# review of #80). Kept beside the loop lock, in the common git directory, so a
# linked worktree shares it.
# Usage: scripts/report-drained.sh   (Step 2 of /work-next-item runs it)
set -euo pipefail

git_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "report-drained: not a git repository: $PWD" >&2
  exit 1
}
date -u +%Y-%m-%dT%H:%M:%SZ >"$git_dir/backlog-loop.drained"
echo "report-drained: recorded in $git_dir/backlog-loop.drained"
