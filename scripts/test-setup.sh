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
  cp "$ROOT"/scripts/{setup,check-verify-section,seed-labels,protect-main,gh-auth-check,gh-repo,missing-allow-rules}.sh "$dir/scripts/"
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

# A sync from a tagged template records the tag on line 2 (#65).
TG="$(configured_repo tagged)"
printf '%s\nv0.1.0\n' "$TEMPLATE_HEAD" >"$TG/.claude/template-version"
run "$TG"; rc=$?
check "a current stamp names its tag" "[ $rc -eq 0 ] && grep -qF 'up to date with the template (v0.1.0)' '$TG/.fake/out'"
printf '0000000000000000000000000000000000000000\nv0.1.0\n' >"$TG/.claude/template-version"
run "$TG"; rc=$?
check "a stale stamp names the tag it was synced from" "[ $rc -eq 0 ] && grep -qF 'synced from template v0.1.0 (0000000)' '$TG/.fake/out'"

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

# "Use this template" also copies the template's release notes (#65).
L="$(configured_repo changelog)"
cp "$ROOT/CHANGELOG.md" "$L/CHANGELOG.md"
run "$L"; rc=$?
check "flags the template's CHANGELOG.md as a warning" "[ $rc -eq 0 ] && grep -q \"CHANGELOG.md is the template's\" '$L/.fake/out'"
check "does not remove it without --fix" "cmp -s '$ROOT/CHANGELOG.md' '$L/CHANGELOG.md'"
run "$L" --fix; rc=$?
check "--fix removes the template's CHANGELOG.md" "[ $rc -eq 0 ] && [ ! -e '$L/CHANGELOG.md' ] && grep -q 'removed CHANGELOG.md' '$L/.fake/out'"
LO="$(configured_repo own-changelog)"
printf '# Changelog\n\n## [1.0.0]\n- our release\n' >"$LO/CHANGELOG.md"
cp "$LO/CHANGELOG.md" "$LO/.fake/changelog"
run "$LO" --fix
check "--fix keeps a repo's own CHANGELOG.md, and says nothing about it" "cmp -s '$LO/.fake/changelog' '$LO/CHANGELOG.md' && ! grep -q 'CHANGELOG' '$LO/.fake/out'"
LT="$(configured_repo template-changelog)"
cp "$ROOT/CHANGELOG.md" "$LT/CHANGELOG.md"
git -C "$LT" remote set-url origin https://github.com/highhair20/backlog-loop.git
run "$LT" --fix
check "--fix keeps the template repo's own CHANGELOG.md" "cmp -s '$ROOT/CHANGELOG.md' '$LT/CHANGELOG.md' && ! grep -q 'CHANGELOG' '$LT/.fake/out'"

# A machine's own allowlist predates rules the example gained later (#30 review):
# name each missing rule, or an unattended run stops at the command it needs.
M="$(configured_repo stale-allow)"
jq '.permissions.allow -= ["Bash(gh issue list *)"]' "$M/.claude/settings.local.json" >"$M/s.tmp" && mv "$M/s.tmp" "$M/.claude/settings.local.json"
run "$M"; rc=$?
check "warns about allow rules the example has and the local file lacks" "[ $rc -eq 0 ] && grep -q 'missing 1 allow rule' '$M/.fake/out' && grep -qF 'Bash(gh issue list *)' '$M/.fake/out'"
check "a local file with every example rule gets no such warning" "! grep -q 'missing .* allow rule' '$C/.fake/out'"
check "a local file with every example rule says so" "grep -q 'has every rule the example allows' '$C/.fake/out'"
MJ="$(configured_repo invalid-allow)"
echo '{"permissions": ' >"$MJ/.claude/settings.local.json"
run "$MJ"; rc=$?
check "invalid local JSON is a warning, not a failure" "[ $rc -eq 0 ] && grep -q 'could not compare .claude/settings.local.json' '$MJ/.fake/out'"

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

