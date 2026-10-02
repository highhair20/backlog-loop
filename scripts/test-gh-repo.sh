#!/usr/bin/env bash
# Tests for scripts/gh-repo.sh, with a fake `gh` on PATH and throwaway repos, so
# no network is involved. Usage: scripts/test-gh-repo.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The fake gh. `repo set-default --view` prints $DEFAULT (nothing when unset, as
# gh does, which says so on stderr only). `repo view` prints $VIEW, or fails with
# gh's message when $VIEW is empty. Every call is logged to $WORK/gh-calls.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$WORK/gh-calls"
case "$*" in
  "repo set-default --view")
    [ -n "${DEFAULT:-}" ] && echo "$DEFAULT" || echo "no default repository has been set" >&2
    exit "${DEFAULT_RC:-0}" ;;
  "repo view --json url --jq .url")
    [ -n "${VIEW:-}" ] || { echo "gh says: none of the git remotes point to a known GitHub host" >&2; exit 1; }
    case "$VIEW" in *://*) echo "$VIEW" ;; *) echo "https://${VIEW_HOST:-github.com}/$VIEW" ;; esac ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/gh"
export WORK

n=0
# resolve <remote names, space-separated, or ""> [VAR=value...]: runs the helper in
# a fresh repo with those remotes; sets $rc, $out, $err, and $calls.
resolve() {
  local names="$1" dir r; shift
  n=$((n + 1)); dir="$WORK/repo$n"
  git init -q "$dir"
  for r in $names; do git -C "$dir" remote add "$r" "https://github.com/$r/r.git"; done
  : >"$WORK/gh-calls"
  out="$(cd "$dir" && env PATH="$WORK/bin:$PATH" "$@" "$HERE/gh-repo.sh" 2>"$WORK/err")"; rc=$?
  # shellcheck disable=SC2034  # read inside check's eval strings
  err="$(cat "$WORK/err")"
  # shellcheck disable=SC2034  # read inside check's eval strings
  calls="$(cat "$WORK/gh-calls")"
}

# One remote: nothing to choose between, so gh's answer is the repo.
resolve origin VIEW=o/r
check "one remote: prints the repo" "[ $rc -eq 0 ] && [ '$out' = o/r ]"
check "one remote: does not need a gh default" "! printf '%s' \"\$calls\" | grep -q set-default"
check "is quiet on success" "[ -z \"\$err\" ]"

# Several remotes and no default: gh would pick one by name (upstream first), so
# stop and say how to choose, and never ask gh for the repo.
resolve "origin upstream" VIEW=upstream/r
check "several remotes, no default: fails" "[ $rc -eq 1 ] && [ -z '$out' ]"
check "names the remotes and the fix" "printf '%s' \"\$err\" | grep -q 'origin, upstream' && printf '%s' \"\$err\" | grep -q 'gh repo set-default <owner/repo>'"
check "does not let gh guess" "! printf '%s' \"\$calls\" | grep -q 'repo view'"

# A failing `set-default --view` (an old gh, say) counts as no default: the safe side.
resolve "origin upstream" DEFAULT=o/r DEFAULT_RC=1 VIEW=o/r
check "a failed default lookup stops, without guessing" "[ $rc -eq 1 ] && [ -z '$out' ] && ! printf '%s' \"\$calls\" | grep -q 'repo view'"
check "a failed default lookup is not reported as unset" "printf '%s' \"\$err\" | grep -q 'could not read gh' && ! printf '%s' \"\$err\" | grep -q 'no gh default'"

# Several remotes with a default: gh resolves to it, and the helper says which.
# The default names neither remote, so the answer cannot come from a remote name.
resolve "origin upstream" DEFAULT=chosen/repo VIEW=chosen/repo
check "several remotes with a default: prints the repo" "[ $rc -eq 0 ] && [ '$out' = chosen/repo ]"
check "several remotes with a default: quiet on success" "[ -z \"\$err\" ]"

# --with-host gives GH_REPO's form, with the host gh resolved, not origin's (PR #48
# review): a GHE repo whose only remote is not named origin stays on its host.
git init -q "$WORK/ghe"
git -C "$WORK/ghe" remote add work https://ghe.example.com/o/r.git
: >"$WORK/gh-calls"
out="$(cd "$WORK/ghe" && env PATH="$WORK/bin:$PATH" VIEW=o/r VIEW_HOST=ghe.example.com "$HERE/gh-repo.sh" --with-host 2>"$WORK/err")"; rc=$?
check "--with-host prints gh's host with the repo" "[ $rc -eq 0 ] && [ '$out' = ghe.example.com/o/r ]"
resolve origin VIEW=o/r VIEW_HOST=ghe.example.com
check "without --with-host the host is dropped" "[ $rc -eq 0 ] && [ '$out' = o/r ]"
for bad_url in "https://github.com/o" "https://github.com/o/r/extra" "not-a-url"; do
  resolve origin VIEW="$bad_url"
  check "rejects an unusable URL from gh: $bad_url" "[ $rc -eq 1 ] && [ -z '$out' ] && printf '%s' \"\$err\" | grep -q 'no usable repository URL'"
done
resolve origin VIEW=o/r
(cd "$WORK/repo$n" && "$HERE/gh-repo.sh" --bogus >/dev/null 2>&1); rc=$?
check "rejects an unknown argument" "[ $rc -eq 2 ]"

# No remote: no repo, and the reason says so.
resolve ""
check "no remote: fails, saying so" "[ $rc -eq 1 ] && [ -z '$out' ] && printf '%s' \"\$err\" | grep -q 'no git remote'"
check "no remote: does not ask gh" "[ -z \"\$calls\" ]"

# gh's own failure is passed on, not replaced, so its reason is not lost.
resolve origin
check "a gh failure fails, with gh's reason" "[ $rc -eq 1 ] && [ -z '$out' ] && printf '%s' \"\$err\" | grep -q 'gh says: none of the git remotes'"

# Outside a git repository there is nothing to resolve.
mkdir -p "$WORK/plain"
out="$(cd "$WORK/plain" && env PATH="$WORK/bin:$PATH" GIT_CEILING_DIRECTORIES="$WORK" "$HERE/gh-repo.sh" 2>"$WORK/err")"; rc=$?
check "outside a repository: fails" "[ $rc -eq 1 ] && [ -z '$out' ] && grep -q 'not inside a git repository' '$WORK/err'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
