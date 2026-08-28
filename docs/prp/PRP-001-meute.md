# PRP-001 — meute: autonomous fleet runner

- **Status:** phase 1 implemented and accepted
- **Created:** 2026-08-28
- **Amended:** 2026-08-28 — subscription-only; API-key mode removed (see §7)
- **Licence:** AGPL-3.0

## 1. Problem

I run a portfolio of personal software projects as local git repositories, plus
I depend on a handful of open-source projects. My Claude Code / Codex
subscriptions have leftover weekly capacity that expires unused. I want that
capacity spent on scheduled, unattended work across those repos, and a small
capped share of it spent contributing back to the projects I use.

The constraint that shapes everything: **scheduled work must never compete with
interactive work.** A chore that eats the window I wanted for real work is worse
than a chore that never ran.

## 2. Non-goals

No dashboards, databases, servers, parallel execution, notification
integrations, or GitHub Actions. Scheduling is cron's job. This repo is an
idempotent script that does one unit of work and exits.

## 3. Invocation model

```
bin/run.sh <daily|weekly> [--engine claude|codex] [--repo N] [--task N] [--dry-run] [--validate]
```

One queue item per invocation, then exit. Cron fires it; the script decides
whether there is anything worth doing and declines cheaply when there isn't.

Sequence:

1. Scrub API keys from the child environment (§7); warn if any were present.
2. `flock -n` on `state/.lock` — a slow run must not stack under a tight timer.
3. Validate the manifest; abort on any schema violation.
4. `bin/quota.sh`; exit 0 if remaining subscription quota is under the floor.
5. Build the work queue from `repos.yaml`; apply the community-share and
   tier-3 in-flight gates; pick the next eligible item after `state/cursor`.
6. Preflight the engine's auth (zero cost, §7).
7. `git worktree add` on a scratch branch `meute/<task>-<date>`.
8. Render the task template with injected variables; invoke the engine with
   tier-appropriate tool restrictions.
9. Capture the final message; write `reports/<repo>/<task>-<date>.md`.
10. Commit any code changes to the scratch branch only. Never push.
11. Remove the worktree, keep the branch if it holds commits.
12. Advance the cursor; append one line to `state/log`.

## 4. Manifest

`repos.yaml` has five blocks: `defaults`, `policy`, `tiers`, `tasks`, and the
two project sections `repos:` (mine) and `community:`. Settings resolve
task > project > defaults. Templates resolve against `MEUTE_ROOT`.

Ordering is structural, not computed: everything under `repos:` is enumerated
before anything under `community:`, so my own projects always have first claim.

## 5. Tiers

| Tier | Purpose | Tools | Mode | Commits |
|---|---|---|---|---|
| 1 | Autonomous, self-verifying: tests, lint sweeps, doc regen, dependency audits, convention conformance | Read/Grep/Glob/Edit/Write/Bash | `acceptEdits` + allowlist | yes |
| 2 | Autonomous reports for async reading: security audit (rotating lens), architecture review, market comparison, feature brainstorm | Read/Grep/Glob | `dontAsk` | no |
| 3 | Drafts behind a human gate: bug fixes and features, `specced: true` tickets only, max 3 in flight | Read/Grep/Glob/Edit/Write/Bash | `acceptEdits` + allowlist | yes |

`tools` is a hard availability filter, not a prompt: a tier without Write/Edit
physically cannot modify the worktree. Verified empirically — a tier-2 session
instructed to write a file reports `WROTE=no` and no file appears.

The weekly split is 80/20 by design. A community item is eligible only while it
keeps the community share of the current ISO week's runs at or under
`policy.community_share`.

## 6. Task template contract

Every template in `tasks/` defines four things:

- **The job** — the subject, and what counts as done.
- **Stop conditions** — file budget, scope boundaries, and an explicit "do not
  modify code" for read-only tiers.
- **Falsifiability requirements** — exploit scenarios with concrete payloads for
  audits; run-it-then-break-it mutation checks for tests. Never vibes.
- **An output contract** — the exact sections, and an explicit instruction to
  state plainly when nothing was found.

Reports are emitted as the engine's **final message**, never written to a file by
the engine. The runner captures the message and files it. This is what makes a
read-only tier possible at all: `reports/` lives in meute while the worktree
lives in the target repo, so a genuinely read-only subprocess could not write
there even if asked.

