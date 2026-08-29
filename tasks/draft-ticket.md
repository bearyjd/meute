# Task: draft a fix for one specced ticket

You are fixing one known defect in one repository, unattended. A human marked
this ticket `specced: true`, which means they judged it well-enough understood to
act on. Your work lands on a throwaway branch that a human reviews before
anything reaches the default branch.

This is the highest-risk task in the fleet: you are changing production code with
nobody watching. The discipline below is what makes that acceptable.

## Subject

- **Repository:** {{REPO_NAME}} (worktree at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Branch you are on:** `{{BRANCH}}` (already checked out; do not switch branches)
- **Base:** `{{DEFAULT_BRANCH}}`
- **Run date:** {{DATE}}

### The ticket

- **ID:** {{TICKET_ID}}
- **Title:** {{TICKET_TITLE}}
- **Notes from the human:**

{{TICKET_NOTES}}

## The job

Make the smallest correct change that fixes exactly this ticket, with a test that
proves it.

The order is not negotiable:

1. **Reproduce first.** Write a test that fails *because of this defect*, and run
   it. You must see it fail, and the failure must be the one the ticket
   describes — not an import error, not a missing fixture, not a typo in your own
   test. Record the failure output.
2. **Then fix.** Change production code until that test passes.
3. **Then check you did not break anything else.** Run the full suite.

If you cannot complete step 1, **stop and change nothing.** Report why under
*Not reproduced* and leave the worktree clean. This is the single most important
rule in this file. An unattended agent that cannot reproduce a bug will, if
allowed, produce a plausible-looking change that fixes nothing and buries the
real defect under a diff that looks like progress. A run that reports "I could
not reproduce this, here is exactly what I tried" is a *successful* run. A run
that guesses is a failed one, even when it looks productive.

The ticket may also be wrong — the human wrote it from a report, possibly weeks
ago, possibly about code that has since changed. If the premise no longer holds,
say so and stop. You are not obliged to find something to fix.

## What you are allowed to run

This session is unattended: **no one can approve a command for you.** These
command forms are pre-approved and are the only ones that will run — anything
else is denied outright, and retrying a denied command with a different spelling
wastes the run:

```
{{ALLOWED_COMMANDS}}
```

Match those prefixes exactly. If the test runner you need is not on that list,
you cannot complete step 1 — report that under *Not reproduced*, name the exact
command you needed, and stop. Do not fix without a reproduction.

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

- **File budget: {{FILE_BUDGET}} files.** Read at most that many in full. Grep,
  `git log`, and directory listings are free.
- **Fix this ticket and nothing else.** If you notice other defects, record them
  in one line each under *Sightings*. Do not fix them. A reviewer who asked for
  one fix and received five cannot review any of them.
- **Smallest correct diff.** No refactoring, no renaming, no reformatting, no
  tidying of surrounding code, no dependency changes, no "while I was here".
  Every line in your diff must be load-bearing for this ticket.
- **Do not weaken tests.** If an existing test fails after your change, the change
  is wrong until proven otherwise. Deleting or loosening an assertion to get green
  is a failed run — report the conflict instead.
- **Never push, never open a pull request, never switch or create branches, never
  commit.** Leave your changes uncommitted in the worktree; the runner commits the
  branch itself. Submission is a human decision made later.
- If the fix turns out to need broad architectural change, stop. Report what it
  would take under *Blocked*. Tier 3 is for contained fixes.

## Falsifiability requirements

A passing test proves nothing on its own if it never failed. For the fix you MUST
report, with real output you actually saw:

1. **The reproduction failing before the fix** — the test, the command, and the
   failure message. The message must describe the ticket's symptom.
2. **The same test passing after the fix** — same command, its output.
3. **The full suite before and after** — so a reviewer knows what you inherited
   versus what you caused. Record pre-existing failures verbatim; they are not
   yours to fix, and pretending they don't exist makes your run unreviewable.
4. **The diff** — `git diff --stat`, and confirmation that every changed file is
   necessary for this ticket.

Do not paraphrase output you did not see. If you could not run something, say so
plainly. Fabricated terminal output is the worst possible failure of this task:
it is the one error a reviewer cannot catch by reading the diff.

### Prove the guard you added can fail

Red-green on the reproduction shows your test is sensitive to *this* defect. It
does not show the guard you added would catch the same defect arriving another
way. Before reporting green:

1. **Break the guard you just added** — delete the check, invert the comparison,
   remove the argument that closes the hole.
2. **Re-run. The suite must go red.** Record which tests failed and how many.
3. **Restore, re-run, confirm the original green** and a clean `git diff`.

Three ways this silently lies to you, all of which have happened:

- **The mutation never applied.** An edit that missed because the line moved or
  the indentation differed. Assert the text you are replacing actually exists
  before replacing it; if it does not, that is a failed step, not a passed one.
- **A mutation that ERRORS is not a mutation that failed.** If your edit produces
  a syntax error, the suite never runs. A summary reading `3 errors` means your
  mutant was invalid — it does *not* mean the test is decorative. A mutant must be
  valid code that is wrong.
- **Stale bytecode.** A same-length edit (`0o600` → `0o644`) does not invalidate a
  cached `.pyc`: mtime and size both match. Clear the cache between runs, or you
  may be testing the mutant you believe you restored.

A guard that survives being broken is a finding about your test, not a green
light. Report it as one.

## Output contract

Two deliverables, and they are separate:

**1. The code.** Changes left uncommitted in the worktree. Do not run `git
commit`, `git push`, `git checkout`, or `git branch`.

**2. The report.** Emit it as your **final message**, as Markdown, and nothing
else. The very first characters of your final message must be `## Summary` — no
preamble, no restatement of the task, no sign-off. Do not write it to a file; the
runner captures your final message and files it at `{{REPORT_PATH}}`.

Use exactly these sections, in this order:

```markdown
## Summary

One paragraph: what the defect actually was, what you changed, and whether a
reviewer can merge this as-is. If you did not reproduce it, say so in the first
sentence and say what you tried.

## Not reproduced

Delete this section entirely if you did reproduce the defect. Otherwise: what the
ticket claimed, what you observed instead, the exact commands you ran, and your
best read on whether the ticket is stale, mis-scoped, or environment-specific.
Then stop — the sections below do not apply.

## Root cause

The actual mechanism, at `file:line`. Not "the input was not validated" but
which input, reaching which call, under which condition. If you fixed a symptom
because the true cause sits outside this ticket's scope, say that explicitly.

## The fix

- **Files changed:** each with one line on why it had to change
- **Approach:** what you did and what you deliberately did not do
- **Alternatives rejected:** and why, briefly

## Evidence

- **Reproduction test:** file and name
- **Failing before:** command + the failure message you saw
- **Passing after:** command + output
- **Full suite before:** green, or the pre-existing failures verbatim
- **Full suite after:** green, or unchanged pre-existing failures
- **Guard mutation:** what you broke, how many tests went red, and
  confirmation you restored it and the suite returned to green
- **`git diff --stat`:** the actual output
- **Budget:** N of {{FILE_BUDGET}} files used

## Risk

What a reviewer should look hardest at. Where this change could be wrong. What it
touches that you could not test. `None known.` is an acceptable answer only if you
genuinely mean it.

## Sightings

Other defects noticed and deliberately not fixed, one line each, with location.
`None.` if nothing.

## Blocked

Anything the ticket needs that you could not do, and why. `None.` if nothing.
```

A reviewer should be able to read *Root cause*, *Evidence*, and *Risk*, look at
the diff, and decide in a few minutes. Write for that reader.
