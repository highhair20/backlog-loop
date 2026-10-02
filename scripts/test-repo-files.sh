#!/usr/bin/env bash
# Checks the template's repo-level files: every workflow action is pinned to a
# commit SHA, Dependabot keeps those pins current, the issue forms parse and
# require the sections docs/ISSUE_GUIDE.md defines, and the editor and PR
# defaults exist. YAML is parsed with Ruby's standard library, present on macOS
# and on GitHub's Ubuntu runners.
# Usage: scripts/test-repo-files.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

command -v ruby >/dev/null || { echo "FAIL ruby is needed to parse YAML" >&2; exit 1; }
yaml() { ruby -ryaml -e "$1" "${@:2}"; }

# --- workflows: third-party actions pinned to a full SHA, version in a comment ---
# A tag can be moved to point at other code; a commit SHA cannot.
unpinned="$(grep -hE '^[[:space:]-]*uses:' "$ROOT"/.github/workflows/*.y*ml \
  | grep -vE 'uses:[[:space:]]*\./' \
  | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true)"
check "every workflow action is pinned to a SHA with a version comment" "[ -z \"\$unpinned\" ]"
[ -z "$unpinned" ] || printf '     unpinned: %s\n' "$unpinned" >&2

# --- CI hardening guide: its snippets follow the same pinning rule ---
# Repos copy these snippets into real workflows, so an unpinned one would teach
# the habit this check forbids above.
guide="$ROOT/docs/CI_HARDENING.md"
guide_uses="$(grep -hE '^[[:space:]-]*uses:' "$guide" 2>/dev/null || true)"
check "CI hardening guide has at least one action snippet to check" "[ -n \"\$guide_uses\" ]"
guide_unpinned="$(printf '%s\n' "$guide_uses" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true)"
check "every action in the CI hardening guide is pinned to a SHA with a version comment" "[ -z \"\$guide_unpinned\" ]"
[ -z "$guide_unpinned" ] || printf '     unpinned: %s\n' "$guide_unpinned" >&2
# One "## N. " section per pattern the guide promises: tooling, own binaries,
# coverage gate, uncached coverage, single source of truth, no committed caches.
check "CI hardening guide has a section per pattern" "[ \"\$(grep -c '^## [1-9]\\. ' '$guide' 2>/dev/null)\" = 6 ]"
check "placeholder CI step points to the hardening guide" "grep -q 'docs/CI_HARDENING.md' '$ROOT/.github/workflows/ci.yml'"
# Each pattern section states its principle, then the failure it prevents, then a
# copy-ready snippet. A heading alone must not pass.
for n in 1 2 3 4 5 6; do
  sec="$(awk -v h="## $n. " '/^## /{ on = (index($0, h) == 1) } on' "$guide" 2>/dev/null)"
  p="$(printf '%s\n' "$sec" | grep -n -m1 '^\*\*Principle:\*\*' | cut -d: -f1)"
  v="$(printf '%s\n' "$sec" | grep -n -m1 '^\*\*Prevents:\*\*' | cut -d: -f1)"
  y="$(printf '%s\n' "$sec" | grep -n -m1 '^```yaml' | cut -d: -f1)"
  check "pattern $n: principle, then what it prevents, then a YAML snippet" "[ -n '$p' ] && [ -n '$v' ] && [ -n '$y' ] && [ '$p' -lt '$v' ] && [ '$v' -lt '$y' ]"
done

# Run the guide's coverage gate itself: it is the snippet whose logic can pass
# silently. A value that is not a number (jq prints "null" for a missing field)
# must fail it, as must a value below the floor.
gate="$(awk '/^## 3\. /{ s = 1 } s && /^## 4\. /{ exit } s && /^```yaml/{ y = 1; next } y && /^```/{ exit } y && r { sub(/^    /, ""); print } y && /run: \|/{ r = 1 }' "$guide" 2>/dev/null)"
check "extracted the coverage gate's script from the guide" "printf '%s' \"\$gate\" | grep -q 'COVERAGE_FLOOR'"
gate_rc() { # gate_rc <coverage value>: exit status of the guide's gate with that total
  local d; d="$(mktemp -d)"
  printf '%s\n' "$1" >"$d/coverage-total.txt"
  (cd "$d" && COVERAGE_TARGET=80 COVERAGE_FLOOR=76 bash -eo pipefail -c "$gate") >/dev/null 2>&1
  local rc=$?; rm -rf "$d"; return "$rc"
}
check "the gate passes coverage above the target" "gate_rc 85"
check "the gate passes coverage between floor and target (warning only)" "gate_rc 78"
check "the gate fails coverage below the floor" "! gate_rc 70"
check "the gate fails a non-numeric total (jq's null)" "! gate_rc null"
check "the gate fails an empty total" "! gate_rc ''"
check "the Jest snippet makes jq fail on a missing field" "grep -q 'jq -e ' '$guide'"