# A repo made with "Use this template" also gets the template's plugin manifests
# (#64). They are the template's, like its CLAUDE.md, so --fix removes them; a
# repo's own plugin, or one holding files the template never shipped, stays.
PL="$(configured_repo pluginleft)"
cp -R "$ROOT/.claude-plugin" "$PL/"
run "$PL"; rc=$?
check "the template's .claude-plugin/ is a warning, not a failure" "[ $rc -eq 0 ] && grep -q \"template's plugin manifests\" '$PL/.fake/out'"
check "does not remove it without --fix" "[ -f '$PL/.claude-plugin/plugin.json' ]"
run "$PL" --fix; rc=$?
check "--fix removes the template's .claude-plugin/" "[ $rc -eq 0 ] && [ ! -e '$PL/.claude-plugin' ] && grep -q 'removed .claude-plugin/' '$PL/.fake/out'"
run "$PL"
check "with it gone, nothing is said about it" "! grep -q 'claude-plugin' '$PL/.fake/out'"

PO="$(configured_repo ownplugin)"
mkdir -p "$PO/.claude-plugin" && echo '{ "name": "my-tool" }' >"$PO/.claude-plugin/plugin.json"
run "$PO" --fix; rc=$?
check "--fix keeps a repo's own plugin, and says nothing" "[ $rc -eq 0 ] && [ -f '$PO/.claude-plugin/plugin.json' ] && ! grep -q 'claude-plugin' '$PO/.fake/out'"

PX="$(configured_repo pluginextra)"
cp -R "$ROOT/.claude-plugin" "$PX/"
echo '# mine' >"$PX/.claude-plugin/commands/mine.md"
run "$PX" --fix; rc=$?
check "--fix keeps a .claude-plugin/ holding files the template never shipped, naming them" "[ $rc -eq 0 ] && [ -f '$PX/.claude-plugin/plugin.json' ] && [ -f '$PX/.claude-plugin/commands/mine.md' ] && grep -q '.claude-plugin/commands/mine.md' '$PX/.fake/out'"

PT="$(configured_repo pluginhome)"
cp -R "$ROOT/.claude-plugin" "$PT/"
git -C "$PT" remote set-url origin https://github.com/highhair20/backlog-loop.git
run "$PT" --fix
check "--fix keeps the template repo's own .claude-plugin/" "[ -f '$PT/.claude-plugin/plugin.json' ] && ! grep -q 'removed .claude-plugin/' '$PT/.fake/out'"

# A sync run from the installed plugin stamps the 12-character commit its cache
# directory is named after (#64).
SS="$(configured_repo shortstamp)"
echo "${TEMPLATE_HEAD:0:12}" >"$SS/.claude/template-version"
run "$SS"; rc=$?
check "a short stamp that prefixes the template's HEAD is up to date" "[ $rc -eq 0 ] && grep -q 'up to date with the template' '$SS/.fake/out'"
SU="$(configured_repo unknownstamp)"
echo unknown >"$SU/.claude/template-version"
run "$SU"; rc=$?
# Re-running the update would stamp unknown again, so the warning says why instead.
check "an unknown stamp is a warning that says so, not up to date" "[ $rc -eq 0 ] && grep -q 'synced from is unknown (unknown)' '$SU/.fake/out' && ! grep -q 'up to date with the template' '$SU/.fake/out'"
SM="$(configured_repo shortstale)"
echo 000000000000 >"$SM/.claude/template-version"
run "$SM"; rc=$?
check "a short stamp that is not a prefix of HEAD is behind" "[ $rc -eq 0 ] && grep -q 'the template is now at' '$SM/.fake/out' && ! grep -q 'up to date with the template' '$SM/.fake/out'"
check "the update hint names the plugin command" "grep -q '/backlog-loop:update' '$SM/.fake/out'"
SP="$(configured_repo shortprefix)"
echo "${TEMPLATE_HEAD:0:7}" >"$SP/.claude/template-version"
run "$SP"
check "a prefix shorter than 12 characters does not count as current" "! grep -q 'up to date with the template' '$SP/.fake/out'"

