#!/usr/bin/env bash
# Tests for scripts/sync-guardrails.sh. Plain bash so it runs anywhere jq and git
# do, including CI. Usage: scripts/test-sync-guardrails.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/sync-guardrails.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# A target repo that already has its own settings, CLAUDE.md, and .gitignore.
new_target() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.claude"
  git -C "$dir" init -q -b main
  cat >"$dir/.claude/settings.json" <<'EOF'
{
  "permissions": { "deny": ["Bash(terraform apply*)", "Bash(gh pr merge:*)"] },
  "hooks": {
    "Stop": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "echo local-stop" } ] } ]
  }
}
EOF
  echo "# Custom CLAUDE.md" >"$dir/CLAUDE.md"
  printf 'node_modules/\n.claude/state/\n' >"$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m init
  echo "$dir"
}

# --- first sync into an existing repo ---
T="$(new_target first)"
"$SYNC" "$T" >/dev/null 2>&1
check "exits 0 on a clean target" "[ \$? -eq 0 ]"
check "copies review hooks, executable" "[ -x '$T/.claude/hooks/pr-review-gate.sh' ] && [ -x '$T/.claude/hooks/pr-review-state.sh' ] && [ -x '$T/.claude/hooks/pr-created-review.sh' ]"
check "leaves an existing CLAUDE.md alone" "grep -qx '# Custom CLAUDE.md' '$T/CLAUDE.md'"
check "seeds a missing ISSUE_GUIDE.md" "[ -f '$T/docs/ISSUE_GUIDE.md' ]"
check "seeds missing issue forms and CI" "[ -f '$T/.github/ISSUE_TEMPLATE/feature.yml' ] && [ -f '$T/.github/ISSUE_TEMPLATE/bug.yml' ] && [ -f '$T/.github/workflows/ci.yml' ]"
check "seeds dependabot and the PR template" "[ -f '$T/.github/dependabot.yml' ] && [ -f '$T/.github/pull_request_template.md' ]"
# Its indent defaults would silently change how editors treat existing code.
check "never adds .editorconfig to an existing repo" "[ ! -e '$T/.editorconfig' ]"
check "keeps the target's own deny rule" "jq -e '.permissions.deny | index(\"Bash(terraform apply*)\")' '$T/.claude/settings.json' >/dev/null"
check "adds the template's deny rules" "jq -e '.permissions.deny | index(\"Bash(git -* push*)\")' '$T/.claude/settings.json' >/dev/null"
check "does not duplicate a shared deny rule" "[ \"\$(jq '[.permissions.deny[] | select(. == \"Bash(gh pr merge:*)\")] | length' '$T/.claude/settings.json')\" = 1 ]"
check "keeps the target's own Stop hook" "jq -e '[.hooks.Stop[].hooks[].command] | index(\"echo local-stop\")' '$T/.claude/settings.json' >/dev/null"
check "adds the review gate Stop hook" "jq -e '[.hooks.Stop[].hooks[].command] | any(test(\"pr-review-gate.sh\"))' '$T/.claude/settings.json' >/dev/null"
check "adds the PR-created PostToolUse hook" "jq -e '[.hooks.PostToolUse[].hooks[].command] | any(test(\"pr-created-review.sh\"))' '$T/.claude/settings.json' >/dev/null"
check "routes MCP PR creation to the review hook" "jq -e '[.hooks.PostToolUse[] | select(.hooks[].command | test(\"pr-created-review.sh\")) | .matcher] | any(test(\"mcp__github__create_pull_request\"))' '$T/.claude/settings.json' >/dev/null"
check "appends only missing .gitignore lines" "[ \"\$(grep -cx '.claude/state/' '$T/.gitignore')\" = 1 ] && grep -qx '.claude/settings.local.json' '$T/.gitignore'"
check "ignores the backlog-loop log directory" "grep -qx '.loop-logs/' '$T/.gitignore'"
check "stamps the template commit it synced from" "grep -qE \"^\$(git -C '$HERE' rev-parse HEAD)(-dirty)?\$\" '$T/.claude/template-version'"

