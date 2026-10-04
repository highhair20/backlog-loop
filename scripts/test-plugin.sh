#!/usr/bin/env bash
# Checks the installer plugin (#64): this repo is a marketplace with one plugin
# whose root is the template, the manifests parse and point at files that exist,
# and the plugin carries only its two commands, so no hook, agent, or loop command
# runs twice beside the repo-resident ones. Usage: scripts/test-plugin.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKET="$ROOT/.claude-plugin/marketplace.json"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
NAME=backlog-loop
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# --- the marketplace ---
check "marketplace.json parses" "jq -e . '$MARKET' >/dev/null 2>&1"
check "the marketplace is named $NAME, with an owner" "jq -e '.name == \"$NAME\" and (.owner.name | length > 0)' '$MARKET' >/dev/null 2>&1"
check "it lists exactly one plugin, $NAME" "jq -e '[.plugins[].name] == [\"$NAME\"]' '$MARKET' >/dev/null 2>&1"
# The template is the plugin: its scripts are what the commands run.
check "the plugin's root is the marketplace root" "jq -e '.plugins[0].source == \"./\"' '$MARKET' >/dev/null 2>&1"

# --- the plugin manifest ---
check "plugin.json parses" "jq -e . '$PLUGIN' >/dev/null 2>&1"
# Install ids use the entry name, command prefixes the manifest name: keep them one.
check "the manifest name matches the marketplace entry" "jq -e '.name == \"$NAME\"' '$PLUGIN' >/dev/null 2>&1"
# With no version, the cache directory is named after the template commit, which
# sync-guardrails.sh records as the version a repo was synced from.
check "neither manifest pins a version" "jq -e 'has(\"version\") | not' '$PLUGIN' >/dev/null 2>&1 && jq -e '.plugins[0] | has(\"version\") | not' '$MARKET' >/dev/null 2>&1"
check "the plugin has exactly the install and update commands" "jq -e '.commands | keys == [\"install\", \"update\"]' '$PLUGIN' >/dev/null 2>&1"

# shellcheck disable=SC2034  # read inside check's eval strings
sources="$(jq -r '.commands[].source' "$PLUGIN" 2>/dev/null)"
check "every command names a source file" "[ \"\$(printf '%s\n' \"\$sources\" | grep -c .)\" = 2 ]"
while IFS= read -r src; do
  [ -n "$src" ] || continue
  check "command source $src exists" "[ -f '$ROOT/$src' ]"
  # setup.sh --fix removes .claude-plugin/, so a command elsewhere would be left
  # behind in every repo made from the template.
  check "command source $src is inside .claude-plugin/" "case '$src' in ./.claude-plugin/*) true ;; *) false ;; esac"
  check "command $src has a description" "jq -e --arg s '$src' '.commands[] | select(.source == \$s) | .description | length > 0' '$PLUGIN' >/dev/null 2>&1"
done <<<"$sources"

# --- nothing else loads from the plugin ---
for key in hooks agents skills mcpServers lspServers outputStyles workflows experimental settings; do
  check "plugin.json declares no $key" "jq -e 'has(\"$key\") | not' '$PLUGIN' >/dev/null 2>&1"
  check "the marketplace entry declares no $key" "jq -e '.plugins[0] | has(\"$key\") | not' '$MARKET' >/dev/null 2>&1"
done
# Claude Code scans these at the plugin root even without a manifest key.
for default in agents commands skills hooks/hooks.json .mcp.json .lsp.json settings.json bin output-styles workflows themes monitors; do
  check "the template root has no $default for the plugin to pick up" "[ ! -e '$ROOT/$default' ]"
done

# --- the commands ---
INSTALL="$ROOT/.claude-plugin/commands/install.md"
UPDATE="$ROOT/.claude-plugin/commands/update.md"
check "install runs the plugin's sync script" "grep -qF '\${CLAUDE_PLUGIN_ROOT}/scripts/sync-guardrails.sh' '$INSTALL'"
check "install runs the repo's setup.sh --fix" "grep -qF 'scripts/setup.sh --fix' '$INSTALL'"
check "update runs the plugin's sync script" "grep -qF '\${CLAUDE_PLUGIN_ROOT}/scripts/sync-guardrails.sh' '$UPDATE'"
check "update shows the diff" "grep -qF 'git diff' '$UPDATE'"
# Plugins outside the official marketplace do not auto-update, and the loaded copy
# stays loaded until a reload.
check "update reminds to refresh the marketplace" "grep -qF 'claude plugin marketplace update $NAME' '$UPDATE'"
check "update reminds to update the plugin" "grep -qF 'claude plugin update $NAME@$NAME' '$UPDATE'"
check "update reminds to reload plugins" "grep -qF '/reload-plugins' '$UPDATE'"
for cmd in "$INSTALL" "$UPDATE"; do
  check "${cmd##*/} runs no commit, stage, or push" "! grep -qE 'git (commit|add|push)' '$cmd'"
  check "${cmd##*/} says never to commit" "grep -qi 'never commit' '$cmd'"
  # Every plugin path a command names must ship with the plugin.
  # shellcheck disable=SC2016  # the variable is matched literally
  for p in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+' "$cmd" 2>/dev/null | sed 's|^${CLAUDE_PLUGIN_ROOT}/||' | sort -u); do
    check "${cmd##*/}: plugin path $p exists" "[ -e '$ROOT/$p' ]"
  done
done

# setup.sh --fix removes the template's .claude-plugin/ only when it holds exactly
# the files setup.sh knows, so its list must match what ships.
# shellcheck disable=SC2034  # read inside check's eval strings
known="$(sed -n '/^PLUGIN_FILES=(/,/^)/p' "$ROOT/scripts/setup.sh" | sed -nE 's/^[[:space:]]+([^[:space:]#)]+).*/\1/p' | sort)"
# shellcheck disable=SC2034  # read inside check's eval strings
shipped="$(cd "$ROOT" && find .claude-plugin -type f 2>/dev/null | sort)"
check "setup.sh's PLUGIN_FILES list is what .claude-plugin/ ships" "[ -n \"\$known\" ] && [ \"\$known\" = \"\$shipped\" ]"

# --- README ---
README="$ROOT/README.md"
check "README gives the marketplace add command" "grep -qF '/plugin marketplace add highhair20/$NAME' '$README'"
check "README gives the install command" "grep -qF '/plugin install $NAME@$NAME' '$README' && grep -qF '/$NAME:install' '$README'"
check "README documents the update command" "grep -qF '/$NAME:update' '$README'"
# shellcheck disable=SC2034  # read inside check's eval strings
existing="$(awk '/^### /{ on = ($0 == "### An existing repository") } on' "$README")"
check "the plugin comes first for an existing repo, clone-and-sync after" "printf '%s\n' \"\$existing\" | awk '/\\/$NAME:install/ && !p { p = NR } /sync-guardrails.sh \\.\\/my-app/ && !s { s = NR } END { exit !(p && s && p < s) }'"
check "README's file list includes .claude-plugin/" "grep -qE '^\\.claude-plugin/' '$README'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
