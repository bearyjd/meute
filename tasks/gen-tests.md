# Task: generate tests for uncovered behaviour

You are adding tests to one repository, unattended, as part of a scheduled fleet
run. Your work lands on a throwaway branch that a human reviews later. Nothing
you do here reaches the default branch automatically, but everything you leave
behind is read by someone with no memory of this session.

## Subject

- **Repository:** {{REPO_NAME}} (worktree at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Branch you are on:** `{{BRANCH}}` (already checked out; do not switch branches)
- **Run date:** {{DATE}}

## The job

Find behaviour in this repository that matters and is not covered by tests, then
write tests that cover it. Test the behaviour the code promises, not the shape
the code happens to have — a test that pins an implementation detail is a
liability, because it will fail the next time someone refactors correctly.

Order of preference for what to cover:

1. Logic that is easy to get wrong and expensive to get wrong: parsing, boundary
   conditions, error paths, state transitions, money, time, concurrency.
2. Behaviour that already broke once — look for bug-fix commits with no
   accompanying test (`git log` is available to you).
3. Public API surface with no coverage at all.

Explicitly *not* worth your budget: getters, trivial delegation, framework glue,
generated code, or anything whose test would only restate the implementation.

Before writing anything, find and read the existing tests. Match their framework,
their directory layout, their naming, their fixture and assertion style. A test
that looks foreign to this repo is a worse test even when it is correct. If the
repo has no tests at all, follow the ecosystem default for its language and say
so in your report.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files.** Read at most that many files in full.
  Grep, `git log`, and directory listings are free.
- **Do not change production code.** Test files, test fixtures, and test
  configuration only. The one exception: if a test cannot be written without a
  seam (a hard-coded singleton, an unmockable clock), do NOT add the seam —
  record it under *Blocked* in your report and move to the next candidate.
- **Do not change existing tests**, except to fix a test you yourself broke.
- **Do not add dependencies** unless the repo already has a test framework that
  requires it, and say so if you do.
- **Leave the suite green.** If the full suite was already failing when you
  arrived, record the pre-existing failures verbatim in your report and make sure
  you added none.
- Stop when the budget is spent or you run out of candidates worth covering.
  Three tests that pin real behaviour beat twenty that pin nothing.

## What you are allowed to run

This session is unattended: **no one can approve a command for you.** These
command forms are pre-approved, and they are the only ones that will run —
anything else is denied outright, and retrying a denied command with a different
spelling wastes the run:

```
{{ALLOWED_COMMANDS}}
```

Match those prefixes exactly. If the suite runner you need is not on that list,
do not fight it: say so under *Blocked*, name the exact command you needed, and
treat verification as impossible for this run (see below). The list is a
manifest setting the human controls — reporting a gap in it is useful work.

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

## Falsifiability requirements

A test that passes proves nothing on its own — a test that passes against broken
code is worse than no test, because it manufactures false confidence. For every
test you add you MUST do this, and report it:

1. **Run it and see it pass.** Record the exact command and its output.
2. **Break the thing it covers and see it fail.** Temporarily edit the production
   code the test targets so the covered behaviour is wrong, re-run just that
   test, and confirm it fails with a message that names the actual problem.
3. **Restore the production code exactly.** Verify with `git diff` that no
   production file is modified. This is not optional. A run that leaves a
   deliberate break behind is a failed run.
4. **Record the failure message** the broken version produced. That message is
   the evidence the test has teeth, and it is what the reviewer checks.

If step 2 does not make the test fail, the test does not test anything. Delete it
and say so in the report rather than shipping it.

**If you find nothing worth covering, say so explicitly and add no tests.** An
honest empty run is a good outcome. Do not pad the branch with tests for trivia
to look productive.

## Output contract

Two deliverables, and they are separate:

**1. The code.** Test files written into the worktree. Leave them on disk,
uncommitted — the runner commits the branch itself. Do not run `git commit`,
`git push`, `git checkout`, or `git branch`.

**2. The report.** Emit it as your **final message**, as Markdown, and nothing
else. The very first characters of your final message must be `## Summary` — no
preamble, no restatement of the task, no sign-off. Do not write it to a file; the runner captures
your final message and files it at `{{REPORT_PATH}}`.

Use exactly these sections, in this order:

```markdown
## Summary

One paragraph: what you covered, why those behaviours, and the state of the
suite when you finished. If you added nothing, say that in the first sentence
and say why.

## Environment

- How you ran the tests (exact command)
- Suite status when you arrived: green | failing (list pre-existing failures verbatim)
- Suite status when you left
- Framework and conventions you matched, or the ecosystem default you fell back to

## Tests added

For each test, as its own `###` subsection:

- **File:** path to the test file
- **Covers:** the behaviour in one sentence, and where it lives (`file:line`)
- **Why it matters:** the failure this test would have caught
- **Passes:** the command you ran and its result
- **Mutation check:** what you broke, the failure message you got, and
  confirmation that you restored it
- **Budget:** N of {{FILE_BUDGET}} files used (once, at the end of this section)

If you added no tests, write exactly: `No tests added this run.` and explain
in Summary.

## Blocked

Behaviour worth covering that you could not reach, one entry each: what it is,
and the specific seam that is missing. `None.` if nothing was blocked. This
section is how untestable code gets fixed, so be concrete — name the singleton,
the clock, the network call.

## Verification notes

What a reviewer runs to confirm this branch: the test command, the expected
output, and `git diff --stat` of what you touched. State explicitly that no
production file is modified, or name the ones that are and why.
```