# --- idempotency: a second sync after committing changes nothing ---
git -C "$T" add -A
git -C "$T" -c user.name=t -c user.email=t@t commit -q -m synced
"$SYNC" "$T" >/dev/null 2>&1
check "second sync is a no-op" "[ -z \"\$(git -C '$T' status --porcelain)\" ]"

# --- a managed hook that drifted is restored ---
echo "# local edit" >>"$T/.claude/hooks/pr-review-gate.sh"
git -C "$T" -c user.name=t -c user.email=t@t commit -qam drift
"$SYNC" "$T" >/dev/null 2>&1
check "copies the generic loop command and driver" "[ -f '$T/.claude/commands/work-next-item.md' ] && [ -x '$T/scripts/backlog-loop.sh' ] && [ -x '$T/scripts/check-verify-section.sh' ]"
check "copies vendor-agents.sh, executable" "[ -x '$T/scripts/vendor-agents.sh' ]"
check "seeds the reviewer agents, their context, and the ECC license" "[ -f '$T/.claude/agents/pr-test-analyzer.md' ] && [ -f '$T/.claude/agents/silent-failure-hunter.md' ] && [ -f '$T/.claude/agent-context/_common.md' ] && [ -f '$T/.claude/agents/LICENSE.ECC' ]"
check "seeds the backlog operator doc" "[ -f '$T/docs/BACKLOG.md' ]"
check "copies setup.sh and seed-labels.sh, executable" "[ -x '$T/scripts/setup.sh' ] && [ -x '$T/scripts/seed-labels.sh' ]"
check "copies protect-main.sh and the allowlist example" "[ -x '$T/scripts/protect-main.sh' ] && [ -f '$T/.claude/settings.local.json.example' ]"
check "does not make the command file executable" "[ ! -x '$T/.claude/commands/work-next-item.md' ]"
check "overwrites a drifted managed hook" "! grep -q '# local edit' '$T/.claude/hooks/pr-review-gate.sh'"

# --- refusals ---
D="$(new_target dirty)"
echo change >>"$D/CLAUDE.md"
"$SYNC" "$D" >/dev/null 2>&1
check "refuses a dirty target" "[ \$? -ne 0 ]"
check "leaves a dirty target untouched" "[ ! -e '$D/.claude/hooks' ]"

mkdir -p "$WORK/not-a-repo"
"$SYNC" "$WORK/not-a-repo" >/dev/null 2>&1
check "refuses a non-git directory" "[ \$? -ne 0 ]"

"$SYNC" >/dev/null 2>&1
check "refuses a missing argument" "[ \$? -ne 0 ]"

# --- a target with no settings.json gets the template's ---
B="$WORK/bare"
mkdir -p "$B" && git -C "$B" init -q -b main
"$SYNC" "$B" >/dev/null 2>&1
check "seeds the project skeleton, not the template's own CLAUDE.md" "cmp -s '$HERE/../templates/CLAUDE.md' '$B/CLAUDE.md'"
check "creates settings.json when missing" "jq -e '.permissions.deny | length > 0' '$B/.claude/settings.json' >/dev/null"

# --- .gitignore with no trailing newline is not corrupted ---
N="$(new_target nonewline)"
printf 'node_modules' >"$N/.gitignore"
git -C "$N" -c user.name=t -c user.email=t@t commit -qam no-newline
"$SYNC" "$N" >/dev/null 2>&1
check "keeps the last .gitignore line intact" "grep -qx node_modules '$N/.gitignore' && grep -qx .claude/settings.local.json '$N/.gitignore'"

# --- a stale registration of a managed hook is replaced, not duplicated ---
S="$(new_target stale)"
jq '.hooks.Stop += [{"matcher":"*","hooks":[{"type":"command","command":"old/.claude/hooks/pr-review-gate.sh --old"}]}]' "$S/.claude/settings.json" >"$S/s.tmp" && mv "$S/s.tmp" "$S/.claude/settings.json"
git -C "$S" -c user.name=t -c user.email=t@t commit -qam stale
"$SYNC" "$S" >/dev/null 2>&1
check "registers the review gate exactly once" "[ \"\$(jq '[.hooks.Stop[].hooks[].command | select(test(\"pr-review-gate.sh\"))] | length' '$S/.claude/settings.json')\" = 1 ]"
check "drops the stale registration" "! grep -q -- '--old' '$S/.claude/settings.json'"
check "keeps unrelated hooks when replacing" "jq -e '[.hooks.Stop[].hooks[].command] | index(\"echo local-stop\")' '$S/.claude/settings.json' >/dev/null"

