---
description: Work the single highest-priority open backlog issue end to end — branch, implement with TDD, verify, push, and open a PR assigned to the maintainer. Designed to be driven by /loop.
---

You are running one iteration of the autonomous backlog loop for this repository.
Do **exactly one** issue, then stop and report. `/loop` re-invokes this command for
the next item.

**Session-limit awareness (important).** A single Claude Code session has finite
context and usage limits. This iteration may be compacted, paused at a usage limit,
or killed (closed terminal) at any moment — possibly mid-issue. Therefore:

- **All loop state lives in git and GitHub labels — never in session memory.**
  Re-derive everything from `gh`/`git` each run; never assume context from a prior
  iteration survived.
- Keep the iteration **atomic and recoverable**: an interrupted run must be safely
  resumable on the next invocation, never orphaned. Step 0 reconciles half-done work
  before any new work begins.

## Hard guardrails (never violate)

- **Never merge.** Do not run `gh pr merge`, do not push to `main`. A push to
  `main` may deploy (see CLAUDE.md). Your job ends when the PR is open.
- **Never implement an issue whose premise you have not verified against the code**
  (Step 3.5). An issue is a claim, not a fact. Implementing a wrong diagnosis is worse
  than doing nothing: it ships a plausible PR that fixes nothing and closes the issue
  over a live bug. If the premise is false, say so, correct the issue, and re-plan.
- **Never scope the work from the issue's prose alone** (Step 3.6). Derive the affected
  set from the code and compare the issue against it. A true issue can still be an
  incomplete one; confirming its list can never reveal what the list omits.
- **One issue → one branch → one PR.** Never bundle multiple issues.
- **Never touch unrelated files.** Only change what the selected issue requires.
- **Skip `blocked` and `needs-infra` apply steps.** For `needs-infra` issues,
  write the infrastructure change but do **not** apply it; flag it for a human in
  the PR body.
- Follow the repo conventions in CLAUDE.md and the global rules: TDD, conventional
  commits, immutable patterns, no hardcoded secrets, comprehensive error handling.
- Prefer the Read/Grep/Glob/Edit/Write tools over shell `cat`/`grep`/`sed`/`find`.
  This loop runs headless under a tight bash allowlist; dedicated tools never need
  bash permission, so the iteration won't stall on a denied shell command.

## The repo contract (CLAUDE.md sections this command reads)

This command is shared across repos; everything repo-specific lives in the repo's
`CLAUDE.md`, under these headings:

| Section | Required | Used in |
|---|---|---|
| `## Verify` | **yes** | Step 5 gate, Step 6.5 re-check, Step 7 PR checklist |
| `## Definition of done` | no | Step 5 — extra checks beyond Verify (e.g. deploy-readiness) |
| `## Scope map` | no | Step 3.6 — where to enumerate the real affected surface |
| `## Specialist reviewers` | no | Step 6.5 — which `.claude/agents/` reviewer covers which paths |

**Before Step 0, run the checker and STOP if it fails:**

```bash
scripts/check-verify-section.sh CLAUDE.md
```