# Run section 6's snippets too: the .gitignore lines must ignore each cache the
# guide names, and the CI step must fail when one is tracked anyway.
caches="$(awk '/^## /{ on = (index($0, "## 6. ") == 1) } on' "$guide" 2>/dev/null)"
ignore="$(printf '%s\n' "$caches" | awk '/^```gitignore/{ y = 1; next } y && /^```/{ exit } y')"
cache_step="$(printf '%s\n' "$caches" | awk '/^```yaml/{ y = 1; next } y && /^```/{ exit } y && r { sub(/^    /, ""); print } y && /run: \|/{ r = 1 }')"
check "extracted the .gitignore lines from section 6" "[ -n \"\$ignore\" ]"
check "extracted the tracked-cache step from section 6" "printf '%s' \"\$cache_step\" | grep -q 'git ls-files'"
CACHE_PATHS=("tsconfig.tsbuildinfo" "packages/web/tsconfig.tsbuildinfo" "__pycache__/app.cpython-312.pyc" "src/pkg/__pycache__/mod.cpython-312.pyc" ".pytest_cache/v/cache/lastfailed" "tests/.pytest_cache/v/cache/nodeids")
# Each helper prints a status rather than returning one, and a setup failure
# prints "setup", so no check can pass because its repo was never built.
ignore_status() { # ignore_status <path>: git check-ignore's status (0 ignored, 1 not) under the guide's lines
  local d rc; d="$(mktemp -d)"
  if git -C "$d" init -q && printf '%s\n' "$ignore" >"$d/.gitignore"; then
    git -C "$d" check-ignore -q --no-index -- "$1"; rc=$?
  else rc=setup; fi
  rm -rf "$d"; echo "$rc"
}
cache_status() { # cache_status <path>...: "<status> <output>" of the guide's step in a repo tracking those paths
  local d p out="" rc; d="$(mktemp -d)"
  if (cd "$d" && git init -q && for p in "$@"; do { mkdir -p "$(dirname "$p")" && echo x >"$p"; } || exit 1; done && git add -f -- "$@"); then
    out="$(cd "$d" && bash -eo pipefail -c "$cache_step" 2>&1)"; rc=$?
  else rc=setup; fi
  rm -rf "$d"; printf '%s %s\n' "$rc" "$out"
}
for p in "${CACHE_PATHS[@]}"; do
  check "the guide's .gitignore lines ignore $p" "[ \"\$(ignore_status '$p')\" = 0 ]"
  # It must fail and name the file, so a step broken some other way does not pass.
  check "the guide's step fails when $p is tracked, naming it" "cache_status src/app.ts '$p' | grep -q '^1 ' && cache_status src/app.ts '$p' | grep -qxF '$p'"
done
check "the guide's .gitignore lines leave source files alone" "[ \"\$(ignore_status src/app.ts)\" = 1 ]"
check "the guide's step passes a repo that tracks no cache" "cache_status src/app.ts tests/test_app.py | grep -q '^0 '"

# The README's file list is how a reader finds the guide (#14 acceptance criterion).
check "README's file list includes the hardening guide" "grep -qE '^docs/CI_HARDENING\\.md[[:space:]]' '$ROOT/README.md'"

# --- deploy guide: pinned snippets, and a parity script that really compares ---
deploy="$ROOT/docs/DEPLOYING.md"
deploy_uses="$(grep -hE '^[[:space:]-]*uses:' "$deploy" 2>/dev/null || true)"
check "deploy guide has at least one action snippet to check" "[ -n \"\$deploy_uses\" ]"
deploy_unpinned="$(printf '%s\n' "$deploy_uses" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true)"
check "every action in the deploy guide is pinned to a SHA with a version comment" "[ -z \"\$deploy_unpinned\" ]"
[ -z "$deploy_unpinned" ] || printf '     unpinned: %s\n' "$deploy_unpinned" >&2
check "deploy guide: dev deploys on push to main" "grep -qE '^    branches: \\[main\\]' '$deploy'"
check "deploy guide: prod deploys on a v* tag" "grep -qF \"tags: ['v*']\" '$deploy'"
check "deploy guide says the loop is denied tag pushes" "grep -qF 'git push * v*' '$deploy'"
check "deploy guide gives the dev-first example" "grep -q '2026-09-30' '$deploy'"
check "deploy guide names no cloud vendor in its snippets" "! awk '/^\`\`\`/{ c = !c; next } c' '$deploy' | grep -qiE 'aws|gcp|gcloud|azure'"

