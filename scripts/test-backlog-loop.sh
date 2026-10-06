#!/usr/bin/env bash
# Tests for scripts/backlog-loop.sh, with fake `gh` and `claude` on PATH so no
# network or model is involved. Usage: scripts/test-backlog-loop.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_OF_TEMPLATE="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
BG=""
trap '[ -z "$BG" ] || kill "$BG" 2>/dev/null; touch "$WORK"/*/go 2>/dev/null; rm -rf "$WORK"' EXIT

# When the loop itself runs these tests, the driver's PID is in the environment.
unset BACKLOG_LOOP_PID BACKLOG_LOOP_STAGED BACKLOG_LOOP_ROOT GH_REPO
# The driver's settings too: a loop started as `MAX_ITEMS=2 scripts/backlog-loop.sh`
# passes them to every session, and its Verify then ran these nested drivers
# with a cap of 2 against 3-issue fixtures (#41).
unset MAX_ITEMS PACE_SECONDS MAX_RETRIES BACKOFF_SECONDS MODEL LOG_DIR BG_WAIT_SECONDS
# The template the start-up check compares with is set per test, never the network's.
unset TEMPLATE_REPO TEMPLATE_GH_REPO

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

# A throwaway repo with the driver, its helper scripts, and a CLAUDE.md.
# $1 = name, $2 = claude fake behaviour: "progress" (decrements the count), "stall",
# "block" (progress, but the first call waits for a `go` file, so a test can act
# while the driver is mid-item), or "steps" (call n sources the fixture's `step-n`
# if there is one, and otherwise changes nothing).
# Open PRs are the fixture's prs.json (none by default).
# Every fake claude also runs the lock check /work-next-item runs, recording its
# exit code, since the driver's own session must pass it.
setup() {
  local dir="$WORK/$1"
  mkdir -p "$dir/scripts" "$dir/bin"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin https://github.com/o/r.git
  cp "$HERE/backlog-loop.sh" "$HERE/check-verify-section.sh" "$HERE/loop-lock.sh" "$HERE/gh-auth-check.sh" "$HERE/gh-repo.sh" "$HERE/missing-allow-rules.sh" "$HERE/report-drained.sh" "$HERE/template-version.sh" "$dir/scripts/"
  printf '## Verify\n```sh\nmake test\n```\n' >"$dir/CLAUDE.md"
  echo 3 >"$dir/count"
  : >"$dir/calls"
  # gh: `issue list ... --jq ...` prints the remaining count.
  # Issues as gh prints them: <count> actionable ones labelled $(cat label) (P2 by
  # default), plus any in extra.json, so the driver's own filter is exercised.
  printf '#!/usr/bin/env bash\n[ -f "%s/extra.json" ] || echo "[]" >"%s/extra.json"\njq -n --argjson n "$(cat "%s/count")" --arg lab "$(cat "%s/label" 2>/dev/null || echo P2)" --slurpfile extra "%s/extra.json" '"'"'[range($n) | {number: (. + 1), labels: [{name: $lab}]}] + $extra[0]'"'"'\n' "$dir" "$dir" "$dir" "$dir" "$dir" >"$dir/bin/issues-json"
  # gh-base answers the repo lookups gh-repo.sh makes (a default only when the
  # fixture has a `default` file) and `pr list`; tests that replace gh fall through to it.
  printf '#!/usr/bin/env bash\ncase "$*" in\n  "repo set-default --view") cat "%s/default" 2>/dev/null; exit 0 ;;\n  "repo view --json url --jq .url") echo https://github.com/o/r; exit 0 ;;\n  "pr list "*) cat "%s/prs.json" 2>/dev/null || echo "[]"; exit 0 ;;\nesac\n"%s/bin/issues-json"\n' "$dir" "$dir" "$dir" >"$dir/bin/gh-base"
  printf '#!/usr/bin/env bash\nexec "%s/bin/gh-base" "$@"\n' "$dir" >"$dir/bin/gh"
  {
    printf '#!/usr/bin/env bash\ncd "%s" || exit 1\necho x >>calls\n' "$dir"
    # The background-wait ceiling this session was given (#22).
    printf 'echo "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}" >>bgwait\n'
    printf 'echo "${BACKLOG_LOOP_STAGED:-unset} ${BACKLOG_LOOP_ROOT:-unset}" >>staging-env\n'
    printf 'echo "${GH_REPO:-unset}" >>gh-repo-env\n'
    printf 'umask >>umask-seen\n'
    printf 'scripts/loop-lock.sh check >>check-out 2>&1; echo $? >>check-rc\n'
    if [ "$2" = block ]; then
      # Gives up after 30s so a failed test cannot leave it running.
      printf ': >started\ni=0; while [ ! -e go ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n'
    fi
    if [ "$2" = flaky ]; then
      # Fails its first call with recognisable output, then makes progress.
      printf 'if [ "$(wc -l <calls)" -eq 1 ]; then echo "first attempt boom"; exit 1; fi\necho "second attempt ok"\n'
    fi
    if [ "$2" = sabotage ]; then
      # What a branch switch can do to the checkout under a running driver (#25):
      # remove a script the driver needs and replace the driver itself.
      printf 'rm -f scripts/loop-lock.sh scripts/check-verify-section.sh\nprintf "#!/usr/bin/env bash\\nexit 99\\n" >scripts/backlog-loop.sh\n'
    fi
    if [ "$2" = steps ]; then
      printf 'n=$(wc -l <calls | tr -d " ")\n[ ! -f "step-$n" ] || . "./step-$n"\n'
    fi
    case "$2" in stall|steps) ;; *) printf 'echo $(( $(cat count) - 1 )) >count\n' ;; esac
    printf ': >finished\n'
  } >"$dir/bin/claude"
  chmod +x "$dir/bin/"* "$dir/scripts/"*
  echo "$dir"
}

