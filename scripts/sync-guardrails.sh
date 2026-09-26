#!/usr/bin/env bash
# Sync this template's GitHub-flow guardrails into an existing repo.
#
# Three kinds of file, handled differently so a re-run never clobbers local work:
#
#   managed  — overwritten every run. Files with no per-repo content (the PR
#              review hooks); a local edit there is drift, and drift is the bug.
#   seeded   — copied only when missing. Files each repo is expected to tailor
#              (CLAUDE.md, CI, issue templates, the issue guide).
#   merged   — .claude/settings.json keeps the repo's own rules and hooks and
#              gains the template's; .gitignore gains only missing lines.
#
# Nothing is committed. The target must start clean, so `git diff` afterwards is
# exactly what the sync changed — review it, then commit on a branch.
#
# Usage (from a clone of the template): scripts/sync-guardrails.sh <target-repo-dir>
set -euo pipefail

TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MANAGED=(
  .claude/hooks/pr-created-review.sh
  .claude/hooks/pr-review-gate.sh
  .claude/hooks/pr-review-state.sh
)
SEEDED=(
  CLAUDE.md
  docs/ISSUE_GUIDE.md
  .github/workflows/ci.yml
  .github/ISSUE_TEMPLATE/bug.md
  .github/ISSUE_TEMPLATE/feature.md
  .github/ISSUE_TEMPLATE/config.yml
)
SETTINGS=.claude/settings.json

die() { echo "sync-guardrails: $*" >&2; exit 1; }

# Union of deny rules (target order first) and hook entries (an entry is added
# only if one of its commands is not already registered for that event).
merge_settings() {
  jq -s '
    .[0] as $t | .[1] as $s
    | $t
    | .permissions.deny = (($t.permissions.deny // []) + (($s.permissions.deny // []) - ($t.permissions.deny // [])))
    | .hooks = reduce (($s.hooks // {}) | to_entries[]) as $e (($t.hooks // {});
        .[$e.key] = ((.[$e.key] // []) as $cur
          | $cur + [ $e.value[] | select(([.hooks[].command] - [$cur[].hooks[]?.command]) | length > 0) ]))
  ' "$1" "$2"
}

main() {
  [ $# -eq 1 ] || die "usage: $0 <target-repo-dir>"
  command -v jq >/dev/null || die "jq not found"
  local target
  target="$(cd "$1" 2>/dev/null && pwd)" || die "no such directory: $1"
  git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $target"
  [ "$target" != "$TEMPLATE" ] || die "target is the template itself"
  [ -z "$(git -C "$target" status --porcelain)" ] || die "target has uncommitted changes; commit or stash first so the sync diff is reviewable"

  local f
  for f in "${MANAGED[@]}"; do
    mkdir -p "$target/$(dirname "$f")"
    cp "$TEMPLATE/$f" "$target/$f"
    chmod +x "$target/$f"
  done

  for f in "${SEEDED[@]}"; do
    [ -e "$target/$f" ] && continue
    mkdir -p "$target/$(dirname "$f")"
    cp "$TEMPLATE/$f" "$target/$f"
  done

  mkdir -p "$target/.claude"
  if [ -f "$target/$SETTINGS" ]; then
    local merged
    merged="$(merge_settings "$target/$SETTINGS" "$TEMPLATE/$SETTINGS")" || die "could not merge $SETTINGS (invalid JSON?)"
    printf '%s\n' "$merged" >"$target/$SETTINGS"
  else
    cp "$TEMPLATE/$SETTINGS" "$target/$SETTINGS"
  fi

  local line
  touch "$target/.gitignore"
  while IFS= read -r line; do
    [ -z "$line" ] || [ "${line#\#}" != "$line" ] && continue
    grep -qxF "$line" "$target/.gitignore" || printf '%s\n' "$line" >>"$target/.gitignore"
  done <"$TEMPLATE/.gitignore"

  echo "Synced from repo-template @ $(git -C "$TEMPLATE" rev-parse --short HEAD)."
  git -C "$target" status --short
  echo "Review with: git diff  (in $target), then commit on a branch."
}

main "$@"
