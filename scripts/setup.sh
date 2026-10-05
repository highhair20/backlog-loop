#!/usr/bin/env bash
# Check that this repo is set up for the backlog loop, and say how to fix what is
# not. Read-only unless --fix, which applies only the safe, repeatable fixes: it
# creates missing labels, copies the local allowlist example, adds a link to
# docs/ISSUE_GUIDE.md to the issue chooser, and replaces the
# template repo's own CLAUDE.md with the project skeleton, moving the old file to
# CLAUDE.md.template-own rather than discarding it, writes the Verify commands it
# proposes into an empty Verify when exactly one stack is found, and removes the template's
# plugin manifests (.claude-plugin/) when they hold only its files. The ruleset is
# never created here, because it needs your CI job names and admin rights; the
# check prints the exact command instead.
#
# Exits 0 when nothing fails (warnings allowed), 1 otherwise, 2 on bad usage.
#
# Usage: scripts/setup.sh [--fix]
#   TEMPLATE_REPO  repo to compare .claude/template-version with
#                  (default: the public backlog-loop)
set -uo pipefail

TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/highhair20/backlog-loop.git}"
RULESET_NAME=protect-main
CI_PLACEHOLDER='Verify (not configured)'
LOCAL_SETTINGS=.claude/settings.local.json
SKELETON=templates/CLAUDE.md
OWN_BACKUP=CLAUDE.md.template-own
# Same test as check-verify-section.sh. The template repo's own CLAUDE.md starts
# with this marker. In any other repo it is the wrong file: its Verify would make
# the template's tests this repo's definition of green. The repo is recognised by
# its origin's name, as CI does.
# Renamed from claude-code-repo-template (#68): repos made before the rename carry the
# old marker, and a clone may still use the old URL, so both names count.
TEMPLATE_MARKER_RE='(backlog-loop|claude-code-repo-template): own instructions'
TEMPLATE_ORIGIN_RE='[/:](backlog-loop|claude-code-repo-template)(\.git)?/?$'
# The template's installer plugin (#64). "Use this template" copies it into every
# new repo, where it is the template's, like its CLAUDE.md. Every file it ships is
# listed, so --fix removes the directory only when it holds nothing else;
# scripts/test-plugin.sh keeps the list equal to what .claude-plugin/ ships.
PLUGIN_NAME_RE='"name"[[:space:]]*:[[:space:]]*"backlog-loop"'
PLUGIN_FILES=(
  .claude-plugin/commands/install.md
  .claude-plugin/commands/update.md
  .claude-plugin/marketplace.json
  .claude-plugin/plugin.json
)

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
repo=""      # owner/repo
repo_host="" # its host, for gh api --hostname
repo_full="" # host/owner/repo, for --repo
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
  grep -qE "$TEMPLATE_MARKER_RE" CLAUDE.md || return 1
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
      bad "CLAUDE.md is the template's own instructions, not this project's" "copy templates/CLAUDE.md from backlog-loop over it"
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
    propose_verify_section
  fi
}

# Verify proposals from the stack files at the repo root (#71). Deterministic on
# purpose: setup runs before Claude is set up, and the same repo must always get
# the same proposal. Monorepo subdirectories are not looked at.

# Whether the Makefile defines target $1, alone or in a list before the colon.
# Skips variable assignments (TEST := 1) and longer names (test-e2e:).
has_make_target() {
  grep -qE "^([^:=#[:space:]]+[[:space:]]+)*$1([[:space:]]+[^:=#[:space:]]+)*[[:space:]]*:([^=]|\$)" Makefile
}

# One line per stack found. A Makefile with a test target is the project's own
# entry point (docs/BACKLOG.md, "Task runners"), so it hides every other stack.
detect_stacks() {
  if [ -f Makefile ] && has_make_target test; then echo make; return 0; fi
  [ ! -f package.json ] || echo node
  [ ! -f go.mod ] || echo go
  [ ! -f Cargo.toml ] || echo rust
  [ ! -f pyproject.toml ] || echo python
}

stack_file() {
  case "$1" in
    make) echo Makefile ;; node) echo package.json ;; go) echo go.mod ;;
    rust) echo Cargo.toml ;; python) echo pyproject.toml ;;
  esac
}

node_pm() {
  if [ -f pnpm-lock.yaml ]; then echo pnpm
  elif [ -f yarn.lock ]; then echo yarn
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then echo bun
  else echo npm
  fi
}

