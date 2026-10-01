#!/usr/bin/env bash
# Tests for scripts/gh-auth-check.sh, with fake `gh` and `ssh` on PATH and
# throwaway repos, so no network is involved. Usage: scripts/test-gh-auth-check.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The fakes. gh: `auth status --hostname $GOOD_HOST` passes, any other
# `--hostname` fails, and bare `auth status` exits $BARE_RC, which defaults to 1:
# a stale token for some unrelated host. ssh: `ssh -G <host>` prints the host's
# real name from $WORK/ssh-aliases ("alias real" lines), or the host itself.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$WORK/gh-calls"
case "$*" in
  "auth status") exit "${BARE_RC:-1}" ;;
  "auth status --hostname $GOOD_HOST") exit 0 ;;
  "auth status --hostname "*) echo "gh says: offline" >&2; exit 1 ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 2 ;;
esac
FAKE
cat >"$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = -G ] || { echo "fake ssh: unexpected: $*" >&2; exit 2; }
real="$(awk -v h="$2" '$1 == h { print $2; exit }' "$WORK/ssh-aliases" 2>/dev/null)"
printf 'user git\nhostname %s\nport 22\n' "${real:-$2}"
FAKE
chmod +x "$WORK/bin/"*
: >"$WORK/ssh-aliases"
export WORK

n=0
# check_auth <origin url, or "" for none> [VAR=value...]: runs the helper in a fresh
# repo; sets $rc and $out, and $calls to the gh commands it ran.
check_auth() {
  local url="$1" dir; shift
  n=$((n + 1)); dir="$WORK/repo$n"
  git init -q "$dir"
  [ -z "$url" ] || git -C "$dir" remote add origin "$url"
  : >"$WORK/gh-calls"
  out="$(cd "$dir" && env PATH="$WORK/bin:$PATH" GOOD_HOST=github.com "$@" "$HERE/gh-auth-check.sh" 2>"$WORK/err")"; rc=$?
  # shellcheck disable=SC2034  # read inside check's eval strings
  calls="$(cat "$WORK/gh-calls")"
}

check_auth https://github.com/o/r.git
check "a stale unrelated host does not fail a github.com repo" "[ $rc -eq 0 ] && [ '$out' = github.com ]"
check "checks only the repo's host" "[ \"\$calls\" = 'auth status --hostname github.com' ]"

check_auth https://github.com/o/r.git GOOD_HOST=nowhere.example
check "fails when the repo's own host is logged out" "[ $rc -eq 1 ]"
check "names the logged-out host" "[ '$out' = github.com ]"

check_auth https://github.com/o/r.git GOOD_HOST=nowhere.example BARE_RC=0
check "fails on the repo's host even when every-host status passes" "[ $rc -eq 1 ]"

# The host from each URL form git accepts; a GitHub Enterprise host is never
# replaced by github.com.
for url in \
    https://ghe.example.com/o/r.git \
    https://user@ghe.example.com:8443/o/r \
    http://ghe.example.com/o/r.git \
    ssh://git@ghe.example.com:2222/o/r.git \
    git@ghe.example.com:o/r.git \
    ghe.example.com:o/r.git; do
  check_auth "$url" GOOD_HOST=ghe.example.com
  check "GitHub Enterprise host from $url" "[ $rc -eq 0 ] && [ '$out' = ghe.example.com ] && [ \"\$calls\" = 'auth status --hostname ghe.example.com' ]"
done

# gh maps an SSH alias to its real host, and ssh.github.com to github.com.
echo "work-gh github.com" >"$WORK/ssh-aliases"
check_auth git@work-gh:o/r.git
check "resolves an SSH alias from ~/.ssh/config" "[ $rc -eq 0 ] && [ '$out' = github.com ]"
check_auth ssh://git@work-gh:2222/o/r.git
check "resolves an SSH alias in an ssh:// URL" "[ $rc -eq 0 ] && [ '$out' = github.com ]"
echo "github.com ssh.github.com" >"$WORK/ssh-aliases"
check_auth git@github.com:o/r.git
check "folds ssh.github.com into github.com" "[ $rc -eq 0 ] && [ '$out' = github.com ]"
: >"$WORK/ssh-aliases"
check_auth https://work-gh/o/r.git GOOD_HOST=work-gh
check "does not resolve an HTTPS host through ssh" "[ $rc -eq 0 ] && [ '$out' = work-gh ]"
check_auth https://GitHub.com/o/r.git
check "lower-cases the host" "[ $rc -eq 0 ] && [ '$out' = github.com ]"

# gh's own report reaches stderr on failure, so its reason is not lost.
check_auth https://github.com/o/r.git GOOD_HOST=nowhere.example
check "passes gh's report through on failure" "[ $rc -eq 1 ] && grep -q 'gh says: offline' '$WORK/err'"
check_auth https://github.com/o/r.git
check "is quiet on success" "[ $rc -eq 0 ] && [ ! -s '$WORK/err' ]"

# No host to pick: falls back to checking every host, as gh auth status does.
check_auth "" BARE_RC=0
check "with no origin, passes when every host is fine" "[ $rc -eq 0 ] && [ -z '$out' ] && [ \"\$calls\" = 'auth status' ]"
check_auth ""
check "with no origin, fails when any host has a problem" "[ $rc -eq 1 ]"
check_auth /srv/git/r.git BARE_RC=0
check "an origin that is a local path falls back to every host" "[ $rc -eq 0 ] && [ \"\$calls\" = 'auth status' ]"
check_auth file:///srv/git/r.git
check "a file:// origin falls back to every host" "[ $rc -eq 1 ] && [ \"\$calls\" = 'auth status' ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
