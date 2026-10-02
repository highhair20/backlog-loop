#!/usr/bin/env bash
# Check that this repo is set up for the backlog loop, and say how to fix what is
# not. Read-only unless --fix, which applies only the safe, repeatable fixes: it
# creates missing labels, copies the local allowlist example, adds a link to
# docs/ISSUE_GUIDE.md to the issue chooser, and replaces the
# template repo's own CLAUDE.md with the project skeleton, moving the old file to
# CLAUDE.md.template-own rather than discarding it. The ruleset is
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
SKELETON=templates/CLAUDE.md
OWN_BACKUP=CLAUDE.md.template-own
# Same test as check-verify-section.sh. The template repo's own CLAUDE.md starts
# with this marker. In any other repo it is the wrong file: its Verify would make
# the template's tests this repo's definition of green. The repo is recognised by
# its origin's name, as CI does.
TEMPLATE_MARKER='claude-code-repo-template: own instructions'
TEMPLATE_ORIGIN_RE='[/:]claude-code-repo-template(\.git)?/?$'

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

# Whether a workflow runs this exact command (a heuristic, not a YAML parse). It must
# start a run: value, a line of a run: | block, or follow a shell separator, and end
# at end of line, whitespace, or a separator. Comments never count. Compares
# strings rather than building a regex, since commands hold regex metacharacters.
workflows_run() { # workflows_run <command> <workflow>...
  local cmd="$1"; shift
  VERIFY_CMD="$cmd" awk '
    BEGIN { cmd = ENVIRON["VERIFY_CMD"]; n = length(cmd) }
    /^[[:space:]]*#/ { next }
    {
      for (p = 1; p + n - 1 <= length($0); p++) {
        if (substr($0, p, n) != cmd) continue
        after = substr($0, p + n, 1)
        if (after != "" && after !~ /[[:space:];&|]/) continue
        before = substr($0, 1, p - 1)
        if (before ~ /(^|[[:space:]])#/) continue # inside a trailing comment
        sub(/[[:space:]]+$/, "", before)
        if (before ~ /^[[:space:]]*(-[[:space:]]+)?(run:)?$/ || before ~ /[;&|]$/) { found = 1; exit }
      }
    }
    END { exit !found }
  ' "$@"
}

is_template_own_claude_md() {
  grep -qF "$TEMPLATE_MARKER" CLAUDE.md || return 1
  ! git remote get-url origin 2>/dev/null | grep -qE "$TEMPLATE_ORIGIN_RE"
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
  if is_template_own_claude_md; then
    if [ ! -f "$SKELETON" ]; then
      bad "CLAUDE.md is the template's own instructions, not this project's" "copy templates/CLAUDE.md from claude-code-repo-template over it"
      return
    fi
    if [ "$fix" -ne 1 ]; then
      bad "CLAUDE.md is the template's own instructions, not this project's" "scripts/setup.sh --fix  (copies $SKELETON over it)"
      return
    fi
    # The marker is an invisible HTML comment, so a file someone has already edited
    # may still carry it: keep the old file rather than discard their work.
    if [ -e "$OWN_BACKUP" ]; then
      bad "CLAUDE.md is the template's own instructions, and $OWN_BACKUP already exists" \
        "move $OWN_BACKUP aside, then re-run scripts/setup.sh --fix"
      return
    fi
    mv CLAUDE.md "$OWN_BACKUP"
    cp "$SKELETON" CLAUDE.md
    ok "replaced CLAUDE.md with the project skeleton from $SKELETON; the old file is $OWN_BACKUP (delete it once you have kept anything you added)"
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
    workflows_run "$cmd" "${workflows[@]}" && continue
    warn "Verify command not found in any workflow: $cmd" "run the same command in CI, so CI and the loop agree on what green means"
    missing=$((missing + 1))
  done < <(verify_commands)
  [ "$count" -eq 0 ] || [ "$missing" -gt 0 ] || ok "CI runs every Verify command"
}

# Sync updates the example but never this machine's own allowlist, so a rule the
# loop gained later (a new helper, a new git command) is missing here, and an
# unattended run stops at the command it needs. Name each missing rule.
check_local_allow_rules() {
  [ -f "$LOCAL_SETTINGS.example" ] || return 0
  local missing count
  if ! missing="$(jq -r --slurpfile mine "$LOCAL_SETTINGS" \
      '(.permissions.allow // []) - ($mine[0].permissions.allow // []) | .[]' \
      "$LOCAL_SETTINGS.example" 2>/dev/null)"; then
    warn "could not compare $LOCAL_SETTINGS with its example (invalid JSON?)"
    return 0
  fi
  [ -n "$missing" ] || { ok "$LOCAL_SETTINGS has every rule the example allows"; return 0; }
  count="$(printf '%s\n' "$missing" | grep -c .)"
  warn "$LOCAL_SETTINGS is missing $count allow rule(s) the example has: $(printf '%s\n' "$missing" | paste -sd ' ' -)" \
    "add them to its allow list; an unattended run stops at the first command it is not allowed"
}

check_local_settings() {
  echo "Unattended runs"
  if [ -f "$LOCAL_SETTINGS" ]; then
    ok "$LOCAL_SETTINGS exists"
    check_local_allow_rules
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
  # GIT_TERMINAL_PROMPT=0: a private or mistyped URL must fail, not wait for a password.
  latest="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$TEMPLATE_REPO" HEAD 2>/dev/null | awk '$2 == "HEAD" { print $1; exit }')"
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
  # Only the login for origin's host counts; a stale token for another host must
  # not fail these checks (#15).
  local host
  if ! host="$(scripts/gh-auth-check.sh)"; then
    bad "gh is not authenticated${host:+ to $host}" "gh auth login${host:+ --hostname $host}"
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
  local enforcement
  # A disabled or evaluate-only ruleset blocks nothing, so read its enforcement too.
  if ! enforcement="$(gh api "repos/$repo/rulesets?includes_parents=false" --paginate 2>/dev/null \
      | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .enforcement' | head -1)"; then
    warn "could not read the rulesets on $repo (needs admin; private repos need a paid plan)"
    return
  fi
  if [ "$enforcement" = active ]; then
    ok "ruleset $RULESET_NAME is active"
  elif [ -n "$enforcement" ]; then
    bad "ruleset $RULESET_NAME exists but is $enforcement, so it blocks nothing" \
      "set it to Active in Settings → Rules → Rulesets, or re-run scripts/protect-main.sh"
  else
    bad "no $RULESET_NAME ruleset, so nothing on GitHub's side stops a push to main" \
      "scripts/protect-main.sh $repo <ci-job-name>...  (job names as they appear on a PR)"
  fi
}