# Setup proposes Verify commands from the stack files at the repo root (#71), and
# --fix writes them only for exactly one stack into the skeleton's placeholders.
stack_repo() { # stack_repo <name>: a fresh repo with no stack files yet
  local dir; dir="$(fresh_repo "stack-$1")"
  mkdir -p "$dir/.claude/agent-context/optional"
  echo "$dir"
}
# The lines of CLAUDE.md's Verify code block, comments included.
verify_block() { awk '/^## /{ v = ($0 ~ /^## Verify/) } v && /^```/{ if (c++) exit; next } v && c' "$1/CLAUDE.md"; }
# commands_are <dir> <command>...: the block's commands are exactly these, in order.
commands_are() {
  local dir="$1"; shift
  [ "$(verify_block "$dir" | grep -Ev '^[[:space:]]*(#|$)')" = "$(printf '%s\n' "$@")" ]
}
unchanged() { cmp -s "$ROOT/templates/CLAUDE.md" "$1/CLAUDE.md"; }

SK="$(stack_repo make)"
printf '.PHONY: lint test\nlint:\n\tshellcheck *.sh\ntest: lint\n\t./run.sh\n' >"$SK/Makefile"
echo 'module example.com/x' >"$SK/go.mod"
run "$SK"; rc=$?
check "make: proposes make lint and make test without --fix" "[ $rc -eq 1 ] && grep -q '^        make lint$' '$SK/.fake/out' && grep -q '^        make test$' '$SK/.fake/out'"
check "make: wins over go.mod, so go is not proposed" "! grep -q 'go vet' '$SK/.fake/out'"
check "make: no --fix, no write" "unchanged '$SK'"
cp "$SK/.github/workflows/ci.yml" "$SK/.fake/ci"
run "$SK" --fix
check "make: --fix writes the commands into Verify and says so" "commands_are '$SK' 'make lint' 'make test' && grep -q 'wrote 2 Verify command' '$SK/.fake/out'"
check "make: the written file passes check-verify-section.sh" "'$ROOT/scripts/check-verify-section.sh' '$SK/CLAUDE.md'"
check "make: --fix replaces the skeleton placeholders" "! verify_block '$SK' | grep -Eq '^# (build|lint|test):'"
check "make: the rest of CLAUDE.md is unchanged" "[ \"\$(grep -Ev '^make (lint|test)\$' '$SK/CLAUDE.md')\" = \"\$(grep -Ev '^# (build|lint|test):\$' '$ROOT/templates/CLAUDE.md')\" ]"
check "make: workflows are never edited" "cmp -s '$SK/.fake/ci' '$SK/.github/workflows/ci.yml'"
check "make: still names go-reviewer for go.mod" "grep -q 'go-reviewer' '$SK/.fake/out'"
cp "$SK/CLAUDE.md" "$SK/.fake/claude"
run "$SK" --fix
check "make: a second --fix leaves the written Verify alone" "cmp -s '$SK/.fake/claude' '$SK/CLAUDE.md' && grep -q 'Verify has commands' '$SK/.fake/out'"

SM="$(stack_repo makeonlytest)"
printf 'test:\n\t./run.sh\n' >"$SM/Makefile"
run "$SM" --fix
check "make: only a test target proposes only make test" "commands_are '$SM' 'make test'"
SN="$(stack_repo makenotest)"
printf 'TEST := 1\ntest-e2e:\n\t./e2e.sh\nlint:\n\tshellcheck *.sh\n' >"$SN/Makefile"
echo 'module example.com/x' >"$SN/go.mod"
run "$SN" --fix
check "make: a Makefile without a test target is not the stack" "commands_are '$SN' 'go vet ./...' 'go test ./...'"
SNP="$(stack_repo makephony)"
printf '.PHONY: test\nall:\n\tcc x.c\n' >"$SNP/Makefile"
echo 'module example.com/x' >"$SNP/go.mod"
run "$SNP" --fix
check "make: .PHONY: test alone is not a test target" "commands_are '$SNP' 'go vet ./...' 'go test ./...'"
SMN="$(stack_repo makenode)"
printf 'lint test:\n\t./check.sh\n' >"$SMN/Makefile"
printf '%s\n' '{"scripts": {"test": "jest"}, "devDependencies": {"typescript": "^5"}}' >"$SMN/package.json"
run "$SMN" --fix
check "make: a multi-target line wins over package.json" "commands_are '$SMN' 'make lint' 'make test' && grep -q 'typescript-reviewer' '$SMN/.fake/out'"

