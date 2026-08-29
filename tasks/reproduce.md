# Task: reproduce one community issue

You are attempting to reproduce a bug in a project someone else maintains. You
are **not** fixing it. The only question this run answers is: *does this bug
actually happen, and can I prove it?*

A reproduction is what separates a contribution the maintainer will thank you for
from noise they have to close. Getting this wrong wastes their time, which is the
one cost that matters here.

## Subject

- **Project:** {{REPO_NAME}} — `{{UPSTREAM}}` on GitHub
- **Worktree:** `{{REPO_PATH}}` (branch `{{BRANCH}}`, already checked out)
- **What it is:** {{REPO_SPEC}}
- **Issue:** {{TICKET_ID}} — {{TICKET_TITLE}}
- **Notes:** {{TICKET_NOTES}}
- **Run date:** {{DATE}}

### The project's contribution policy (`{{ETIQUETTE}}`)

```yaml
{{ETIQUETTE_CONTENT}}
```

You are not contributing anything this run, but if this file or the project's own
docs say autonomous agents may not contribute, say so in your report so the human
knows the fix stage must not run.

## What you are allowed to run

```
{{ALLOWED_COMMANDS}}
```

Those prefixes exactly. Setting up an unfamiliar project's environment is the
hard part of this task and the allowlist may not cover it. If you cannot install
dependencies or invoke the test runner, that is not a failure to hide — record
precisely which command you needed under *Blocked* and report the reproduction as
not attempted. Do not substitute reasoning for execution.

## The job

In order:

1. **Understand the claim.** Read the issue via `gh`. Extract the exact inputs,
   the expected behaviour, and the observed behaviour. If those three are not
   recoverable from the issue, stop — this issue was mis-scouted, say so.
2. **Get the project running.** Follow its own README/CONTRIBUTING. Confirm the
   existing test suite runs *before* you change anything, and record its state.
3. **Reproduce.** Trigger the bug. Observe the wrong behaviour yourself.
4. **Pin it with a failing test.** Write a test, in the project's own style, that
   fails *because of this bug*. Run it. See it fail. The failure message must
   describe the issue's symptom — not a setup error, not a missing import.

Step 4 is the deliverable. A prose description of a reproduction is not a
reproduction.

### Confirm you are testing *this worktree's* code

Every run happens in a git worktree, not the original checkout. If the project is
installed in development mode — `pip install -e`, `npm link`, a Gradle composite
build, a `cargo` path override — the language's import resolution points at the
**original checkout**, not at your worktree. Your edits then appear to have no
effect, and tests you just wrote fail against unmodified code.

Before trusting any test result, prove which source is loaded. In Python that is
`python3 -c "import <pkg>; print(<pkg>.__file__)"`; the equivalent exists in every
ecosystem. If it resolves outside this worktree, put the worktree first —
`pytest -o pythonpath=src`, `NODE_PATH`, and so on — and say in your report which
invocation you used and why.

Reporting "the suite fails" when the cause is that you tested a different copy of
the code is a false result, and it is indistinguishable from a real regression to
whoever reads the report.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files** read in full.
- **Do not fix the bug.** Not even a one-liner, not even if it is obvious and you
  are certain. The fix is a separate, human-gated stage with its own review. A
  reproduce run that contains a fix has destroyed the evidence that the test
  actually catches the bug.
- **Test files only.** Do not touch production code, configuration, or
  dependencies beyond what setup requires. If setup required changing something,
  say exactly what and why.
- **Do not contact the project.** No comments, no PRs, no reactions.
- **Never push, never open a PR, never switch branches, never commit.** Leave
  changes uncommitted; the runner commits the branch.
- **A failed reproduction kills the candidate, and that is a good outcome.** If
  you cannot reproduce it, stop and report. Do not widen the search, do not
  reproduce "something similar", do not conclude it is probably real. An issue
  that cannot be reproduced must not proceed to a fix.

## Falsifiability requirements

Report, with output you actually saw:

1. **Environment setup** — the exact commands, and whether each worked.
2. **Baseline suite** — the command and its result *before* your test existed.
   Record pre-existing failures verbatim; they are not yours and you must not
   silently inherit blame for them.
3. **The reproduction** — the command, and the wrong behaviour you observed.
4. **The failing test** — its name, the command, and the failure message, quoted.
5. **Confirmation the failure is the issue's symptom**, not incidental. Say how
   you know the difference.
6. **`git diff --stat`** proving only test files changed.

If any step did not happen, say so in that step's place. Never write output you
did not see.

## Output contract

Emit the report as your **final message**, as Markdown, and nothing else. The very
first characters must be `## Summary` — no preamble, no sign-off. Do not write it
to a file; the runner files it at `{{REPORT_PATH}}`.

```markdown
## Summary

One paragraph, and the first sentence must state plainly whether the bug
reproduced: `Reproduced.` or `Not reproduced.` Then what you did and what it
means for the next stage.

## Verdict

`REPRODUCED` or `NOT REPRODUCED` on its own line, then two or three sentences of
justification. A human reads this line to decide whether to mark the ticket
`specced: true`, so it must be unambiguous.

## Environment

- Setup commands, each with its result
- Baseline suite: the command, and green / the pre-existing failures verbatim
- Anything you had to change to get it running, and why

## Reproduction

What you ran, what you expected per the issue, what actually happened. Quote real
output. If not reproduced: what you tried, what happened instead, and your read
on why — stale issue, missing detail, environment-specific, or already fixed.

## Failing test

- **File and test name**
- **Command and the failure message**, quoted
- **Why this failure is the issue's symptom** and not an artefact of your setup
- `Not written.` if the bug did not reproduce.

## Analysis for the fix stage

Only if reproduced. Where the defect appears to live (`file:line`), the mechanism
as you understand it, and what a minimal fix would touch. This is a handoff note,
not a fix — do not write the patch.

## Blocked

What you could not do and the specific command or access you lacked. `None.` if
nothing.
```