It fails when `## Verify` is missing or still a placeholder ("the loop has no
definition of green"), and when `CLAUDE.md` is claude-code-repo-template's own
instructions in a repo created from it: that Verify runs the template's tests, which
pass whatever this repo's code does. Report its message and stop. Never guess the
build or test commands.

**Then check that no other loop run is working this repo, and STOP if one is:**

```bash
scripts/loop-lock.sh check
```

`scripts/backlog-loop.sh` holds a lock for as long as it runs, and two runs sharing
one working tree would claim the same issue and edit the same files. A non-zero exit
means another run holds the lock, or the lock could not be checked: report the
message and stop. Never remove the lock yourself; the message tells the human how to
clear a stale one. The check passes when this session was started by the driver that
holds the lock, and it clears a lock whose owner is no longer running.

## GitHub access: `gh` locally, the GitHub MCP tools in the cloud

The GitHub steps below are written as `gh` commands. Cloud sessions (scheduled
routines) have **no `gh` CLI**; they reach GitHub through `mcp__github__*` tools
instead. Decide once, before Step 0:

```bash
git remote get-url origin
command -v gh && gh auth status --hostname <host>
```

`<host>` is the host in origin's URL: `github.com` in `https://github.com/o/r.git`
or `git@github.com:o/r.git`, the GitHub Enterprise host otherwise. For an SSH alias
from `~/.ssh/config`, use its real `HostName`. Never run a bare `gh auth status`:
it exits 1 when any account on any stored host has a stale token, even one this
repo never uses. With no origin, run it bare.

If that succeeds, run the `gh` commands as written. Otherwise do each GitHub
operation with the MCP tool in this table. Git itself (fetch, branch, commit, push)
works the same in both; take `owner`/`repo` from `git remote get-url origin`.

| Operation (as written below) | GitHub MCP equivalent |
|---|---|
| `gh issue list --label X …` | `mcp__github__list_issues` with state `OPEN` and labels `[X]`; page until a short page, since one call returns a single page |
| `gh issue view N` | `mcp__github__issue_read` (get) |
| `gh issue edit N --add-label A --remove-label R` | `mcp__github__issue_read` for the current labels, then `mcp__github__issue_write` (update) with the **complete** new set — current minus R plus A. The `labels` field **replaces** the whole set; passing only `[A]` silently deletes the priority and type labels. |
| `gh issue edit N --body …` / close | `mcp__github__issue_write` (update) with `body` / `state: closed` |
| `gh issue comment N --body …` | `mcp__github__add_issue_comment` |
| `gh pr list --state open …` | `mcp__github__list_pull_requests` with state `open` |
| `gh pr create --assignee @me …` | `mcp__github__create_pull_request` (base `main`, head = the branch), then `mcp__github__issue_write` (update) on **the PR's number** with `assignees: [<your login>]` from `mcp__github__get_me` — the create tool cannot assign, and a PR is an issue for this purpose |

Never use the MCP tools that merge, enable auto-merge, or write files or branches
through the API (`merge_pull_request`, `push_files`, `create_or_update_file`, …); the
committed settings deny them, and the guardrails above forbid what they do.

## Step 0 — Recover any interrupted iteration

A prior run may have died (context/usage limit, closed session) after claiming an
issue but before opening its PR. Reconcile before starting anything new. There should
be at most one `in-progress` issue:

```bash
gh issue list --state open --label in-progress --limit 1000 --json number,title \
  --jq '.[] | "\(.number)\t\(.title)"'
```

For that issue `#N`, find its branch (the convention is `<type>/<N>-<slug>`):

```bash
# Avoid shell grep/jq pipes so this runs under a tight headless allowlist —
# read the output and identify the branch / PR named `<type>/${N}-…` yourself.
git ls-remote --heads origin
git branch --list
git status --porcelain
gh pr list --state open --json number,headRefName,url
```

The branch reaches the remote only at Step 6, so a run interrupted in Steps 4–5 leaves
a **local-only** branch, possibly with uncommitted edits. Check local branches too.

Branches named `abandoned/<N>-<sha>` are work a give-up preserved for a human (see
**Give up**), never work in flight: always ignore them when looking for `#N`'s
branch. They outlive the attempt that made them, so they say nothing about the
current one.

Then:

1. **An open PR already exists from that branch** → the work finished but the label
   swap didn't. Just fix the state and move on to a new item:
   `gh issue edit ${N} --remove-label in-progress --add-label in-review`.
2. **A branch exists (remote or local-only) but no open PR** → work was underway.
   Resume *that* issue as this iteration (do not pick a new one). First, if an earlier
   run stopped in the middle of a merge (`git rev-parse -q --verify MERGE_HEAD` prints
   a hash; no output means none is in progress), abort it: git refuses to change
   branches during a merge, and its conflict markers must not be committed as work.
   The merges below redo it.
   ```bash
   git merge --abort
   ```
   Then check out the branch (fetch it first if it is remote-only; a local one keeps
   any uncommitted edits).

   A merge needs a clean tree, so if `git status --porcelain` lists anything, commit
   it first:
   ```bash
   git add -A
   git commit -m "wip: resumed edits (#${N})"
   ```
   If the branch exists both locally and on the remote, merge the pushed copy in, so
   commits that exist only there are kept even if the two have diverged:
   ```bash
   git pull --no-rebase --no-edit origin <type>/${N}-<slug>
   ```
   Then bring it up to date with `main`: other PRs may have merged while it sat, and a
   PR from a stale branch can be unmergeable. Merge, never rebase (the branch may
   already be pushed, and force pushes are denied):
   ```bash
   git fetch origin
   git merge --no-edit origin/main
   ```
   Either merge can conflict; both are handled the same way, below.
   If the fetch fails, stop and report it: never merge against a stale
   `origin/main`. If the merge fails without starting one (`git status --porcelain`
   lists no conflicted paths; for example, unrelated histories), there is nothing to
   abort: follow **Give up**, quoting the error.

   If the merge conflicts, resolve it when the conflict is within this issue's scope
   and Verify passes afterwards. Otherwise abort, and follow **Give up**, naming the
   conflicting files in the comment:
   ```bash
   git merge --abort
   ```
   Then bring it to green (Step 5's gate), then continue from Step 6 (commit/push,
   review, PR).
3. **Neither a branch nor a PR** → nothing was actually done; release the claim so the
   issue becomes selectable again: `gh issue edit ${N} --remove-label in-progress`.
   If `git status --porcelain` is non-empty here, the edits belong to no branch: stash
   them (`git stash push -u -m "orphaned edits for #${N}"`) so Step 1 starts clean,
   and mention the stash in your report.

Note: if an issue is labelled `in-review` but its PR is closed-unmerged, leave it —
that is a human signal, not loop work.

Proceed to Step 1 only once no resumable in-progress item remains.

## Step 1 — Clean base

```bash
git fetch origin
git switch main
git pull --ff-only
git status --porcelain
```

If `git status --porcelain` is **non-empty** (dirty working tree), STOP immediately.
Report: "Working tree is dirty — cannot start a clean iteration." Do not proceed.

## Step 2 — Select the next item

Pick the highest-priority actionable issue. In priority order `P0`, then `P1`,
then `P2` (always pass `--limit`: `gh` returns only 30 issues by default, which can
hide every actionable one behind newer in-review or blocked ones):

```bash
gh issue list --state open --label P0 --limit 1000 --json number,title,labels \
  --jq 'sort_by(.number)[] | {number, title, labels: [.labels[].name]}'
```

The first **actionable** issue is the one whose labels do **not** include any of:
`in-progress`, `in-review`, `blocked`, `needs-attention`. Take the first actionable
issue at the highest priority that has one; if `P0` has none, try `P1`, then `P2`.

If **no** actionable issue exists at any priority: report
"✅ Backlog drained — no actionable issues remain." and STOP. (This ends the loop —
do not schedule another iteration.)

Read the full body of the selected issue — its **Acceptance criteria** are the spec:

```bash
gh issue view <number> --json title,body
```

## Step 3 — Claim it

```bash
gh issue edit <number> --add-label in-progress
```

## Step 3.5 — Verify the issue's premise BEFORE writing code

**An issue is a claim, not a fact.** Issues are written by humans and agents from
logs, hunches, and half-memories, and a confidently-worded wrong diagnosis is the
single most dangerous input this loop can receive: it produces a plausible PR that
fixes nothing, a test that passes for the wrong reason, and a closed issue with the
bug still live.

This is not hypothetical. One issue stated the fix for an LLM repetition loop was to
set `temperature: 0`. It was **already 0**, on every call, and was 0 when the bug
occurred — the real cause was closer to the opposite (greedy decoding *causes*
repetition loops). Implementing that issue as written would have changed nothing and
shipped a green checkmark over a live bug.

So, before Step 4, **read the code the issue is about and confirm its factual claims**:

- Does the file/function/line it cites exist, and say what the issue says it says?
- Is the "fix" it proposes already in place?
- Does the described cause actually explain the described symptom?
- Do the acceptance criteria still make sense given what the code actually does?

Then act on what you found:

- **Premise holds** → proceed to Step 4.
- **Premise is wrong, but the underlying problem is real** → the *problem* is the work
  item, not the issue's prescription. Then, in order:
  1. **Say so.** Comment on the issue with what you checked, what you found, and why
     the stated cause is wrong — cite the file and line.
  2. **Correct the issue.** Edit the body so the Context and Implementation notes
     describe the *real* cause. Leave the issue accurate for the next reader; a wrong
     issue left standing will mislead the next agent exactly as it nearly misled you.
  3. **Re-plan** against the real cause and continue.
  4. Repeat the correction in the PR body, so the reviewer knows the issue moved.
- **Premise is wrong and there is no problem** (already fixed, or misread) → do not
  invent work to justify the issue. Comment with the evidence, remove `in-progress`,
  close it or drop it to the correct label, and move to the next item.

Treat an issue's "Implementation notes" as a *suggestion from someone who may not have
read the code recently* — never as a specification. The acceptance criteria are the
contract; the proposed approach is not — but the contract may itself be incomplete,
which is what Step 3.6 is for.

## Step 3.6 — Check the issue for COMPLETENESS, not just truth

Step 3.5 asks *"is what the issue says true?"* This step asks the opposite question:
**"what does the issue fail to say?"** An issue can be entirely accurate and still be
missing half the work. Verifying a claim and generating the full scope are different
operations, and only the second one catches an omission.

This is not hypothetical either. An "audit log of admin actions" issue named six admin
mutations. There were **seven** — the prose omitted the delete endpoint, the most
destructive in the set, so a proposal that checked each named endpoint against the code
confirmed all six and never noticed the gap. The same issue said "disable/**enable**
user" when no enable endpoint existed. Prose-anchored enumeration produces both
phantoms and blind spots.

Run these four checks before Step 4. They are deliberately mechanical — do not rely on
judgment where a command will do.

**1. Derive the affected surface from the code, never from the issue's prose.**
Enumerate the real set first, then compare it to the issue's list — not the reverse.
Confirming someone else's list can only validate what is on it.

CLAUDE.md `## Scope map` says where this repo's surfaces are enumerated (route
tables, handler directories, page registries). Without one, find the registry the
issue's category lives in — the route table, the command list, the page index — and
enumerate from it, never from the issue's list.

