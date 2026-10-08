---
description: Draft a loop-ready issue from a one-line idea — read the code, check for duplicates, show the draft, and file it only once you approve.
---

You are turning a one-line idea into an issue that `/work-next-item` can pick up
cold (#72). You draft; the user decides. **Nothing is filed until the user approves
the draft in a later message**, and you never start the work: no branch, no code,
no claim, no PR.

**The idea:** `$ARGUMENTS`. If it is empty, ask for one and stop.

## Step 1 — Read the rules

Read `docs/ISSUE_GUIDE.md` (what each section holds, the title convention, the
labels and their meanings) and this repo's `CLAUDE.md`, in particular its Scope map
(what counts as in scope, and any repo-specific label family) and its Definition of
done (what a change must update besides the code, which belongs in the acceptance
criteria).

## Step 2 — Check for duplicates

Search open and closed issues before reading any code. Try two or three phrasings
of the idea (its key nouns, the file or command it names, a synonym):

```bash
gh issue list --state all --limit 20 --search "<keywords>" --json number,title,state,closedAt
```

Read the body of any result whose title looks close (`gh issue view <n>`). If one
already asks for the same change, it is a **likely duplicate**: do not draft. Report
it (number, title, state, and why it matches) and stop. A closed duplicate is still
one: say whether it was fixed or declined, so the user can reopen it instead. Keep
partial overlaps for the draft's Context, linked as `#NN`.

## Step 3 — Read the code

Find what the idea touches: search for the files, functions, commands, and tests
involved, and read them. Every path you cite in the draft must exist; cite what
you read, not what you expect. If the idea rests on a premise the code contradicts
(the bug is already fixed, the option already exists), say so instead of drafting
around it, and stop.

## Step 4 — Draft it

**Pick the form.** A defect is a bug, anything else a feature. Read the matching
form in `.github/ISSUE_TEMPLATE/` (`bug.yml` or `feature.yml`): its body's `label:`
fields, in order, are the sections, each written as a `### <label>` heading (exactly
three `#`, as the form itself produces; never `## `), and its `labels:` line is the type label (`enhancement` or `bug`). Take the headings
from the form every time; never from memory, since the forms are the place of
record and may differ in this repo.

**Write each section** as the guide describes, so a reader with only the repo and
the issue can finish it:

- Context cites the real paths you read and the reason for the change.
- Acceptance criteria are checkable `- [ ]` items, including what the Definition of
  done requires.
- Implementation notes name the approach, the key files, and the alternatives you
  rejected, with why.
- Out of scope is explicit.
- Testing names the tests to add, and for a bug the regression test.

**Title:** the conventional-commit type the work will use, then the change, as the
guide says (`feat: …`, `fix: …`).

**Labels:**

- the form's type label;
- **exactly one priority**, `P0`, `P1`, `P2`, or `P3`, by the guide's table, with a
  one-line reason. It is a proposal: the user confirms it;
- `no-auto-heal` when the change touches `.claude/`, which a headless loop session
  cannot write, and for any work the guide reserves for a human;
- a repo-specific label only when the Scope map defines its family.

## Step 5 — Show the draft and stop

Show the whole draft: title, labels, the priority's reason, and the body exactly as
it would be filed. Below it, list any near-matches from Step 2 that you judged not
to be duplicates. Then ask the user to approve it, change it, or drop it, and
**end your turn**. Do not file in this turn, even if the draft looks certain.

Run headless (`claude -p`, a routine, or the backlog driver), there is no one to
approve: the turn ends here, so this prints the draft and files nothing.

## Step 6 — File it, once approved

Only when the user's reply approves the draft. If they asked for changes, make them,
show the new draft, and end your turn again (Step 5). If they dropped it, stop.

File the approved text exactly, with one `--label` for every label the approved
draft shows, `no-auto-heal` and any repo label included (the brackets below mark
the optional ones; drop the brackets, not the labels). The body goes through
standard input, so no temporary file is left behind and nothing in it is expanded
by the shell:

```bash
gh issue create --title "<title>" --label <type> --label <priority> [--label no-auto-heal] [--label <repo label>] --body-file - <<'ISSUE_BODY'
<body>
ISSUE_BODY
```

This needs the user's permission: the unattended allowlist leaves it out on
purpose, so a loop session can never file an issue. If it is refused (a headless
session, or the user declined the prompt), file nothing else and offer the two ways
on: approve the prompt in an interactive session, or run the command themselves
with the approved body. Never suggest adding `gh issue create` to any allow list:
that would let every unattended session file issues. If it fails, report the error.
A missing label usually means the repo's labels were never created: suggest
`scripts/seed-labels.sh`. Then print the new issue's URL, and say what happens next:
with `no-auto-heal`, the loop never takes it, so it is the user's to work; with the
Proposal gate on in `CLAUDE.md`, the loop first posts a proposal and waits for
`heal:approved`; otherwise the loop picks it up on its own, by priority. Stop there.
