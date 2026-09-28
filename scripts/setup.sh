#!/usr/bin/env bash
# Check that this repo is set up for the backlog loop, and say how to fix what is
# not. Read-only unless --fix, which applies only the safe, repeatable fixes: it
# creates missing labels and copies the local allowlist example. The ruleset is
# never created here, because it needs your CI job names and admin rights; the
# check prints the exact command instead.
#
# Exits 0 when nothing fails (warnings allowed), 1 otherwise, 2 on bad usage.
#
# Usage: scripts/setup.sh [--fix]
#   TEMPLATE_REPO  repo to compare .claude/template-version with
#                  (default: the public claude-code-repo-template)
set -uo pipefail

TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/highhair20/claude-code-repo-template.git}"
RULESET_NAME=protect-main
CI_PLACEHOLDER='Verify (not configured)'
LOCAL_SETTINGS=.claude/settings.local.json

fix=0
case "${1:-}" in
  --fix) fix=1 ;;
  "") ;;
  *) echo "usage: $0 [--fix]" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "setup: not inside a git repository" >&2; exit 1; }
cd "$root" || exit 1

failures=0
warnings=0
repo=""
ok()   { echo "  ✓ $1"; }
info() { echo "  - $1"; }
bad()  { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "      fix: $2"; failures=$((failures + 1)); }
warn() { echo "  ⚠ $1"; [ -z "${2:-}" ] || echo "      fix: $2"; warnings=$((warnings + 1)); }

