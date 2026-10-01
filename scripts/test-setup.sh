#!/usr/bin/env bash
# Tests for scripts/setup.sh, with a fake `gh` on PATH and throwaway repos, so no
# network is involved. Usage: scripts/test-setup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

ALL_LABELS="$(sed -nE 's/^[[:space:]]*"([^|"]+)\|.*/\1/p' "$ROOT/scripts/seed-labels.sh")"
TEMPLATE_HEAD="$(git -C "$ROOT" rev-parse HEAD)"

# A repo as "Use this template" creates it: the template's placeholder CLAUDE.md
# and CI, no labels, no ruleset. State the fake gh serves lives in $dir/.fake.
fresh_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/.claude" "$dir/.github/workflows" "$dir/.fake/bin" "$dir/templates"
  git -C "$dir" init -q -b main
  cp "$ROOT"/scripts/{setup,check-verify-section,seed-labels,protect-main,gh-auth-check}.sh "$dir/scripts/"
  cp "$ROOT/templates/CLAUDE.md" "$dir/templates/"
  cp "$ROOT/templates/CLAUDE.md" "$dir/"
  cp "$ROOT/.github/workflows/ci.yml" "$dir/.github/workflows/"
  cp "$ROOT/.claude/settings.local.json.example" "$dir/.claude/"
  : >"$dir/.fake/labels"
  echo '[]' >"$dir/.fake/rulesets"
  cat >"$dir/.fake/bin/gh" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  "auth status") exit \${FAKE_BARE_AUTH_RC:-\${FAKE_AUTH_RC:-0}} ;;
  "auth status --hostname ghe.example.com") exit \${FAKE_AUTH_RC:-0} ;;
  "repo view"*) echo o/r ;;
  "label list"*) cat "$dir/.fake/labels" ;;
  "label create"*) echo "\$3" >>"$dir/.fake/labels" ;;
  "api repos/o/r/rulesets?includes_parents=false"*) cat "$dir/.fake/rulesets" ;;
  *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$dir/.fake/bin/gh" "$dir/scripts/"*.sh
  echo "$dir"
}

# A repo with everything done: named, Verify filled in and run by CI, labels,
# ruleset, local allowlist, and a current template stamp.
configured_repo() {
  local dir; dir="$(fresh_repo "$1")"
  printf '# acme — Project Instructions\n\n## Verify\n\n```sh\nmake lint\nmake test\n```\n' >"$dir/CLAUDE.md"
  printf 'jobs:\n  verify:\n    steps:\n      - run: make lint\n      - run: make test\n' >"$dir/.github/workflows/ci.yml"
  printf '%s\n' "$ALL_LABELS" >"$dir/.fake/labels"
  echo '[{"id": 1, "name": "protect-main", "enforcement": "active"}]' >"$dir/.fake/rulesets"
  cp "$dir/.claude/settings.local.json.example" "$dir/.claude/settings.local.json"
  echo "$TEMPLATE_HEAD" >"$dir/.claude/template-version"
  echo "$dir"
}

run() { # run <dir> [args...]
  local dir="$1"; shift
  (cd "$dir" && PATH="$dir/.fake/bin:$PATH" TEMPLATE_REPO="$ROOT" scripts/setup.sh "$@") >"$dir/.fake/out" 2>&1
}

F="$(fresh_repo fresh)"
run "$F"; rc=$?
check "a fresh repo fails" "[ $rc -eq 1 ]"
check "flags the empty Verify section" "grep -q 'Verify has no commands' '$F/.fake/out'"
check "flags the placeholder CI step" "grep -q 'placeholder step' '$F/.fake/out'"
check "flags missing labels" "grep -q 'missing labels' '$F/.fake/out'"
check "flags the missing ruleset with the command to fix it" "grep -q 'scripts/protect-main.sh o/r' '$F/.fake/out'"
check "does not create labels without --fix" "[ ! -s '$F/.fake/labels' ]"
check "does not copy the allowlist without --fix" "[ ! -e '$F/.claude/settings.local.json' ]"

C="$(configured_repo configured)"
run "$C"; rc=$?
check "a configured repo passes" "[ $rc -eq 0 ]"
check "reports no problems" "! grep -q '✗' '$C/.fake/out'"
check "reports the template as current" "grep -q 'up to date with the template' '$C/.fake/out'"

D="$(configured_repo drift)"
printf 'jobs:\n  verify:\n    steps:\n      - run: make test\n' >"$D/.github/workflows/ci.yml"
run "$D"; rc=$?
check "Verify/CI drift is a warning, not a failure" "[ $rc -eq 0 ]"
check "names the Verify command CI does not run" "grep -q 'not found in any workflow: make lint' '$D/.fake/out'"

