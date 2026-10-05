#!/usr/bin/env bash
# Says, in one line on stdout, how the template commit this repo was synced from
# (.claude/template-version, written by sync-guardrails.sh) compares with the
# template's latest commit. scripts/setup.sh and scripts/backlog-loop.sh both call
# this, so a repo that runs the loop unattended hears it is behind without anyone
# running setup.sh, and the two cannot disagree (#73).
#
# When the template is on github.com and `gh api` answers its compare endpoint, a
# repo that is behind is told by how many commits, with a link to what changed.
# Otherwise it gets the two commits. Nothing here waits on a password prompt, and
# what cannot be compared is a one-line answer, never an error.
#
# Usage: scripts/template-version.sh [stamp-file]   (from the repo root)
#   TEMPLATE_REPO     the template's git URL (default: the public backlog-loop)
#   TEMPLATE_GH_REPO  its owner/repo on github.com, for the compare (default: read
#                     from TEMPLATE_REPO when that is a github.com URL)
#   TEMPLATE_CHECK_TIMEOUT  seconds each network call may take (default 20)
# Exits 0 when not behind, 1 when behind, 2 when it cannot tell (the template is
# unreachable, or does not have the stamp's commit), 3 when the stamp names no
# commit, 4 when there is no stamp.
set -uo pipefail

TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/highhair20/backlog-loop.git}"
stamp="${1:-.claude/template-version}"
TIMEOUT="${TEMPLATE_CHECK_TIMEOUT:-20}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=20 ;; esac

# Runs a command, killing it after $TIMEOUT seconds, so a network that never
# answers (a dropped connection, a black-holed route) cannot hold up the driver's
# start. macOS has no `timeout`. The watcher writes nowhere, so a caller's $(...)
# does not wait for it.
bounded() {
  "$@" &
  local pid=$! watcher rc
  ( sleep "$TIMEOUT"; kill "$pid" ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"; rc=$?
  kill "$watcher" 2>/dev/null
  return "$rc"
}

# owner/repo of a github.com URL (https, ssh://, or scp-style), or nothing.
github_slug() {
  local url="${1%/}"
  url="${url%.git}"
  printf '%s\n' "$url" | sed -nE 's#^(https://(www\.)?|ssh://git@|git@)github\.com[:/]([^/:]+/[^/]+)$#\3#p'
}

commits() { if [ "$1" -eq 1 ]; then echo "1 commit"; else echo "$1 commits"; fi; }

if [ ! -f "$stamp" ]; then
  echo "no $stamp (written by sync-guardrails.sh)"
  exit 4
fi
have="$(head -1 "$stamp")"
# A sync from a template clone with uncommitted changes stamps <commit>-dirty: the
# comparison is from that commit, and the message says the changes came along.
changes=""
case "$have" in
  *-dirty) have="${have%-dirty}"; changes=" plus uncommitted changes" ;;
esac
# Line 2, when present, is the release tag that commit carried (#65).
tag="$(sed -n 2p "$stamp")"
# A sync from the installed plugin stamps the commit shortened to 12 characters.
if ! printf '%s\n' "$have" | grep -qxE '[0-9a-f]{12,40}'; then
  echo "the template version this repo was synced from is unknown ($have)"
  exit 3
fi

# The HEAD pattern also matches refs like refs/remotes/origin/HEAD; take the exact one.
# GIT_TERMINAL_PROMPT=0: a private or mistyped URL must fail, not wait for a password.
# BatchMode: ssh's own passphrase and host-key prompts ignore GIT_TERMINAL_PROMPT, and
# the timeout kills git, not the ssh it started. A command the user set is kept.
latest="$(bounded env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git ls-remote "$TEMPLATE_REPO" HEAD 2>/dev/null \
  | awk '$2 == "HEAD" { print $1; exit }')"
if [ -z "$latest" ]; then
  echo "could not reach $TEMPLATE_REPO to compare versions"
  exit 2
fi

if [ "${latest#"$have"}" != "$latest" ]; then
  if [ -n "$changes" ]; then
    echo "up to date with the template${tag:+ ($tag)}, plus uncommitted changes its clone had when synced"
  else
    echo "up to date with the template${tag:+ ($tag)}"
  fi
  exit 0
fi

from="${have:0:7}"
[ -z "$tag" ] || from="$tag ($from)"
two_commits="synced from template $from$changes; the template is now at ${latest:0:7}"
slug="${TEMPLATE_GH_REPO:-$(github_slug "$TEMPLATE_REPO")}"
if [ -z "$slug" ] || ! command -v gh >/dev/null; then
  echo "$two_commits"
  exit 1
fi

# ahead_by: commits the template has that the stamp lacks; behind_by: the reverse.
# Always github.com, whatever host gh defaults to: the template lives there.
range="${have:0:12}...${latest:0:12}"
if ! counts="$(bounded gh api --hostname github.com "repos/$slug/compare/$range" \
    --jq '"\(.ahead_by) \(.behind_by)"' 2>&1)"; then
  case "$counts" in
    *"HTTP 404"*|*"HTTP 422"*)
      echo "the template ($slug) has no commit ${have:0:12} that gh can find, the one this repo was synced from (a fork's commit, or a template gh cannot read?), so how far behind it is cannot be told; the template is now at ${latest:0:7}"
      exit 2 ;;
  esac
  echo "$two_commits"
  exit 1
fi
ahead="${counts%% *}"
behind="${counts#* }"
case "$ahead" in ''|*[!0-9]*) echo "$two_commits"; exit 1 ;; esac
case "$behind" in ''|*[!0-9]*) echo "$two_commits"; exit 1 ;; esac

if [ "$ahead" -eq 0 ]; then
  echo "not behind the template: synced from template $from$changes, $(commits "$behind") past its default branch (${latest:0:7})"
  exit 0
fi
extra=""
[ "$behind" -eq 0 ] || extra="; the synced commit also has $(commits "$behind") the template's default branch lacks"
echo "$(commits "$ahead") behind the template: $two_commits$extra. What changed: https://github.com/$slug/compare/$range"
exit 1
