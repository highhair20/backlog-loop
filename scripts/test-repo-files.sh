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
# coverage gate, uncached coverage, single source of truth.
check "CI hardening guide has a section per pattern" "[ \"\$(grep -c '^## [1-5]\\. ' '$guide' 2>/dev/null)\" = 5 ]"
check "placeholder CI step points to the hardening guide" "grep -q 'docs/CI_HARDENING.md' '$ROOT/.github/workflows/ci.yml'"
# The README's file list is how a reader finds the guide (#14 acceptance criterion).
check "README's file list includes the hardening guide" "grep -qE '^docs/CI_HARDENING\\.md[[:space:]]' '$ROOT/README.md'"

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