# Run the guide's parity script against sample workflows: the check is only worth
# copying if a missing unit or a missing list really fails it.
parity="$(awk '/^```bash/{ y = 1; next } y && /^```/{ exit } y' "$deploy" 2>/dev/null)"
check "extracted the parity script from the deploy guide" "printf '%s' \"\$parity\" | grep -q 'units()'"
parity_rc() { # parity_rc <dev unit line> <prod unit line>: exit status of the script
  local d; d="$(mktemp -d)"
  printf 'jobs:\n  deploy:\n    strategy:\n      matrix:\n%s\n' "$1" >"$d/dev.yml"
  printf 'jobs:\n  deploy:\n    strategy:\n      matrix:\n%s\n' "$2" >"$d/prod.yml"
  bash -c "$parity" parity "$d/dev.yml" "$d/prod.yml" >/dev/null 2>&1
  local rc=$?; rm -rf "$d"; return "$rc"
}
check "parity passes the same units" "parity_rc '        unit: [api, worker]' '        unit: [api, worker]'"
check "parity ignores order, quotes, and a trailing comment" "parity_rc '        unit: [api, worker]' \"        unit: ['worker', \\\"api\\\"]  # prod\""
# Joined into one string, these two lists would be equal ("abc").
check "parity compares unit names, not their concatenation" "! parity_rc '        unit: [ab, c]' '        unit: [a, bc]'"
check "parity fails a unit missing from prod" "! parity_rc '        unit: [api, worker]' '        unit: [api]'"
check "parity fails a unit missing from dev" "! parity_rc '        unit: [api]' '        unit: [api, worker]'"
check "parity fails when neither workflow has a unit list" "! parity_rc '        os: [linux]' '        os: [linux]'"
check "parity fails an empty unit list" "! parity_rc '        unit: []' '        unit: []'"
# shellcheck disable=SC2034  # read inside check's eval string
missing_out="$(bash -c "$parity" parity /nonexistent/dev.yml /nonexistent/prod.yml 2>&1)"
missing_rc=$?
check "parity fails a missing workflow file, naming it" "[ '$missing_rc' -ne 0 ] && printf '%s' \"\$missing_out\" | grep -q 'no such workflow: /nonexistent/dev.yml'"
check "parity reads a list whose comment holds brackets" "parity_rc '        unit: [api]  # see [docs]' '        unit: [api]'"
# The guide's own two workflow snippets must pass its own script.
snippets_rc() {
  local d; d="$(mktemp -d)"
  awk '/^```yaml/{ n++; y = 1; next } y && /^```/{ y = 0 } y && n == 1' "$deploy" >"$d/dev.yml"
  awk '/^```yaml/{ n++; y = 1; next } y && /^```/{ y = 0 } y && n == 2' "$deploy" >"$d/prod.yml"
  bash -c "$parity" parity "$d/dev.yml" "$d/prod.yml" >/dev/null 2>&1
  local rc=$?; rm -rf "$d"; return "$rc"
}
check "the guide's dev and prod snippets pass its parity script" "snippets_rc"
# The guide cites these deny rules; it must stop being true only by failing here.
for rule in 'Bash(git push * v*)' 'Bash(git push *+v*)' 'Bash(git push *--ta*)' 'Bash(git push *--fol*)' 'Bash(git push *refs/tags/*)'; do
  check "settings.json denies $rule, as the deploy guide says" "jq -e --arg r '$rule' '.permissions.deny | index(\$r)' '$ROOT/.claude/settings.json' >/dev/null"
done

check "README's file list includes the deploy guide" "grep -qE '^docs/DEPLOYING\\.md[[:space:]]' '$ROOT/README.md'"
check "README links the deploy guide" "grep -qF '(docs/DEPLOYING.md)' '$ROOT/README.md'"
check "BACKLOG.md links the deploy guide" "grep -qF '(./DEPLOYING.md)' '$ROOT/docs/BACKLOG.md'"

# --- task-runner conventions (#35): the three conventions, each with an example ---
# shellcheck disable=SC2034  # read inside check's eval strings
runners="$(awk '/^## /{ on = ($0 == "## Task runners") } on' "$ROOT/docs/BACKLOG.md" 2>/dev/null)"
check "BACKLOG.md has a Task runners section" "[ -n \"\$runners\" ]"
# One convention's text: from its bold lead-in to the next one.
convention() { printf '%s\n' "$runners" | awk -v h="**$1.**" 'index($0, h) == 1 { on = 1; next } /^\*\*/ { on = 0 } on'; }
for convention in 'One entry point' 'Guard recipes' 'Confirm destructive recipes'; do
  check "Task runners describes '$convention'" "printf '%s\n' \"\$runners\" | grep -qF '**$convention.**'"
  check "'$convention' has a just example" "convention '$convention' | grep -q '^\`\`\`just'"
  check "'$convention' has a one-line equivalent in another runner" "convention '$convention' | grep -qE '^(In|With) (make|npm)'"