run() { PATH="$1/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-$(basename "$1")" "$1/scripts/backlog-loop.sh" >"$1/out" 2>&1; }

# Wait up to 10s for file $1 to appear.
wait_for() {
  local i=0
  while [ ! -e "$1" ]; do
    [ "$i" -lt 100 ] || { echo "FAIL timed out waiting for $1" >&2; failures=$((failures + 1)); return 1; }
    sleep 0.1; i=$((i + 1))
  done
}

# A PID that is not running: a child that has already exited and been reaped.
dead_pid() { (exit 0) & local p=$!; wait "$p"; echo "$p"; }

P="$(setup progress progress)"
run "$P"; rc=$?
check "drains the backlog and exits 0" "[ $rc -eq 0 ]"
check "runs one item per remaining issue" "[ \$(wc -l <'$P/calls') -eq 3 ]"
check "the driver's own sessions pass the lock check" "[ \"\$(sort -u '$P/check-rc')\" = 0 ]"
check "releases the lock when it exits" "[ ! -e '$P/.git/backlog-loop.lock' ]"

S="$(setup stall stall)"
run "$S"; rc=$?
check "stops when an iteration makes no progress" "[ $rc -ne 0 ]"
check "does not retry a stalled loop" "[ \$(wc -l <'$S/calls') -eq 1 ]"
check "explains the no-progress stop" "grep -q 'no progress' '$S/out'"
check "releases the lock when it stops early" "[ ! -e '$S/.git/backlog-loop.lock' ]"

check "gives claude a 45-minute background-wait ceiling by default" "[ \"\$(head -1 '$P/bgwait')\" = 2700000 ]"

W="$(setup bgwait progress)"
BG_WAIT_SECONDS=60 run "$W"
check "BG_WAIT_SECONDS sets the ceiling (in ms)" "[ \"\$(head -1 '$W/bgwait')\" = 60000 ]"

# Bash arithmetic reads a leading zero as octal: 0600 would become 384s, 08 an error.
Z="$(setup zeropad progress)"
BG_WAIT_SECONDS=0600 run "$Z"
check "reads a zero-padded BG_WAIT_SECONDS as decimal" "[ \"\$(head -1 '$Z/bgwait')\" = 600000 ]"
E="$(setup eight progress)"
BG_WAIT_SECONDS=08 run "$E"; rc=$?
check "accepts 08 (not a bad octal number)" "[ $rc -eq 0 ] && [ \"\$(head -1 '$E/bgwait')\" = 8000 ]"

X="$(setup badwait progress)"
BG_WAIT_SECONDS=soon run "$X"; rc=$?
check "rejects a non-numeric BG_WAIT_SECONDS before any item" "[ $rc -ne 0 ] && [ ! -s '$X/calls' ]"

F="$(setup flaky flaky)"
BACKOFF_SECONDS=0 run "$F"; rc=$?
flogs="$WORK/logs-flaky"
check "a retried item still completes" "[ $rc -eq 0 ]"
check "keeps the failed attempt's log" "grep -l 'first attempt boom' '$flogs'/item-*.log >/dev/null"
check "writes the retry to its own log" "grep -l 'second attempt ok' '$flogs'/item-*.attempt2.log >/dev/null"
check "names the failed attempt's log in the retry message" "grep -q 'attempt 1 failed (log: ' '$F/out'"

