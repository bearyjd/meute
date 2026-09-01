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

**A configured probe that fails is a broken source, not an absent one, and must
fail closed.** An earlier version fell through to the stub when `MEUTE_QUOTA_CMD`
errored, which meant a broken probe let the fleet run at full speed at precisely
the moment the operator had asked it not to — a safety feature that silently
disappeared. It now exits non-zero and the runner skips the slot.

Because the shipped default is a stub, the gate does nothing until a real source
is wired. That is easy to forget, so the quota and its source are recorded on
every run line — `quota=77:stub` versus `quota=41:MEUTE_QUOTA_CMD` — making an
unconfigured gate permanently visible rather than silently absent.

Two sources ship, answering different questions. `contrib/quota-self-budget.sh`
caps meute's own footprint from its own run log and needs nothing external; it
cannot see interactive usage, so it is a self-cap, not a pool reading. It is the
first source that makes the gate actually fire, and it is honest about what it
measures.

The real rolling 5-hour / weekly pool is only reachable with a claude.ai session
cookie, which requires an interactive browser login. `~/.claude/.credentials.json`
alone yields the subscription tier and no message counts — verified in
llm-usage-tracker's own Claude collector, which documents exactly that split. So
the true pool reading cannot be wired unattended, by anyone, today.

`contrib/quota-llm-usage-tracker.sh` adapts llm-usage-tracker, whose Claude
collector already reduces the 5-hour and 7-day windows to whichever is more
restrictive and stores it as `messages_used` against `messages_limit == 100`.

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

No etiquette file, no contribution. That is a hard gate, not a warning — the
manifest refuses to validate a community project without one.

**`autonomous_agents` is a second, separate axis, and it is the one that gates
meute.** A project can welcome AI-assisted contributions from a human while
forbidding agent-authored ones; `ai_policy` alone cannot express that. The
motivating case is real and was found by a live scout run: ripgrep's
`AI_POLICY.md` welcomes AI-assisted coding with a human in the loop and then says
"Autonomous agents are not allowed to be used for contributing to this project."

When `autonomous_agents: banned`, the **queue builder** — not the prompt — refuses
every task whose tier writes code. Scouting stays available, because read-only
analysis is not a contribution. Enforcing this in code rather than in template
text matters: a rule that only exists as instructions is a rule an unattended
agent can rationalise past.

The etiquette file's **contents** are injected into the prompt, not its path. The
agent runs inside a worktree of the target repo and cannot read a file under
`MEUTE_ROOT` by construction — a live run proved the earlier path-only version
was unreadable, and the agent fell back to reading the project's own
`AI_POLICY.md`. Templates now also instruct that where the project's own
documents are stricter than the etiquette file, the project wins.

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

**The runner commits its own audit trail — but not on a public harness.**
`commit_state()` is pathspec-scoped to `state` and `reports`, never pushes, and
`MEUTE_NO_AUTOCOMMIT=1` opts out. The original design committed both, so that a
cron-driven runner would not hand the operator a permanently dirty checkout.

That was right for a private harness and wrong for a public one, and the mistake
was made before it was noticed: a verified, unfixed CRITICAL for a private
project — the unauthenticated route inventory, the default `0.0.0.0` bind, exact
file paths — was committed and pushed to a public repository by the runner's own
autocommit. Removing it required rewriting history and recreating the remote,
because GitHub keeps orphaned objects fetchable by SHA after a force-push.

`reports/*/` and the fleet state files are therefore gitignored, alongside
`repos.local.yaml`. `commit_state()` is consequently inert in the default
configuration: `git status --porcelain -- state reports` is empty, so it returns
early and commits nothing. It stays in the code because a privately-hosted meute
should still commit its audit trail, and un-ignoring those paths is all it takes.

**The rule the whole thing collapses to: the harness is public, everything about
your fleet is local.** That covers which repos you run against, what the runner
found in them, and what it decided to do about it.

**Machine-written tickets never touch `repos.yaml`.** `meute promote` writes to
`state/tickets.yaml`; `manifest.py` merges it with the hand-written tickets and
applies the same `specced: true` gate to both. PyYAML destroys comments on
round-trip (verified: `safe_dump(safe_load("# c\nk: 1"))` → `"k: 1\n"`), and this
manifest's comments are its documentation. `ruamel.yaml` would round-trip, but
taking a dependency so a machine can rewrite hand-curated config is the wrong
trade — separate the files instead.