done
check "the guard is a private recipe that another recipe depends on" "convention 'Guard recipes' | grep -qE '^_[a-z-]+:' && convention 'Guard recipes' | grep -qE '^[a-z-]+: _[a-z-]+'"
check "the guard fails with a message naming what is missing" "convention 'Guard recipes' | grep -qE 'echo .*not set.*>&2; exit 1'"
check "the destructive example refuses without a terminal" "convention 'Confirm destructive recipes' | grep -qF '[ -t 0 ] ||'"
check "the destructive example compares the typed answer to the target" "convention 'Confirm destructive recipes' | grep -qF '[ \"\$answer\" = \"\$env\" ] || {'"
# shellcheck disable=SC2034  # read inside check's eval strings
tracked="$(git -C "$ROOT" ls-files)" || tracked=""
check "git lists the template's files" "[ -n \"\$tracked\" ]"
check "the template ships no task-runner file" "! printf '%s\n' \"\$tracked\" | grep -qiE '(^|/)(\\.?justfile|gnumakefile|makefile)$'"
check "README's file list mentions the task-runner conventions" "grep -qE '^docs/BACKLOG\\.md[[:space:]].*task runner' '$ROOT/README.md'"

# --- dependabot: updates the pinned actions ---
check "dependabot.yml parses and updates github-actions" \
  "yaml 'd = YAML.load_file(ARGV[0]); exit(d[\"version\"] == 2 && d[\"updates\"].any? { |u| u[\"package-ecosystem\"] == \"github-actions\" } ? 0 : 1)' '$ROOT/.github/dependabot.yml'"

# --- issue forms ---
# Section names from the Anatomy table in the guide: rows like | **Context** | ... |
anatomy="$(awk '/^## /{ on = ($0 ~ /^## Anatomy/); next } on' "$ROOT/docs/ISSUE_GUIDE.md" \
  | sed -nE 's/^\|[[:space:]]*\*\*([^*]+)\*\*.*/\1/p')"
check "extracted the section names from ISSUE_GUIDE.md" "[ \"\$(printf '%s\n' \"\$anatomy\" | grep -c .)\" -ge 6 ]"

# Prints one line per field: "<label>|<required true/false>|<has a prefilled value>".
form_fields() {
  yaml 'f = YAML.load_file(ARGV[0])
        abort "missing name/description/body" unless f["name"] && f["description"] && f["body"].is_a?(Array)
        f["body"].reject { |b| b["type"] == "markdown" }.each do |b|
          puts [b["attributes"]["label"], !!(b["validations"] || {})["required"], !(b["attributes"]["value"].to_s.strip.empty?)].join("|")
        end' "$1"
}

REQUIRED_SECTIONS=("Context" "Goal" "Acceptance criteria" "Testing")
for form in feature bug; do
  file="$ROOT/.github/ISSUE_TEMPLATE/$form.yml"
  check "$form form exists and parses" "form_fields '$file' >/dev/null 2>&1"
  # shellcheck disable=SC2034  # read inside check's eval strings
  fields="$(form_fields "$file" 2>/dev/null)"
  while IFS= read -r section; do
    [ -n "$section" ] || continue
    check "$form form has the guide's '$section' section" "printf '%s\n' \"\$fields\" | grep -q '^$section|'"
  done <<<"$anatomy"
  for section in "${REQUIRED_SECTIONS[@]}"; do
    check "$form form requires '$section'" "printf '%s\n' \"\$fields\" | grep -q '^$section|true|'"
  done
  # A prefilled value satisfies "required", so a required field must start empty.
  check "$form form's required fields start empty" "! printf '%s\n' \"\$fields\" | grep -q '|true|true$'"
done
# shellcheck disable=SC2034  # read inside check's eval strings
bug_fields="$(form_fields "$ROOT/.github/ISSUE_TEMPLATE/bug.yml" 2>/dev/null)"
check "bug form requires steps to reproduce" "printf '%s\n' \"\$bug_fields\" | grep -q '^Steps to reproduce|true|'"
check "bug form requires expected vs actual" "printf '%s\n' \"\$bug_fields\" | grep -q '^Expected vs actual|true|'"
check "no Markdown issue templates remain beside the forms" "! ls '$ROOT'/.github/ISSUE_TEMPLATE/*.md >/dev/null 2>&1"

# --- editor and PR defaults ---
check ".editorconfig is a root config" "grep -qx 'root = true' '$ROOT/.editorconfig'"
check "PR template links the issue it closes" "grep -q '^Closes #' '$ROOT/.github/pull_request_template.md'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
