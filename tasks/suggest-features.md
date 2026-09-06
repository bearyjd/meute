# Task: feature suggestions — single lens

You are proposing what this repository should build next, unattended, as part
of a scheduled fleet run. Nobody is watching this session. The person who
reads your output will read it days from now, out of context, and will decide
whether to build something based only on what you wrote.

## Subject

- **Repository:** {{REPO_NAME}} (checked out at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Lens for this run:** **{{LENS}}**
- **Run date:** {{DATE}}

## The job

Suggest features for {{REPO_SPEC}} that fall under the **{{LENS}}** lens.
Only that lens. Rotating the lens across runs is deliberate — depth on one
axis beats a shallow sweep of all of them, and the other lenses get their own
runs.

The failure mode this task exists to prevent: an agent with no evidentiary
bar produces a generic wishlist — "add dark mode," "add a REST API," "add
notifications" — that could be attached to any project and tells the reader
nothing they did not already know. That is not a suggestion. A suggestion is
**anchored**: it names the specific thing in *this* repository that makes it
the right next step, and the reader can open that thing and see it.

Scope for each lens:

| Lens | What anchors a suggestion | Out of scope for this run |
|---|---|---|
| `unfinished` | Work the code itself admits is incomplete: `TODO`/`FIXME`/`XXX`, stubbed or `NotImplemented` functions, tests marked skip, config keys parsed but never read, feature flags that are never flipped, UI entry points that lead nowhere | Anything not already started |
| `promised` | A capability the README, docs, help text, changelog or app-store listing describes that the code does not actually deliver, or delivers only partially | Undocumented gaps, new ideas |
| `friction` | A manual step, workaround, or repeated error path the project's own docs, issues, scripts or commit history show the user going through — the feature is the thing that removes it | Speculative pain nobody has hit |
| `adjacent` | A capability the existing code is one clear step from: a data model that already holds the field, a pipeline with an obvious missing stage, a UI with a natural next control. Name the code that does 80% of it | Anything needing new infrastructure |

Work from what the repository actually contains. Every suggestion must point
at a file, a line, a doc sentence, a commit, or an issue that a skeptical
reader can open. If the best you can say is "projects like this usually
have X," you do not have a suggestion under this task — that belongs to
`market-comparison`, which sources it properly.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files.** Read at most that many files in
  full. Grep, `git log`, and directory listings are free and do not count.
  Spend the budget following the strongest anchors to the code behind them.
- **Do not modify anything.** No edits, no new files, no commands that change
  state. Your tools are read-only by construction; do not try to work around it.
- **Do not design the feature.** A suggestion says what and why, sized in
  one line. A multi-file design is a separate, human-gated piece of work.
- **Stay in the lens.** If you trip over a strong suggestion outside
  **{{LENS}}**, do not chase it — record it in one line under *Out-of-lens
  sightings* and move on.
- **At most five suggestions.** Fewer, well-anchored, beats a list. Stop when
  the budget is spent or the lens is genuinely exhausted, whichever comes
  first. Exhausting the lens early and saying so is a good outcome.

## Falsifiability requirements

This is the part that makes the report worth reading. Every suggestion must
be checkable by someone who does not trust you.

For each suggestion you MUST supply:

1. **The anchor** — `path/to/file.ext:LINE`, a doc sentence quoted verbatim,
   a commit hash, or an issue number. The concrete thing that makes this
   suggestion belong to *this* project.
2. **The evidence** — quote it. The TODO text, the README sentence, the
   stub body, the parsed-but-unread key. Do not summarize it into a claim.
3. **What to build** — one or two sentences. What the user would be able to
   do afterwards that they cannot do now.
4. **Why now** — what about the anchor makes this the next step rather than
   one of many: the code is already 80% there, the docs already promise it,
   the user already does it by hand.
5. **Size** — `S` (a session), `M` (a few sessions), `L` (a real project).
   A guess is fine; say it is one.
6. **Confidence** — `confirmed` (you read the code behind the anchor and the
   gap is real) or `suspected` (the anchor is real but you could not verify
   the gap end to end — say what you did not check).

Claims you may not make: that users "would want" something without an anchor
showing they already reach for it; that a feature is "standard" or
"expected"; that something "should" exist because comparable projects have it
(that is `market-comparison`'s job, with sources).

**If you find nothing, say so explicitly.** A well-scoped project with no
unfinished work under this lens is a legitimate and useful result. Do not pad
the report. Inventing a suggestion is a worse failure than finding none.

## Output contract

Emit the report as your **final message**, as Markdown, and nothing else. The
very first characters of your final message must be `## Summary` — no
preamble, no restatement of the task, no sign-off, no "here is the report".
Do not write it to a file; the runner captures your final message and files
it at `{{REPORT_PATH}}` itself.

Use exactly these sections, in this order:

```markdown
## Summary

One paragraph. What you looked at, what you concluded, and the single
suggestion the reader should consider first. If nothing was found, say that
here in the first sentence.

## Coverage

- Files read in full (list them, with the reason each earned budget)
- Areas searched but not read in full, and why they were ruled out
- Budget: N of {{FILE_BUDGET}} files used
- What this lens did NOT look at (so the reader does not mistake this for a
  full roadmap)

## Findings

For each suggestion, as its own `###` subsection titled
`[PRIORITY] short description`, where PRIORITY is HIGH / MEDIUM / LOW — how
much the reader should want this relative to the others here, not how sure
you are:

- **Anchor:** file:line, quoted doc sentence, commit, or issue
- **Evidence:** the quoted text
- **Build:** what the user could do afterwards
- **Why now:** what makes it the next step
- **Size:** S | M | L
- **Confidence:** confirmed | suspected

Order by priority, highest first. If there are none, write exactly:
`No suggestions under the {{LENS}} lens within this run's budget.`

## Out-of-lens sightings

One line each, or `None.` Things worth a future run's attention. No detail —
just enough for the reader to schedule it.

## Verification notes

How a skeptical reader checks each anchor: the grep to run, the file to
open, the doc to read.
```

Priority means how much this should move the reader's plans, not how
confident you are — confidence has its own field. A `suspected` HIGH is more
useful than a `confirmed` LOW, and they are different axes.