# --- a repo's own reviewer agent is kept ---
V="$(new_target ownagent)"
mkdir -p "$V/.claude/agents" && echo "# my own reviewer" >"$V/.claude/agents/pr-test-analyzer.md"
git -C "$V" add -A && git -C "$V" -c user.name=t -c user.email=t@t commit -qm agent
"$SYNC" "$V" >/dev/null 2>&1
check "keeps a repo's own version of a seeded agent" "grep -qx '# my own reviewer' '$V/.claude/agents/pr-test-analyzer.md'"
# Its context file would make the next vendor-agents.sh run target that agent.
check "seeds no context for an agent the repo already has" "[ ! -e '$V/.claude/agent-context/pr-test-analyzer.md' ] && [ -f '$V/.claude/agent-context/silent-failure-hunter.md' ]"

# --- a file the repo has under another extension is not seeded beside it ---
E="$(new_target equivalents)"
mkdir -p "$E/.github/ISSUE_TEMPLATE"
echo "# old-style template" >"$E/.github/ISSUE_TEMPLATE/feature.md"
echo "version: 2" >"$E/.github/dependabot.yaml"
git -C "$E" add -A && git -C "$E" -c user.name=t -c user.email=t@t commit -qm equivalents
"$SYNC" "$E" >/dev/null 2>&1
check "adds no issue forms to a repo with its own templates" "[ ! -e '$E/.github/ISSUE_TEMPLATE/feature.yml' ] && [ ! -e '$E/.github/ISSUE_TEMPLATE/bug.yml' ]"
check "does not seed dependabot.yml beside an existing dependabot.yaml" "[ ! -e '$E/.github/dependabot.yml' ]"

# GitHub's default template names, and the other places it reads a PR template from.
G="$(new_target defaultnames)"
mkdir -p "$G/.github/ISSUE_TEMPLATE" "$G/docs"
echo "# bug" >"$G/.github/ISSUE_TEMPLATE/bug_report.md"
echo "# pr" >"$G/docs/PULL_REQUEST_TEMPLATE.md"
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm defaults
"$SYNC" "$G" >/dev/null 2>&1
check "adds no issue forms beside GitHub-default template names" "[ ! -e '$G/.github/ISSUE_TEMPLATE/bug.yml' ] && [ ! -e '$G/.github/ISSUE_TEMPLATE/feature.yml' ]"
check "adds no PR template when one exists elsewhere" "[ ! -e '$G/.github/pull_request_template.md' ]"

# A repo whose ISSUE_TEMPLATE holds only config.yml still gets the forms.
K="$(new_target configonly)"
mkdir -p "$K/.github/ISSUE_TEMPLATE" && echo "blank_issues_enabled: true" >"$K/.github/ISSUE_TEMPLATE/config.yml"
git -C "$K" add -A && git -C "$K" -c user.name=t -c user.email=t@t commit -qm config
"$SYNC" "$K" >/dev/null 2>&1
check "seeds the forms when only config.yml exists" "[ -f '$K/.github/ISSUE_TEMPLATE/bug.yml' ] && [ -f '$K/.github/ISSUE_TEMPLATE/feature.yml' ]"

# --- placeholder CI is not added next to an existing workflow ---
W="$(new_target hasci)"
mkdir -p "$W/.github/workflows" && echo "name: test" >"$W/.github/workflows/test.yml"
git -C "$W" add -A && git -C "$W" -c user.name=t -c user.email=t@t commit -qm ci
"$SYNC" "$W" >/dev/null 2>&1
check "skips ci.yml when other workflows exist" "[ ! -e '$W/.github/workflows/ci.yml' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