**Engine results are normalised, not shared.** `claude -p --output-format json`
returns one envelope with `.result`; `codex exec --json` streams JSONL events and
writes the final message to a separate file via `-o`. Extraction paths are
distinct; a shared `jq .result` would silently yield empty for codex.

**Artifact excludes are layered at commit time.** A tier-1 run that verifies
itself generates `__pycache__`, `.pytest_cache`, `node_modules`. `git add -A` in a
repo with a thin `.gitignore` commits them. `lib/artifacts.gitignore` is layered
under the repo's own rules via `core.excludesFile`; the repo's rules still win.

## 10a. The decline path

Every tier-1 maintenance template has a condition under which the correct
behaviour is to change nothing and say why:

| Template | Declines when | Because |
|---|---|---|
| `lint-sweep` | the repo configures no linter, or its formatter would exceed 300 lines | formatting a codebase to a standard its owner never chose is an opinion imposed at scale, and it destroys `git blame` |
| `doc-regen` | there is no generator and no convention-derived block | an agent writing docs from scratch produces confident unchecked prose, which is worse than a stale doc — a stale doc at least looks old |
| `dep-audit` | scanners are unavailable | fabricated scanner output is indistinguishable from real output |
| `conventions` | the repo states no written conventions | with no stated rules an agent falls back on its own taste and calls it conformance |

`conventions` is the sharpest case and was verified live against a repo with no
conventions file: it checked every named location, reported what such a file
would need to contain, and changed nothing.

These declines are successful runs, and the templates say so explicitly. Without
that, an unattended agent under implicit pressure to look productive will find
something to do — which for maintenance tasks means a large diff nobody asked
for.

## 10b. Deployability

The runner is invoked by cron, so "works" means works in cron's environment, not
in an interactive shell. `bin/meute doctor` checks that specific claim: it probes
each required binary against cron's real default `PATH` (`/usr/bin:/bin`), runs
the auth preflight through the same scrubbed environment the runner uses, reports
whether the quota gate is real or still a stub, and prints a crontab block with
`PATH` already filled in.

Two findings from building it, both measured rather than assumed:

- **Not every machine has cron.** This one does not: `cronie` is absent on the
  immutable Fedora variant it runs on, so every crontab instruction in this
  document and in `meute doctor` was guidance that would silently never fire.
  `doctor` now detects the scheduler and `meute install-timers` writes systemd
  user units. Those want `Persistent=true` and lingering enabled — without
  lingering, user timers do not run while you are logged out, which for an
  overnight fleet means they do not run at all.
- **`claude` and `codex` are not on cron's default `PATH`** (they install to
  `~/.local/bin` and `~/.npm-global/bin`). The cron snippet this document's own
  README shipped set no `PATH`, so following it would have failed on every run
  with `the 'claude' CLI is not on PATH`. `git`, `jq`, `python3`, `flock`,
  `timeout` and `gh` are all in `/usr/bin` and fine.
- **Subscription auth survives a bare environment.** Credentials live in
  `~/.claude/.credentials.json`, not a keychain agent, so `env -i` still reports
  `loggedIn=true, authMethod=claude.ai, subscriptionType=max`. This was the
  larger risk and it is not one.

## 10c. Proof standards, and why they differ per tier

Every write tier must now break its own guard and confirm the suite goes red.
This was uneven before: `gen-tests` demanded a mutation check while
`draft-ticket` — the tier that changes production code unattended — asked only
for red-green on the reproduction. The highest-risk task had the weakest proof
standard.

Red-green shows a test is sensitive to *the* defect. It does not show the guard
would catch that defect arriving another way. For a fix that adds a check, only
mutation shows the check is load-bearing.

The requirement is fitted, not uniform. `reproduce` writes no fix and adds no
guard, so mutation does not apply to it; what it gets instead is the warning
below. `lint-sweep`, `conventions`, `dep-audit`, `doc-regen` and the audit tasks
add no guards at all, and demanding a mutation there would be cargo cult.

**A run that ERRORS is not a run that failed.** This is in the templates because
it happened here, to me. Mutating an auth guard, two of three edits produced
syntax errors; pytest reported `3 errors`; a classifier matching only on `failed`
printed "GREEN — TEST IS DECORATIVE" for two guards that were entirely sound. A
mutant must be valid code that is wrong. Adjacent hazards, both real: an edit that
silently did not apply, and stale bytecode — a same-length change does not
invalidate a `.pyc`, so the "restored" run can execute the mutant.

The trigger for all of this was the `prove-it` skill. It is worth recording that
the skill governs the operator and the templates govern the unattended runs, and
that the two had drifted apart — applying the skill's standard to my own work is
what exposed that the templates did not demand it.

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

