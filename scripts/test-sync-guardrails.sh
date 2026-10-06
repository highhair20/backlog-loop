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
# The template's release notes; "Use this template" copies them, sync must not.
check "does not copy the template's CHANGELOG.md" "[ ! -e '$T/CHANGELOG.md' ]"
# The plugin's manifests belong to the template repo, not to the repos it syncs (#64).
check "never copies the plugin's .claude-plugin/" "[ ! -e '$T/.claude-plugin' ]"

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
# The driver and the command both call it; without it neither starts.
check "copies loop-lock.sh, executable" "[ -x '$T/scripts/loop-lock.sh' ]"
check "copies report-drained.sh, executable" "[ -x '$T/scripts/report-drained.sh' ]"
check "copies ready-to-merge.sh, executable" "[ -x '$T/scripts/ready-to-merge.sh' ]"
check "seeds the ready-to-merge workflow" "[ -f '$T/.github/workflows/ready-to-merge.yml' ]"
# The driver and setup.sh call it to check gh auth.
check "copies gh-auth-check.sh, executable" "[ -x '$T/scripts/gh-auth-check.sh' ]"
# The driver and setup.sh call it to pick the repo they act on (#17).
check "copies gh-repo.sh, executable" "[ -x '$T/scripts/gh-repo.sh' ]"
# The driver and setup.sh call it to compare the local allowlist with the example (#81).
check "copies missing-allow-rules.sh, executable" "[ -x '$T/scripts/missing-allow-rules.sh' ]"
# The driver and setup.sh call it to compare the repo with the template (#73).
check "copies template-version.sh, executable" "[ -x '$T/scripts/template-version.sh' ]"
check "copies vendor-agents.sh, executable" "[ -x '$T/scripts/vendor-agents.sh' ]"
check "seeds the reviewer agents, their context, and the ECC license" "[ -f '$T/.claude/agents/pr-test-analyzer.md' ] && [ -f '$T/.claude/agents/silent-failure-hunter.md' ] && [ -f '$T/.claude/agent-context/_common.md' ] && [ -f '$T/.claude/agents/LICENSE.ECC' ]"
# vendor-agents.sh refuses to run without it (#97); it matches the seeded agents.
check "seeds the ECC pin" "cmp -s '$HERE/ECC_PIN' '$T/scripts/ECC_PIN'"
# Inert until a repo copies one into .claude/agent-context/.
seeds_stack_contexts() {
  local a
  for a in go-reviewer database-reviewer typescript-reviewer python-reviewer; do
    cmp -s "$HERE/../.claude/agent-context/optional/$a.md" "$1/.claude/agent-context/optional/$a.md" || return 1
    [ ! -e "$1/.claude/agent-context/$a.md" ] || return 1
  done
}
check "seeds the optional stack reviewer contexts, not enabled" "seeds_stack_contexts '$T'"
check "seeds the backlog operator doc" "[ -f '$T/docs/BACKLOG.md' ]"
check "seeds the CI hardening guide" "cmp -s '$HERE/../docs/CI_HARDENING.md' '$T/docs/CI_HARDENING.md'"
check "manages the routine guide" "cmp -s '$HERE/../docs/ROUTINE.md' '$T/docs/ROUTINE.md'"
check "seeds the deploy guide" "cmp -s '$HERE/../docs/DEPLOYING.md' '$T/docs/DEPLOYING.md'"
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

# --- a committed symlink is never written through (#96) ---
# A new target whose path $2 is a committed symlink to $3.
link_target() {
  local dir
  dir="$(new_target "$1")"
  mkdir -p "$dir/$(dirname "$2")"
  rm -rf "${dir:?}/$2"
  ln -s "$3" "$dir/$2"
  git -C "$dir" add -A && git -C "$dir" -c user.name=t -c user.email=t@t commit -qm link
  echo "$dir"
}

