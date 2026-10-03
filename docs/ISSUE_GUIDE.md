# Writing Issues

Issues are the unit of work in this repo. They can drive an autonomous backlog
loop, so each one must be a **self-contained work item**: a fresh contributor —
or an agent with no prior context — should be able to pick it up cold and finish
it without asking questions.

GitHub offers two issue forms when you open a new issue (**Feature** / **Bug**),
defined in [`.github/ISSUE_TEMPLATE/`](../.github/ISSUE_TEMPLATE). The forms make
Context, Goal, Acceptance criteria, and Testing required, and each section becomes
a `### <Section>` heading in the issue body. They cannot set a priority label, so
add one after creating the issue. When creating issues via `gh` or the API, write
the body with the same headings.

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
too, and in `scripts/seed-labels.sh`, which creates them.

**Priority** (exactly one — the loop selects highest first):

| Label | Meaning |
|---|---|
| `P0` | Do first — blocker / release-critical |
| `P1` | High |
| `P2` | Medium |
| `P3` | Nice-to-have. Selected only when no `P0`–`P2` issue is actionable. |

**Type:** `enhancement` or `bug`.

**Status** (the loop manages these; set manually only to steer, except `changes-requested`, which is yours):

| Label | Meaning |
|---|---|
| `in-progress` | Claimed and being worked |
| `in-review` | PR open, awaiting maintainer merge |
| `changes-requested` | Set by the maintainer **on the PR**: the loop reads the changes from the PR's comments and reviews (by its author or assignees only), makes them, and removes the label. A label, because GitHub does not let a PR's author request changes on their own PR. |
| `blocked` | Cannot proceed; skipped by the loop |
| `needs-infra` | Infra change written but must be applied by a human |
| `needs-attention` | Gave up after repeated attempts; needs a human |

**Proposal gate** (used when the Proposal gate section of `CLAUDE.md` turns it on):

| Label | Meaning |
|---|---|
| `heal:proposed` | The loop posted a proposal comment and is waiting for a human. Skipped until `heal:approved` is added. |
| `heal:approved` | A human approved the proposal; the loop may implement it and open a PR. |
| `no-auto-heal` | Never selected by the loop: work a human keeps, such as infrastructure or the loop's own plumbing. |

The label that marks machine-filed issues, which skip the proposal, is per repo
(for example source:worker-dlq from a triage agent). Name it in `CLAUDE.md`, not here.

**Repo-specific families.** A repo can add its own family, such as which surface
a change ships to. Define it here before anyone relies on it, giving each label
its meaning, and add a "commonly misread as" line for any label whose name invites
a wrong reading: a misread label quietly drops acceptance criteria from the work.
Paste this example out of its fence and adapt it:

```markdown
**Surface** (exactly one — what has to ship when this merges):

| Label | Meaning |
|---|---|
| `surface-none` | No mobile app change. Server, admin web app, CI, and docs changes all qualify. |
| `surface-ota` | Mobile change that ships as an over-the-air update |
| `surface-store` | Mobile change that needs a new store build |

> **Commonly misread as:** `surface-none` read as "no UI change". The admin web
> app is UI and is in scope: an issue labelled `surface-none` can still have UI
> acceptance criteria. (A name like `mobile-none` would not invite the misreading.)
```

Then:

- Create the labels in GitHub with gh label create. Do not add them to
  `scripts/seed-labels.sh`: it is managed, so the next sync overwrites it. It
  never deletes labels, so yours survive a re-seed.
- Name the family in the Scope map section of `CLAUDE.md`, so the loop knows
  which labels narrow or widen an issue's scope.

In backlog-loop itself, a standard label goes in both
`scripts/seed-labels.sh` and the tables above. `scripts/test-labels.sh` fails
when they differ; it skips fenced blocks, like the example.

## Lifecycle

The loop takes the highest-priority actionable issue → claims it (`in-progress`)
→ branches `<type>/<n>-<slug>` → implements test-first until the **Verify**
commands in `CLAUDE.md` pass → opens a PR with `Closes #NN` **assigned** to the
maintainer (a sole maintainer cannot be review-requested on their own PR) →
swaps to `in-review`. It **never merges and never pushes to `main`**. Merge is
the maintainer's manual step.
