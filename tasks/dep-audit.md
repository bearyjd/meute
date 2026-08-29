# Task: dependency risk report

You are assessing one repository's dependencies for risk, unattended, and writing
a report a human reads later. **You are not upgrading anything.**

Most dependency reports are worthless because they list every advisory the
scanner emits, and the reader learns nothing except that scanners are noisy. The
job here is the opposite: separate what is actually reachable from what merely
appears in a lockfile.

## Subject

- **Repository:** {{REPO_NAME}} (worktree at `{{REPO_PATH}}`)
- **What it is:** {{REPO_SPEC}}
- **Run date:** {{DATE}}

## What you are allowed to run

```
{{ALLOWED_COMMANDS}}
```

Those prefixes exactly. If the repo's ecosystem tooling is not on that list, say
so under *Blocked* and report only what you can determine by reading the manifest
and lockfile. Do not fabricate scanner output.

## The job

1. **Identify the ecosystem** and its manifest + lockfile.
2. **Run the ecosystem's audit tool** if it is allowlisted.
3. **For each advisory, determine reachability.** This is the entire value of the
   task. For every reported vulnerability, answer: does this repository actually
   call the affected code path?
   - Find where the package is imported.
   - Find whether the specific vulnerable function or feature is used.
   - A transitive dependency pulled in by a build tool and never invoked at
     runtime is a different risk from one in the request path.
4. **Separately, note staleness** — dependencies far behind, unmaintained, or
   with a single maintainer — but keep it clearly apart from vulnerabilities.
   "Out of date" is not "vulnerable".

## Stop conditions

- **File budget: {{FILE_BUDGET}} files** read in full. Spend it on reachability
  analysis for the highest-severity advisories, not on skimming everything.
- **Change nothing.** No upgrades, no lockfile edits, no manifest edits, no
  `npm install`, no `pip install`, no `cargo update`. This task produces a report
  and an empty branch; the runner deletes the empty branch automatically. An
  unattended dependency upgrade is how a working build stops working overnight.
- **Do not install anything** to make a scanner run. If the environment lacks it,
  that is a *Blocked* entry.
- If the audit tool reports nothing, say so plainly and spend your budget on
  staleness and supply-chain shape instead.

## Falsifiability requirements

For every vulnerability you report:

1. **Advisory ID** (CVE / GHSA / RUSTSEC) and the affected package + version range.
2. **The installed version**, quoted from the lockfile.
3. **Direct or transitive** — and if transitive, what pulls it in.
4. **Reachability verdict**, one of:
   - `reachable` — you found the call path. Show it: `file:line` → the vulnerable API.
   - `not reachable` — the package is present but the vulnerable API is never
     called. Say what you searched for.
   - `unknown` — you could not determine it within budget. Say what is missing.
5. **Consequence if exploited**, in this repo's context specifically.

A list of advisory IDs with no reachability analysis is exactly the report this
task exists to avoid. If you can only manage `unknown` for everything, say that
in the Summary — it is honest, and it tells the reader the report is thin.

## Output contract

Emit the report as your final message, Markdown, nothing else. The very first
characters must be `## Summary` — no preamble, no sign-off. The runner files it at
`{{REPORT_PATH}}`. Do not write it to a file, and do not modify the repository.

```markdown
## Summary

One paragraph: ecosystem, how many advisories the scanner reported, how many are
actually reachable, and the single thing worth doing. If nothing is reachable,
lead with that — it is the most useful sentence in the report.

## Environment

- Ecosystem, manifest and lockfile paths
- Audit command run, and its headline output
- What you could not run, and why

## Reachable vulnerabilities

Highest severity first, each as `### [SEVERITY] PACKAGE@VERSION — ADVISORY-ID`:

- **Installed:** version, quoted from the lockfile
- **Path:** direct, or what pulls it in
- **Reachability:** the call path, `file:line` → vulnerable API
- **Consequence here:** what an attacker gains in *this* repo
- **Fix:** the version that resolves it, and whether it is a breaking change

`No reachable vulnerabilities found.` if none.

## Present but not reachable

One line each: `PACKAGE@VERSION — ADVISORY-ID — vulnerable API not called (searched for X)`.
This section is what makes the one above trustworthy.

## Unknown reachability

One line each, with what you would need to resolve it. `None.`

## Staleness and supply-chain shape

Separate from vulnerabilities. Dependencies far behind, unmaintained, or
single-maintainer. One line each. Say plainly that none of this is a vulnerability.

## Blocked

`None.` if nothing.
```
