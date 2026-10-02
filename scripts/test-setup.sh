#!/usr/bin/env bash
# Tests for scripts/setup.sh, with a fake `gh` on PATH and throwaway repos, so no
# network is involved. Usage: scripts/test-setup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
command -v ruby >/dev/null || { echo "FAIL ruby is needed to parse YAML" >&2; exit 1; }

ALL_LABELS="$(sed -nE 's/^[[:space:]]*"([^|"]+)\|.*/\1/p' "$ROOT/scripts/seed-labels.sh")"
TEMPLATE_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
GUIDE_URL=https://github.com/o/r/blob/main/docs/ISSUE_GUIDE.md

# A repo as "Use this template" creates it: the template's placeholder CLAUDE.md
# and CI, no labels, no ruleset. State the fake gh serves lives in $dir/.fake.
fresh_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/.claude" "$dir/.github/workflows" "$dir/.github/ISSUE_TEMPLATE" "$dir/docs" "$dir/.fake/bin" "$dir/templates"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin https://github.com/o/r.git
  cp "$ROOT"/scripts/{setup,check-verify-section,seed-labels,protect-main,gh-auth-check,gh-repo}.sh "$dir/scripts/"
  cp "$ROOT/templates/CLAUDE.md" "$dir/templates/"
  cp "$ROOT/templates/CLAUDE.md" "$dir/"
  cp "$ROOT/.github/workflows/ci.yml" "$dir/.github/workflows/"
  cp "$ROOT/.github/ISSUE_TEMPLATE/config.yml" "$dir/.github/ISSUE_TEMPLATE/"
  cp "$ROOT/docs/ISSUE_GUIDE.md" "$dir/docs/"
  cp "$ROOT/.claude/settings.local.json.example" "$dir/.claude/"
  : >"$dir/.fake/labels"
  echo '[]' >"$dir/.fake/rulesets"
  cat >"$dir/.fake/bin/gh" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  "auth status") exit \${FAKE_BARE_AUTH_RC:-\${FAKE_AUTH_RC:-0}} ;;
  "auth status --hostname github.com"|"auth status --hostname ghe.example.com") exit \${FAKE_AUTH_RC:-0} ;;
  "repo view "*"/o/r --json url,defaultBranchRef"*) echo "\${FAKE_REPO_URL-https://github.com/o/r} \${FAKE_BRANCH-main}" ;;
  "repo set-default --view") echo "\${FAKE_DEFAULT:-}" ;;
  "repo view --json url --jq .url") echo "https://\${FAKE_HOST:-github.com}/o/r" ;;
  "label list"*) echo "\$*" >>"$dir/.fake/label-calls"; cat "$dir/.fake/labels" ;;
  "label create"*) echo "\$3" >>"$dir/.fake/labels"; echo "\$*" >>"$dir/.fake/label-calls" ;;
  "api repos/o/r/rulesets?includes_parents=false"*) echo "\$*" >>"$dir/.fake/api-calls"; cat "$dir/.fake/rulesets" ;;
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
  printf 'blank_issues_enabled: true\ncontact_links:\n  - name: Issue guide\n    url: %s\n    about: How to write an issue here\n' "$GUIDE_URL" >"$dir/.github/ISSUE_TEMPLATE/config.yml"
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

