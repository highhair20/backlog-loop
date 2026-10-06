#!/usr/bin/env bash
# Sync this template's GitHub-flow guardrails into an existing repo.
#
# Three kinds of file, handled differently so a re-run never clobbers local work:
#
#   managed  — overwritten every run. Files with no per-repo content (the PR
#              review hooks, the backlog loop command and driver); a local edit
#              there is drift, and drift is the bug. Repo specifics go in CLAUDE.md.
#   seeded   — copied only when missing. Files each repo is expected to tailor
#              (CLAUDE.md, CI, issue templates, the issue and CI guides).
#   merged   — .claude/settings.json keeps the repo's own rules and hooks and
#              gains the template's; .gitignore gains only missing lines.
#
# Nothing is committed. The target must start clean, so `git diff` afterwards is
# exactly what the sync changed — review it, then commit on a branch.
#
# Usage (from a clone of the template): scripts/sync-guardrails.sh <target-repo-dir>
# The installer plugin's /backlog-loop:install and :update run it the same way,
# from the plugin's installed copy of the template.
set -euo pipefail

TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MANAGED=(
  .claude/hooks/pr-created-review.sh
  .claude/hooks/pr-review-gate.sh
  .claude/hooks/pr-review-state.sh
  .claude/commands/work-next-item.md
  scripts/backlog-loop.sh
  scripts/check-verify-section.sh
  scripts/gh-auth-check.sh
  scripts/gh-repo.sh
  scripts/loop-lock.sh
  scripts/missing-allow-rules.sh
  scripts/protect-main.sh
  scripts/ready-to-merge.sh
  scripts/report-drained.sh
  scripts/seed-labels.sh
  scripts/setup.sh
  scripts/template-version.sh
  scripts/vendor-agents.sh
  .claude/settings.local.json.example
  # Describes the managed command's --dry-run and gate, so it tracks the command.
  docs/ROUTINE.md
)
SEEDED=(
  CLAUDE.md
  docs/ISSUE_GUIDE.md
  .github/workflows/ci.yml
  .github/workflows/ready-to-merge.yml
  .github/ISSUE_TEMPLATE/bug.yml
  .github/ISSUE_TEMPLATE/feature.yml
  .github/ISSUE_TEMPLATE/config.yml
  .github/pull_request_template.md
  .github/dependabot.yml
  docs/BACKLOG.md
  docs/CI_HARDENING.md
  docs/DEPLOYING.md
  .claude/agent-context/_common.md
  .claude/agent-context/pr-test-analyzer.md
  .claude/agent-context/silent-failure-hunter.md
  .claude/agents/pr-test-analyzer.md
  .claude/agents/silent-failure-hunter.md
  .claude/agents/LICENSE.ECC
  # Optional stack reviewers. They stay off only because vendor-agents.sh reads
  # the top level of .claude/agent-context/, never optional/; a repo turns one on
  # by copying it up a level. If vendor-agents.sh ever searches subfolders, this
  # would switch all of them on in every synced repo.
  .claude/agent-context/optional/database-reviewer.md
  .claude/agent-context/optional/go-reviewer.md
  .claude/agent-context/optional/python-reviewer.md
  .claude/agent-context/optional/typescript-reviewer.md
)
# Not synced: .editorconfig. New repos get it from the template, but its indent
# defaults would silently change how editors treat an existing repo's code.
SETTINGS=.claude/settings.json
VERSION_FILE=.claude/template-version

die() { echo "sync-guardrails: $*" >&2; exit 1; }