If the code's set is bigger than the issue's, **the code wins** — implement the full
set and say so in the PR body. If it is smaller, the issue names something that does
not exist; treat that as a Step 3.5 premise failure.

**2. Every acceptance criterion must name a concrete artifact.**
For each `- [ ]`, write down the file(s) that will satisfy it. An AC you cannot map to
an artifact is an AC you are about to skip. Watch for criteria phrased in user terms —
"an admin can view X" is satisfied by a **page**, not by the endpoint that feeds it.
Check the Scope map for label meanings that narrow or widen scope.

**3. The Testing section is a floor, not a ceiling.**
Scale coverage to what you actually touched. If an issue says "a test asserting X for a
representative case" and you changed seven call sites, write a table-driven test over
all seven — six untested call sites can regress silently and the issue's author was
estimating, not specifying. Also add the negative case: the behavior must **not** happen
on the failure path.

**4. A new side effect on an existing success path needs stated failure semantics.**
If you are adding a write, an enqueue, or an external call to a path that already
succeeds, answer explicitly: what happens when the new thing fails? Usually the answer
is "log it and let the original operation succeed" — a logging table must not turn a
working delete into a 500. Whatever you choose, state it in the PR body and cover it
with a test.

**If any check turns up a gap, correct the issue body before implementing** (same
mechanism as Step 3.5): edit it so the scope is accurate, note what you added in a
comment, and carry the correction into the PR body. Leave the issue correct for the
next reader.