# The drift check matches whole commands that a workflow runs, not substrings.
# ci_case <warns|passes> <description> <Verify command> <workflow line>...
M="$(configured_repo match)"
ci_case() {
  local expect="$1" desc="$2" cmd="$3"; shift 3
  printf '# acme\n\n## Verify\n\n```sh\n%s\n```\n' "$cmd" >"$M/CLAUDE.md"
  printf 'jobs:\n  verify:\n    steps:\n' >"$M/.github/workflows/ci.yml"
  printf '%s\n' "$@" >>"$M/.github/workflows/ci.yml"
  run "$M"; rc=$?
  if [ "$expect" = warns ]; then
    check "drift: $desc" "[ $rc -eq 0 ] && grep -qF 'not found in any workflow: $cmd' '$M/.fake/out'"
  else
    check "no drift: $desc" "[ $rc -eq 0 ] && grep -q 'CI runs every Verify command' '$M/.fake/out'"
  fi
}
ci_case warns  "a longer command is not a match" "make test" "      - run: make test-e2e"
ci_case warns  "a plural is not a match" "make test" "      - run: make tests"
ci_case warns  "a YAML comment is not a match" "make test" "      # make test" "      - run: echo hi"
ci_case warns  "a run-block comment is not a match" "make test" "      - run: |" "          # make test" "          echo hi"
ci_case warns  "a step name is not a match" "make test" "      - name: make test" "        run: echo hi"
ci_case warns  "a shell comment is not a match" "make test" "      - run: echo hi # make test"
ci_case warns  "a separator inside a comment is not a match" "make test" "      - run: echo hi # a && make test"
ci_case warns  "regex metacharacters match literally" "scripts/run.sh" "      - run: scripts/runXsh"
ci_case passes "run: value" "make test" "      - run: make test"
ci_case passes "run: under a named step" "make test" "      - name: Test" "        run: make test"
ci_case passes "a line in a run: | block" "make test" "      - run: |" "          make lint" "          make test"
ci_case passes "followed by &&" "make test" "      - run: make test && echo done"
ci_case passes "followed by a comment" "make test" "      - run: make test # the suite"
ci_case passes "after a shell separator" "make test" "      - run: npm ci && make test"
ci_case passes "with regex metacharacters" "shellcheck --severity=warning scripts/*.sh" "      - run: shellcheck --severity=warning scripts/*.sh"
ci_case passes "with Windows line endings" "make test" "$(printf '      - run: make test\r')"
# A command run only by a second workflow still counts.
printf 'jobs:\n  e2e:\n    steps:\n      - run: make test\n' >"$M/.github/workflows/other.yml"
ci_case passes "run by another workflow" "make test" "      - run: echo hi"
rm "$M/.github/workflows/other.yml"

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
git -C "$G" remote set-url origin https://ghe.example.com/o/r.git
FAKE_BARE_AUTH_RC=1 run "$G"; rc=$?
check "a stale token for another host does not fail the GitHub checks" "[ $rc -eq 0 ] && grep -q 'gh authenticated' '$G/.fake/out' && grep -q 'every loop label exists' '$G/.fake/out'"
H="$(configured_repo hostloggedout)"
git -C "$H" remote set-url origin https://ghe.example.com/o/r.git
FAKE_AUTH_RC=1 FAKE_BARE_AUTH_RC=0 run "$H"; rc=$?
check "the repo's own host logged out still fails, naming that host" "[ $rc -eq 1 ] && grep -q 'gh auth login --hostname ghe.example.com' '$H/.fake/out'"

# The repo is named before any check that reads or writes it (#17).
check "names the repo before the label and ruleset checks" "awk '/repository o\\/r/{ r = NR } /^Labels/{ l = NR } /^Branch protection/{ b = NR } END { exit !(r && l && b && r < l && r < b) }' '$C/.fake/out'"

# A fork with an upstream remote and no gh default (#17): gh would pick upstream,
# so setup must stop before touching either repo, and say how to choose.
U="$(fresh_repo ambiguous)"
git -C "$U" remote add upstream https://github.com/up/r.git
run "$U" --fix; rc=$?
check "several remotes and no gh default fails with the fix" "[ $rc -eq 1 ] && grep -q 'gh repo set-default <owner/repo>' '$U/.fake/out'"
check "it names no repo it did not choose" "! grep -q 'repository o/r' '$U/.fake/out'"
check "--fix creates no labels when the repo is ambiguous" "[ ! -s '$U/.fake/labels' ]"
check "it skips the label and ruleset checks" "! grep -q '^Labels' '$U/.fake/out' && ! grep -q '^Branch protection' '$U/.fake/out'"
V="$(configured_repo chosen)"
git -C "$V" remote add upstream https://github.com/up/r.git
FAKE_DEFAULT=o/r run "$V"; rc=$?
check "several remotes with a gh default checks that repo" "[ $rc -eq 0 ] && grep -q 'repository o/r' '$V/.fake/out' && grep -q 'every loop label exists' '$V/.fake/out'"
# --fix writes the missing labels to the repo it printed, and only there.
W="$(fresh_repo chosenfix)"
git -C "$W" remote add upstream https://github.com/up/r.git
FAKE_DEFAULT=o/r run "$W" --fix
check "--fix with a gh default creates the labels" "grep -q '^label create' '$W/.fake/label-calls' && grep -q 'repository o/r (github.com)' '$W/.fake/out'"
check "--fix creates every label on the printed repo" "! grep -v -- '--repo github.com/o/r' '$W/.fake/label-calls'"

# A bare owner/repo means github.com to gh, so on GitHub Enterprise the host must
# travel with it (PR #48 review): labels and rulesets are read and written there.
E="$(fresh_repo ghefix)"
git -C "$E" remote set-url origin https://ghe.example.com/o/r.git
FAKE_HOST=ghe.example.com run "$E" --fix
check "GHE: names the repo with its host" "grep -q 'repository o/r (ghe.example.com)' '$E/.fake/out'"
check "GHE: every label call targets the GHE repo" "grep -q '^label create' '$E/.fake/label-calls' && ! grep -v -- '--repo ghe.example.com/o/r' '$E/.fake/label-calls'"
check "GHE: the ruleset is read from the GHE host" "grep -q -- '--hostname ghe.example.com' '$E/.fake/api-calls'"

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