## 7. Auth and billing (amended)

**meute is subscription-only. It never runs on metered API billing.**

Claude Code silently prefers an API key over subscription auth when one is
present in the environment, which flips billing to per-token without any visible
signal. Two defences, both always on:

1. **Scrub.** Every engine invocation runs through
   `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u OPENAI_API_KEY`. If any
   were set, the runner warns on stderr and records `scrubbed=` in `state/log`.
2. **Preflight.** Before any work, the runner verifies the engine resolves to a
   subscription, through the scrubbed environment, and aborts with instructions
   otherwise:
   - claude: `claude auth status --json` must report `loggedIn: true`, a non-null
     `subscriptionType`, and **no** `apiKeySource`. Failure → `claude auth login`.
   - codex: `codex login status` must report a ChatGPT login. Failure → `codex login`.

Both probes are local and cost zero quota. This is deliberately *not* the
`claude -p "say ok"` smoke test originally sketched: a smoke prompt costs the
very quota the tool exists to conserve, and tells us less — it cannot distinguish
a subscription from an API key, which is the exact failure being guarded against.
Because the check is free, it runs every invocation, and no first-run caching is
needed.

There is no `MEUTE_AUTH` variable and no API-key mode.

## 8. Quota model (amended)

Quota means the **subscription allowance** — the plan's rolling 5-hour window and
its weekly pool — as a percentage still available. It is not a dollar budget;
there is no spend to cap. Where both pools are visible the binding figure is the
minimum of the two.

`bin/quota.sh` prints one integer 0-100 and exits 0. Sources in order:
`$MEUTE_QUOTA_CMD`, `state/quota-override`, then `$MEUTE_QUOTA_STUB` (default
100). If no source can be consulted it exits non-zero and the runner declines to
run — starving the human is worse than skipping a chore.

There is no built-in probe: as of Claude Code 2.1.x the remaining allowance is
exposed only interactively via `/usage`; `claude auth status --json` reports the
plan tier but not the balance. `MEUTE_QUOTA_CMD` is the seam for a real source.

The `cost_usd` recorded per run is the list-price equivalent of work already paid
for by the seat. It is useful for ranking which tasks are expensive. It is not
what the gate measures.

## 9. Community track

Three stages, each its own template, gated by `policy.community_share`:

- **scout.md** — `gh`-driven triage of allowlisted projects: maintainer-confirmed
  or clearly reproducible, `help wanted`/`good first issue`, unassigned, no
  linked PR, older than two weeks, estimated diff ≤ ~100 lines. Emits a ranked
  shortlist with one-paragraph briefs, and logs rejects with reasons.
- **reproduce.md** — clone, set up, attempt reproduction, write a failing test.
  No fix. Failure to reproduce kills the candidate.
- **draft.md** — reproduced issues only. Minimal fix plus test on a local branch,
  with a PR description that links the issue and discloses AI-assisted authorship
  per `etiquette/<project>.yaml` (`ai_policy`, `cla`, `pr_size_preference`,
  `comment_before_pr`). **Never pushes and never opens a PR** — it stops at the
  local branch; submission is manual and human.

No etiquette file, no contribution. That is a hard gate, not a warning.

## 10. Design decisions

**Cursor stores the last executed key, not an index.** An index drifts the moment
the manifest is edited, silently reordering the fleet. A key survives edits; if
it disappears the queue restarts from the top.

**The cursor advances even when a run fails.** Nonzero exit, `is_error: true`,
and an empty report are three distinct failures, all logged distinctly — but all
advance the cursor. A poisoned entry that stalled the cursor would silently halt
the entire fleet under cron, and the failure would be invisible until someone
read the log. Failures surface in `state/log` and in the report file, which is
written either way with the engine's stderr tail.

**Cleanup removes the worktree and keeps the branch — unless the branch is
empty.** For tier-3 drafts and the community `draft.md` stage, that branch *is*
the deliverable, and the tier-3 in-flight cap is computed by counting surviving
branches. An empty branch is deleted because it is pure noise and would inflate
the cap.

