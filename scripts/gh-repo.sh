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
# Usage: scripts/gh-repo.sh   (from inside the repo)
set -uo pipefail

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
# stderr if it fails.
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 1
if [ -z "$repo" ]; then
  echo "gh repo view named no repository for this checkout" >&2
  exit 1
fi
echo "$repo"
