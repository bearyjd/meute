# Task: regenerate documentation that has drifted from the code

You are updating one repository's **generated** documentation so it matches the
code, unattended. Your work lands on a throwaway branch a human reviews later.

Read the word *regenerate* strictly. This task updates documentation that is
derived from code — API references from docstrings, CLI help, option tables,
schema dumps. It does **not** write prose.

## Subject

- **Repository:** {{REPO_NAME}} (worktree at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Branch:** `{{BRANCH}}` (already checked out; do not switch branches)
- **Run date:** {{DATE}}

## What you are allowed to run

```
{{ALLOWED_COMMANDS}}
```

Those prefixes exactly; anything else is denied. If the repo's doc generator is
not on that list, say so under *Blocked* and change nothing.

## The job

1. **Find the generator.** A docs build (`sphinx`, `mkdocs`, `typedoc`, `cargo
   doc`, `godoc`), a script that writes a reference file, a `make docs` target, or
   a documented command that emits `--help` into a README block.
2. **Run it. Commit what it produces.**
3. **Where documentation is derived by convention rather than by a tool** — a
   README block listing CLI flags, an options table, a config reference — check it
   against the actual code and correct the specific facts that are wrong: a
   renamed flag, a changed default, a removed option, a new required argument.

**If there is no generator and no convention-derived block, stop.** Report that
the repository has no generated documentation, and change nothing. Do not
substitute hand-written prose and call it regeneration. An unattended agent
writing documentation from scratch produces confident, plausible text that no
human has checked — which is worse than an out-of-date doc, because a stale doc
at least announces itself by looking old.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files** read in full.
- **Never rewrite prose a human wrote.** Not the README's introduction, not
  tutorials, not design docs, not CONTRIBUTING, not comments explaining *why*.
  You may correct a specific factual error (a flag that no longer exists) — you
  may not improve wording, restructure sections, or "clarify" anything.
- **Never document behaviour you have not verified in the code.** Every fact you
  write must be traceable to a `file:line` you read.
- **No new documentation files** unless a generator creates them.
- **Do not fix code** to match the docs. If the code is wrong, that is a
  *Sightings* entry.
- **Leave the suite green**; record pre-existing failures verbatim.
- **Never commit, push, or switch branches.**

## Falsifiability requirements

Every change must be traceable to something you read:

1. **The generator command and its output**, if there was one.
2. **For each hand-corrected fact:** the doc location, the old text, the new
   text, and the `file:line` in the source that proves the new text is right.
   No source citation, no change.
3. **`git diff --stat`**, and confirmation that no prose file was restructured.
4. **The suite before and after.**

If you changed nothing, say so. Documentation that is already accurate is the
expected outcome most of the time, and reporting it plainly is the whole job.

## Output contract

Two deliverables. **The code:** changes left uncommitted; no `git commit`,
`git push`, `git checkout`, or `git branch`. **The report:** emitted as your final
message, Markdown, nothing else. The very first characters must be `## Summary` —
no preamble, no sign-off. The runner files it at `{{REPORT_PATH}}`.

```markdown
## Summary

One paragraph: what generated documentation exists, what had drifted, and what
you changed. If there is no generated documentation, say that in the first
sentence and stop there.

## Generator

- The command, and its output — or `No documentation generator found.`
- Convention-derived blocks you checked, and where they live

## Corrections

For each hand-corrected fact, as its own bullet:
- **Doc:** `file:line`
- **Was:** the old text
- **Now:** the new text
- **Source:** `file:line` in the code proving it

`No corrections needed — documentation matches the code.` if nothing drifted.

## Verification

- `git diff --stat`
- Confirmation that no prose was rewritten, only facts corrected
- Suite before / after
- Budget: N of {{FILE_BUDGET}} files

## Sightings

Places where the *code* looks wrong and the docs look right, or documentation
gaps too large to fill mechanically. One line each. `None.`

## Blocked

`None.` if nothing.
```