**`doctor` asserted the wrong claim about scheduling.** Both timers were
installed by `install-timers` and reported by `doctor` as `enabled`. Neither
would ever have fired. `systemctl --user show` gave the real state:

```
UnitFileState=enabled   ActiveState=inactive   NextElapseUSecRealtime=
```

`enable` writes the `timers.target.wants` symlink; `--now` is what starts the
unit, and the two halves fail independently — so a unit can be enabled and inert
at the same moment. `is-enabled` reads the symlink, so it answers *enabled* for a
timer with no next firing. `install-timers` compounded it by sending its own
verification to `/dev/null`: it printed `0 timers listed` and reported success.

Both now assert the next elapse, which is the only property the scheduler acts
on. The same run surfaced a second conflation: `loginctl` needs the *system* bus,
absent inside a container even when the user bus works, and a failed query was
being reported as `lingering is OFF` — sending you to a remedy that errors with
`Host is down`. It is now a third state, *cannot tell*.

The lesson generalises past systemd: **check the property the system acts on, not
the one that is easiest to read.** `enabled` is configuration; `next elapse` is
behaviour. A green check on the first is how a fleet reports itself deployable
and then quietly never runs — the same failure class as a crontab on a machine
with no cron, one layer further in.

**The gate measures the wrong pool.** `quota-self-budget.sh` is a cap on meute's
own footprint, which is most of what the gate is for — but its own header admits
it cannot see interactive usage. The failure that follows is not hypothetical:
on a week where the operator's subscription is nearly spent, `meute status`
reads `quota 100% · ok`, because meute has spent none of *its* budget, and the
next slot competes with exactly the work §1 says it must never compete with.

Reading the real pool needs a browser session cookie, so the honest interim is
a manual override rather than a better probe: `meute pause --for 3d`, checked
before the lock, the manifest and the probe, logged as `status=skipped` so it
consumes no budget. A hold always carries an expiry and lifts itself, and there
is no unbounded form — a fleet paused into silence is the same failure as a
timer that is enabled and inert.

Open: the gate still cannot answer "how much is left?", only "has the fleet had
enough?". `contrib/quota-llm-usage-tracker.sh` is the path to the real reading.

**The finding above stopped being hypothetical on the first night the timers
actually fired.** 2026-08-31, 03:21, unattended: `meute status` read
`quota 100% · ok` and the daily slot ran anyway, straight into the account's
real weekly limit — an HTTP 429 three seconds in, `$0` spent, one turn. Two
things about how it surfaced were themselves findings:

- The claude CLI's own JSON reported `is_error: true` with `subtype: "success"`
  — its event name, not a verdict — so `state/log` recorded `detail=success`
  next to `status=error`. Reading `subtype` as if it meant something was the
  same mistake as reading `enabled` as if it meant *armed*: the field that's
  easiest to print again wasn't the one that was true. Fixed by checking
  `api_error_status == 429` instead, which is what actually happened.
- The raw stdout/stderr behind that line only survived because `run.sh`'s
  `mktemp` files for the engine's output are never cleaned up — an unrelated
  leak that happened to be the only reason this was diagnosable at all. Still
  open: worth capping or scoping once it causes an actual problem, not before.

Fixed: a 429 now sets an automatic hold (`hold_extend`, 24h, never shortening
a hold the operator set on purpose) instead of retrying into the same wall
every slot until a human notices. It does not know the provider's real reset
time — that text is free-form and not worth parsing — so it backs off a day at
a time, which costs nothing per attempt and self-corrects without knowing the
answer precisely. The manual `meute pause` from the prior finding is still the
right tool for *foreseeing* a squeeze; this is what happens when nobody did.

**`doctor` checked binaries against a PATH nothing on this machine uses.** The
binaries section always compared `claude`/`codex` against `CRON_PATH_DEFAULT`
and, when they weren't reachable there, pointed at "the cron block below" — on
a systemd-only host, that block is never printed; the scheduling section takes
a different branch entirely. `install-timers` had the matching problem in the
other direction: it wrote a hardcoded `~/.local/bin:~/.npm-global/bin` into the
unit's own `Environment=PATH=`, correct on this machine purely by coincidence
of layout, silently wrong on the next one. Same lesson as the timer-arming
finding, applied to a different field: check the PATH the thing will actually
run under, not a fixed guess. Both are now derived from where the binaries
actually resolve (`unit_path_line`), and `doctor` checks against that when
cron isn't the active scheduler.