SG="$(stack_repo go)"
echo 'module example.com/x' >"$SG/go.mod"
run "$SG" --fix
check "go: --fix writes go vet and go test" "commands_are '$SG' 'go vet ./...' 'go test ./...'"
check "go: CI hint names the run lines and actions/setup-go" "grep -q 'fix: .*ci.yml' '$SG/.fake/out' && grep -q 'actions/setup-go' '$SG/.fake/out' && grep -qF -- '- run: go vet ./...' '$SG/.fake/out' && grep -qF -- '- run: go test ./...' '$SG/.fake/out'"
check "go: names go-reviewer with the cp and vendor-agents.sh commands" "grep -qF 'cp .claude/agent-context/optional/go-reviewer.md .claude/agent-context/' '$SG/.fake/out' && grep -q 'scripts/vendor-agents.sh' '$SG/.fake/out'"
SGE="$(stack_repo goenabled)"
echo 'module example.com/x' >"$SGE/go.mod"
echo ctx >"$SGE/.claude/agent-context/go-reviewer.md"
run "$SGE"
check "go: an enabled reviewer is reported as on, with no cp command" "grep -q 'go-reviewer is on' '$SGE/.fake/out' && ! grep -qF 'optional/go-reviewer.md' '$SGE/.fake/out'"

SR="$(stack_repo cargo)"
printf '[package]\nname = "x"\n' >"$SR/Cargo.toml"
run "$SR" --fix
check "cargo: --fix writes fmt, clippy, and test" "commands_are '$SR' 'cargo fmt --check' 'cargo clippy --all-targets -- -D warnings' 'cargo test'"
check "cargo: CI hint names a Rust toolchain action with rustfmt and clippy" "grep -q 'dtolnay/rust-toolchain' '$SR/.fake/out' && grep -q 'rustfmt, clippy' '$SR/.fake/out'"
check "cargo: no reviewer is named" "! grep -q 'reviewer' '$SR/.fake/out'"

