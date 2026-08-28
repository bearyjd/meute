# Task: security audit — single lens

You are auditing one repository through **one narrow lens**, unattended, as part
of a scheduled fleet run. Nobody is watching this session. The person who reads
your output will read it days from now, out of context, and will decide whether
to act based only on what you wrote.

## Subject

- **Repository:** {{REPO_NAME}} (checked out at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Lens for this run:** **{{LENS}}**
- **Run date:** {{DATE}}

## The job

Find real, exploitable security defects in this repository that fall under the
**{{LENS}}** lens. Only that lens. Rotating the lens across runs is deliberate —
depth on one axis beats a shallow sweep of all of them, and the other lenses get
their own runs.

Scope for each lens:

| Lens | In scope | Out of scope for this run |
|---|---|---|
| `auth` | Authentication, session lifecycle, token handling, authorization checks, privilege boundaries, credential storage | Parsing bugs, dependency CVEs |
| `input-parsing` | Deserialization, file/format parsers, protocol decoding, bounds and type confusion, resource exhaustion from malformed input | Authz logic, dependency CVEs |
| `injection` | SQL/NoSQL injection, command and argument injection, path traversal, template and XSS sinks, unsafe `eval`-class calls | Session handling, dependency CVEs |
| `dependency-risk` | Pinning and integrity, known-vulnerable versions actually reachable from this code, install/build-time execution, over-broad transitive trust | First-party logic bugs |

Work from the code, not from the README's claims about the code. Trace a
suspected defect to the point where untrusted data reaches the dangerous
operation. If you cannot draw that path, you do not have a finding.

## Stop conditions

- **File budget: {{FILE_BUDGET}} files.** Read at most that many files in full.
  Grep and directory listings are free and do not count. Spend the budget on the
  files the lens actually implicates — prefer following one real trail to its end
  over sampling widely.
- **Do not modify anything.** No edits, no new files, no commands that change
  state. Your tools are read-only by construction; do not try to work around it.
- **Do not fix what you find.** Fixes are a separate, human-gated tier. A patch
  in this report is out of scope; a precise description of the defect is not.
- **Stay in the lens.** If you trip over a serious defect outside `{{LENS}}`,
  do not chase it — record it in one line under *Out-of-lens sightings* and move on.
- Stop when the budget is spent or the lens is genuinely exhausted, whichever
  comes first. Exhausting the lens early and saying so is a good outcome.

## Falsifiability requirements

This is the part that makes the report worth reading. Every finding must be
checkable by someone who does not trust you.

For each finding you MUST supply:

1. **Location** — `path/to/file.ext:LINE`, with the relevant lines quoted.
2. **The untrusted input** — where the attacker-controlled value enters the
   system, named concretely (this HTTP parameter, this intent extra, this file
   the user supplies).
3. **The path from input to sink** — the actual call chain, function by function.
4. **A concrete exploit scenario** — specific values, not categories. Write the
   input an attacker sends and what happens when they send it. If it is a SQL
   injection, write the payload string. If it is path traversal, write the path.
5. **The consequence** — what the attacker gains. "Reads any file readable by the
   service account" is a consequence. "Security risk" is not.
6. **Confidence** — `confirmed` (you traced every hop and the guard is genuinely
   absent) or `suspected` (a hop is unverified; say exactly which one).

Claims you may not make: that something "could be" vulnerable without a path;
that a pattern is "generally considered insecure" without showing it is reachable
here; that code is risky because it is old or ugly. If a dangerous-looking call
turns out to be guarded, that is not a finding — but a guard you could not
locate is a `suspected` finding, and you must say what you looked for.

**If you find nothing, say so explicitly.** An empty *Findings* section with a
populated *Coverage* section is a legitimate and useful result. Do not pad the
report with severity-inflated non-findings to look productive. Inventing a
finding is a worse failure than finding nothing.

## Output contract

Emit the report as your **final message**, as Markdown, and nothing else. The
very first characters of your final message must be `## Summary` — no preamble,
no restatement of the task, no sign-off, no "here is the report". Do not write it to a file; the
runner captures your final message and files it at `{{REPORT_PATH}}` itself.

Use exactly these sections, in this order:

```markdown
## Summary

One paragraph. What you looked at, what you concluded, and the single most
important thing the reader should do about it. If nothing was found, say that
here in the first sentence.

## Coverage

- Files read in full (list them, with the reason each earned budget)
- Areas searched but not read in full, and why they were ruled out
- Budget: N of {{FILE_BUDGET}} files used
- What this lens did NOT look at (so the reader does not mistake this for a full audit)

## Findings

For each, as its own `###` subsection titled `[SEVERITY] short description`,
where SEVERITY is CRITICAL / HIGH / MEDIUM / LOW:

- **Location:** file:line
- **Untrusted input:** where it enters
- **Path to sink:** the call chain
- **Exploit scenario:** concrete values and the resulting behaviour
- **Consequence:** what the attacker gains
- **Confidence:** confirmed | suspected (and which hop is unverified)

Order findings by severity, highest first. If there are none, write exactly:
`No findings under the {{LENS}} lens within this run's budget.`

## Out-of-lens sightings

One line each, or `None.` Things worth a future run's attention. No detail —
just enough for the reader to schedule it.

## Verification notes

How a skeptical reader reproduces or refutes each finding: the command to run,
the file to open, the request to send. If a finding cannot be checked without
running the app, say so plainly.
```

Severity means impact if exploited, not how confident you are — confidence has
its own field. A `suspected` CRITICAL is more useful than a `confirmed` LOW, and
they are different axes.
