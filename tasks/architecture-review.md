# Task: architecture review — single lens

You are reviewing one repository's structure through **one narrow lens**,
unattended, as part of a scheduled fleet run. Nobody is watching this session.
The person who reads your output will read it days from now, out of context,
and will decide whether to act based only on what you wrote.

## Subject

- **Repository:** {{REPO_NAME}} (checked out at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Lens for this run:** **{{LENS}}**
- **Run date:** {{DATE}}

## The job

Find real, evidenced structural problems in this repository that fall under
the **{{LENS}}** lens. Only that lens. Rotating the lens across runs is
deliberate — depth on one axis beats a shallow sweep of all of them, and the
other lenses get their own runs.

The failure mode this task exists to prevent: an agent with no evidentiary
bar produces generic architectural opinions — "this should use dependency
injection," "consider splitting this into microservices" — untethered to
anything measurable in *this* codebase. That is not a finding. A finding
names a structural property you can point to and count, not a taste.

Scope for each lens:

| Lens | In scope | Out of scope for this run |
|---|---|---|
| `coupling` | Modules that reach around each other's declared interface to touch internals directly; changes that require correlated edits in unrelated-looking files; import cycles | Duplicated logic, layering direction, missing tests |
| `layering` | A lower-level or more-general module importing from a higher-level or more-specific one (e.g. a library importing from the CLI that calls it); a "shared" module that actually only serves one caller | Coupling within a layer, duplication, missing tests |
| `duplication` | The same logic or algorithm implemented more than once, especially where a fix landed in one copy and not the other (check this directly — it is the strongest evidence duplication is a live cost, not a style nit) | Coupling, layering, missing tests |
| `boundaries` | A module's own tests, callers, or the module itself reaching past a stated interface (an exported function, a documented contract) to depend on an implementation detail that could change | Duplication, layering direction, coupling between unrelated modules |

Work from what the code and its history actually show, not from a general
sense of what "good architecture" looks like. Every finding must be something
a skeptical reader can independently count or reproduce — a grep result, an
import graph, a `git log` co-change pattern, a diff that fixed the same bug
twice. If you cannot point to that evidence, you do not have a finding.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files.** Read at most that many files in
  full. Grep, `git log`, and directory listings are free and do not count.
  Spend the budget following one real structural thread to its end over
  sampling widely.
- **Do not modify anything.** No edits, no new files, no commands that
  change state. Your tools are read-only by construction; do not try to
  work around it.
- **Do not propose a redesign.** A finding names the problem and its
  evidence. "Extract an interface here" as a one-line direction is fine;
  a multi-file restructuring plan is a separate, human-gated piece of work.
- **Stay in the lens.** If you trip over a serious structural problem outside
  **{{LENS}}**, do not chase it — record it in one line under *Out-of-lens
  sightings* and move on.
- Stop when the budget is spent or the lens is genuinely exhausted, whichever
  comes first. Exhausting the lens early and saying so is a good outcome.

## Falsifiability requirements

This is the part that makes the report worth reading. Every finding must be
checkable by someone who does not trust you.

For each finding you MUST supply:

1. **Location(s)** — every `path/to/file.ext:LINE` involved, not just one.
2. **The evidence** — the concrete, countable thing: a grep that lists every
   site of the duplication, the two call sites of a layering violation, the
   `git log --oneline -- <files>` output showing they always change together.
   Quote it; do not summarize it into a claim.
3. **The structural mechanism** — *why* this shape causes the cost: what has
   to happen in two places when it should happen in one, or what breaks in
   module A when module B changes for a reason A should not need to know
   about.
4. **A concrete cost paid because of this** — an actual instance, if one
   exists in the history (a bug fixed in one copy and not the other, a PR
   that touched four files to make a one-concept change), or, absent that,
   the specific next change that would have to pay it and how.
5. **Confidence** — `confirmed` (you traced the mechanism and can show the
   cost was actually paid at least once) or `suspected` (the shape is real
   but you found no instance yet of it costing anything).

Claims you may not make: that a pattern is "an anti-pattern" without showing
the cost here; that something is "hard to maintain" without naming what
specifically becomes hard and why; that a file is a "god object" because of
its line count alone, with no shown coupling or duplication to go with it.

**If you find nothing, say so explicitly.** An empty *Findings* section with
a populated *Coverage* section is a legitimate and useful result. Do not pad
the report with speculative findings to look productive. Inventing a finding
is a worse failure than finding nothing.

## Output contract

Emit the report as your **final message**, as Markdown, and nothing else. The
very first characters of your final message must be `## Summary` — no
preamble, no restatement of the task, no sign-off, no "here is the report".
Do not write it to a file; the runner captures your final message and files
it at `{{REPORT_PATH}}` itself.

Use exactly these sections, in this order:

```markdown
## Summary

One paragraph. What you looked at, what you concluded, and the single most
important thing the reader should do about it. If nothing was found, say
that here in the first sentence.

## Coverage

- Files read in full (list them, with the reason each earned budget)
- Areas searched but not read in full, and why they were ruled out
- Budget: N of {{FILE_BUDGET}} files used
- What this lens did NOT look at (so the reader does not mistake this for a
  full architecture review)

## Findings

For each, as its own `###` subsection titled `[SEVERITY] short description`,
where SEVERITY is CRITICAL / HIGH / MEDIUM / LOW — severity here means how
much real work the shape costs over time, not how it looks:

- **Location(s):** file:line, every site involved
- **Evidence:** the grep/log/diff output, quoted
- **Mechanism:** why this shape causes a cost
- **Cost paid:** an actual instance, or the specific next change it would hit
- **Confidence:** confirmed | suspected

Order findings by severity, highest first. If there are none, write exactly:
`No findings under the {{LENS}} lens within this run's budget.`

## Out-of-lens sightings

One line each, or `None.` Things worth a future run's attention. No detail —
just enough for the reader to schedule it.

## Verification notes

How a skeptical reader reproduces each finding: the grep to run, the log
command, the files to open side by side.
```

Severity means cost over time if left alone, not how confident you are —
confidence has its own field. A `suspected` CRITICAL is more useful than a
`confirmed` LOW, and they are different axes.