# Logs hold whole session transcripts, so only the user who ran the driver may read
# them (#99). Each run sets umask 022, so the checks do not depend on this shell's.
mode() { ls -ldL "$1" | cut -c1-10; }
run_default() { PATH="$1/bin:$PATH" PACE_SECONDS=0 "$1/scripts/backlog-loop.sh" >"$1/out" 2>&1; }
L="$(setup privatelogs flaky)"
(umask 022; BACKOFF_SECONDS=0 run "$L"); rc=$?
llogs="$WORK/logs-privatelogs"
check "a LOG_DIR the driver creates is mode 700" "[ $rc -eq 0 ] && [ \"\$(mode '$llogs')\" = drwx------ ]"
check "its logs, a retry's included, are mode 600" "( n=0; for f in '$llogs'/item-*.log; do [ \"\$(mode \"\$f\")\" = -rw------- ] || exit 1; n=\$((n + 1)); done; [ \$n -ge 2 ] )"
check "its sessions keep the driver's umask" "[ \"\$(sort -u '$L/umask-seen')\" = 0022 ]"
D="$(setup defaultlogdir progress)"
mkdir -m 755 "$D/.loop-logs"
(umask 022; run_default "$D"); rc=$?
check "tightens an existing default .loop-logs to 700" "[ $rc -eq 0 ] && [ \"\$(mode '$D/.loop-logs')\" = drwx------ ] && ls '$D/.loop-logs'/item-*.log >/dev/null"
O="$(setup ownlogdir progress)"
mkdir -m 755 "$WORK/logs-ownlogdir"
(umask 022; run "$O"); rc=$?
check "leaves an existing LOG_DIR the operator chose as it was" "[ $rc -eq 0 ] && [ \"\$(mode '$WORK/logs-ownlogdir')\" = drwxr-xr-x ]"
check "but still writes its logs there as mode 600" "[ \"\$(mode \"\$(ls '$WORK/logs-ownlogdir'/item-*.log | head -1)\")\" = -rw------- ]"
check "and warns that the directory is not private" "grep -q 'logs-ownlogdir is not private to you' '$O/out'"
check "a private LOG_DIR gets no such warning" "! grep -q 'not private to you' '$L/out'"
NE="$(setup nestedlogdir progress)"
(umask 022; PATH="$NE/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/nested/a/logs" "$NE/scripts/backlog-loop.sh" >"$NE/out" 2>&1); rc=$?
check "creates a nested LOG_DIR, its leaf mode 700" "[ $rc -eq 0 ] && [ \"\$(mode '$WORK/nested/a/logs')\" = drwx------ ]"
# A file or symlink already at a log's name is never written through: the run stops
# and the target is untouched. The first attempt plants a symlink at the retry's
# log name, then fails, so the driver's next log name is the planted one.
PL="$(setup plantedlog steps)"
mkdir -m 700 "$WORK/logs-planted"
echo keep >"$WORK/victim"; chmod 644 "$WORK/victim"
printf 'f="$(ls "%s"/item-*.log)"\nln -s "%s" "${f%%.log}.attempt2.log"\nexit 1\n' "$WORK/logs-planted" "$WORK/victim" >"$PL/step-1"
PATH="$PL/bin:$PATH" PACE_SECONDS=0 BACKOFF_SECONDS=0 LOG_DIR="$WORK/logs-planted" "$PL/scripts/backlog-loop.sh" >"$PL/out" 2>&1; rc=$?
check "refuses a symlink planted at the log's name, leaving its target alone" "[ $rc -eq 1 ] && [ \$(wc -l <'$PL/calls') -eq 1 ] && [ -L \"\$(ls -d '$WORK/logs-planted'/item-*.attempt2.log)\" ] && [ \"\$(cat '$WORK/victim')\" = keep ] && [ \"\$(mode '$WORK/victim')\" = -rw-r--r-- ] && grep -q 'already there' '$PL/out'"
Y="$(setup linkedlogdir progress)"
mkdir -m 755 "$WORK/linked-target"
ln -s "$WORK/linked-target" "$Y/.loop-logs"
(umask 022; run_default "$Y"); rc=$?
check "does not chmod the directory a symlinked .loop-logs points at" "[ $rc -eq 0 ] && [ \"\$(mode '$WORK/linked-target')\" = drwxr-xr-x ]"
RF="$(setup filelogdir progress)"
: >"$RF/.loop-logs"; chmod 644 "$RF/.loop-logs"
run_default "$RF"; rc=$?
check "a regular file named .loop-logs stops the run, its mode untouched" "[ $rc -eq 1 ] && [ ! -s '$RF/calls' ] && [ \"\$(mode '$RF/.loop-logs')\" = -rw-r--r-- ] && grep -q 'not a directory' '$RF/out'"
DL="$(setup danglinglogdir progress)"
ln -s "$WORK/no-such-dir" "$DL/.loop-logs"
run_default "$DL"; rc=$?
check "a dangling .loop-logs symlink says it is not a directory" "[ $rc -eq 1 ] && [ ! -s '$DL/calls' ] && grep -q 'not a directory' '$DL/out'"
N="$(setup badlogdir progress)"
: >"$WORK/notadir"
PATH="$N/bin:$PATH" PACE_SECONDS=0 BACKOFF_SECONDS=0 LOG_DIR="$WORK/notadir/logs" "$N/scripts/backlog-loop.sh" >"$N/out" 2>&1; rc=$?
check "stops before any item when it cannot create LOG_DIR" "[ $rc -ne 0 ] && [ ! -s '$N/calls' ] && grep -q '✗.*notadir/logs' '$N/out' && ! grep -q 'attempt 1 failed' '$N/out'"
# A log it cannot create stops the run, not read as a failed session and retried.
# Root ignores the read-only mode, so the check needs a normal user.
if [ "$(id -u)" -ne 0 ]; then
  RO="$(setup readonlylogdir progress)"
  mkdir -m 555 "$WORK/logs-readonly"
  PATH="$RO/bin:$PATH" PACE_SECONDS=0 BACKOFF_SECONDS=0 LOG_DIR="$WORK/logs-readonly" "$RO/scripts/backlog-loop.sh" >"$RO/out" 2>&1; rc=$?
  check "stops before any item when it cannot create a log" "[ $rc -eq 1 ] && [ ! -s '$RO/calls' ] && grep -q 'cannot create the log ' '$RO/out' && ! grep -q 'attempt 1 failed' '$RO/out'"
fi

# The driver must not depend on the checkout its sessions change (#25).
B="$(setup sabotage sabotage)"
mkdir -p "$B/tmp"
TMPDIR="$B/tmp" run "$B"; rc=$?
check "survives its sessions replacing or deleting its scripts" "[ $rc -eq 0 ] && [ \$(wc -l <'$B/calls') -eq 3 ]"
check "releases the lock after its scripts vanished from the checkout" "[ ! -e '$B/.git/backlog-loop.lock' ]"
check "removes its private copy on exit" "[ -z \"\$(ls -A '$B/tmp')\" ]"
check "its sessions do not inherit the staging variables" "[ \"\$(sort -u '$B/staging-env')\" = 'unset unset' ]"

# An early exit (a bad setting, before the lock) must not leave the copy behind.
Q="$(setup earlyexit progress)"
mkdir -p "$Q/tmp"
TMPDIR="$Q/tmp" BG_WAIT_SECONDS=soon run "$Q"; rc=$?
check "an early exit removes the private copy too" "[ $rc -ne 0 ] && [ -z \"\$(ls -A '$Q/tmp')\" ]"