# One of each kind of write: managed copy, settings merge, .gitignore merge, version stamp.
for rel in .claude/commands/work-next-item.md .claude/settings.json .gitignore .claude/template-version; do
  # Valid JSON, so a settings merge through the link would succeed and change it.
  out="$WORK/outside-${rel//\//_}"
  echo '{"outside": true}' >"$out"
  L="$(link_target "link${rel//\//_}" "$rel" "$out")"
  "$SYNC" "$L" >"$WORK/link.out" 2>&1
  rc=$?
  check "refuses a symlinked $rel, naming it" "[ $rc -ne 0 ] && grep -q 'symlink' '$WORK/link.out' && grep -qF '$rel' '$WORK/link.out'"
  check "leaves the file behind a symlinked $rel unchanged" "[ \"\$(cat '$out')\" = '{\"outside\": true}' ]"
  check "writes nothing into a target with a symlinked $rel" "[ -z \"\$(git -C '$L' status --porcelain)\" ] && [ ! -e '$L/scripts' ]"
done

# A symlinked parent directory sends every write under it outside the repo.
OUTDIR="$WORK/outside-dir"
mkdir -p "$OUTDIR" && echo '{}' >"$OUTDIR/settings.json"
L="$(link_target linkdir .claude "$OUTDIR")"
"$SYNC" "$L" >"$WORK/linkdir.out" 2>&1
rc=$?
check "refuses a symlinked .claude directory, naming it" "[ $rc -ne 0 ] && grep -q 'symlink' '$WORK/linkdir.out' && grep -qF '.claude' '$WORK/linkdir.out'"
check "leaves the directory behind a symlinked .claude unchanged" "[ \"\$(ls -A '$OUTDIR')\" = settings.json ] && [ \"\$(cat '$OUTDIR/settings.json')\" = '{}' ]"
check "writes nothing into a target with a symlinked .claude" "[ -z \"\$(git -C '$L' status --porcelain)\" ] && [ ! -e '$L/scripts' ]"

# The walk checks every directory, not only the first: here the link is two deep.
OUTWF="$WORK/outside-workflows"
mkdir -p "$OUTWF"
L="$(link_target linknested .github/workflows "$OUTWF")"
"$SYNC" "$L" >"$WORK/linknested.out" 2>&1
rc=$?
check "refuses a symlinked directory below the top level, naming it" "[ $rc -ne 0 ] && grep -qF '.github/workflows' '$WORK/linknested.out'"
check "writes nothing behind a nested symlinked directory" "[ -z \"\$(ls -A '$OUTWF')\" ] && [ ! -e '$L/scripts' ]"

# [ -e ] calls a dangling link missing, so the seeding would cp through it.
mkdir -p "$WORK/dangling"
L="$(link_target linkdangling docs/BACKLOG.md "$WORK/dangling/BACKLOG.md")"
"$SYNC" "$L" >"$WORK/dangling.out" 2>&1
rc=$?
check "refuses a dangling symlink at a seeded path" "[ $rc -ne 0 ] && grep -qF 'docs/BACKLOG.md' '$WORK/dangling.out'"
check "creates nothing behind a dangling seeded symlink" "[ ! -e '$WORK/dangling/BACKLOG.md' ]"

# A seeded file the sync skips is never written, so its link is no risk.
L="$(link_target linkskipped CLAUDE.md AGENTS.md)"
echo "# Agents" >"$L/AGENTS.md"
git -C "$L" add -A && git -C "$L" -c user.name=t -c user.email=t@t commit -qm agents
"$SYNC" "$L" >/dev/null 2>&1
check "syncs a target whose skipped seeded file is a symlink" "[ \$? -eq 0 ] && [ -x '$L/scripts/setup.sh' ] && grep -qx '# Agents' '$L/AGENTS.md'"

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
mkdir -p "$V/.claude/agents" "$V/scripts" && echo "# my own reviewer" >"$V/.claude/agents/pr-test-analyzer.md"
# A repo that adopted another ECC commit keeps its pin, which matches its agents.
echo 0123456789abcdef0123456789abcdef01234567 >"$V/scripts/ECC_PIN"
git -C "$V" add -A && git -C "$V" -c user.name=t -c user.email=t@t commit -qm agent
"$SYNC" "$V" >/dev/null 2>&1
check "keeps a repo's own version of a seeded agent" "grep -qx '# my own reviewer' '$V/.claude/agents/pr-test-analyzer.md'"
check "keeps a repo's own ECC pin" "grep -qx 0123456789abcdef0123456789abcdef01234567 '$V/scripts/ECC_PIN'"
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

# --- a repo's own CI hardening guide is kept ---
H="$(new_target ownguide)"
mkdir -p "$H/docs" && echo "# our CI notes" >"$H/docs/CI_HARDENING.md"
git -C "$H" add -A && git -C "$H" -c user.name=t -c user.email=t@t commit -qm guide
"$SYNC" "$H" >/dev/null 2>&1
check "leaves an existing CI_HARDENING.md alone" "grep -qx '# our CI notes' '$H/docs/CI_HARDENING.md'"

# --- a repo's own deploy guide is kept ---
P="$(new_target owndeploy)"
mkdir -p "$P/docs" && echo "# our deploy notes" >"$P/docs/DEPLOYING.md"
git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -qm deploy
"$SYNC" "$P" >/dev/null 2>&1
check "leaves an existing DEPLOYING.md alone" "grep -qx '# our deploy notes' '$P/docs/DEPLOYING.md'"

# --- placeholder CI is not added next to an existing workflow ---
W="$(new_target hasci)"
mkdir -p "$W/.github/workflows" && echo "name: test" >"$W/.github/workflows/test.yml"
git -C "$W" add -A && git -C "$W" -c user.name=t -c user.email=t@t commit -qm ci
"$SYNC" "$W" >/dev/null 2>&1
check "skips ci.yml when other workflows exist" "[ ! -e '$W/.github/workflows/ci.yml' ]"

# --- template-version records the release tag the template is on (#65) ---
# A copy of this checkout's working tree in a repo of its own, so tagging it
# touches nothing real and the scripts under test are the ones being edited.
tagged_template() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  (cd "$HERE/.." && tar --exclude=./.git -cf - .) | (cd "$dir" && tar -xf -)
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm template
  git -C "$dir" tag v9.9.9
  echo "$dir"
}