## Step 4 — Branch

Derive the type from the issue title prefix (`feat`/`fix`/`refactor`/`docs`/`chore`)
and a short kebab-case slug from the title (drop the prefix, ~5 words max):

```bash
git switch -c <type>/<number>-<slug>
# e.g. fix/19-audit-burger-restaurant-exclusion
```

## Step 5 — Implement with TDD

1. Translate the issue's acceptance criteria into tests **first** (RED), following
   any testing notes in CLAUDE.md. Mock external services rather than calling them.
2. Implement the minimal code to satisfy them (GREEN), then refactor.
3. The change is **done** only when every command in CLAUDE.md `## Verify` that
   applies to the changed paths passes locally, **and** every check in
   `## Definition of done` (if present) is satisfied and recorded in the PR body.
   Run the commands exactly as written; do not substitute or skip one because it is
   slow. If Verify marks a command as needing something this runner lacks (e.g.
   Docker), follow its stated fallback and say so in the PR body.
4. Do a quick self-review of your diff against the repo's code-quality checklist
   (small functions, error handling, no secrets, no debug prints) before shipping.

**Give-up condition:** if after a focused effort (~3 substantial implement+test
cycles) it still isn't green, follow **Give up** at the end of this file. Do not
assume nothing is committed: a branch resumed by Step 0 may hold commits, and may
already be on the remote. Then report what blocked you and STOP.