# Variables inherited from an outer driver must not skip staging or retarget it.
I="$(setup inherited progress)"
BACKLOG_LOOP_STAGED="$WORK" BACKLOG_LOOP_ROOT="$ROOT_OF_TEMPLATE" run "$I"; rc=$?
check "inherited staging variables do not redirect a nested driver" "[ $rc -eq 0 ] && [ \$(wc -l <'$I/calls') -eq 3 ] && [ ! -e '$I/.git/backlog-loop.lock' ]"

# P3 issues are worked once no P0-P2 issue is actionable (#45).
Q3="$(setup p3only progress)"
echo P3 >"$Q3/label"
run "$Q3"; rc=$?
check "works a backlog of only P3 issues" "[ $rc -eq 0 ] && [ \$(wc -l <'$Q3/calls') -eq 3 ]"
B3="$(setup blockedp2 progress)"
echo P3 >"$B3/label"; echo 1 >"$B3/count"
echo '[{"labels": [{"name": "P2"}, {"name": "blocked"}]}, {"labels": [{"name": "P1"}, {"name": "needs-attention"}]}]' >"$B3/extra.json"
run "$B3"; rc=$?
check "a blocked P2 and a needs-attention P1 do not hold back a P3" "[ $rc -eq 0 ] && [ \$(wc -l <'$B3/calls') -eq 1 ] && grep -q 'Backlog drained' '$B3/out'"

# The proposal gate (#13): an opted-out issue, or a proposal awaiting a human, is
# not remaining work; an approved proposal is.
G="$(setup gated stall)"
echo 0 >"$G/count"
echo '[{"labels": [{"name": "P1"}, {"name": "no-auto-heal"}]}, {"labels": [{"name": "P1"}, {"name": "heal:proposed"}]}, {"labels": [{"name": "P1"}, {"name": "no-auto-heal"}, {"name": "heal:approved"}]}]' >"$G/extra.json"
run "$G"; rc=$?
check "no-auto-heal (even with heal:approved) and an unapproved proposal are not remaining work" "[ $rc -eq 0 ] && [ \$(wc -l <'$G/calls') -eq 0 ] && grep -q 'Backlog drained' '$G/out'"
A="$(setup approved stall)"
echo 0 >"$A/count"
echo '[{"labels": [{"name": "P1"}, {"name": "heal:proposed"}, {"name": "heal:approved"}]}]' >"$A/extra.json"
run "$A"
check "an approved proposal is remaining work" "[ \$(wc -l <'$A/calls') -eq 1 ]"
H="$(setup approvedonly stall)"
echo 0 >"$H/count"
echo '[{"labels": [{"name": "P1"}, {"name": "heal:approved"}]}]' >"$H/extra.json"
run "$H"
check "heal:approved without heal:proposed is remaining work" "[ \$(wc -l <'$H/calls') -eq 1 ]"

# Follow-ups (#77): an in-review issue may have a PR Step 1.5 should work, so it
# keeps the driver running; the session, not the driver, decides whether it does.
DRAINED_LINE='✅ Backlog drained — no actionable issues remain.'
# No priority label: an in-review issue counts whatever its priority.
IN_REVIEW='[{"number": 10, "labels": [{"name": "in-review"}]}]'
pr_at() { printf '[{"number": 5, "headRefOid": "%s", "updatedAt": "%s"}]' "$1" "$2"; }

R1="$(setup reviewonly steps)"
echo 0 >"$R1/count"; echo "$IN_REVIEW" >"$R1/extra.json"
printf 'scripts/report-drained.sh >/dev/null\necho "Nothing to follow up."\n' >"$R1/step-1"
run "$R1"; rc=$?
check "runs a session while only in-review issues are open, whatever their priority" "[ \$(wc -l <'$R1/calls') -eq 1 ]"
check "a session that records the backlog drained ends the run with exit 0" "[ $rc -eq 0 ] && grep -q 'nothing left to work or follow up' '$R1/out'"

# The driver reads the marker, never the session's words: a model paraphrases its
# report (measured in backlog-loop#80's review), so prose cannot end a run as drained.
for form in "$DRAINED_LINE" "✅ The backlog is drained: no issues are ready for the loop to work."; do
  RF="$(setup "drainedwords-$(printf '%s' "$form" | cksum | cut -d' ' -f1)" steps)"
  echo 0 >"$RF/count"; echo "$IN_REVIEW" >"$RF/extra.json"
  printf 'cat <<'"'"'EOF'"'"'\nDone.\n%s\nEOF\n' "$form" >"$RF/step-1"
  run "$RF"; rc=$?
  check "a session that only says it is drained, with no marker, is no progress: $form" "[ $rc -eq 3 ] && grep -q 'no progress' '$RF/out'"
done

# A marker left by an earlier session must not end a later, stalled one as drained.
R7="$(setup stalemarker steps)"
echo 0 >"$R7/count"; echo "$IN_REVIEW" >"$R7/extra.json"
echo stale >"$(git -C "$R7" rev-parse --absolute-git-dir)/backlog-loop.drained"
run "$R7"; rc=$?
check "a stale marker from before the session is cleared, so a stall is still no progress" "[ $rc -eq 3 ] && grep -q 'no progress' '$R7/out'"
R8="$(setup failedmarker steps)"
echo 0 >"$R8/count"; echo "$IN_REVIEW" >"$R8/extra.json"
printf 'cd /  # report-drained.sh run outside the repo fails, so no marker\n/bin/sh -c "$OLDPWD/scripts/report-drained.sh" 2>/dev/null; cd "$OLDPWD"\n' >"$R8/step-1"
run "$R8"; rc=$?
check "a marker that could not be written leaves a stall as no progress (the safe side)" "[ $rc -eq 3 ] && grep -q 'no progress' '$R8/out'"

