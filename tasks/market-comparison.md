# Task: market comparison — single lens

You are comparing one repository against real, currently-existing alternatives
on the public web, unattended, as part of a scheduled fleet run. Nobody is
watching this session. The person who reads your output will read it days
from now, out of context, and will decide whether to act based only on what
you wrote.

## Subject

- **Repository:** {{REPO_NAME}} (checked out at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Lens for this run:** **{{LENS}}**
- **Run date:** {{DATE}}

## The job

Find real, sourced facts about how other projects or products solve the same
problem as {{REPO_SPEC}}, under the **{{LENS}}** lens. Only that lens.
Rotating the lens across runs is deliberate — depth on one axis beats a
shallow sweep of all of them, and the other lenses get their own runs.

The failure mode this task exists to prevent: an agent with no evidentiary bar
produces generic market-research prose — "there are several apps like this,"
"competitors are more polished," "consider adding social features" — untethered
to any real, checkable source. That is not a finding. A finding names a
specific alternative and quotes what its own materials actually say.

Scope for each lens:

| Lens | In scope | Out of scope for this run |
|---|---|---|
| `direct-alternatives` | Named, currently-maintained projects or products that do the same core job as {{REPO_SPEC}}; what each one actually is, per its own README/docs/store listing | Feature-by-feature diffing, pricing, technical approach |
| `feature-gap` | A specific capability a named alternative has, evidenced by its own documentation or changelog, that this repo's README or code does not show it having | Discovering new alternatives, unverified claims about a feature |
| `approach-divergence` | A concrete way this repo's technical or design approach differs from a named alternative's (self-hosted vs. cloud, on-device vs. server, local model vs. API), evidenced by that alternative's own materials | Feature parity, pricing, discovering new alternatives |

Work from what the alternative's own materials actually say, not from general
impressions of "what's out there." Every claim about another project must be
something a skeptical reader can open the same page and verify. If you cannot
point to that source, you do not have a finding.

**Never cite a URL you did not get back from a `WebSearch` result or reach by
following a link from a page `WebFetch` returned.** Do not write a URL from
memory — a remembered URL for a real project is frequently wrong, renamed, or
dead, and this task's whole value is that every claim is checkable right now.

## Stop conditions

- **Web-lookup budget: {{FILE_BUDGET}} total calls**, `WebSearch` and
  `WebFetch` combined. Spend it following one real comparison to a sourced
  conclusion over spraying many shallow searches.
- **Do not modify anything.** No edits, no new files, no commands that change
  state. Your tools are read-only by construction; do not try to work around it.
- **Do not propose a roadmap.** A finding names the sourced fact and why it
  matters to this repo specifically. "Consider X" as a one-line direction is
  fine; a feature plan or redesign is a separate, human-gated piece of work.
- **Stay in the lens.** If you find something noteworthy outside
  **{{LENS}}**, do not chase it — record it in one line under *Out-of-lens
  sightings* and move on.
- Stop when the budget is spent or the lens is genuinely exhausted, whichever
  comes first. Exhausting the lens early and saying so is a good outcome —
  so is finding no real alternative at all.

## Falsifiability requirements

This is the part that makes the report worth reading. Every finding must be
checkable by someone who does not trust you.

For each finding you MUST supply:

1. **Source(s)** — the URL for every alternative or claim, exactly as
   returned by `WebSearch`/`WebFetch`, plus the date you accessed it (today,
   {{DATE}} — the web changes, so a stale citation is a liability, not a
   convenience).
2. **The evidence** — the exact passage quoted from the source. Do not
   paraphrase it into a claim; quote it, then interpret it.
3. **Why it matters here** — tie the fact to {{REPO_SPEC}} specifically, not
   to a generic best practice. What about *this* project makes the fact
   relevant.
4. **The concrete implication** — the specific next thing the reader might do:
   adopt an approach, decide the gap is real and worth closing, or explicitly
   decide the divergence is deliberate and leave it alone. Say which.
5. **Confidence** — `confirmed` (the source states the fact directly and
   unambiguously) or `suspected` (inferred from indirect evidence, or the
   source was incomplete, paywalled, or ambiguous — say which).

Claims you may not make: naming an "alternative" or "competitor" without a
link to it; describing what a tool "probably" does or "seems to" offer without
having read its own materials; treating marketing copy as a demonstrated fact
when a changelog, screenshot, or repository would confirm or refute it and you
did not check.

**If you find nothing, say so explicitly.** An empty *Findings* section with a
populated *Coverage* section is a legitimate and useful result — most
self-hosted personal tools genuinely have no direct commercial alternative.
Do not pad the report with a strained comparison to look productive. Inventing
a finding is a worse failure than finding nothing.

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

- Queries run and pages fetched (list them, with the reason each earned budget)
- Alternatives considered but ruled out, and why
- Budget: N of {{FILE_BUDGET}} lookups used
- What this lens did NOT look at (so the reader does not mistake this for a
  full market survey)

## Findings

For each, as its own `###` subsection titled `[SEVERITY] short description`,
where SEVERITY is CRITICAL / HIGH / MEDIUM / LOW — severity here means how
much it should change what the reader does next, not how interesting it is:

- **Source(s):** URL(s), accessed {{DATE}}
- **Evidence:** the quoted passage
- **Why it matters here:** tied to {{REPO_SPEC}}
- **Implication:** the specific next thing to do, or to deliberately not do
- **Confidence:** confirmed | suspected

Order findings by severity, highest first. If there are none, write exactly:
`No findings under the {{LENS}} lens within this run's budget.`

## Out-of-lens sightings

One line each, or `None.` Things worth a future run's attention. No detail —
just enough for the reader to schedule it.

## Verification notes

How a skeptical reader reproduces each finding: the exact search query or URL
to open, and what to look for on the page.
```

Severity means how much it should change the reader's next decision, not how
confident you are — confidence has its own field. A `suspected` CRITICAL is
more useful than a `confirmed` LOW, and they are different axes.
