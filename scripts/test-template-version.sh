#!/usr/bin/env bash
# Tests for scripts/template-version.sh, with a fake `gh` on PATH and a local bare
# repo as the template, so no network is involved.
# Usage: scripts/test-template-version.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unset TEMPLATE_REPO TEMPLATE_GH_REPO

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# The template: three commits, served from a bare clone.
SRC="$WORK/src"
git init -q -b main "$SRC"
for n in 1 2 3; do
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "c$n"
done
C1="$(git -C "$SRC" rev-parse HEAD~2)"
C3="$(git -C "$SRC" rev-parse HEAD)"
BARE="$WORK/template.git"
git clone -q --bare "$SRC" "$BARE"

# The fake gh logs its arguments and answers the compare call with $FAKE_COMPARE
# (what the real gh prints for the script's --jq), or fails with $FAKE_GH_ERR.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$WORK/gh-calls"
[ -z "\${FAKE_GH_SLEEP:-}" ] || exec sleep "\$FAKE_GH_SLEEP"
if [ -n "\${FAKE_GH_ERR:-}" ]; then echo "\$FAKE_GH_ERR" >&2; exit 1; fi
echo "\${FAKE_COMPARE:-}"
FAKE
chmod +x "$WORK/bin/gh"

# run <name> <stamp, or "none"> [env assignments...]: runs the helper in a fresh
# repo with that stamp. Output in $WORK/<name>.out, exit code in $WORK/<name>.rc.
run() {
  local name="$1" stamp="$2" dir="$WORK/$1"; shift 2
  mkdir -p "$dir/.claude"
  [ "$stamp" = none ] || printf '%s\n' "$stamp" >"$dir/.claude/template-version"
  : >"$WORK/gh-calls"
  (cd "$dir" && env PATH="$WORK/bin:$PATH" TEMPLATE_REPO="$BARE" "$@" "$HERE/template-version.sh") >"$WORK/$name.out" 2>&1
  echo $? >"$WORK/$name.rc"
}
rc() { cat "$WORK/$1.rc"; }
out() { cat "$WORK/$1.out"; }
one_line() { [ "$(grep -c . "$WORK/$1.out")" -eq 1 ]; }
COMPARE_URL="https://github.com/o/template/compare/${C1:0:12}...${C3:0:12}"

run current "$C3" TEMPLATE_GH_REPO=o/template
check "up to date: exit 0, says so" "[ \$(rc current) -eq 0 ] && out current | grep -qx 'up to date with the template'"
check "up to date: no compare call" "[ ! -s '$WORK/gh-calls' ]"
run currenttag "$(printf '%s\nv0.1.0' "$C3")"
check "up to date on a tag names the tag" "[ \$(rc currenttag) -eq 0 ] && out currenttag | grep -qxF 'up to date with the template (v0.1.0)'"
run currentshort "${C3:0:12}"
check "a 12-character stamp of the latest commit is up to date" "[ \$(rc currentshort) -eq 0 ] && out currentshort | grep -q 'up to date'"

run behind "$C1" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='2 0'
check "behind: exit 1, one line" "[ \$(rc behind) -eq 1 ] && one_line behind"
check "behind: says how many commits" "out behind | grep -q '^2 commits behind the template'"
check "behind: links the compare page" "out behind | grep -qF 'What changed: $COMPARE_URL'"
check "behind: still names both commits" "out behind | grep -qF 'synced from template ${C1:0:7}' && out behind | grep -qF 'now at ${C3:0:7}'"
check "behind: asks github.com's compare API for that range" "grep -qF -- '--hostname github.com repos/o/template/compare/${C1:0:12}...${C3:0:12}' '$WORK/gh-calls'"
run behindone "$C1" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='1 0'
check "one commit behind is singular" "out behindone | grep -q '^1 commit behind the template'"
run behindtag "$(printf '%s\nv0.1.0' "$C1")" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='2 0'
check "behind from a tag names the tag" "out behindtag | grep -qF 'synced from template v0.1.0 (${C1:0:7})'"
run diverged "$C1" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='2 3'
check "diverged: behind, and says the synced commit has commits the template lacks" "[ \$(rc diverged) -eq 1 ] && out diverged | grep -q '^2 commits behind' && out diverged | grep -q 'also has 3 commits'"
run ahead "$C1" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='0 4'
check "ahead of the template's default branch is not behind" "[ \$(rc ahead) -eq 0 ] && out ahead | grep -q '^not behind the template' && out ahead | grep -q '4 commits past'"