# A marker counts only when the session also changed nothing. Session 1 here writes
# it but also makes progress (one issue fewer), so the run must go on; session 2 then
# stalls without writing it, so the marker session 1 left must have been cleared.
R9="$(setup markerprogress steps)"
echo 1 >"$R9/count"; echo "$IN_REVIEW" >"$R9/extra.json"
printf 'scripts/report-drained.sh >/dev/null\necho $(( $(cat count) - 1 )) >count\n' >"$R9/step-1"
run "$R9"; rc=$?
check "a marker from a session that made progress does not end the run" "[ \$(wc -l <'$R9/calls') -eq 2 ]"
check "the marker is cleared before every session, so a later stall is no progress" "[ $rc -eq 3 ] && grep -q 'no progress' '$R9/out'"

# A marker from a failed attempt must not make a stalled retry of the same item
# read as drained: it is cleared before every attempt, not once per item.
R10="$(setup markerretry steps)"
echo 0 >"$R10/count"; echo "$IN_REVIEW" >"$R10/extra.json"
printf 'scripts/report-drained.sh >/dev/null\nexit 1\n' >"$R10/step-1"
BACKOFF_SECONDS=0 run "$R10"; rc=$?
check "a marker from a failed attempt is cleared before the retry, so a stalled retry is no progress" "[ \$(wc -l <'$R10/calls') -eq 2 ] && [ $rc -eq 3 ] && grep -q 'no progress' '$R10/out'"

R2="$(setup reviewskipped steps)"
echo 0 >"$R2/count"
echo '[{"number": 10, "labels": [{"name": "in-review"}, {"name": "needs-attention"}]}, {"number": 11, "labels": [{"name": "in-review"}, {"name": "blocked"}]}, {"number": 12, "labels": [{"name": "in-review"}, {"name": "no-auto-heal"}]}]' >"$R2/extra.json"
run "$R2"; rc=$?
check "in-review issues Step 1.5 skips start no session" "[ $rc -eq 0 ] && [ ! -s '$R2/calls' ] && grep -q 'Backlog drained' '$R2/out'"

R3="$(setup reviewidle steps)"
echo 0 >"$R3/count"; echo "$IN_REVIEW" >"$R3/extra.json"
run "$R3"; rc=$?
check "a session that neither drains nor changes anything stops the run (exit 3)" "[ $rc -eq 3 ] && [ \$(wc -l <'$R3/calls') -eq 1 ] && grep -q 'no progress' '$R3/out'"

# A follow-up leaves every label as it was (in-review -> in-progress -> in-review);
# only the PR shows it: a comment (updatedAt), then a pushed fix (headRefOid).
R4="$(setup followup steps)"
echo 1 >"$R4/count"; echo "$IN_REVIEW" >"$R4/extra.json"
pr_at a 2026-01-01T00:00:00Z >"$R4/prs.json"
printf "printf '%%s' '%s' >prs.json\n" "$(pr_at a 2026-01-02T00:00:00Z)" >"$R4/step-1"
printf "printf '%%s' '%s' >prs.json\n" "$(pr_at b 2026-01-02T00:00:00Z)" >"$R4/step-2"
# Then a label swap alone (the actionable P2 handed back as needs-attention, same
# number), then the in-review issue's PR merged, which leaves nothing to work.
echo 'echo needs-attention >label' >"$R4/step-3"
echo 'echo "[]" >extra.json' >"$R4/step-4"
run "$R4"; rc=$?
check "a follow-up that changes only a PR, or only a label, counts as progress" "[ $rc -eq 0 ] && [ \$(wc -l <'$R4/calls') -eq 4 ] && ! grep -q 'no progress' '$R4/out'"

# A setup refusal in Steps 3-3.7 claims and releases an issue: its updatedAt moves,
# its labels do not. That must still halt the run, or every item hits the refusal.
R5="$(setup touched steps)"
echo 0 >"$R5/count"
echo '[{"number": 7, "labels": [{"name": "P1"}], "updatedAt": "2026-01-01T00:00:00Z"}]' >"$R5/extra.json"
echo "echo '[{\"number\": 7, \"labels\": [{\"name\": \"P1\"}], \"updatedAt\": \"2026-01-02T00:00:00Z\"}]' >extra.json" >"$R5/step-1"
run "$R5"; rc=$?
check "an issue touched but left with the same labels is no progress" "[ $rc -eq 3 ] && [ \$(wc -l <'$R5/calls') -eq 1 ]"

