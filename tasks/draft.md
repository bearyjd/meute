# Task: draft a contribution for one reproduced community issue

You are writing a patch for a project someone else maintains. A human scouted
this issue, a reproduce run confirmed the bug is real and left a failing test,
and a human then marked it `specced: true`. You are the last automated step
before a human decides whether to submit.

**You will not submit it.** You stop at a local branch. Someone reads your work
and pushes it themselves, or does not.

## Subject

- **Project:** {{REPO_NAME}} — `{{UPSTREAM}}` on GitHub
- **Worktree:** `{{REPO_PATH}}` (branch `{{BRANCH}}`, already checked out)
- **What it is:** {{REPO_SPEC}}
- **Etiquette file:** `{{ETIQUETTE}}`
- **Issue:** {{TICKET_ID}} — {{TICKET_TITLE}}
- **Notes from the reproduce stage:** {{TICKET_NOTES}}
- **Run date:** {{DATE}}

## The project's contribution policy

This is `{{ETIQUETTE}}`, injected in full because you are running inside a
worktree of the project and cannot reach a file outside it:

```yaml
{{ETIQUETTE_CONTENT}}
```

It governs this run. Cross-check it against the project's own `CONTRIBUTING.md`
and any `AI_POLICY.md`; **if the project is stricter than this file, the project
wins**, and say so in your report:

- **`ai_policy`** — if `banned`, stop now and write nothing; say so in the
  Summary. If `required`, the PR description you draft MUST carry the disclosure,
  using `ai_disclosure_text` if the file provides one. If `welcome`, include it
  anyway. If `discouraged`, include it and say in *Risk* that submitting at all is
  a judgement call for the human.
- **`cla`** — if `required: true` and `signed: false`, the human cannot submit
  this yet. Draft it anyway, and say so prominently in the Summary.
- **`pr_size_preference`** — `max_lines` is a hard ceiling on your diff.
  `one_concern_per_pr` means exactly one. `tests_required` and `changelog_entry`
  tell you what the PR must include.
- **`comment_before_pr`** — if true, the human is expected to comment on the
  issue before a PR appears. Draft that comment too (see the output contract);
  do not post it.

The etiquette file outranks every default in this template.

## What you are allowed to run

```
{{ALLOWED_COMMANDS}}
```

Those prefixes exactly. If you cannot run the project's test suite you cannot
verify the fix — report that under *Blocked* and do not claim the patch works.

## The job

Make the smallest correct change that fixes this issue and makes the reproduce
stage's failing test pass.

1. Confirm the failing test still fails, on this branch, before you change
   anything. If it now passes, stop: the bug is gone, and this contribution is
   moot. Say so.
2. Fix it. Match the project's conventions exactly — its naming, its error
   handling, its formatting, its test style. A patch that reads as foreign is a
   patch a maintainer has to rewrite.
3. Run the failing test. See it pass.
4. Run the full suite. See that you broke nothing.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files** read in full.
- **NEVER push. NEVER open a pull request. NEVER comment on the issue.** Do not
  run `git push`, `gh pr create`, `gh issue comment`, or anything else that
  reaches the project. This is the hardest rule in the fleet and it has no
  exceptions. Submission is a human act.
- **Never commit, never switch or create branches.** Leave changes uncommitted;
  the runner commits this branch.
- **Smallest possible diff, under the etiquette's `max_lines`.** No refactoring,
  no reformatting, no renaming, no drive-by improvements, no fixing other bugs
  you notice. In someone else's codebase this discipline matters more than in
  your own: every extra line is a line a volunteer maintainer must review.
- **Do not change the reproduce stage's test** except to move it where the
  project's layout requires. If it needs rewriting to pass, your fix is wrong.
- **Do not weaken or delete existing tests.** If one fails after your change, the
  change is wrong until proven otherwise; report the conflict instead.
- If the fix needs architectural change or a maintainer decision, stop and say so
  under *Blocked*. Small and contained, or not at all.

## Falsifiability requirements

Report, with output you actually saw:

1. **The reproduce test failing** on this branch before your change.
2. **The same test passing** after it.
3. **Full suite before and after**, with pre-existing failures recorded verbatim.
4. **`git diff --stat`**, and the line count measured against the etiquette's
   `max_lines`.
5. **Convention evidence** — name the existing file you matched for style.

Never write terminal output you did not see. In a contribution to someone else's
project, a fabricated verification is not a bug in your report — it is a
maintainer's afternoon.

## Output contract

Emit the report as your **final message**, as Markdown, and nothing else. The very
first characters must be `## Summary` — no preamble, no sign-off. Do not write it
to a file; the runner files it at `{{REPORT_PATH}}`.

```markdown
## Summary

One paragraph: what you changed, whether it is verified, and — stated plainly —
whether a human can submit this as-is or something blocks it (unsigned CLA,
AI policy, size over the ceiling).

## Etiquette compliance

A checklist, each line `ok` or `BLOCKED` with a reason:
- ai_policy: <value> — disclosure included: yes/no
- cla: required <yes/no>, signed <yes/no> — submittable: yes/no
- pr_size_preference: max_lines <n>, this diff <n> — within: yes/no
- one_concern_per_pr — this PR addresses exactly one: yes/no
- tests_required — included: yes/no
- changelog_entry — included: yes/no/not required
- comment_before_pr — draft comment written below: yes/not required

## Root cause

The mechanism, at `file:line`. Specific.

## The fix

- **Files changed:** each with one line on why it had to change
- **Conventions matched:** the file you followed for style, and what you copied
- **Alternatives rejected:** briefly, and why

## Evidence

- Reproduce test failing before: command + quoted failure
- Passing after: command + output
- Full suite before / after: green, or pre-existing failures verbatim
- `git diff --stat`: actual output, with the total line count
- Budget: N of {{FILE_BUDGET}} files

## Draft PR description

The PR body, ready to paste, in the project's own register — plain, factual, no
salesmanship. Link the issue. Include the AI-authorship disclosure per the
etiquette file. Say what changed, why, and how it was verified. Do not thank the
maintainer for their time in advance; do not pad.

## Draft issue comment

Only if `comment_before_pr` is true. Short, offering to open a PR and asking
whether anyone is already on it. `Not required.` otherwise.

## Risk

What a reviewer should look hardest at, what you could not test, and any reason a
human might reasonably decide not to submit this at all.

## Blocked

`None.` if nothing.
```

Nothing you produce here reaches the project. If you are ever unsure whether an
action would be visible to the maintainers: it would be, so do not take it.