# The issue chooser links to docs/ISSUE_GUIDE.md (#37). contact_links needs an
# absolute URL, so the template cannot ship it; --fix adds it for the resolved repo.
CFG=.github/ISSUE_TEMPLATE/config.yml
yaml_urls() { ruby -ryaml -e 'puts((YAML.safe_load(File.read(ARGV[0]))["contact_links"] || []).map { |l| l["url"] })' "$1"; }
chooser_repo() { # chooser_repo <name> <config.yml content>
  local dir; dir="$(configured_repo "$1")"
  printf '%s' "$2" >"$dir/$CFG"
  echo "$dir"
}
check "a fresh repo warns that the issue chooser has no guide link" "grep -q 'issue chooser has no link to docs/ISSUE_GUIDE.md' '$F/.fake/out'"
check "does not add the link without --fix" "cmp -s '$ROOT/$CFG' '$F/$CFG'"
check "a configured repo's link counts" "grep -q 'issue chooser links to docs/ISSUE_GUIDE.md' '$C/.fake/out' && ! grep -q 'issue chooser has no link' '$C/.fake/out'"
check "--fix adds the guide link for the resolved repo" "[ \"\$(yaml_urls '$X/$CFG')\" = '$GUIDE_URL' ]"
check "--fix keeps the rest of config.yml, comments included" "grep -q '^blank_issues_enabled: true' '$X/$CFG' && grep -q '^# Keep blank issues' '$X/$CFG'"
cp "$X/$CFG" "$X/.fake/cfg"
run "$X" --fix
check "a second --fix adds no duplicate" "cmp -s '$X/.fake/cfg' '$X/$CFG' && grep -q 'issue chooser links to' '$X/.fake/out'"