# Whether config file $1 links to the issue guide of the repo at URL $2, on any
# branch. Case-insensitive, like GitHub's owner and repo names. Comments never count.
guide_linked() { # guide_linked <config> <repo-url>
  GUIDE_PREFIX="$2/blob/" awk '
    BEGIN { prefix = tolower(ENVIRON["GUIDE_PREFIX"]); suffix = "/docs/issue_guide.md" }
    /^[[:space:]]*#/ { next }
    {
      line = tolower($0)
      sub(/[[:space:]]#.*/, "", line)
      i = index(line, prefix)
      if (!i) next
      rest = substr(line, i + length(prefix))
      j = index(rest, suffix)
      if (j < 2 || substr(rest, 1, j - 1) ~ /[[:space:]]/) next
      # Ends the path: end of line, a quote, "}", "#anchor", "?query", and so on.
      after = substr(rest, j + length(suffix), 1)
      if (after !~ /[a-z0-9._~%\/-]/) { found = 1; exit }
    }
    END { exit !found }
  ' "$1"
}

# Prints config file $1 with an issue guide entry for URL $2 added as the first
# contact link, keeping every other line, comments included (a YAML round trip
# would drop them). Exits 3 when contact_links is written on one line ([...]) or
# as a quoted key, which this text edit cannot extend safely.
add_guide_link() { # add_guide_link <config> <guide-url>
  GUIDE_URL="$2" awk '
    function entry(indent) {
      print indent "- name: Issue guide"
      print indent "  url: " ENVIRON["GUIDE_URL"]
      print indent "  about: How issues here are written and labelled. Read it before opening one."
    }
    { lines[NR] = $0 }
    /^["\047]contact_links["\047][[:space:]]*:/ { quoted = 1 }
    END {
      if (quoted) exit 3
      for (k = 1; k <= NR; k++) if (lines[k] ~ /^contact_links:/) break
      if (k > NR) {
        for (i = 1; i <= NR; i++) print lines[i]
        print "contact_links:"
        entry("  ")
        exit 0
      }
      if (lines[k] !~ /^contact_links:[[:space:]]*(#.*)?$/) exit 3
      # Indent like the first existing item, so the list stays one list.
      indent = "  "
      for (i = k + 1; i <= NR; i++) {
        if (lines[i] ~ /^[[:space:]]*(#|$)/) continue
        if (match(lines[i], /^[[:space:]]*- /)) indent = substr(lines[i], 1, RLENGTH - 2)
        break
      }
      for (i = 1; i <= k; i++) print lines[i]
      entry(indent)
      for (i = k + 1; i <= NR; i++) print lines[i]
    }
  ' "$1"
}

# A link to docs/ISSUE_GUIDE.md in GitHub's "New issue" chooser (#37). Its URL is
# absolute, so the template cannot ship it; --fix adds it for the resolved repo.
check_issue_chooser() {
  echo "Issue chooser"
  local cfg="" f url guide tmp rc
  for f in .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/config.yaml; do
    [ -f "$f" ] && { cfg="$f"; break; }
  done
  if [ -z "$cfg" ]; then
    info "no .github/ISSUE_TEMPLATE/config.yml; skipped"
    return
  fi
  if [ ! -f docs/ISSUE_GUIDE.md ]; then
    info "no docs/ISSUE_GUIDE.md to link to; skipped"
    return
  fi
  # The template seeds its config.yml into every repo, so its own URL must stay out.
  if git remote get-url origin 2>/dev/null | grep -qE "$TEMPLATE_ORIGIN_RE"; then
    info "this is the template repo, whose $cfg is seeded into other repos; skipped"
    return
  fi
  local view branch
  view="$(gh repo view "$repo" --json url,defaultBranchRef --jq '.url + " " + (.defaultBranchRef.name // "")' 2>/dev/null)" || view=""
  url="${view%% *}"
  branch="${view#* }"
  if [ -z "$url" ] || [ "$url" = "$view" ]; then
    warn "could not read the URL of $repo, so the issue chooser link was not checked"
    return
  fi
  # A repo with no commits has no default branch yet; main is what it will get.
  [ -n "$branch" ] || branch=main
  if guide_linked "$cfg" "$url"; then
    ok "the issue chooser links to docs/ISSUE_GUIDE.md"
    return
  fi
  guide="$url/blob/$branch/docs/ISSUE_GUIDE.md"
  if [ "$fix" -ne 1 ]; then
    warn "the issue chooser has no link to docs/ISSUE_GUIDE.md" "scripts/setup.sh --fix  (adds it to contact_links in $cfg)"
    return
  fi
  tmp="$(mktemp "$cfg.XXXXXX")" || { warn "could not create a temporary file beside $cfg"; return; }
  add_guide_link "$cfg" "$guide" >"$tmp"; rc=$?
  # Copied back rather than moved, so the file keeps its mode, not mktemp's 0600.
  if [ "$rc" -eq 0 ] && guide_linked "$tmp" "$url" && cat "$tmp" >"$cfg"; then
    rm -f "$tmp"
    ok "added a link to docs/ISSUE_GUIDE.md to the issue chooser ($cfg)"
    return
  fi
  rm -f "$tmp"
  if [ "$rc" -eq 3 ]; then
    warn "the issue chooser has no link to docs/ISSUE_GUIDE.md, and $cfg writes contact_links on one line or as a quoted key, which --fix does not edit" \
      "add an entry to contact_links by hand, with url: $guide"
  else
    warn "could not add the issue guide link to $cfg" "add an entry to contact_links by hand, with url: $guide"
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
    echo; check_issue_chooser
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