X="$(fresh_repo fix)"
run "$X" --fix; rc=$?
check "--fix creates every missing label" "[ \"\$(sort '$X/.fake/labels')\" = \"\$(printf '%s\n' \"\$ALL_LABELS\" | sort)\" ]"
check "--fix copies the allowlist example" "cmp -s '$X/.claude/settings.local.json.example' '$X/.claude/settings.local.json'"
check "--fix still fails on what it cannot fix" "[ $rc -eq 1 ] && grep -q 'Verify has no commands' '$X/.fake/out'"

A="$(configured_repo noauth)"
FAKE_AUTH_RC=1 run "$A"; rc=$?
check "a logged-out gh fails with the login command" "[ $rc -eq 1 ] && grep -q 'gh auth login' '$A/.fake/out'"

# Only the host origin points at counts (#15): bare `gh auth status` fails when any
# stored host has a stale token.
G="$(configured_repo stalehost)"
git -C "$G" remote add origin https://ghe.example.com/o/r.git
FAKE_BARE_AUTH_RC=1 run "$G"; rc=$?
check "a stale token for another host does not fail the GitHub checks" "[ $rc -eq 0 ] && grep -q 'gh authenticated' '$G/.fake/out' && grep -q 'every loop label exists' '$G/.fake/out'"
H="$(configured_repo hostloggedout)"
git -C "$H" remote add origin https://ghe.example.com/o/r.git
FAKE_AUTH_RC=1 FAKE_BARE_AUTH_RC=0 run "$H"; rc=$?
check "the repo's own host logged out still fails, naming that host" "[ $rc -eq 1 ] && grep -q 'gh auth login --hostname ghe.example.com' '$H/.fake/out'"

S="$(configured_repo stale)"
echo 0000000000000000000000000000000000000000 >"$S/.claude/template-version"
run "$S"; rc=$?
check "a stale template stamp is a warning" "[ $rc -eq 0 ] && grep -q 'the template is now at' '$S/.fake/out'"

R="$(configured_repo disabled)"
echo '[{"id": 1, "name": "protect-main", "enforcement": "disabled"}]' >"$R/.fake/rulesets"
run "$R"; rc=$?
check "a ruleset that is not enforced fails" "[ $rc -eq 1 ] && grep -q 'protect-main exists but is disabled' '$R/.fake/out'"

# A repo made with "Use this template" starts with the template's own CLAUDE.md.
O="$(fresh_repo owncopy)"
cp "$ROOT/CLAUDE.md" "$O/CLAUDE.md"
run "$O"; rc=$?
check "flags the template's own CLAUDE.md" "[ $rc -eq 1 ] && grep -q \"template's own\" '$O/.fake/out'"
check "does not replace it without --fix" "cmp -s '$ROOT/CLAUDE.md' '$O/CLAUDE.md'"
printf '\n## Notes I added by hand\n' >>"$O/CLAUDE.md"
cp "$O/CLAUDE.md" "$O/.fake/edited"
run "$O" --fix
check "--fix swaps in the project skeleton" "cmp -s '$ROOT/templates/CLAUDE.md' '$O/CLAUDE.md'"
check "--fix keeps the replaced file, edits included" "cmp -s '$O/.fake/edited' '$O/CLAUDE.md.template-own'"

# A second swap must not overwrite the first backup.
cp "$ROOT/CLAUDE.md" "$O/CLAUDE.md"
run "$O" --fix; rc=$?
check "--fix refuses when a backup already exists" "[ $rc -eq 1 ] && cmp -s '$ROOT/CLAUDE.md' '$O/CLAUDE.md' && cmp -s '$O/.fake/edited' '$O/CLAUDE.md.template-own'"

# A machine's own allowlist predates rules the example gained later (#30 review):
# name each missing rule, or an unattended run stops at the command it needs.
M="$(configured_repo stale-allow)"
jq '.permissions.allow -= ["Bash(gh issue list *)"]' "$M/.claude/settings.local.json" >"$M/s.tmp" && mv "$M/s.tmp" "$M/.claude/settings.local.json"
run "$M"; rc=$?
check "warns about allow rules the example has and the local file lacks" "[ $rc -eq 0 ] && grep -q 'missing 1 allow rule' '$M/.fake/out' && grep -qF 'Bash(gh issue list *)' '$M/.fake/out'"
check "a local file with every example rule gets no such warning" "! grep -q 'missing .* allow rule' '$C/.fake/out'"

run "$C" --bogus; rc=$?
check "rejects an unknown argument" "[ $rc -eq 2 ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
