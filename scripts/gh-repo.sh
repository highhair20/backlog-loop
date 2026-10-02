#!/usr/bin/env bash
# Which GitHub repo does gh act on here? Prints it as owner/repo, or says why on
# stderr and exits 1 when that is not clear.
#
# Every gh command run without --repo picks the repo itself. With several remotes
# and no `gh repo set-default`, gh cannot ask when it has no terminal, so it takes
# one by remote name, `upstream` before `origin`: in a fork, the parent repo. The
# loop's issue and PR commands and setup.sh's label writes then land on a repo
# nobody chose (#17). So the rule here, which matches gh's own:
#   - one remote: that one;
#   - several: the one `gh repo set-default` names, and stop when none is set.
# Once this succeeds, every gh command in this checkout resolves to the repo printed.
#
# Usage: scripts/gh-repo.sh [--with-host]   (from inside the repo)
#   --with-host  print HOST/OWNER/REPO, the form GH_REPO takes, with the host gh
#                itself resolved (not origin's: the repo may be on another remote)
set -uo pipefail

with_host=0
case "${1:-}" in
  --with-host) with_host=1 ;;
  "") ;;
  *) echo "usage: $0 [--with-host]" >&2; exit 2 ;;
esac

remotes="$(git remote 2>/dev/null)" || { echo "not inside a git repository" >&2; exit 1; }
count="$(printf '%s\n' "$remotes" | grep -c .)"

if [ "$count" -eq 0 ]; then
  echo "no git remote, so no GitHub repository to act on. Fix: gh repo create, or git remote add origin <url>" >&2
  exit 1
fi

if [ "$count" -gt 1 ]; then
  # gh prints the default on stdout, and nothing there (exit 0) when none is set.
  # A failed lookup stops too, without guessing, and is not called "unset".
  if ! default="$(gh repo set-default --view 2>/dev/null)"; then
    echo "could not read gh's default repository; run gh repo set-default --view to see why" >&2
    exit 1
  fi
  if [ -z "$default" ]; then
    echo "this checkout has $count remotes ($(printf '%s\n' "$remotes" | paste -sd, - | sed 's/,/, /g')) and no gh default repository, so gh would guess which repo to act on. Fix: gh repo set-default <owner/repo>  (the repo your issues and PRs live in)" >&2
    exit 1
  fi
fi

# Unambiguous now: one remote, or a default gh will use. gh's message reaches
# stderr if it fails. Its url (https://HOST/OWNER/REPO) gives the host and the
# name from one answer.
url="$(gh repo view --json url --jq .url)" || exit 1
full="${url#*://}"
case "$full" in
  */*/*/*|/*|*//*|"$url") full="" ;;
  */*/*) ;;
  *) full="" ;;
esac
if [ -z "$full" ]; then
  echo "gh repo view gave no usable repository URL for this checkout: '$url'" >&2
  exit 1
fi
if [ "$with_host" -eq 1 ]; then echo "$full"; else echo "${full#*/}"; fi