# A stall that leaves unsaved work (#85): a session that ended its turn while its
# Verify still ran (#84) leaves edits or unpushed commits, which the driver names.
# These fixtures are committed, with the fake's own files excluded, so the tree is
# clean unless the session dirties it; origin/main stands in for a fetched remote.
NO_PROGRESS_OUT='✗ The last item made no progress'
committed_repo() { # committed_repo <name> <step-1 script>
  local dir; dir="$(setup "$1" steps)"
  echo 0 >"$dir/count"; echo "$IN_REVIEW" >"$dir/extra.json"
  printf '%s\n' "$2" >"$dir/step-1"
  printf '%s\n' calls bgwait staging-env gh-repo-env umask-seen check-out check-rc finished started out >>"$dir/.git/info/exclude"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm fixture
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" branch -q --set-upstream-to=origin/main main
  echo "$dir"
}
GIT_COMMIT='git -c user.name=t -c user.email=t@t commit -qm wip'
UNSAVED='unsaved work on'
U1="$(committed_repo unsaveddirty 'echo half-done >edit.txt')"
run "$U1"; rc=$?
check "a stall that leaves a dirty tree names its branch" "[ $rc -eq 3 ] && grep -qF 'the session ended with unsaved work on main: it may have ended its turn while a command still ran (#84)' '$U1/out'"
check "and names the session's log" "grep -q '^  Its log: $WORK/logs-unsaveddirty/item-.*\\.log' '$U1/out'"
check "and still explains the no-progress stop" "grep -qF '$NO_PROGRESS_OUT' '$U1/out'"
U2="$(committed_repo unsavedahead "echo more >edit.txt; git add edit.txt; $GIT_COMMIT")"
run "$U2"; rc=$?
check "a stall that leaves commits its upstream lacks names its branch" "[ $rc -eq 3 ] && grep -qF '$UNSAVED main:' '$U2/out'"
U3="$(committed_repo unsavedlocal "git switch -qc feat/9-x; echo more >edit.txt; git add edit.txt; $GIT_COMMIT")"
run "$U3"; rc=$?
check "a stall that leaves commits on a never-pushed branch names it" "[ $rc -eq 3 ] && grep -qF '$UNSAVED feat/9-x:' '$U3/out'"
U4="$(committed_repo unsavedclean ':')"
run "$U4"; rc=$?
check "a clean stall says nothing about unsaved work" "[ $rc -eq 3 ] && grep -qF '$NO_PROGRESS_OUT' '$U4/out' && ! grep -q 'unsaved work' '$U4/out'"
check "a clean stall prints what it printed before" "[ \"\$(sed -n '/no progress/,\$p' '$U4/out')\" = \"\$(printf '%s\n' \"$NO_PROGRESS_OUT: it changed no issue's labels and no PR,\" '  and did not record the backlog drained (scripts/report-drained.sh).' \"  Read its log in $WORK/logs-unsavedclean, fix the cause, and re-run.\")\" ]"
U6="$(committed_repo unsavednewbranch 'git switch -qc feat/9-y')"
run "$U6"; rc=$?
check "a clean stall on a never-pushed branch with no new commits says nothing" "[ $rc -eq 3 ] && ! grep -q 'unsaved work' '$U6/out'"
U5="$(committed_repo unsavedgitfails ':')"
printf '#!/usr/bin/env bash\n[ "$1" = status ] && exit 128\nexec %s "$@"\n' "$(command -v git)" >"$U5/bin/git"
chmod +x "$U5/bin/git"
run "$U5"; rc=$?
check "a check that cannot run says so, and still exits 3" "[ $rc -eq 3 ] && grep -q 'could not check for unsaved work' '$U5/out'"

R6="$(setup prsfail steps)"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "pr list" ] && exit 1\nexec "%s/bin/gh-base" "$@"\n' "$R6" >"$R6/bin/gh"
run "$R6"; rc=$?
check "stops before any session when the open PRs cannot be read" "[ $rc -eq 1 ] && [ ! -s '$R6/calls' ] && grep -q 'could not read' '$R6/out'"

N="$(setup noverify progress)"
printf '## Verify\n```sh\n# test:\n```\n' >"$N/CLAUDE.md"
run "$N"; rc=$?
check "refuses to start without Verify commands" "[ $rc -ne 0 ] && [ ! -s '$N/calls' ]"

# Preflight: a missing tool or a logged-out gh fails fast instead of backing off.
C="$(setup noclaude progress)"
rm "$C/bin/claude"
PATH="$C/bin:/usr/bin:/bin" PACE_SECONDS=0 BACKOFF_SECONDS=60 LOG_DIR="$WORK/logs-noclaude" \
  "$C/scripts/backlog-loop.sh" >"$C/out" 2>&1; rc=$?
check "refuses to start without claude on PATH" "[ $rc -ne 0 ] && grep -q 'claude not found' '$C/out'"

A="$(setup noauth progress)"
printf '#!/usr/bin/env bash\n[ "$1" = auth ] && exit 1\nexec "%s/bin/gh-base" "$@"\n' "$A" >"$A/bin/gh"
run "$A"; rc=$?
check "refuses to start when gh is not authenticated" "[ $rc -ne 0 ] && [ ! -s '$A/calls' ] && grep -q 'gh auth login' '$A/out'"

# Only the host origin points at counts (#15): bare `gh auth status` fails when any
# stored host has a stale token.
G="$(setup stalehost progress)"
git -C "$G" remote set-url origin https://ghe.example.com/o/r.git
printf '#!/usr/bin/env bash\n[ "$*" = "auth status --hostname ghe.example.com" ] && exit 0\n[ "$1" = auth ] && exit 1\nexec "%s/bin/gh-base" "$@"\n' "$G" >"$G/bin/gh"
run "$G"; rc=$?
check "a stale token for another host does not stop the loop" "[ $rc -eq 0 ] && [ \$(wc -l <'$G/calls') -eq 3 ]"