# The commands in CLAUDE.md's Verify code block, one per line, comments dropped.
# Same parse as check-verify-section.sh.
verify_commands() {
  awk '
    /^```/ { in_code = !in_code; next }
    !in_code && /^## / { in_verify = ($0 ~ /^## Verify[[:space:]]*$/); next }
    in_verify && in_code && $0 !~ /^[[:space:]]*(#|$)/ { sub(/^[[:space:]]+/, ""); print }
  ' CLAUDE.md
}

# Label names from seed-labels.sh, the script that creates them.
required_labels() { sed -nE 's/^[[:space:]]*"([^|"]+)\|.*/\1/p' scripts/seed-labels.sh; }

check_tools() {
  echo "Tools"
  local t
  for t in git gh jq; do
    if command -v "$t" >/dev/null; then ok "$t installed"; else bad "$t not found" "install $t"; fi
  done
  if command -v claude >/dev/null; then
    ok "claude installed"
  else
    warn "claude not found (needed only to run the loop)" "install Claude Code: https://code.claude.com/docs/en/overview"
  fi
}

check_claude_md() {
  echo "CLAUDE.md"
  if [ ! -f CLAUDE.md ]; then
    bad "CLAUDE.md is missing" "copy it from the template and fill it in"
    return
  fi
  if grep -q '^# <project>' CLAUDE.md; then
    warn "the title is still the <project> placeholder" "put your project's name on the first line of CLAUDE.md"
  else
    ok "project named"
  fi
  if scripts/check-verify-section.sh CLAUDE.md >/dev/null 2>&1; then
    ok "Verify has commands"
  else
    bad "## Verify has no commands, so the loop will refuse to run" "add your build, lint, and test commands to the Verify code block"
  fi
}

check_ci() {
  echo "CI"
  local workflows=(.github/workflows/*.y*ml)
  if [ ! -e "${workflows[0]}" ]; then
    bad "no workflows in .github/workflows" "add one that runs the Verify commands from CLAUDE.md"
    return
  fi
  if grep -qF "$CI_PLACEHOLDER" "${workflows[@]}"; then
    bad "ci.yml still has the placeholder step that always fails" "replace it with the Verify commands from CLAUDE.md"
  else
    ok "no placeholder step"
  fi

  [ -f CLAUDE.md ] || return
  local cmd count=0 missing=0
  while IFS= read -r cmd; do
    count=$((count + 1))
    grep -qF -- "$cmd" "${workflows[@]}" && continue
    warn "Verify command not found in any workflow: $cmd" "run the same command in CI, so CI and the loop agree on what green means"
    missing=$((missing + 1))
  done < <(verify_commands)
  [ "$count" -eq 0 ] || [ "$missing" -gt 0 ] || ok "CI runs every Verify command"
}

check_local_settings() {
  echo "Unattended runs"
  if [ -f "$LOCAL_SETTINGS" ]; then
    ok "$LOCAL_SETTINGS exists"
  elif [ ! -f "$LOCAL_SETTINGS.example" ]; then
    warn "no $LOCAL_SETTINGS, and no example to start from" "re-run sync-guardrails.sh from the template"
  elif [ "$fix" -eq 1 ]; then
    cp "$LOCAL_SETTINGS.example" "$LOCAL_SETTINGS"
    ok "copied the example to $LOCAL_SETTINGS (add your Verify commands to its allow list)"
  else
    warn "no $LOCAL_SETTINGS, so scripts/backlog-loop.sh stops at the first command it cannot run" \
      "scripts/setup.sh --fix, then add your Verify commands to its allow list"
  fi
}

check_template_version() {
  echo "Template"
  if [ ! -f .claude/template-version ]; then
    info "no .claude/template-version (written by sync-guardrails.sh); skipped"
    return
  fi
  local have latest
  have="$(head -1 .claude/template-version)"
  have="${have%-dirty}"
  # The HEAD pattern also matches refs like refs/remotes/origin/HEAD; take the exact one.
  latest="$(git ls-remote "$TEMPLATE_REPO" HEAD 2>/dev/null | awk '$2 == "HEAD" { print $1; exit }')"
  if [ -z "$latest" ]; then
    warn "could not reach $TEMPLATE_REPO to compare versions"
  elif [ "$have" = "$latest" ]; then
    ok "up to date with the template"
  else
    warn "synced from template ${have:0:7}; the template is now at ${latest:0:7}" \
      "from a fresh clone of the template: scripts/sync-guardrails.sh $root"
  fi
}

# Sets $repo. Returns non-zero when the GitHub checks cannot run.
check_github() {
  echo "GitHub"
  if ! command -v gh >/dev/null || ! command -v jq >/dev/null; then
    info "skipped: needs gh and jq"
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    bad "gh is not authenticated" "gh auth login"
    return 1
  fi
  ok "gh authenticated"
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  if [ -z "$repo" ]; then
    bad "no GitHub repository for this checkout" "gh repo create, or git remote add origin <url>"
    return 1
  fi
  ok "repository $repo"
}

check_labels() {
  echo "Labels"
  if [ ! -f scripts/seed-labels.sh ]; then
    bad "scripts/seed-labels.sh is missing, so the required labels are unknown" "re-run sync-guardrails.sh from the template"
    return
  fi
  local have want missing=()
  if ! have="$(gh label list --repo "$repo" --limit 1000 --json name --jq '.[].name' 2>/dev/null)"; then
    bad "could not list the labels on $repo"
    return
  fi
  while IFS= read -r want; do
    printf '%s\n' "$have" | grep -qxF -- "$want" || missing+=("$want")
  done < <(required_labels)

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "every loop label exists"
  elif [ "$fix" -eq 1 ] && scripts/seed-labels.sh "$repo" >/dev/null; then
    ok "created the missing labels: ${missing[*]}"
  else
    bad "missing labels: ${missing[*]}" "scripts/setup.sh --fix  (or scripts/seed-labels.sh $repo)"
  fi
}

check_ruleset() {
  echo "Branch protection"
  local names
  if ! names="$(gh api "repos/$repo/rulesets?includes_parents=false" 2>/dev/null | jq -r '.[].name')"; then
    warn "could not read the rulesets on $repo (needs admin; private repos need a paid plan)"
    return
  fi
  if printf '%s\n' "$names" | grep -qxF "$RULESET_NAME"; then
    ok "ruleset $RULESET_NAME exists"
  else
    bad "no $RULESET_NAME ruleset, so nothing on GitHub's side stops a push to main" \
      "scripts/protect-main.sh $repo <ci-job-name>...  (job names as they appear on a PR)"
  fi
}

main() {
  check_tools; echo
  check_claude_md; echo
  check_ci; echo
  check_local_settings; echo
  check_template_version; echo
  if check_github; then
    echo; check_labels
    echo; check_ruleset
  fi
  echo
  if [ "$failures" -eq 0 ]; then
    echo "Ready: no problems, $warnings warning(s)."
    exit 0
  fi
  echo "$failures problem(s), $warnings warning(s). Fix the ✗ items above, then re-run."
  exit 1
}

main
