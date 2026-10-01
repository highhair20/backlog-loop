#!/usr/bin/env bash
# Can gh act on this repo? Checks gh's login for the host the repo's origin points
# at, prints that host, and exits with gh's status: 0 when logged in.
#
# A bare `gh auth status` tests every host and account gh has stored, and exits 1
# if any of them has a problem (see `gh auth status --help`). So a stale token for
# some unrelated GitHub Enterprise host made the loop and setup.sh report gh as
# logged out (#15). Checking the origin's host keeps GitHub Enterprise repos working
# too, where hard-coding github.com would break them.
#
# With no origin, or an origin with no host (a local path), there is no host to
# pick: it checks every host as before, and prints nothing.
#
# Usage: scripts/gh-auth-check.sh   (from inside the repo)
set -uo pipefail

# The host in a git remote URL: scheme://[user@]host[:port]/path, or scp-style
# [user@]host:path. Prints nothing for a local path.
url_host() {
  local url="$1" rest
  case "$url" in
    *://*)
      rest="${url#*://}"
      rest="${rest%%/*}"
      rest="${rest##*@}"
      echo "${rest%%:*}"
      ;;
    /*|./*|../*) ;;
    *:*)
      rest="${url%%:*}"
      echo "${rest##*@}"
      ;;
  esac
}

# The host as gh names it. gh resolves an SSH remote's host through ~/.ssh/config,
# so an alias like `git@work-gh:o/r` means the alias's real host, and it treats
# subdomains of github.com (ssh.github.com) as github.com.
gh_host() {
  local url="$1" host real
  host="$(url_host "$url")"
  [ -n "$host" ] || return 0
  case "$url" in
    http://*|https://*) ;;
    *)
      # ssh -G prints the resolved config without connecting.
      if command -v ssh >/dev/null; then
        real="$(ssh -G "$host" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
        [ -z "$real" ] || host="$real"
      fi
      ;;
  esac
  case "$host" in
    *.github.com) host=github.com ;;
  esac
  echo "$host"
}

host=""
if url="$(git remote get-url origin 2>/dev/null)"; then
  host="$(gh_host "$url")"
fi

if [ -z "$host" ]; then
  gh auth status >/dev/null 2>&1
  exit
fi
echo "$host"
gh auth status --hostname "$host" >/dev/null 2>&1