# Fallbacks to the two-commit message.
TWO_SHAS="synced from template ${C1:0:7}; the template is now at ${C3:0:7}"
run ghfails "$C1" TEMPLATE_GH_REPO=o/template FAKE_GH_ERR='HTTP 500: Server Error'
check "gh fails: exit 1, the two-commit message, no link" "[ \$(rc ghfails) -eq 1 ] && out ghfails | grep -qxF '$TWO_SHAS'"
run ghgarbage "$C1" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='null null'
check "an answer that is not two counts: the two-commit message" "[ \$(rc ghgarbage) -eq 1 ] && out ghgarbage | grep -qxF '$TWO_SHAS'"
run noslug "$C1" FAKE_COMPARE='2 0'
check "a template not on github.com: the two-commit message, gh not called" "[ \$(rc noslug) -eq 1 ] && out noslug | grep -qxF '$TWO_SHAS' && [ ! -s '$WORK/gh-calls' ]"
mkdir -p "$WORK/nogh"
for t in git awk sed grep head env sleep; do ln -s "$(command -v "$t")" "$WORK/nogh/$t"; done
mkdir -p "$WORK/nogh-repo/.claude" && echo "$C1" >"$WORK/nogh-repo/.claude/template-version"
# shellcheck disable=SC2034  # read inside check's eval string
nogh_out="$(cd "$WORK/nogh-repo" && PATH="$WORK/nogh" TEMPLATE_REPO="$BARE" TEMPLATE_GH_REPO=o/template /bin/bash "$HERE/template-version.sh" 2>&1)"; nogh_rc=$?
check "no gh installed: the two-commit message" "[ $nogh_rc -eq 1 ] && [ \"\$nogh_out\" = '$TWO_SHAS' ]"

# The template's owner/repo comes from a github.com TEMPLATE_REPO; git's insteadOf
# serves that URL from the local bare repo, so no network is used.
via_github() { # via_github <name> <url>
  run "$1" "$C1" TEMPLATE_REPO="$2" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$BARE.insteadOf" GIT_CONFIG_VALUE_0="$2" FAKE_COMPARE='2 0'
}
via_github slughttps https://github.com/o/template.git
check "a github.com https URL gives the compare its owner/repo" "[ \$(rc slughttps) -eq 1 ] && out slughttps | grep -qF '$COMPARE_URL'"
via_github slugssh git@github.com:o/template.git
check "a github.com scp-style URL gives the compare its owner/repo" "out slugssh | grep -qF '$COMPARE_URL'"
via_github slughost https://ghe.example.com/o/template.git
check "another host's URL skips the compare" "out slughost | grep -qxF '$TWO_SHAS' && [ ! -s '$WORK/gh-calls' ]"

# What cannot be compared is one clear line, never an error.
run unreachable "$C1" TEMPLATE_REPO="$WORK/no-such-template"
check "unreachable template: exit 2, one line saying so" "[ \$(rc unreachable) -eq 2 ] && one_line unreachable && out unreachable | grep -q '^could not reach .*no-such-template'"
# A network that never answers must not hold up the driver's start (#73): each call
# is cut off after TEMPLATE_CHECK_TIMEOUT seconds. The fakes exec sleep, so the
# process the helper kills is the one holding its output.
mkdir -p "$WORK/hang"
printf '#!/usr/bin/env bash\n[ "$1" = ls-remote ] && exec sleep 30\nexec %s "$@"\n' "$(command -v git)" >"$WORK/hang/git"
chmod +x "$WORK/hang/git"
start=$SECONDS
run hanggit "$C1" PATH="$WORK/hang:$WORK/bin:$PATH" TEMPLATE_CHECK_TIMEOUT=1
hang_secs=$((SECONDS - start))
check "a template that never answers: exit 2 within the timeout, one line" "[ \$(rc hanggit) -eq 2 ] && one_line hanggit && out hanggit | grep -q '^could not reach' && [ $hang_secs -lt 10 ]"
start=$SECONDS
run hanggh "$C1" TEMPLATE_GH_REPO=o/template TEMPLATE_CHECK_TIMEOUT=1 FAKE_GH_SLEEP=30
hang_secs=$((SECONDS - start))
check "a compare that never answers: the two-commit message within the timeout" "[ \$(rc hanggh) -eq 1 ] && out hanggh | grep -qxF '$TWO_SHAS' && [ $hang_secs -lt 10 ]"

run dirtycurrent "$C3-dirty" TEMPLATE_GH_REPO=o/template
check "a -dirty stamp of the latest commit is up to date, and says it had changes" "[ \$(rc dirtycurrent) -eq 0 ] && one_line dirtycurrent && out dirtycurrent | grep -q '^up to date with the template' && out dirtycurrent | grep -q 'uncommitted changes'"
run dirtybehind "$C1-dirty" TEMPLATE_GH_REPO=o/template FAKE_COMPARE='2 0'
check "a -dirty stamp behind: counted from its commit, and says it had changes" "[ \$(rc dirtybehind) -eq 1 ] && one_line dirtybehind && out dirtybehind | grep -q '^2 commits behind' && out dirtybehind | grep -q 'uncommitted changes' && grep -qF 'compare/${C1:0:12}...' '$WORK/gh-calls'"
FORK=0123456789abcdef0123456789abcdef01234567
run forkcommit "$FORK" TEMPLATE_GH_REPO=o/template FAKE_GH_ERR='gh: No commit found for SHA: 0123456789ab (HTTP 404)'
check "a commit the template lacks: exit 2, one line naming it" "[ \$(rc forkcommit) -eq 2 ] && one_line forkcommit && out forkcommit | grep -qF 'has no commit ${FORK:0:12}'"
run unknown unknown
check "a stamp that names no commit: exit 3, one line" "[ \$(rc unknown) -eq 3 ] && one_line unknown && out unknown | grep -qF 'synced from is unknown (unknown)'"
run nostamp none
check "no stamp: exit 4, one line" "[ \$(rc nostamp) -eq 4 ] && one_line nostamp && out nostamp | grep -q '^no .claude/template-version'"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