# Deny rules: union, target order first. A rule later removed from the template
# stays in synced repos — the script cannot tell it from one the repo added.
#
# Hooks: registrations of the managed hook scripts are managed too. Any target
# command naming one is dropped, then the template's entries are added, so a
# changed invocation replaces the old one instead of running twice. Other hooks
# are kept, and a template entry is added only if one of its commands is new.
merge_settings() {
  local managed
  managed="$(printf '%s\n' "${MANAGED[@]##*/}" | jq -R . | jq -s .)"
  jq -s --argjson managed "$managed" '
    def is_managed: . as $c | [$managed[] as $m | $c | contains($m)] | any;
    .[0] as $t | .[1] as $s
    | $t
    | .permissions.deny = (($t.permissions.deny // []) + (($s.permissions.deny // []) - ($t.permissions.deny // [])))
    | .hooks = (($t.hooks // {})
        | map_values(map(.hooks |= map(select(.command | is_managed | not))) | map(select(.hooks | length > 0))))
    | .hooks = reduce (($s.hooks // {}) | to_entries[]) as $e (.hooks;
        .[$e.key] = ((.[$e.key] // []) as $cur
          | $cur + [ $e.value[] | select(([.hooks[].command] - [$cur[].hooks[]?.command]) | length > 0) ]))
    | .hooks |= with_entries(select(.value | length > 0))
  ' "$1" "$2"
}

# True if the target already has seeded file $2, or the same file under another
# extension: GitHub reads both .yml and .yaml. Seeding beside one would give
# GitHub two of the same thing.
has_equivalent() {
  local target="$1" f="$2" ext
  case "$f" in
    *.md|*.yml|*.yaml)
      for ext in md yml yaml; do
        [ -e "$target/${f%.*}.$ext" ] && return 0
      done
      return 1 ;;
    *) [ -e "$target/$f" ] ;;
  esac
}

# True if the target has any issue template of its own, whatever its name
# (bug_report.md, feature_request.yml, ...). The forms are a set: adding them
# beside other templates would only double the "New issue" chooser.
has_issue_templates() {
  local f
  for f in "$1"/.github/ISSUE_TEMPLATE/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in config.yml|config.yaml) ;; *) return 0 ;; esac
  done
  return 1
}

# True if the target has a PR template anywhere GitHub reads one from.
has_pr_template() {
  local dir name
  for dir in .github . docs; do
    for name in pull_request_template.md PULL_REQUEST_TEMPLATE.md PULL_REQUEST_TEMPLATE; do
      [ -e "$1/$dir/$name" ] && return 0
    done
  done
  return 1
}

# True if seeded file $2 is to be copied into target $1, where $3 is 1 if the
# target had issue templates of its own before seeding.
should_seed() {
  local target="$1" f="$2" had_issue_templates="$3"
  case "$f" in
    .github/ISSUE_TEMPLATE/config.yml) has_equivalent "$target" "$f" && return 1 ;;
    .github/ISSUE_TEMPLATE/*) [ "$had_issue_templates" -eq 0 ] || return 1 ;;
    .github/pull_request_template.md) has_pr_template "$target" && return 1 ;;
    # A context file makes vendor-agents.sh build that agent, so none for an
    # agent the repo already has (its own, or one it built another way). The
    # optional/ files match here too, on purpose: a repo with its own go-reviewer
    # does not need a second, inactive context for it.
    .claude/agent-context/_common.md) has_equivalent "$target" "$f" && return 1 ;;
    .claude/agent-context/*)
      [ -e "$target/.claude/agents/${f##*/}" ] && return 1
      has_equivalent "$target" "$f" && return 1 ;;
    *) has_equivalent "$target" "$f" && return 1 ;;
  esac
  # The placeholder CI fails on purpose. Next to a repo's existing workflows it
  # would only add a red check, so seed it only into a repo with no CI at all.
  if [ "$f" = .github/workflows/ci.yml ] && compgen -G "$target/.github/workflows/*.y*ml" >/dev/null; then
    echo "skipped $f: the repo already has workflows"
    return 1
  fi
  return 0
}

# The first symlink on the way from target $1 down to its path $2, relative to $1.
# cp, >, >>, touch, chmod and mkdir -p all follow one, so a committed link would
# send the write outside the repo.
symlink_on_path() {
  local p="" rest="$2"
  while [ -n "$rest" ]; do
    p="${p:+$p/}${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    if [ -L "$1/$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Dies, naming each symlink, if any path in $2... under target $1 runs through one.
# Called before the first write, so a refusal leaves the target untouched (#96).
refuse_symlinks() {
  local target="$1" rel link found=""
  shift
  for rel in "$@"; do
    link="$(symlink_on_path "$target" "$rel")" || continue
    case " $found " in *" $link "*) ;; *) found="$found $link" ;; esac
  done
  [ -z "$found" ] || die "refusing to write through a symlink in $target:$found. Replace each with a real file or directory, commit, and sync again."
}

# Where the template keeps a seeded file. The root CLAUDE.md is the template
# repo's own instructions; repos get the project skeleton instead.
seed_source() {
  case "$1" in
    CLAUDE.md) echo templates/CLAUDE.md ;;
    *) echo "$1" ;;
  esac
}