TT="$(tagged_template tpl-tagged)"
R="$(new_target ontag)"
"$TT/scripts/sync-guardrails.sh" "$R" >"$WORK/ontag.out" 2>&1
check "on a tag: line 1 is still the commit" "[ \"\$(sed -n 1p '$R/.claude/template-version')\" = \"\$(git -C '$TT' rev-parse HEAD)\" ]"
check "on a tag: line 2 is the tag" "[ \"\$(sed -n 2p '$R/.claude/template-version')\" = v9.9.9 ]"
check "on a tag: the sync names the tag" "grep -qF 'backlog-loop @ v9.9.9' '$WORK/ontag.out'"

git -C "$TT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m past-the-tag
R2="$(new_target pasttag)"
"$TT/scripts/sync-guardrails.sh" "$R2" >/dev/null 2>&1
check "past a tag: records the commit only" "[ \"\$(cat '$R2/.claude/template-version')\" = \"\$(git -C '$TT' rev-parse HEAD)\" ]"

git -C "$TT" checkout -q v9.9.9
echo "# uncommitted" >>"$TT/README.md"
R3="$(new_target dirtytag)"
"$TT/scripts/sync-guardrails.sh" "$R3" >/dev/null 2>&1
# A dirty tree is not the release, whatever tag its HEAD carries.
check "on a tag with uncommitted changes: no tag, -dirty commit" "[ \"\$(cat '$R3/.claude/template-version')\" = \"\$(git -C '$TT' rev-parse HEAD)-dirty\" ]"

# --- run from an installed plugin: a copy of the template, not a git checkout (#64) ---
# Claude Code copies the plugin to cache/<marketplace>/<plugin>/<version>/, and the
# version is the template commit shortened to 12 characters. The copy sits inside
# a git repo here, as it would under a git-managed ~/.claude: that repo's commit
# must never be recorded as the template's.
plugin_copy() { # plugin_copy <dir>: the template's files, without .git
  local f
  mkdir -p "$1"
  git -C "$HERE/.." ls-files --cached --others --exclude-standard | while IFS= read -r f; do
    [ -e "$HERE/../$f" ] || continue
    mkdir -p "$1/$(dirname "$f")" && cp -p "$HERE/../$f" "$1/$f"
  done
}
CACHE="$WORK/dot-claude"
git -C "$WORK" init -q dot-claude
git -C "$CACHE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m enclosing
plugin_copy "$CACHE/plugins/cache/backlog-loop/backlog-loop/0123456789ab"
Q="$(new_target fromplugin)"
bash "$CACHE/plugins/cache/backlog-loop/backlog-loop/0123456789ab/scripts/sync-guardrails.sh" "$Q" >"$WORK/fromplugin.out" 2>&1
check "syncs from a plugin copy that is not a git checkout" "[ \$? -eq 0 ] && [ -x '$Q/scripts/setup.sh' ]"
check "stamps the commit the plugin's cache directory is named after" "[ \"\$(cat '$Q/.claude/template-version')\" = 0123456789ab ]"
check "says which version it synced" "grep -q '@ 0123456789ab' '$WORK/fromplugin.out'"
check "a plugin copy syncs no .claude-plugin/ either" "[ ! -e '$Q/.claude-plugin' ]"
plugin_copy "$CACHE/plugins/cache/backlog-loop/backlog-loop/unknown"
U="$(new_target unknownversion)"
bash "$CACHE/plugins/cache/backlog-loop/backlog-loop/unknown/scripts/sync-guardrails.sh" "$U" >"$WORK/unknown.out" 2>&1
check "a copy whose directory names no commit stamps unknown" "[ \$? -eq 0 ] && [ \"\$(cat '$U/.claude/template-version')\" = unknown ]"
check "and warns that the version is unknown" "grep -q 'warning: .*template version as unknown' '$WORK/unknown.out'"
# The enclosing repo's tags are not the template's (#65): a copy named after a
# tagged commit there must still record the commit alone.
git -C "$CACHE" tag v9.9.9
ENCLOSING="$(git -C "$CACHE" rev-parse HEAD | cut -c1-12)"
plugin_copy "$CACHE/plugins/cache/backlog-loop/backlog-loop/$ENCLOSING"
PT="$(new_target plugintagged)"
bash "$CACHE/plugins/cache/backlog-loop/backlog-loop/$ENCLOSING/scripts/sync-guardrails.sh" "$PT" >/dev/null 2>&1
check "a plugin copy records no release tag" "[ \"\$(cat '$PT/.claude/template-version')\" = '$ENCLOSING' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