# node_case <name> <lockfile or -> <package.json> <expected command>...; sets ND.
node_case() {
  local name="$1" lock="$2" pkg="$3"; shift 3
  ND="$(stack_repo "$name")"
  [ "$lock" = - ] || : >"$ND/$lock"
  printf '%s\n' "$pkg" >"$ND/package.json"
  run "$ND" --fix
  check "node ($name): --fix writes $*" "commands_are '$ND' $(printf "'%s' " "$@")"
}
NP='{"scripts": {"test": "vitest", "lint": "eslint .", "build": "tsc", "start": "node ."}}'
node_case npm - "$NP" 'npm run lint' 'npm run build' 'npm run test'
check "node (npm): CI hint names actions/setup-node and npm ci" "grep -q 'actions/setup-node' '$ND/.fake/out' && grep -q 'run: npm ci' '$ND/.fake/out'"
check "node (npm): no typescript, no typescript-reviewer" "! grep -q 'typescript-reviewer' '$ND/.fake/out'"
node_case pnpm pnpm-lock.yaml "$NP" 'pnpm run lint' 'pnpm run build' 'pnpm run test'
check "node (pnpm): CI hint names pnpm/action-setup" "grep -q 'pnpm/action-setup' '$ND/.fake/out'"
check "node (pnpm): the hint says pnpm/action-setup needs a version" "grep -q 'pnpm/action-setup.*packageManager' '$ND/.fake/out'"
node_case yarn yarn.lock "$NP" 'yarn run lint' 'yarn run build' 'yarn run test'
node_case bun bun.lockb "$NP" 'bun run lint' 'bun run build' 'bun run test'
check "node (bun): CI hint names oven-sh/setup-bun" "grep -q 'oven-sh/setup-bun' '$ND/.fake/out'"
node_case buntext bun.lock "$NP" 'bun run lint' 'bun run build' 'bun run test'
node_case ts - '{"scripts": {"typecheck": "tsc --noEmit", "test": "jest"}, "devDependencies": {"typescript": "^5"}}' 'npm run typecheck' 'npm run test'
check "node (ts): names typescript-reviewer" "grep -qF 'cp .claude/agent-context/optional/typescript-reviewer.md .claude/agent-context/' '$ND/.fake/out'"
node_case all4 - '{"scripts": {"test": "jest", "build": "tsc", "typecheck": "tsc --noEmit", "lint": "eslint ."}, "dependencies": {"typescript": "^5"}}' 'npm run lint' 'npm run typecheck' 'npm run build' 'npm run test'
check "node (all4): typescript in dependencies names typescript-reviewer" "grep -q 'typescript-reviewer' '$ND/.fake/out'"
node_case npminit - '{"scripts": {"lint": "eslint .", "test": "echo \"Error: no test specified\" && exit 1"}}' 'npm run lint'
SNS="$(stack_repo noscripts)"
echo '{"name": "x"}' >"$SNS/package.json"
run "$SNS" --fix; rc=$?
check "node: a package.json with none of the scripts writes nothing and says so" "[ $rc -eq 1 ] && unchanged '$SNS' && grep -q 'package.json.*none of' '$SNS/.fake/out'"
SNB="$(stack_repo badjson)"
echo '{ not json' >"$SNB/package.json"
run "$SNB" --fix; rc=$?
check "node: an unreadable package.json writes nothing and says so" "[ $rc -eq 1 ] && unchanged '$SNB' && grep -q 'could not read package.json' '$SNB/.fake/out'"

SPY="$(stack_repo python)"
printf '[project]\nname = "x"\n\n[tool.ruff]\nline-length = 100\n\n[tool.pytest.ini_options]\naddopts = "-q"\n' >"$SPY/pyproject.toml"
run "$SPY" --fix
check "python: --fix writes only the configured tools" "commands_are '$SPY' 'ruff check .' 'pytest'"
check "python: CI hint names actions/setup-python" "grep -q 'actions/setup-python' '$SPY/.fake/out'"
check "python: names python-reviewer" "grep -qF 'optional/python-reviewer.md' '$SPY/.fake/out'"
SPM="$(stack_repo mypy)"
printf '[tool.mypy]\nstrict = true\n' >"$SPM/pyproject.toml"
run "$SPM" --fix
check "python: [tool.mypy] proposes mypy ." "commands_are '$SPM' 'mypy .'"
SP0="$(stack_repo pynotools)"
printf '[project]\nname = "x"\n# [tool.ruff] is not configured\n' >"$SP0/pyproject.toml"
run "$SP0" --fix; rc=$?
check "python: no configured tools writes nothing, and says so" "[ $rc -eq 1 ] && unchanged '$SP0' && grep -q 'pyproject.toml.*none of' '$SP0/.fake/out' && ! grep -q 'ruff check' '$SP0/.fake/out'"
check "python: still names python-reviewer" "grep -q 'python-reviewer' '$SP0/.fake/out'"

SGN="$(stack_repo gonode)"
echo 'module example.com/x' >"$SGN/go.mod"
printf '%s\n' "$NP" >"$SGN/package.json"
run "$SGN" --fix; rc=$?
check "several stacks: nothing is written" "[ $rc -eq 1 ] && unchanged '$SGN'"
check "several stacks: both proposals are printed" "grep -q 'go vet ./...' '$SGN/.fake/out' && grep -q 'npm run test' '$SGN/.fake/out' && grep -q 'several stacks' '$SGN/.fake/out'"
check "several stacks: each proposal has its CI hint" "grep -q 'actions/setup-go' '$SGN/.fake/out' && grep -q 'actions/setup-node' '$SGN/.fake/out' && grep -qF -- '- run: go vet ./...' '$SGN/.fake/out' && grep -qF -- '- run: npm run test' '$SGN/.fake/out'"
SGP="$(stack_repo goemptypy)"
echo 'module example.com/x' >"$SGP/go.mod"
printf '[project]\nname = "x"\n' >"$SGP/pyproject.toml"
run "$SGP" --fix
check "a stack with nothing to propose still counts, so nothing is written" "unchanged '$SGP'"

