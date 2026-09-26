# Writing Issues

Issues are the unit of work in this repo. They can drive an autonomous backlog
loop, so each one must be a **self-contained work item**: a fresh contributor —
or an agent with no prior context — should be able to pick it up cold and finish
it without asking questions.

GitHub offers two templates when you open a new issue (**Feature** / **Bug**),
defined in [`.github/ISSUE_TEMPLATE/`](../.github/ISSUE_TEMPLATE). When creating
issues via `gh`, follow the same structure below.

## Principles

- **Self-contained.** Assume the reader has only the repo and this issue. Put the
  background in the issue; don't rely on chat history or tribal knowledge.
- **Observable done.** Acceptance criteria are checkable conditions, not vibes.
- **Approach before code.** Capture the chosen approach and the rejected
  alternatives (with the why) so the implementation isn't re-litigated.
- **Testable.** Every issue says how it will be validated.

## Anatomy (Feature)

| Section | What goes in it |
|---|---|
| **Context** | Why this is needed and the background to act on it. Constraints. Link related issues with `#NN`. |
| **Goal** | The outcome in 1–2 sentences — what "done" looks like from the user's view. |
| **Acceptance criteria** | Checkable, observable conditions (`- [ ]`). The definition of done. |
| **Implementation notes** | Proposed approach, key files, decisions and trade-offs. Flag `needs-infra` work. |
| **Out of scope** | What this issue deliberately does *not* cover, plus alternatives rejected. |
| **Testing** | Tests to add or run, plus manual / E2E steps and any deploy prerequisites. |

**Bug** issues add **Steps to reproduce** and **Expected vs actual** under
Context, and **Testing** names the regression test that keeps it from recurring.

## Title convention

Prefix with the conventional-commit type the work will use: `feat:`, `fix:`,
`refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`. The title reads as the
change, not the symptom — `feat: in-app account deletion`, not `add delete button`.

## Labels

This table is the definition of record. An agent working from a checkout never
sees GitHub's label descriptions, so if you add or change a label, change it here
too.

**Priority** (exactly one — the loop selects highest first):

| Label | Meaning |
|---|---|
| `P0` | Do first — blocker / release-critical |
| `P1` | High |
| `P2` | Medium |
| `P3` | Nice-to-have. Not selected by the loop. |

**Type:** `enhancement` or `bug`.

**Status** (the loop manages these; set manually only to steer):

| Label | Meaning |
|---|---|
| `in-progress` | Claimed and being worked |
| `in-review` | PR open, awaiting maintainer merge |
| `blocked` | Cannot proceed; skipped by the loop |
| `needs-infra` | Infra change written but must be applied by a human |
| `needs-attention` | Gave up after repeated attempts; needs a human |

<!-- Add repo-specific label families here (e.g. which surface a change ships to). -->

## Lifecycle

The loop takes the highest-priority actionable issue → claims it (`in-progress`)
→ branches `<type>/<n>-<slug>` → implements test-first until the **Verify**
commands in `CLAUDE.md` pass → opens a PR with `Closes #NN` **assigned** to the
maintainer (a sole maintainer cannot be review-requested on their own PR) →
swaps to `in-review`. It **never merges and never pushes to `main`**. Merge is
the maintainer's manual step.