# The template commit being synced. A clone gives its HEAD (with -dirty for
# uncommitted changes). The installed plugin (#64) is a copy with no .git, in
# cache/<marketplace>/<plugin>/<version>/, whose <version> is the commit shortened
# to 12 characters. Only a repo whose top level is the template counts: a copy
# inside another repo (a git-managed ~/.claude) must not report that repo's commit.
template_version() {
  local top real version changes
  top="$(git -C "$TEMPLATE" rev-parse --show-toplevel 2>/dev/null)" || top=""
  real="$(cd "$TEMPLATE" && pwd -P)" || return 1
  if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$real" ]; then
    version="$(git -C "$TEMPLATE" rev-parse HEAD)" || return 1
    changes="$(git -C "$TEMPLATE" status --porcelain)" || return 1
    [ -z "$changes" ] || version="$version-dirty"
    echo "$version"
  elif printf '%s\n' "${real##*/}" | grep -qxE '[0-9a-f]{12}'; then
    echo "${real##*/}"
  else
    echo "sync-guardrails: warning: $TEMPLATE is neither a git clone nor a plugin copy named after its commit; recording the template version as unknown, so setup.sh cannot tell how far behind it is" >&2
    echo unknown
  fi
}

# The release tag (#65) the template is exactly on, or nothing. Only a clean clone
# can carry one: template_version gives it as a bare 40-character commit. A dirty
# tree is not the release, whatever tag its HEAD carries, and a plugin copy has no
# tags of its own.
template_tag() {
  printf '%s\n' "$1" | grep -qxE '[0-9a-f]{40}' || return 0
  # A non-zero exit here only means the commit carries no tag.
  git -C "$TEMPLATE" describe --tags --exact-match "$1" 2>/dev/null || true
}

main() {
  [ $# -eq 1 ] || die "usage: $0 <target-repo-dir>"
  command -v jq >/dev/null || die "jq not found"
  local target
  target="$(cd "$1" 2>/dev/null && pwd)" || die "no such directory: $1"
  git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $target"
  [ "$target" != "$TEMPLATE" ] || die "target is the template itself"
  [ -z "$(git -C "$target" status --porcelain)" ] || die "target has uncommitted changes; commit or stash first so the sync diff is reviewable"

  # Every write is decided before the first one, so the symlink check covers them
  # all. Only seeded files that will be copied count: one the repo already has is
  # never written, whatever it is.
  local had_issue_templates=0 f seeds=()
  has_issue_templates "$target" && had_issue_templates=1
  for f in "${SEEDED[@]}"; do
    if should_seed "$target" "$f" "$had_issue_templates"; then
      seeds+=("$f")
    fi
  done
  refuse_symlinks "$target" "${MANAGED[@]}" ${seeds[@]+"${seeds[@]}"} "$SETTINGS" .gitignore "$VERSION_FILE"

  for f in "${MANAGED[@]}"; do
    mkdir -p "$target/$(dirname "$f")"
    cp "$TEMPLATE/$f" "$target/$f"
    case "$f" in *.sh) chmod +x "$target/$f" ;; esac
  done

  for f in ${seeds[@]+"${seeds[@]}"}; do
    mkdir -p "$target/$(dirname "$f")"
    cp "$TEMPLATE/$(seed_source "$f")" "$target/$f"
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
  # Without this, the first appended line would join a last line that has no newline.
  if [ -s "$target/.gitignore" ] && [ -n "$(tail -c1 "$target/.gitignore")" ]; then
    echo >>"$target/.gitignore"
  fi
  while IFS= read -r line; do
    [ -z "$line" ] || [ "${line#\#}" != "$line" ] && continue
    grep -qxF -- "$line" "$target/.gitignore" || printf '%s\n' "$line" >>"$target/.gitignore"
  done <"$TEMPLATE/.gitignore"

  # Record which template commit this repo now matches, so drift is visible later
  # (in git history, and to any tool comparing it with the template's HEAD).
  # Line 1 is always the commit, so that comparison keeps working. A second line
  # names the release tag, only when there is one.
  local version tag
  version="$(template_version)" || die "could not read the template's version"
  tag="$(template_tag "$version")"
  printf '%s\n' "$version" ${tag:+"$tag"} >"$target/$VERSION_FILE"

  if [ -n "$tag" ]; then
    echo "Synced from backlog-loop @ $tag ($version)."
  else
    echo "Synced from backlog-loop @ $version."
  fi
  git -C "$target" status --short
  echo "Review with: git diff  (in $target), then commit on a branch."
}

main "$@"