That change retired the last "something is missing from the list" case on a
fully healthy box, which exposed a second, sharper bug: `grep -v` exits 1 when
it selects zero lines — exactly what an empty missing-binaries list produces —
and a bare pipeline (or a plain, non-`local` assignment built from one) takes
that on as its own exit status. Under `set -e` that killed `doctor` outright,
with no message, on precisely the machine state — nothing wrong — that should
have been the easiest of all to report. Factored into `dedup_dirs`, guarded,
and pinned by a test that calls the real function rather than a copy of it —
the first version of that test passed against a hand-written duplicate of the
snippet and would have caught nothing had the actual fix regressed.

**`contrib/quota-llm-usage-tracker.sh`'s own header admitted it had never run
against a live instance — checking why found the instance doesn't exist on
this machine at all.** `bearyjd/llm-usage-tracker` is a real, public repo, but
it isn't cloned, installed, or running here. Verifying the adapter against the
tracker's actual source (`backend/api/routes.py`, `backend/db/models.py`,
`backend/recommendations.py`, `backend/collectors/claude.py`) confirmed every
claim in the adapter's header except one: the default `LUT_URL` was
`127.0.0.1:8000`, a plausible guess, while the tracker's own `serve` command
(`backend/cli.py`) binds `48372`. Fixed, and pinned by a test that reads the
adapter's own error message rather than re-deriving the port, so a future edit
that changes the literal without checking it against the tracker's real
default fails the test instead of drifting again.

Still open, and squarely out of scope for an unattended fix: `llm-tracker auth
claude` requires a *headed* browser and a manual login — Cloudflare's bot
detection on claude.ai depends on a persistent browser profile and a human at
the keyboard. That step cannot run from this container, and should not run
unattended anywhere: it is the operator's own session credential. Deploying
the tracker is therefore a task with a mandatory human step in the middle, not
something to automate through.

## 12. Phase status

Built and accepted:

- `repos.yaml` schema, with commented personal and community examples
- `lib/manifest.py` — validation, queue flattening, policy, template rendering
- `bin/run.sh` — full lifecycle: lock, scrub, preflight, quota gate, queue,
  gates, worktree, render, invoke, capture, report, commit, cleanup, cursor, log
- `lib/engines.sh`, `lib/preflight.sh` — engine adapters and the
  subscription-only guarantees, split out as coherent units
- `bin/quota.sh` — pluggable probe with a stub default
- `tasks/audit-security.md` (tier 2, rotating lens), `tasks/gen-tests.md` (tier 1),
  `tasks/draft-ticket.md` (tier 3, specced tickets only)
- `lib/artifacts.gitignore`
- `contrib/quota-llm-usage-tracker.sh` — a real quota source adapter
- `bin/meute` — review and triage CLI: report lifecycle (new/read/actioned/
  dismissed) and `promote`, which converts a tier-2 finding into a tier-3
  `specced: true` ticket. Plan: `.claude/PRPs/plans/meute-report-lifecycle-cli.plan.md`
- `lib/state.sh`, `lib/fleet.sh` — kv store and fleet accounting, extracted so the
  runner and the review CLI share one implementation of the 80/20 and cap arithmetic
- `lib/report.py` — report parsing; `tests/test_meute.sh` — the first test suite

- `tasks/scout.md`, `tasks/reproduce.md`, `tasks/draft.md` — the community track,
  with the `tier2-scout` tier (read-only `gh`, no `gh api`, no bare `gh`) and the
  candidate/specced ticket gates that separate reproduce from draft

- `tasks/lint-sweep.md`, `tasks/doc-regen.md`, `tasks/dep-audit.md`,
  `tasks/conventions.md` — the tier-1 maintenance set. Each carries an explicit
  decline path (see below).

Phase 2, in rough priority order:

- Remaining tier-2 templates: architecture review, market comparison (needs
  WebSearch in the tier tool set), feature brainstorm

## 13. Acceptance

`bin/run.sh <slot>` against a sample repo must produce a report file, leave the
main checkout untouched, clean up its worktree, advance the cursor, and exit 0.

Verified across six runs on a throwaway repo. Evidence: `state/log`, the files
under `reports/sample-repo/`, and before/after captures of `git status
--porcelain`, `git rev-parse HEAD`, `git worktree list`, and `git branch --list
'meute/*'` showing the main checkout unchanged at `4d77284a`, no leftover
worktrees, and the tier-1 scratch branch surviving with its commit.