H="$(setup hostloggedout progress)"
git -C "$H" remote set-url origin https://ghe.example.com/o/r.git
printf '#!/usr/bin/env bash\n[ "$*" = "auth status" ] && exit 0\n[ "$1" = auth ] && exit 1\nexec "%s/bin/gh-base" "$@"\n' "$H" >"$H/bin/gh"
run "$H"; rc=$?
check "refuses to start when the repo's own host is logged out" "[ $rc -ne 0 ] && [ ! -s '$H/calls' ] && grep -q 'gh auth login --hostname ghe.example.com' '$H/out'"

# Several remotes and no gh default (#17): without a terminal gh would act on one
# it picks by name (upstream before origin), so the loop must not start.
R="$(setup ambiguous progress)"
git -C "$R" remote add upstream https://github.com/up/r.git
run "$R"; rc=$?
check "refuses to start when the repo is ambiguous" "[ $rc -ne 0 ] && [ ! -s '$R/calls' ] && grep -q 'gh repo set-default <owner/repo>' '$R/out'"
R2="$(setup chosen progress)"
git -C "$R2" remote add upstream https://github.com/up/r.git
echo o/r >"$R2/default"
run "$R2"; rc=$?
check "runs, naming the repo, once a gh default is set" "[ $rc -eq 0 ] && [ \$(wc -l <'$R2/calls') -eq 3 ] && head -1 '$R2/out' | grep -qx 'Working the backlog of o/r'"
# Every session's gh is pinned to that repo, host included (GHE), so a change to
# the remotes or the default mid-run cannot move the loop.
check "pins every session's gh to the repo it named" "[ \"\$(sort -u '$R2/gh-repo-env')\" = github.com/o/r ]"

# The local allowlist (#81): sync updates the example but never this machine's copy,
# so a rule added later is missing until someone copies it. Warn before any session,
# but run anyway: the operator may have dropped a rule on purpose.
allow_repo() { # allow_repo <name> <local allow rules as JSON, or "none" for no file>
  local dir; dir="$(setup "$1" progress)"
  mkdir -p "$dir/.claude"
  echo '{"permissions": {"allow": ["Bash(gh issue list *)", "Bash(scripts/report-drained.sh)"]}}' >"$dir/.claude/settings.local.json.example"
  [ "$2" = none ] || printf '%s\n' "$2" >"$dir/.claude/settings.local.json"
  echo "$dir"
}
AM="$(allow_repo allowmissing '{"permissions": {"allow": ["Bash(gh issue list *)", "Bash(make test)"]}}')"
run "$AM"; rc=$?
check "names each allow rule the local file lacks" "grep -q 'missing 1 allow rule' '$AM/out' && grep -qF 'Bash(scripts/report-drained.sh)' '$AM/out'"
check "warns before the first session" "[ \"\$(grep -n 'missing 1 allow rule' '$AM/out' | cut -d: -f1)\" -lt \"\$(grep -n '▶ \\[1/' '$AM/out' | cut -d: -f1)\" ]"
check "still runs with a rule missing" "[ $rc -eq 0 ] && [ \$(wc -l <'$AM/calls') -eq 3 ]"
check "does not name rules the local file has" "! grep -qF 'Bash(gh issue list *)' '$AM/out'"
AC="$(allow_repo allowcomplete '{"permissions": {"allow": ["Bash(make test)", "Bash(scripts/report-drained.sh)", "Bash(gh issue list *)"]}}')"
run "$AC"; rc=$?
check "a complete allowlist prints no warning" "[ $rc -eq 0 ] && ! grep -q 'allow rule\\|settings.local' '$AC/out'"
check "no example to compare with prints no warning" "! grep -q 'allow rule\\|settings.local' '$P/out'"
AI="$(allow_repo allowinvalid '{"permissions": ')"
run "$AI"; rc=$?
check "invalid local JSON gets a one-line warning" "[ \$(grep -c 'could not compare .claude/settings.local.json' '$AI/out') -eq 1 ] && [ \$(grep -c 'allow rule\\|settings.local' '$AI/out') -eq 1 ]"
check "invalid local JSON does not stop the run" "[ $rc -eq 0 ] && [ \$(wc -l <'$AI/calls') -eq 3 ]"
AN="$(allow_repo allownone none)"
run "$AN"; rc=$?
check "a missing local file gets a one-line warning" "[ \$(grep -c 'no .claude/settings.local.json' '$AN/out') -eq 1 ] && [ \$(grep -c 'allow rule\\|settings.local' '$AN/out') -eq 1 ]"
check "a missing local file does not stop the run" "[ $rc -eq 0 ] && [ \$(wc -l <'$AN/calls') -eq 3 ]"