# The Verify commands for stack $1, one per line; none when its file configures
# nothing this knows. Fails when the file cannot be read.
propose_verify() {
  case "$1" in
    make)
      if has_make_target lint; then echo "make lint"; fi
      echo "make test" ;;
    node)
      command -v jq >/dev/null || return 1
      # npm init's test script always fails, so it is no test at all.
      jq -r --arg pm "$(node_pm)" '(.scripts // {}) as $sc
        | if ($sc | type) != "object" then empty
          else ("lint", "typecheck", "build", "test") as $s
            | select($sc | has($s)) | select(($sc[$s] | tostring | test("no test specified")) | not)
            | "\($pm) run \($s)" end' \
        package.json 2>/dev/null ;;
    go) printf '%s\n' "go vet ./..." "go test ./..." ;;
    rust) printf '%s\n' "cargo fmt --check" "cargo clippy --all-targets -- -D warnings" "cargo test" ;;
    python)
      if grep -qE '^\[tool\.ruff[].]' pyproject.toml; then echo "ruff check ."; fi
      if grep -qE '^\[tool\.mypy[].]' pyproject.toml; then echo "mypy ."; fi
      if grep -qE '^\[tool\.pytest[].]' pyproject.toml; then echo "pytest"; fi ;;
  esac
}

# Why stack $1 proposed nothing.
nothing_proposed() {
  case "$1" in
    node) echo "package.json has none of the scripts lint, typecheck, build, test" ;;
    python) echo "pyproject.toml configures none of ruff, mypy, pytest" ;;
  esac
}

# The toolchain steps a CI job needs before stack $1's commands, as YAML list items.
ci_setup() {
  local pm
  case "$1" in
    make) echo "# plus the setup action for whatever toolchain make needs" ;;
    node)
      pm="$(node_pm)"
      case "$pm" in
        bun) echo "- uses: oven-sh/setup-bun" ;;
        pnpm) printf '%s\n' "- uses: pnpm/action-setup  # needs with: version:, unless package.json sets packageManager" "- uses: actions/setup-node" ;;
        *) echo "- uses: actions/setup-node" ;;
      esac
      case "$pm" in
        npm) echo "- run: npm ci" ;;
        yarn) echo "- run: yarn install --frozen-lockfile" ;;
        *) echo "- run: $pm install --frozen-lockfile" ;;
      esac ;;
    go) printf '%s\n' "- uses: actions/setup-go" "  with:" "    go-version-file: go.mod" ;;
    rust) printf '%s\n' "- uses: dtolnay/rust-toolchain@stable" "  with:" "    components: rustfmt, clippy" ;;
    python) printf '%s\n' "- uses: actions/setup-python" "- run: pip install -e .  # and the dev tools Verify runs" ;;
  esac
}

# The ci.yml step for stack $1 running commands $2, as a fix: hint. Workflows are
# never edited: setup steps, caching, and version matrices vary too much.
print_ci_hint() {
  echo "      fix: in .github/workflows/ci.yml, replace the placeholder step with these (pin each action to a commit SHA, as the checkout step is):"
  { ci_setup "$1"; printf '%s\n' "$2" | sed 's/^/- run: /'; } | sed 's/^/            /'
}

# Prints stack $1's proposal and its CI hint, or why there is none.
print_proposal() {
  local file cmds
  file="$(stack_file "$1")"
  if ! cmds="$(propose_verify "$1")"; then
    info "could not read $file (invalid JSON, or jq missing), so nothing is proposed from it"
  elif [ -z "$cmds" ]; then
    info "$(nothing_proposed "$1"); nothing proposed from it"
  else
    info "proposed Verify for $file:"
    printf '%s\n' "$cmds" | sed 's/^/        /'
    print_ci_hint "$1" "$cmds"
  fi
}

