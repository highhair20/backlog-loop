#!/usr/bin/env bash
# Tests for .claude/hooks/pr-created-review.sh: it must open a review loop for a
# PR created through the gh CLI (local sessions) AND through the GitHub MCP tool
# (cloud sessions, which have no gh), and for nothing else.
# Usage: scripts/test-pr-created-review.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# Each case gets a fresh copy of the hooks, so state from one cannot leak into the next.
hook() { # hook <case-name> <payload-json>  → stdout in $WORK/<case>/out
  local dir="$WORK/$1"
  mkdir -p "$dir/.claude"
  cp -R "$ROOT/.claude/hooks" "$dir/.claude/"
  printf '%s' "$2" | "$dir/.claude/hooks/pr-created-review.sh" >"$dir/out" 2>&1
}
armed() { [ -f "$WORK/$1/.claude/state/pr-review/$2.json" ]; }

URL=https://github.com/o/r/pull/12

hook cli '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"'"$URL"'\n"}}'
check "gh CLI: opens a loop" "armed cli 12"
check "gh CLI: tells Claude to review by URL" "grep -q '/code-review $URL' '$WORK/cli/out'"

hook cli-fail '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"gh pr create --fill 2>&1"},"tool_response":{"stdout":"a pull request for branch \"x\" into branch \"main\" already exists:\n'"$URL"'\n"}}'
check "gh CLI: ignores an already-exists failure" "! armed cli-fail 12"

# The GitHub MCP server returns its result as text content holding JSON.
hook mcp-text '{"session_id":"s","tool_name":"mcp__github__create_pull_request","tool_input":{"owner":"o","repo":"r","title":"t","head":"b","base":"main"},"tool_response":[{"type":"text","text":"{\"id\":1,\"url\":\"'"$URL"'\"}"}]}'
check "MCP (text JSON): opens a loop" "armed mcp-text 12"
check "MCP (text JSON): tells Claude to review by URL" "grep -q '/code-review $URL' '$WORK/mcp-text/out'"

hook mcp-obj '{"session_id":"s","tool_name":"mcp__github__create_pull_request","tool_input":{},"tool_response":{"number":12,"url":"https://api.github.com/repos/o/r/pulls/12","html_url":"'"$URL"'"}}'
check "MCP (object): opens a loop from html_url, not the API url" "armed mcp-obj 12"

hook mcp-mention '{"session_id":"s","tool_name":"mcp__github__create_pull_request","tool_input":{},"tool_response":[{"type":"text","text":"{\"body\":\"Follows https://github.com/o/r/pull/3\",\"url\":\"'"$URL"'\"}"}]}'
check "MCP: a PR merely mentioned in the body is not armed" "armed mcp-mention 12 && ! armed mcp-mention 3"

hook mcp-error '{"session_id":"s","tool_name":"mcp__github__create_pull_request","tool_input":{},"tool_response":[{"type":"text","text":"failed to create pull request: 422 A pull request already exists for o:b."}]}'
check "MCP: an error response opens nothing" "[ ! -d '$WORK/mcp-error/.claude/state' ] || [ -z \"\$(ls -A '$WORK/mcp-error/.claude/state/pr-review' 2>/dev/null)\" ]"

hook other '{"session_id":"s","tool_name":"mcp__github__list_pull_requests","tool_input":{},"tool_response":[{"type":"text","text":"[{\"url\":\"'"$URL"'\"}]"}]}'
check "other MCP tools that return PR URLs open nothing" "! armed other 12"

hook bash-other '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"echo '"$URL"'"},"tool_response":{"stdout":"'"$URL"'\n"}}'
check "other Bash commands that print PR URLs open nothing" "! armed bash-other 12"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