## Step 6 — Commit & push

Conventional commit referencing the issue:

```bash
git add -A
git commit -m "<type>: <concise description> (#<number>)"
git push -u origin <type>/<number>-<slug>
```

Push now, before review: Step 0 can only recover a branch that exists on the remote.

## Step 6.5 — Specialist review before the PR

The self-review in Step 5 checks the general checklist; this step adds stack-specific
reviewers. CLAUDE.md `## Specialist reviewers` maps changed paths to agents in
`.claude/agents/` (committed to the repo, because cloud sessions do not load
plugins). If that section is absent, skip this step. List what the branch changed:

```bash
git diff --name-only main...HEAD
```

Launch each reviewer whose paths match as an agent (in parallel when several apply),
giving it the issue number, the acceptance criteria, and the changed-file list.

If none applies, skip this step. If an agent is unavailable in this runner, say so in
the PR body rather than skipping silently.

Act on the findings:

- **CRITICAL / HIGH:** fix, re-run the Step 5 gate (the Verify commands), and commit as `fix: address review findings (#<number>)`. One fix round only: if
  a CRITICAL finding still stands after it, follow **Give up** at the end of this
  file, naming the surviving finding in the comment. It also removes the branch you
  pushed in Step 6, so it is not orphaned.
- **MEDIUM / LOW:** don't fix unless trivial and inside the issue's scope (the
  "never touch unrelated files" guardrail still applies). List them in the PR body.
- **A finding you judge wrong:** don't act on it; record it with a one-line reason in
  the PR body. An agent's report is a claim, like an issue (Step 3.5).

If you committed fixes, push them before Step 7 with
`git push origin <type>/<number>-<slug>`. Always name the branch: a bare `git push` is
denied in `.claude/settings.json`, because on `main` it would push to `main`.

## Step 7 — Open the PR (assigned, not reviewer)

GitHub forbids requesting review from your own PR's author, so assign instead:

```bash
gh pr create --base main \
  --title "<type>: <issue title>" \
  --assignee @me \
  --body "$(cat <<'PRBODY'
## Summary
<what changed and why, 1–3 sentences>

## Changes
- <bullet>
- <bullet>

## Testing
- [x] <each Verify command that ran, one per line, exactly as run>
- <Definition of done checks and their outcome, if the section exists>
- <manual verification steps, if any>

## Specialist review
<!-- From Step 6.5. Omit this section if no reviewer applied. -->
- Reviewers run: <agent names>
- Fixed: <CRITICAL/HIGH findings addressed, or "none">
- Not fixed: <MEDIUM/LOW findings, or disputed ones with a one-line reason>

<!-- For needs-infra issues, add: -->
## ⚠️ Manual step required
Infrastructure changes are included but NOT applied. <exact command to apply, per
CLAUDE.md> before this takes effect.

Closes #<number>
PRBODY
)"
```

## Step 8 — Update state & report

```bash
gh issue edit <number> --remove-label in-progress --add-label in-review
```

Report concisely: issue number + title, branch, PR URL, and test results. If any
actionable issues remain, the loop will continue to the next one.

## Give up — keep the work, then release the issue