check "no stack: nothing proposed or written" "! grep -q 'proposed Verify' '$F/.fake/out' && unchanged '$F'"
S0="$(stack_repo none)"
run "$S0" --fix; rc=$?
check "no stack: --fix writes nothing and says no stack file was found" "[ $rc -eq 1 ] && unchanged '$S0' && grep -q 'no stack file' '$S0/.fake/out'"

SE="$(configured_repo stackfilled)"
echo 'module example.com/x' >"$SE/go.mod"
cp "$SE/CLAUDE.md" "$SE/.fake/claude"
run "$SE" --fix; rc=$?
check "an existing Verify block is untouched" "[ $rc -eq 0 ] && cmp -s '$SE/.fake/claude' '$SE/CLAUDE.md' && ! grep -q 'proposed Verify' '$SE/.fake/out'"

SC="$(stack_repo comments)"
echo 'module example.com/x' >"$SC/go.mod"
awk '{ print } /^# test:$/ { print "# when api/ changes, also run the e2e suite" }' "$ROOT/templates/CLAUDE.md" >"$SC/CLAUDE.md"
run "$SC" --fix
check "--fix keeps the user's own comments in the block" "verify_block '$SC' | grep -q '^# when api/ changes' && commands_are '$SC' 'go vet ./...' 'go test ./...'"
# A comment above a command scopes it to paths, so the kept one must not end up above ours.
check "--fix writes the commands above a kept comment, so it scopes none of them" "[ \"\$(verify_block '$SC' | head -2)\" = \"\$(printf '%s\n' 'go vet ./...' 'go test ./...')\" ]"
SV="$(stack_repo noblock)"
echo 'module example.com/x' >"$SV/go.mod"
printf '# acme\n\n## Verify\n\nTo do.\n' >"$SV/CLAUDE.md"
cp "$SV/CLAUDE.md" "$SV/.fake/claude"
run "$SV" --fix; rc=$?
check "a Verify with no code block is not written, but the proposal is printed" "[ $rc -eq 1 ] && cmp -s '$SV/.fake/claude' '$SV/CLAUDE.md' && grep -q 'go vet ./...' '$SV/.fake/out'"

# The template's own CLAUDE.md is swapped for the skeleton first, then filled in.
SO="$(stack_repo ownthenfill)"
echo 'module example.com/x' >"$SO/go.mod"
cp "$ROOT/CLAUDE.md" "$SO/CLAUDE.md"
run "$SO" --fix
check "--fix swaps in the skeleton, then fills its Verify" "[ -f '$SO/CLAUDE.md.template-own' ] && commands_are '$SO' 'go vet ./...' 'go test ./...'"

# A new repo has both the template's CHANGELOG.md (#65) and an unfilled Verify
# (#71): one --fix does both.
SL="$(stack_repo changelog)"
echo 'module example.com/x' >"$SL/go.mod"
cp "$ROOT/CHANGELOG.md" "$SL/CHANGELOG.md"
run "$SL" --fix
check "--fix fills Verify and removes the template's CHANGELOG.md in one run" "commands_are '$SL' 'go vet ./...' 'go test ./...' && [ ! -e '$SL/CHANGELOG.md' ] && grep -q 'wrote 2 Verify command' '$SL/.fake/out' && grep -q 'removed CHANGELOG.md' '$SL/.fake/out'"

run "$C" --bogus; rc=$?
check "rejects an unknown argument" "[ $rc -eq 2 ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