# Behind the template (#73): a repo that runs the loop unattended hears it at
# start-up, without running setup.sh. The template is a local bare repo.
TSRC="$WORK/template-src"
git init -q -b main "$TSRC"
git -C "$TSRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
TOLD="$(git -C "$TSRC" rev-parse HEAD)"
git -C "$TSRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
TNEW="$(git -C "$TSRC" rev-parse HEAD)"
TBARE="$WORK/template.git"
git clone -q --bare "$TSRC" "$TBARE"
stamped_repo() { # stamped_repo <name> <stamp>
  local dir; dir="$(setup "$1" progress)"
  mkdir -p "$dir/.claude"
  echo "$2" >"$dir/.claude/template-version"
  echo "$dir"
}
TB="$(stamped_repo tvbehind "$TOLD")"
TEMPLATE_REPO="$TBARE" run "$TB"; rc=$?
check "behind the template: warns, naming both commits" "grep -qF '⚠ synced from template ${TOLD:0:7}; the template is now at ${TNEW:0:7}' '$TB/out'"
check "behind the template: says how to update" "grep -q 'Update: /backlog-loop:update' '$TB/out'"
check "behind the template: warns before the first session" "[ \"\$(grep -n 'the template is now at' '$TB/out' | cut -d: -f1)\" -lt \"\$(grep -n '▶ \\[1/' '$TB/out' | cut -d: -f1)\" ]"
check "behind the template: still runs" "[ $rc -eq 0 ] && [ \$(wc -l <'$TB/calls') -eq 3 ]"
TC="$(stamped_repo tvcurrent "$TNEW")"
TEMPLATE_REPO="$TBARE" run "$TC"; rc=$?
check "up to date with the template: no warning" "[ $rc -eq 0 ] && ! grep -q 'template' '$TC/out'"
check "no stamp: no template line" "! grep -q 'template' '$P/out'"
TU="$(stamped_repo tvunreachable "$TOLD")"
TEMPLATE_REPO="$WORK/no-such-template" run "$TU"; rc=$?
check "an unreachable template is a one-line warning" "[ \$(grep -c 'template' '$TU/out') -eq 1 ] && grep -q '⚠ could not reach' '$TU/out'"
check "an unreachable template does not stop the run" "[ $rc -eq 0 ] && [ \$(wc -l <'$TU/calls') -eq 3 ]"
# The check itself failing (a broken copy, say) still never stops the run.
TF="$(stamped_repo tvbroken "$TOLD")"
printf '#!/usr/bin/env bash\nexit 99\n' >"$TF/scripts/template-version.sh"
TEMPLATE_REPO="$TBARE" run "$TF"; rc=$?
check "a check that fails outright warns in one line and still runs" "[ $rc -eq 0 ] && [ \$(wc -l <'$TF/calls') -eq 3 ] && grep -qx '⚠ could not compare this repo with the template' '$TF/out'"

# --- the single-instance lock ---
# A lock a live process holds (this test script stands in for the other run).
L="$(setup livelock progress)"
mkdir "$L/.git/backlog-loop.lock" && echo $$ >"$L/.git/backlog-loop.lock/pid"
run "$L"; rc=$?
check "refuses to start while a live run holds the lock" "[ $rc -ne 0 ] && [ ! -s '$L/calls' ] && grep -q 'holds the lock' '$L/out'"
check "the refusal says how to clear a stale lock" "grep -qF 'rm -rf $L/.git/backlog-loop.lock' '$L/out'"
check "a refused run leaves the holder's lock in place" "[ \"\$(cat '$L/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $$ ]"

# A lock whose owner is gone.
D="$(setup deadlock progress)"
DEAD="$(dead_pid)"
mkdir "$D/.git/backlog-loop.lock" && echo "$DEAD" >"$D/.git/backlog-loop.lock/pid"
run "$D"; rc=$?
check "reclaims a lock whose owner is dead and runs" "[ $rc -eq 0 ] && [ \$(wc -l <'$D/calls') -eq 3 ]"
check "says it reclaimed the stale lock" "grep -qi 'stale' '$D/out' && grep -q 'PID $DEAD' '$D/out'"

# Two drivers with different LOG_DIRs, and a session started outside the driver.
T="$(setup twodirs block)"
PATH="$T/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-twodirs-a" "$T/scripts/backlog-loop.sh" >"$T/out-a" 2>&1 &
BG=$!
wait_for "$T/started"
check "the first driver is mid-item" "[ -e '$T/started' ] && [ ! -e '$T/finished' ]"
PATH="$T/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-twodirs-b" "$T/scripts/backlog-loop.sh" >"$T/out-b" 2>&1; rc=$?
check "a second driver with another LOG_DIR is refused" "[ $rc -ne 0 ] && grep -q 'holds the lock' '$T/out-b' && [ \$(wc -l <'$T/calls') -eq 1 ]"
check "the refused driver leaves the first one's lock in place" "[ \"\$(cat '$T/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $BG ]"
"$T/scripts/loop-lock.sh" check >"$T/out-i" 2>&1; rc=$?
check "a session outside the driver fails the lock check" "[ $rc -eq 1 ] && grep -q 'holds the lock' '$T/out-i'"
touch "$T/go"
wait "$BG"; rc=$?
BG=""
check "the first driver is unaffected and drains the backlog" "[ $rc -eq 0 ] && [ \$(wc -l <'$T/calls') -eq 3 ] && [ \"\$(sort -u '$T/check-rc')\" = 0 ]"

# kill -9 gives the driver no chance to release its lock.
K="$(setup hardkill block)"
PATH="$K/bin:$PATH" PACE_SECONDS=0 LOG_DIR="$WORK/logs-hardkill" "$K/scripts/backlog-loop.sh" >"$K/out-killed" 2>&1 &
BG=$!
wait_for "$K/started"
kill -9 "$BG"
wait "$BG" 2>/dev/null
check "a hard-killed driver leaves its lock behind" "[ \"\$(cat '$K/.git/backlog-loop.lock/pid' 2>/dev/null)\" = $BG ]"
KILLED=$BG
BG=""
# Let the orphaned fake claude finish, so the next run starts from a settled count.
touch "$K/go"
wait_for "$K/finished"
run "$K"; rc=$?
check "the next run reclaims a hard-killed driver's lock" "[ $rc -eq 0 ] && grep -qi 'stale' '$K/out' && grep -q 'PID $KILLED' '$K/out'"
check "and works the rest of the backlog" "[ \"\$(cat '$K/count')\" = 0 ]"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed" >&2; exit 1; fi