**The runner commits its own audit trail.** `state/cursor`, `state/log` and
`reports/` are committed history by design. A runner that only wrote them would
hand the operator a checkout that is permanently dirty with nobody responsible
for it. The commit is pathspec-scoped to `state` and `reports` so unrelated edits
in the meute tree are never swept in, and it never pushes.
`MEUTE_NO_AUTOCOMMIT=1` opts out.

**Engine results are normalised, not shared.** `claude -p --output-format json`
returns one envelope with `.result`; `codex exec --json` streams JSONL events and
writes the final message to a separate file via `-o`. Extraction paths are
distinct; a shared `jq .result` would silently yield empty for codex.

**Artifact excludes are layered at commit time.** A tier-1 run that verifies
itself generates `__pycache__`, `.pytest_cache`, `node_modules`. `git add -A` in a
repo with a thin `.gitignore` commits them. `lib/artifacts.gitignore` is layered
under the repo's own rules via `core.excludesFile`; the repo's rules still win.

## 11. Empirical findings from phase 1

Two findings that changed the design. Both were caught by running the thing, not
by reasoning about it.

**`acceptEdits` cannot self-verify.** The original spec assigned `acceptEdits` to
write tiers. Measured behaviour: `acceptEdits` auto-approves *edits* but still
denies arbitrary shell execution, as does `dontAsk`. Only `bypassPermissions`
permits it. A tier-1 `gen-tests` run under plain `acceptEdits` therefore could
not run the suite it had just written, and honestly reported every test as
unverified — the tier's defining property, self-verification, was unreachable.

The resolution keeps `acceptEdits` and adds a per-tier `allowed_tools` allowlist
(`--allowed-tools`), which pre-approves specific command prefixes without a
blanket bypass. Verified: `Bash(python3:*)` permits `python3 -c`, while `curl`
is still denied.

This is a **blast-radius reducer, not a sandbox** — `pytest` executes test code
the agent wrote seconds earlier. What it buys: an unattended run cannot reach the
network, install packages, push a branch, or write outside its worktree.
Interpreters are deliberately absent from the default list; pre-approving one is
equivalent to full execution.

**An agent cannot comply with an allowlist it cannot see.** With
`Bash(pytest:*)` allowed but undisclosed, the run reached for `python3 -m pytest`,
was denied, retried five spellings, gave up, and reported the tier unverifiable —
while `pytest` sat installed and permitted the whole time. The allowlist is now
injected into the prompt as `{{ALLOWED_COMMANDS}}`, and templates instruct the
agent to report a gap in it under *Blocked* rather than fight it. After the fix
the same task ran its suite green and performed four genuine mutation checks.

The general lesson, worth applying to every future template: **a restriction the
agent cannot observe is indistinguishable from a broken environment.**

## 12. Phase status

Built and accepted:

- `repos.yaml` schema, with commented personal and community examples
- `lib/manifest.py` — validation, queue flattening, policy, template rendering
- `bin/run.sh` — full lifecycle: lock, scrub, preflight, quota gate, queue,
  gates, worktree, render, invoke, capture, report, commit, cleanup, cursor, log
- `lib/engines.sh`, `lib/preflight.sh` — engine adapters and the
  subscription-only guarantees, split out as coherent units
- `bin/quota.sh` — pluggable probe with a stub default
- `tasks/audit-security.md` (tier 2, rotating lens), `tasks/gen-tests.md` (tier 1)
- `lib/artifacts.gitignore`

Phase 2, in rough priority order:

- Community templates: `scout.md`, `reproduce.md`, `draft.md`
- Remaining tier-1 templates: lint sweep, doc regen, dependency audit, conventions
- Remaining tier-2 templates: architecture review, market comparison (needs
  WebSearch in the tier tool set), feature brainstorm
- `draft-ticket.md` for tier 3
- A real `MEUTE_QUOTA_CMD` source once a machine-readable balance exists

## 13. Acceptance

`bin/run.sh <slot>` against a sample repo must produce a report file, leave the
main checkout untouched, clean up its worktree, advance the cursor, and exit 0.

Verified across six runs on a throwaway repo. Evidence: `state/log`, the files
under `reports/sample-repo/`, and before/after captures of `git status
--porcelain`, `git rev-parse HEAD`, `git worktree list`, and `git branch --list
'meute/*'` showing the main checkout unchanged at `4d77284a`, no leftover
worktrees, and the tier-1 scratch branch surviving with its commit.
