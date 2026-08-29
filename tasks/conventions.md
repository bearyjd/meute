# Task: house-convention conformance sweep

You are checking one repository against **its own written conventions**, and
fixing mechanical deviations, unattended.

The load-bearing phrase is *its own written conventions*. This task has exactly
one failure mode worth guarding against: an agent with no stated rules to check
against will fall back on its own taste, restyle a codebase to match its
preferences, and present that as conformance. Do not do this.

## Subject

- **Repository:** {{REPO_NAME}} (worktree at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Branch:** `{{BRANCH}}` (already checked out; do not switch branches)
- **Run date:** {{DATE}}

## What you are allowed to run

```
{{ALLOWED_COMMANDS}}
```

Those prefixes exactly; anything else is denied.

## The job

1. **Find the written conventions.** In priority order: `CLAUDE.md`, `AGENTS.md`,
   `CONTRIBUTING.md`, a style guide under `docs/`, `.editorconfig`, linter
   configuration, and any `README` section stating rules. Read them and extract
   the concrete, checkable rules.
2. **If you find no written conventions, stop.** Report that, list what a
   conventions file would need to contain to make this task possible, and change
   nothing. This is a complete and successful run. Do not infer conventions from
   the existing code and enforce them — "most files do X" is a description, not a
   rule, and codifying it silently freezes accidents into policy.
3. **Check conformance against those rules only.** A rule the repository did not
   state is not a violation, no matter how strongly you feel about it.
4. **Fix only mechanical deviations** — the ones where the correct outcome is
   unambiguous given the rule.

Rules worth checking, *if the repo states them*: file and directory naming, import
ordering and grouping, error-handling shape, logging format, test file placement
and naming, file-length and function-length limits, documentation comment style,
banned constructs.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files** read in full.
- **Only mechanical fixes.** If applying a rule requires a judgement call — how to
  split an over-long file, what to name an extracted function, whether an error
  is truly recoverable — do not do it. Record it under *Needs judgement*.
- **Never change behaviour.** No refactoring that alters control flow, no renaming
  anything exported or public, no changing signatures, no moving files that others
  import.
- **Never edit the conventions** to match the code.
- **One rule at a time, and stop at 200 changed lines.** A conformance sweep that
  touches everything is unreviewable; a small diff against one clearly stated rule
  is mergeable. If more remains, say so — the next run continues.
- **Leave the suite green**; record pre-existing failures verbatim.
- **Never commit, push, or switch branches.**

## Falsifiability requirements

Every change must be justified by a quoted rule:

1. **The rule, quoted, with its source** — `CLAUDE.md:12`, and the text.
2. **The violation** — `file:line`, and what was wrong.
3. **The fix** — what you changed.
4. **`git diff --stat`** against the 200-line ceiling.
5. **The suite before and after.**

A change you cannot attach a quoted rule to is out of scope: revert it. If you
find yourself writing "it is generally better to..." you have left this task.

## Output contract

Two deliverables. **The code:** changes left uncommitted; no `git commit`,
`git push`, `git checkout`, or `git branch`. **The report:** emitted as your final
message, Markdown, nothing else. The very first characters must be `## Summary` —
no preamble, no sign-off. The runner files it at `{{REPORT_PATH}}`.

```markdown
## Summary

One paragraph: which conventions document you worked from, which rule you swept,
and how much changed. If the repository states no conventions, say that in the
first sentence and stop.

## Conventions found

- Source file(s), and the concrete checkable rules you extracted — quoted
- `No written conventions found.` plus what such a file would need to contain

## Rule swept this run

The single rule, quoted with its source. Why this one first.

## Fixes

Each as a bullet:
- **Rule:** quoted, with `source:line`
- **Violation:** `file:line` — what was wrong
- **Fix:** what changed

`No violations of this rule found.` if the codebase already conforms.

## Needs judgement

Violations you found but did not fix because the correct outcome is not
mechanical. `file:line`, the rule, and what the choice is. `None.`

## Remaining

Rules you did not sweep this run, so the next run knows where to continue.

## Verification

- `git diff --stat`, against the 200-line ceiling
- Suite before / after
- Budget: N of {{FILE_BUDGET}} files

## Blocked

`None.` if nothing.
```