# Puts commands $1 (one per line) at the top of the Verify code block, where the
# skeleton's "# build:" placeholders are, dropping those and keeping any other
# comment below the commands: a comment above a command scopes it to paths, so
# one left above these would scope them too. Fails, and changes nothing, when the
# result would still have no Verify commands.
write_verify() {
  local tmp rc=0
  tmp="$(mktemp CLAUDE.md.XXXXXX)" || return 1
  VERIFY_CMDS="$1" awk '
    BEGIN { n = split(ENVIRON["VERIFY_CMDS"], cmds, "\n") }
    /^```/ {
      print
      in_code = !in_code
      if (in_verify && in_code && !blocks++) for (i = 1; i <= n; i++) print cmds[i]
      next
    }
    !in_code && /^## / { in_verify = ($0 ~ /^## Verify[[:space:]]*$/) }
    in_verify && in_code && blocks == 1 && /^#[[:space:]]*(build|lint|test):[[:space:]]*$/ { next }
    { print }
    END { exit !blocks }
  ' CLAUDE.md >"$tmp" && scripts/check-verify-section.sh "$tmp" >/dev/null 2>&1 && cat "$tmp" >CLAUDE.md || rc=1
  rm -f "$tmp"
  return "$rc"
}

# The optional reviewer for each language found, and how to turn it on. Keyed on
# the language files, not the Verify stack: a Go repo whose Makefile won still
# has Go to review.
print_reviewers() {
  local r
  for r in \
      "$([ -f go.mod ] && echo go-reviewer)" \
      "$([ -f package.json ] && command -v jq >/dev/null \
          && jq -e '(.dependencies // {}) + (.devDependencies // {}) | has("typescript")' package.json >/dev/null 2>&1 \
          && echo typescript-reviewer)" \
      "$([ -f pyproject.toml ] && echo python-reviewer)"; do
    [ -n "$r" ] || continue
    if [ -f ".claude/agent-context/$r.md" ]; then
      ok "$r is on"
    else
      info "optional reviewer for this stack: $r"
      echo "      fix: cp .claude/agent-context/optional/$r.md .claude/agent-context/ && scripts/vendor-agents.sh, then add a row for $r to CLAUDE.md's ## Specialist reviewers"
    fi
  done
}

# Verify has no commands: write the proposal when --fix and exactly one stack
# gives one, otherwise print each so the user can choose.
propose_verify_section() {
  local stacks n cmds="" stack fix_hint="add your build, lint, and test commands to the Verify code block"
  stacks="$(detect_stacks)"
  n="$(printf '%s' "$stacks" | grep -c .)"
  [ "$n" -ne 1 ] || cmds="$(propose_verify "$stacks")" || cmds=""
  if [ -n "$cmds" ] && [ "$fix" -eq 1 ]; then
    if write_verify "$cmds"; then
      ok "wrote $(printf '%s\n' "$cmds" | grep -c .) Verify command(s) from $(stack_file "$stacks") into CLAUDE.md: $(printf '%s\n' "$cmds" | paste -sd ';' - | sed 's/;/; /g')"
      print_ci_hint "$stacks" "$cmds"
      print_reviewers
      return
    fi
    fix_hint="add the proposal below to the Verify code block by hand (--fix found no code block under ## Verify to write it into)"
  elif [ -n "$cmds" ]; then
    fix_hint="scripts/setup.sh --fix  (writes the proposal below into the Verify code block)"
  elif [ "$n" -gt 1 ]; then
    fix_hint="several stacks found, so nothing was written: copy the commands you want from the proposals below into the Verify code block"
  fi
  bad "## Verify has no commands, so the loop will refuse to run" "$fix_hint"
  [ "$n" -gt 0 ] || info "no stack file at the repo root (Makefile with a test target, package.json, go.mod, Cargo.toml, pyproject.toml), so nothing is proposed"
  while IFS= read -r stack; do
    [ -z "$stack" ] || print_proposal "$stack"
  done <<EOF
$stacks
EOF
  print_reviewers
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
# unattended run stops at the command it needs. Name each missing rule. The
# comparison is the helper's, shared with backlog-loop.sh (#81).
check_local_allow_rules() {
  [ -f "$LOCAL_SETTINGS.example" ] || return 0
  local missing count rc=0
  missing="$(scripts/missing-allow-rules.sh "$LOCAL_SETTINGS" 2>&1)" || rc=$?
  case "$rc" in
    0) ok "$LOCAL_SETTINGS has every rule the example allows"; return 0 ;;
    1) ;;
    *) warn "${missing:-could not compare $LOCAL_SETTINGS with its example}"; return 0 ;;
  esac
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

is_plugin_file() { # is_plugin_file <path>: one of the files the template's plugin ships
  local f
  for f in "${PLUGIN_FILES[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

# Says nothing about a repo's own plugin, or the template repo's.
check_plugin_manifests() {
  [ -d .claude-plugin ] || return 0
  git remote get-url origin 2>/dev/null | grep -qE "$TEMPLATE_ORIGIN_RE" && return 0
  grep -qE "$PLUGIN_NAME_RE" .claude-plugin/plugin.json 2>/dev/null || return 0
  local f extra=()
  while IFS= read -r f; do
    is_plugin_file "$f" || extra+=("$f")
  done < <(find .claude-plugin ! -type d)
  if [ "${#extra[@]}" -gt 0 ]; then
    warn "the template's plugin manifests (.claude-plugin/) are here beside files the template never shipped: ${extra[*]}" \
      "delete the template's files from .claude-plugin/ by hand and keep yours"
  elif [ "$fix" -ne 1 ]; then
    warn "the template's plugin manifests (.claude-plugin/) came with the template; this repo does not need them" \
      "scripts/setup.sh --fix  (removes .claude-plugin/)"
  elif rm -rf .claude-plugin; then
    ok "removed .claude-plugin/, the template's plugin manifests"
  else
    warn "could not remove .claude-plugin/, the template's plugin manifests" "delete it by hand"
  fi
}

check_template_version() {
  echo "Template"
  check_plugin_manifests
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
  # A sync from the installed plugin stamps the commit shortened to 12 characters.
  if ! printf '%s\n' "$have" | grep -qE '^[0-9a-f]{12,40}$'; then
    warn "the template version this repo was synced from is unknown ($have)" \
      "re-sync from a clone of the template, or from the plugin as installed from its marketplace: its copy is named after the template commit"
  elif [ -z "$latest" ]; then
    warn "could not reach $TEMPLATE_REPO to compare versions"
  elif [ "${#have}" -ge 12 ] && [ "${latest#"$have"}" != "$latest" ]; then
    ok "up to date with the template"
  else
    warn "synced from template ${have:0:7}; the template is now at ${latest:0:7}" \
      "/backlog-loop:update with the plugin, or from a fresh clone of the template: scripts/sync-guardrails.sh $root"
  fi
}

# Sets $repo, $repo_host, and $repo_full. Returns non-zero when the GitHub checks
# cannot run.
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
  # The same rule the loop uses (#17): with several remotes, the gh default or stop,
  # so --fix never writes labels to a repo gh guessed. Its reason goes in the ✗ line.
  local why
  if ! why="$(mktemp)"; then
    bad "could not create a temp file to resolve the repository"
    return 1
  fi
  if ! repo_full="$(scripts/gh-repo.sh --with-host 2>"$why")"; then
    bad "cannot tell which GitHub repository to check: $(tr '\n' ' ' <"$why")"
    rm -f "$why"
    return 1
  fi
  rm -f "$why"
  # A bare owner/repo means github.com to gh, so the host travels with it: --repo
  # takes $repo_full, and gh api takes --hostname $repo_host.
  repo_host="${repo_full%%/*}"
  repo="${repo_full#*/}"
  ok "repository $repo ($repo_host)"
}

check_labels() {
  echo "Labels"
  if [ ! -f scripts/seed-labels.sh ]; then
    bad "scripts/seed-labels.sh is missing, so the required labels are unknown" "re-run sync-guardrails.sh from the template"
    return
  fi
  local have want missing=()
  if ! have="$(gh label list --repo "$repo_full" --limit 1000 --json name --jq '.[].name' 2>/dev/null)"; then
    bad "could not list the labels on $repo"
    return
  fi
  while IFS= read -r want; do
    printf '%s\n' "$have" | grep -qxF -- "$want" || missing+=("$want")
  done < <(required_labels)

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "every loop label exists"
  elif [ "$fix" -eq 1 ] && scripts/seed-labels.sh "$repo_full" >/dev/null; then
    ok "created the missing labels: ${missing[*]}"
  else
    bad "missing labels: ${missing[*]}" "scripts/setup.sh --fix  (or scripts/seed-labels.sh $repo_full)"
  fi
}

check_ruleset() {
  echo "Branch protection"
  local enforcement
  # A disabled or evaluate-only ruleset blocks nothing, so read its enforcement too.
  if ! enforcement="$(gh api "repos/$repo/rulesets?includes_parents=false" --hostname "$repo_host" --paginate 2>/dev/null \
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
    # Off github.com the host goes in the argument, or the ruleset lands there (#56).
    local target="$repo"
    [ "$repo_host" = github.com ] || target="$repo_full"
    bad "no $RULESET_NAME ruleset, so nothing on GitHub's side stops a push to main" \
      "scripts/protect-main.sh $target <ci-job-name>...  (job names as they appear on a PR)"
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
  view="$(gh repo view "$repo_full" --json url,defaultBranchRef --jq '.url + " " + (.defaultBranchRef.name // "")' 2>/dev/null)" || view=""
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