Steps 5 and 6.5 both end here. The branch may be in any state: fresh, resumed by
Step 0 with commits, local-only, or already pushed. Giving up must never destroy
work silently, and must not leave the issue's branch on the remote. So: save the
work, then release the issue, then delete branches. An interruption after the
release can only leave a stray branch that the comment already names, never an
issue that still looks claimed or that has lost its explanation.

**Check every command's result.** If step 1 or 2 fails, the work is not saved: do
step 3, saying so, and delete nothing (leave the branch checked out as it is). If
step 3 fails (the comment or the label swap), delete nothing either: the issue
would look claimed, or unexplained, with its work gone. Stop and report it. If
step 4 or 5 fails, the work is already saved: add a comment naming what is left,
so a human removes it. Never get past a failure with `--no-verify` or `--force`.

Run these on the issue's branch, `<type>/<number>-<slug>`.

1. **Commit anything uncommitted**, so it travels with the branch. A stash would stay
   on this machine, and a cloud session's clone is discarded. First make sure a merge
   from Step 0 is not half done: committing it would save conflict markers as if they
   were work. A merge is in progress only if this prints a hash. No output (exit 1)
   means no merge is in progress, which is the normal case, not a failure:
   ```bash
   git rev-parse -q --verify MERGE_HEAD
   ```
   If it does, abort the merge, and say in the comment that the merge was abandoned.
   (Abort only then: a line of `=======` can look like a conflict marker in a file
   that is not being merged, and aborting with no merge in progress fails.)
   ```bash
   git merge --abort
   ```
   Then, if `git status --porcelain` still lists anything:
   ```bash
   git add -A
   git commit -m "wip: uncommitted work at give-up (#<number>)"
   ```
2. **Save any commits** that are not on `main`, under a name no later run reuses:
   ```bash
   git log --oneline origin/main..HEAD
   git log -1 --format='%h %H'
   ```
   If the first command lists commits, push them, using the short hash from the
   second:
   ```bash
   git push origin HEAD:refs/heads/abandoned/<number>-<short-sha>
   ```
   If that push fails, the work is not saved: follow the rule above.
3. **Release the issue.** The comment must say, truthfully:
   - **Why:** the blocker, in a sentence.
   - **Where the work is:** `abandoned/<number>-<short-sha>` with the full hash, or
     "no commits to keep". If a save failed, say what failed and that the work
     exists only in this checkout (its path and tip hash). In a cloud session that
     checkout is discarded when the session ends, so say the work will be lost
     unless someone saves it first. Never call it safe.
   - **What happens next**, one of:
     - the save worked: `<type>/<number>-<slug>` is being deleted, locally and on
       the remote (unless the remote copy holds commits not saved here; step 4 then
       keeps it and says so), and if it still exists, delete it before retrying the issue (a
       retry needs the name, and its work is on `abandoned/…`);
     - the save failed: nothing was deleted.
   ```bash
   gh issue comment <number> --body "Autonomous loop could not complete this. Blocker: <concise reason>. Work: <where it is>. Next: <what happens next>."
   gh issue edit <number> --remove-label in-progress --add-label needs-attention
   ```
4. **Remove the issue's branch from the remote**, if it is there and holds nothing
   that was not saved. Nothing revisits a released issue, so a branch left here would
   be orphaned; but it may hold commits that never reached this checkout (a pushed copy
   that diverged, or a pull that failed or was aborted). So first prove that every
   commit on it is already in `HEAD`, which step 2 saved. The first command prints the
   remote branch's hash, if it exists; the second must succeed and print nothing:
   ```bash
   git ls-remote --heads origin <type>/<number>-<slug>
   git log --oneline HEAD..<remote-hash>
   ```
   Only then delete it:
   ```bash
   git push origin --delete <type>/<number>-<slug>
   ```
   If the second command prints commits, or fails (those commits were never fetched),
   keep the remote branch: it is the only copy of them. Say so in a follow-up comment,
   naming the branch, so a human can look at it.
5. **Delete the local branch.** Its commits are safe on `abandoned/…` (or there were
   none), and a retry needs the name free:
   ```bash
   git switch main
   git branch -D <type>/<number>-<slug>
   ```