K="$(chooser_repo keep "$(printf 'blank_issues_enabled: false\ncontact_links:\n  - name: Forum\n    url: https://example.com/forum\n    about: Questions\n')")"
run "$K"; rc=$?
check "a missing link is a warning, not a failure" "[ $rc -eq 0 ] && grep -q 'issue chooser has no link' '$K/.fake/out'"
run "$K" --fix
check "--fix keeps an existing contact link and adds ours" "[ \"\$(yaml_urls '$K/$CFG')\" = \"\$(printf '%s\n' '$GUIDE_URL' https://example.com/forum)\" ] && grep -q '^blank_issues_enabled: false' '$K/$CFG'"
K0="$(chooser_repo keep0 "$(printf 'contact_links:\n- name: Forum\n  url: https://example.com/forum\n  about: Questions\n')")"
run "$K0" --fix
check "--fix matches a list written at column 0" "[ \"\$(yaml_urls '$K0/$CFG')\" = \"\$(printf '%s\n' '$GUIDE_URL' https://example.com/forum)\" ]"
KN="$(chooser_repo empty "$(printf 'contact_links:\nblank_issues_enabled: true\n')")"
run "$KN" --fix
check "--fix fills an empty contact_links" "[ \"\$(yaml_urls '$KN/$CFG')\" = '$GUIDE_URL' ]"
KF="$(chooser_repo flow "$(printf 'contact_links: []\n')")"
cp "$KF/$CFG" "$KF/.fake/cfg"
run "$KF" --fix; rc=$?
check "--fix leaves a one-line contact_links alone and says how to add the link" "[ $rc -eq 0 ] && cmp -s '$KF/.fake/cfg' '$KF/$CFG' && grep -qF '$GUIDE_URL' '$KF/.fake/out'"
KB="$(chooser_repo branch "$(printf 'contact_links:\n  - name: Guide\n    url: https://github.com/O/R/blob/master/docs/ISSUE_GUIDE.md\n    about: x\n')")"
cp "$KB/$CFG" "$KB/.fake/cfg"
run "$KB" --fix
check "a link on another branch, in other case, counts" "cmp -s '$KB/.fake/cfg' '$KB/$CFG' && grep -q 'issue chooser links to' '$KB/.fake/out'"
# A link written another way still counts, so --fix adds no second one.
link_form() { # link_form <description> <config.yml content>
  local dir; dir="$(chooser_repo form "$2")"
  cp "$dir/$CFG" "$dir/.fake/cfg"
  run "$dir" --fix
  check "counts as linked: $1" "cmp -s '$dir/.fake/cfg' '$dir/$CFG' && grep -q 'issue chooser links to' '$dir/.fake/out'"
  rm -rf "$dir"
}
link_form "a quoted url" "$(printf 'contact_links:\n  - name: G\n    url: "%s"\n    about: x\n' "$GUIDE_URL")"
link_form "a url with an #anchor" "$(printf 'contact_links:\n  - name: G\n    url: %s#labels\n    about: x\n' "$GUIDE_URL")"
link_form "a flow-style entry" "$(printf 'contact_links:\n  - {name: G, url: %s, about: x}\n' "$GUIDE_URL")"
KL="$(chooser_repo longer "$(printf 'contact_links:\n  - name: G\n    url: %s.bak\n    about: x\n' "$GUIDE_URL")")"
run "$KL"
check "a longer path is not the guide" "grep -q 'issue chooser has no link' '$KL/.fake/out'"
KQ="$(chooser_repo quoted "$(printf '"contact_links":\n  - name: Forum\n    url: https://example.com/forum\n    about: x\n')")"
cp "$KQ/$CFG" "$KQ/.fake/cfg"
run "$KQ" --fix; rc=$?
check "--fix leaves a quoted contact_links key alone" "[ $rc -eq 0 ] && cmp -s '$KQ/.fake/cfg' '$KQ/$CFG' && grep -q 'quoted key' '$KQ/.fake/out'"
KI="$(chooser_repo between "$(printf 'contact_links: # links\n\n    # the forum\n    - name: Forum\n      url: https://example.com/forum\n      about: x\n')")"
run "$KI" --fix
check "--fix indents past comments and blank lines" "[ \"\$(yaml_urls '$KI/$CFG')\" = \"\$(printf '%s\n' '$GUIDE_URL' https://example.com/forum)\" ]"
KU="$(configured_repo nourl)"
cp "$ROOT/$CFG" "$KU/$CFG"
FAKE_REPO_URL='' run "$KU" --fix; rc=$?
check "an unreadable repo URL is a warning, and nothing changes" "[ $rc -eq 0 ] && cmp -s '$ROOT/$CFG' '$KU/$CFG' && grep -q 'could not read the URL of o/r' '$KU/.fake/out'"
KC="$(chooser_repo comment "$(printf 'blank_issues_enabled: true\n# url: %s\n' "$GUIDE_URL")")"
run "$KC"
check "a commented-out link does not count" "grep -q 'issue chooser has no link' '$KC/.fake/out'"
KY="$(configured_repo yaml)"
cp "$ROOT/$CFG" "$KY/${CFG%.yml}.yaml" && rm "$KY/$CFG"
run "$KY" --fix
check "--fix edits config.yaml when that is the file" "[ ! -e '$KY/$CFG' ] && [ \"\$(yaml_urls '$KY/${CFG%.yml}.yaml')\" = '$GUIDE_URL' ]"
KE="$(configured_repo ghe)"
cp "$ROOT/$CFG" "$KE/$CFG"
FAKE_REPO_URL=https://ghe.example.com/o/r run "$KE" --fix
check "--fix uses the repo's own host" "[ \"\$(yaml_urls '$KE/$CFG')\" = https://ghe.example.com/o/r/blob/main/docs/ISSUE_GUIDE.md ]"
KD="$(configured_repo trunk)"
cp "$ROOT/$CFG" "$KD/$CFG"
FAKE_BRANCH=trunk run "$KD" --fix
check "--fix links the default branch, so the link does not 404" "[ \"\$(yaml_urls '$KD/$CFG')\" = https://github.com/o/r/blob/trunk/docs/ISSUE_GUIDE.md ]"
KZ="$(configured_repo nocommits)"
cp "$ROOT/$CFG" "$KZ/$CFG"
FAKE_BRANCH='' run "$KZ" --fix
check "--fix falls back to main when there is no default branch yet" "[ \"\$(yaml_urls '$KZ/$CFG')\" = '$GUIDE_URL' ]"
KM="$(configured_repo noconfig)"
rm "$KM/$CFG"
run "$KM" --fix; rc=$?
check "no config.yml: skipped, and none created" "[ $rc -eq 0 ] && [ ! -e '$KM/$CFG' ] && ! grep -q 'issue chooser has no link' '$KM/.fake/out'"
KG="$(configured_repo noguide)"
cp "$ROOT/$CFG" "$KG/$CFG" && rm "$KG/docs/ISSUE_GUIDE.md"
run "$KG" --fix
check "no docs/ISSUE_GUIDE.md: skipped, so no link to a missing page" "cmp -s '$ROOT/$CFG' '$KG/$CFG' && ! grep -q 'issue chooser has no link' '$KG/.fake/out'"
# The template's config.yml is seeded into every repo, so it must not carry its own URL.
KT="$(configured_repo template)"
cp "$ROOT/$CFG" "$KT/$CFG"
git -C "$KT" remote set-url origin https://ghe.example.com/x/claude-code-repo-template.git
run "$KT" --fix
check "the template repo itself gets no link" "cmp -s '$ROOT/$CFG' '$KT/$CFG' && ! grep -q 'issue chooser has no link' '$KT/.fake/out'"

run "$C" --bogus; rc=$?
check "rejects an unknown argument" "[ $rc -eq 2 ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
