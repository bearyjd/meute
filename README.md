# meute

Spends leftover Claude Code / Codex **subscription** quota on scheduled,
unattended work across a portfolio of local git repositories, plus a small
capped track of contributions to open-source projects.

No daemon, no database, no web UI. `bin/run.sh` does one unit of work and exits.
Scheduling is your cron's job.

Licence: AGPL-3.0. Spec: [`docs/prp/PRP-001-meute.md`](docs/prp/PRP-001-meute.md).

## Requirements

`bash` 4+, `git`, `jq`, `python3` with PyYAML, and `claude` and/or `codex`
signed in to a subscription.

## Your fleet config is private

The harness is public; the list of your projects and what they do is not.
`repos.local.yaml` is gitignored and takes precedence over `repos.yaml`, so you
never have to choose between committing your project list and using the tool.

```
MEUTE_MANIFEST  >  repos.local.yaml  >  repos.yaml
```

`reports/` is committed by default too — see the note under *Output* before you
push a repo containing real audit findings.

## Quick start

```sh
# 1. Fill in repos.yaml — it ships inert, with commented examples.
$EDITOR repos.yaml

# 2. Check the manifest parses and every template resolves.
./bin/run.sh --validate

# 3. See what the next run would pick, without invoking anything.
./bin/run.sh daily --dry-run

# 4. Run it.
./bin/run.sh daily
```

Then check it will actually survive cron, and get a crontab block with the right
`PATH` filled in for your machine:

```sh
./bin/meute doctor
```

### If your machine has no cron

Immutable Fedora variants and many minimal images ship without `cronie`, and a
crontab there is instructions that silently never fire. `meute doctor` detects
which scheduler you actually have. For systemd:

```sh
./bin/meute install-timers        # writes and enables meute-daily/weekly .timer units
loginctl enable-linger "$USER"    # REQUIRED, or timers only fire while you are logged in
systemctl --user list-timers 'meute-*'
```

The units set `Persistent=true`, so a slot missed while the machine was off runs
at next boot rather than being skipped — which plain cron does not do. Output
goes to the journal (`journalctl --user -u meute-daily`) as well as `state/log`.

**Set `PATH` in your crontab.** `claude` and `codex` are usually installed
outside cron's default `PATH` (`/usr/bin:/bin`), so a crontab without it fails
every run with `the 'claude' CLI is not on PATH`. `doctor` prints a block you can
paste, along these lines:

```cron
PATH=/home/you/.local/bin:/home/you/.npm-global/bin:/usr/bin:/bin
17 3 * * *   cd /path/to/meute && ./bin/run.sh daily  >> state/cron.log 2>&1
41 4 * * 6   cd /path/to/meute && ./bin/run.sh weekly >> state/cron.log 2>&1
```

Overlapping fires are safe: the runner takes a non-blocking `flock` and exits 0
if another run holds it. Subscription auth works headless — credentials live in
`~/.claude/.credentials.json`, not a keychain agent that a cron job could not
reach.

## Subscription-only

meute never runs on metered API billing. Claude Code silently prefers an API key
over subscription auth when one is present in the environment, so every
invocation is scrubbed of `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
`OPENAI_API_KEY` (with a warning if any were set), and a zero-cost preflight
refuses to start unless the engine resolves to a real subscription:

```
meute: preflight: claude is not logged in. Run:  claude auth login
```

There is no API-key mode.

## Quota gate

"Quota" is your plan's rolling 5-hour and weekly allowance, not a dollar budget.
`bin/quota.sh` prints one integer 0–100; below `policy.quota_floor_percent` the
runner exits 0 without doing anything. Scheduled chores must never eat the window
you wanted for interactive work.

There is no machine-readable balance on the Claude CLI today (`/usage` is
interactive only; `claude auth status --json` reports the plan tier but not the
balance), so the probe ships as a **stub returning 100** — meaning **the gate
never fires until you wire a real source**. Every log line records which it is:

```
quota=77:stub          ← the gate is not real yet
quota=41:MEUTE_QUOTA_CMD   ← the gate is real
```

Wire it up. Two sources ship, and they answer different questions:

| Source | Answers | Needs |
|---|---|---|
| `contrib/quota-self-budget.sh` | *has the fleet had enough this week?* | nothing — reads meute's own log |
| `contrib/quota-llm-usage-tracker.sh` | *how much of my subscription pool is left?* | llm-usage-tracker with a claude.ai browser login |

Observed cost per run, so you can calibrate rather than guess — it scales with
repo size far more than with task type:

| Repo | Files | Task | Cost | Turns |
|---|---|---|---|---|
| veille-finance | 124 | lint-sweep | $0.17 | 12 |
| immich-journal | 79 | audit-security | $0.36 | 18 |
| bascule-bluetooth | 201 | audit-security | $1.29 | 47 |
| immich-journal | 79 | draft-ticket (opus) | $2.60 | 56 |

Seven daily audits across mid-sized repos is comfortably $6–9, so a ceiling
calibrated on your smallest repo will trip mid-week. `meute status` shows the
week's burn against the ceiling.

The self-budget source cannot see your interactive usage, so it is a cap on
meute's footprint rather than a reading of your pool. That is most of what the
gate is for, and a cap you actually have beats a true reading you do not:

```sh
MEUTE_WEEKLY_RUNS=20 MEUTE_QUOTA_CMD='contrib/quota-self-budget.sh' ./bin/run.sh daily
# or budget by list-price-equivalent effort instead of run count:
MEUTE_WEEKLY_COST_USD=5.00 MEUTE_QUOTA_CMD='contrib/quota-self-budget.sh' ./bin/run.sh daily
```

The real pool needs a claude.ai session cookie, which means an interactive
browser login (`llm-tracker auth claude`); `~/.claude/.credentials.json` alone
yields the plan tier and no message counts.

Other options:

```sh
# llm-usage-tracker (https://github.com/bearyjd/llm-usage-tracker) — adapter included
MEUTE_QUOTA_CMD='contrib/quota-llm-usage-tracker.sh' ./bin/run.sh daily

# or any command that prints one integer 0-100
MEUTE_QUOTA_CMD='my-probe --percent' ./bin/run.sh daily
echo 45 > state/quota-override      # or just pin it by hand
```

**A configured probe that fails makes the runner decline the slot.** It does not
fall back to the stub — falling back would silently disable the gate at exactly
the moment you asked for it. Fail closed, always.

## How work is chosen

`repos.yaml` flattens into an ordered queue. Everything under `repos:` comes
before anything under `community:`, so your own projects always have first claim;
the community track runs only while it stays under `policy.community_share`
(0.20) of the week's runs. `state/cursor` remembers the last item executed per
slot and the next run resumes after it.

Each run creates a worktree on `meute/<task>-<date>`, so your working checkout is
never touched. Read-only tiers leave nothing behind. Write tiers commit to the
scratch branch and **never push** — the branch is the deliverable, and you decide
what happens to it.

## Tiers

| Tier | What it does | Touches code |
|---|---|---|
| 1 | Tests, lint sweeps, doc regen, dependency audits — self-verifying | yes, scratch branch |
| 2 | Security audits, architecture reviews, market comparisons — reports only | no |
| 3 | Bug fixes and features, `specced: true` tickets only, 3 in flight max | yes, scratch branch |

Tier 3 (`tasks/draft-ticket.md`) must reproduce the defect with a failing test
before it may change anything. If it cannot reproduce, it changes nothing and
reports why — a run that guesses at a fix is a failed run, not a productive one.

Tier tool lists are hard availability filters: a tier-2 session has no Write tool
and physically cannot modify the repo.

Write tiers additionally get an `allowed_tools` allowlist of pre-approved command
prefixes, because `acceptEdits` alone denies shell execution — without it a
"self-verifying" task cannot run the suite it just wrote. Treat the allowlist as
a blast-radius reducer, not a sandbox: `pytest` runs test code the agent wrote
seconds ago. What it buys you is no network, no installs, no `git push`, and no
writes outside the worktree.

## Output

- `reports/<repo>/<task>-<date>.md` — the report, with a metadata header
- `state/log` — one line per invocation, including every skip
- `state/cursor` — round-robin position and lens rotation counters

```
2026-08-28T15:22:54-04:00	week=2026-35	slot=weekly	status=ok	kind=personal
repo=sample-repo	task=gen-tests	tier=tier1	engine=claude	auth=claude.ai/max
branch=meute/gen-tests-2026-08-28	commit=64c180d	report=reports/...	cost=0.31	turns=29	dur=263s
```

A failed run still writes a report (with the engine's stderr tail) and still
advances the cursor — a poisoned entry must not stall the whole fleet.

**The runner commits its own `state/` and `reports/` at the end of each run**,
scoped to those paths, so a cron-driven fleet doesn't leave you with a
permanently dirty checkout. It never pushes. Set `MEUTE_NO_AUTOCOMMIT=1` if you
would rather commit the audit trail yourself.

Skipped runs (quota floor, empty queue, lock held) append their log line but do
not commit — otherwise a quota-starved week would produce a commit per cron fire.
Those lines are folded into the next real run's commit.

## Task catalogue

| Task | Tier | Slot | What it does |
|---|---|---|---|
| `lint-sweep` | 1 | daily | runs the repo's **own** linter/formatter; caps the diff at 300 lines |
| `gen-tests` | 1 | weekly | writes tests, then breaks the code to prove they have teeth |
| `doc-regen` | 1 | weekly | regenerates *generated* docs; never writes prose |
| `dep-audit` | 1 | weekly | dependency risk, sorted by whether the vulnerable path is actually reachable |
| `conventions` | 1 | weekly | conformance against the repo's **written** conventions only |
| `audit-security` | 2 | daily/weekly | security audit through one rotating lens |
| `draft-ticket` | 3 | weekly | fixes a `specced: true` ticket, reproduction first |
| `scout` / `reproduce` / `draft` | community | weekly | the contribution pipeline |

Each maintenance task has a condition under which the right answer is to change
nothing — no linter configured, no doc generator, no written conventions — and
the templates state that declining is a successful run. Otherwise an unattended
agent under implicit pressure to look productive finds something to do, and for
maintenance work that means a large diff nobody asked for.

## Reviewing the output — `bin/meute`

The runner produces; `bin/meute` is how you consume. The failure mode of a fleet
like this was never "the runner breaks" — it's forty unread audits rotting in
`reports/`. So reports carry triage state, and `--new` is the default view.

```sh
./bin/meute doctor              # is this deployable? checks cron's real environment
./bin/meute status              # quota, what runs next, this week, unread count
./bin/meute reports             # unread reports (--all for everything)
./bin/meute findings            # one row per FINDING — the actual unit of decision
./bin/meute show <id>           # print a report, mark it read
./bin/meute promote <id> -f 1   # finding 1 becomes a tier-3 specced ticket
./bin/meute dismiss <id> -f 2 -r false-positive -m "guarded upstream"
./bin/meute branches            # scratch branches, with what each still holds
./bin/meute branches --prune    # delete only the ones whose work is already in the base
```

A report id is its path under `reports/` without the `.md`
(`netlens-android/audit-security-2026-08-28`). Anything printed as an id can be
passed straight back in. `show` writes only the report to stdout, so
`./bin/meute show <id> | bat` works.

`promote` is the loop that makes the tier system worth having: a tier-2 audit
finds something, one command turns it into the `specced: true` ticket that tier 3
is allowed to fix. It refuses when the tier-3 in-flight cap is already reached.

### Where tickets live

`promote` writes to `state/tickets.yaml`, never to `repos.yaml`. The manifest
merges both sources through the same `specced: true` gate, and a ticket id
present in both is a hard error.

The reason is narrow and worth stating: PyYAML cannot round-trip a file without
destroying its comments, and `repos.yaml` is mostly hand-written documentation.
Rather than take a dependency so a machine can rewrite hand-curated config,
machine-written state gets its own file. `repos.yaml` is yours alone.

## Adding a task

1. Write `tasks/<name>.md`. It must define the job, stop conditions
   (file budget, scope boundaries), falsifiability requirements (concrete exploit
   payloads or run-it-then-break-it checks, never vibes), and an output contract
   naming the exact sections — including what to say when nothing was found.
2. Register it under `tasks:` in `repos.yaml` with a tier and its slots.
3. Add it to a repo's `tasks:` list.

Templates are rendered with `{{REPO_NAME}}`, `{{REPO_SPEC}}`, `{{REPO_PATH}}`,
`{{TASK}}`, `{{TIER}}`, `{{DATE}}`, `{{BRANCH}}`, `{{FILE_BUDGET}}`, `{{LENS}}`,
`{{REPORT_PATH}}`, `{{DEFAULT_BRANCH}}`, `{{ALLOWED_COMMANDS}}`, `{{UPSTREAM}}`,
`{{ETIQUETTE}}`, `{{TICKET_ID}}`, `{{TICKET_TITLE}}`, `{{TICKET_NOTES}}`.
Rendering fails loudly on an unknown placeholder.

Reports are the engine's **final message** — templates must tell it not to write
the file itself. That is what lets a read-only tier produce a report at all.

## Community track

Each allowlisted project needs `etiquette/<project>.yaml`
(see [`etiquette/example-project.yaml`](etiquette/example-project.yaml)):
`ai_policy`, `cla`, `pr_size_preference`, `comment_before_pr`. No etiquette file,
no contribution.

Three stages, each refusing work the previous one did not clear:

| Stage | Runs on | Produces |
|---|---|---|
| `scout` | any allowlisted project | ranked shortlist of issues, plus rejects with reasons |
| `reproduce` | tickets **not** yet `specced: true` | a failing test, or a verdict that it does not reproduce |
| `draft` | tickets you marked `specced: true` | a minimal fix on a local branch, plus a draft PR body |

`draft` **never pushes and never opens a PR** — it stops at the local branch and
you submit by hand. The `gh` allowlist excludes bare `gh` and `gh api` (which can
POST); the permission layer parses compound commands, so an allowlisted prefix
cannot smuggle a chained `gh pr create` past the gate.

Flipping a ticket to `specced: true` after reading the reproduce report is a
deliberate manual step. Contributing to someone else's project should not be
something that happens while you are asleep.

### Findings, not reports

A report is a row; a decision is made per finding. An audit that turns up a
CRITICAL and two HIGHs is three decisions, and acting on one must not hide the
other two — which is exactly what report-level state did.

`meute findings` lists them grouped by repo, most severe first inside each group,
because three findings in one codebase cost less to review than three context
switches. A report closes only once every finding in it has a decision.

Dismissing takes a reason from a fixed set — `false-positive`, `wont-fix`,
`out-of-scope`, `duplicate`, `too-large`, `other` — plus optional free text. The
enum is not bureaucracy: it is the only signal for which audit lens to retire.
Twenty-eight dismissals tell you nothing if they are all free text, but twenty-
eight `false-positive` under one lens says stop running it.

### Pruning scratch branches

Tier-1 tasks commit to a branch and nothing deletes it, so unreviewed lint sweeps
and doc regens accumulate. `--prune` removes only branches that add nothing their
base lacks, and reports the rest with a line count so you can look before
deciding.

The check is content-based on purpose. Squash-merge — the normal way these land —
rewrites the commit, so the branch is not an ancestor of the base and
`git branch --merged` will never list it, however completely its work was
absorbed. Asking "does this branch add any line the base lacks" is the only
question with a reliable answer.

### `autonomous_agents` — the gate that matters

Set it in the etiquette file. Some projects welcome AI-assisted contributions
from a human but forbid agent-authored ones — ripgrep's `AI_POLICY.md` says
exactly that. With `autonomous_agents: banned`, the queue builder refuses every
contribution stage for that project and leaves only scouting. It is enforced in
code, not in prompt text.

Clone the project yourself before adding it; every stage runs in a worktree of
that clone.

## Engines

`--engine codex` swaps `claude -p` for `codex exec` with equivalent semantics:
read-only tiers map to `-s read-only`, write tiers to `-s workspace-write`, and
the final message is read from `-o` rather than a JSON envelope. Set
`MEUTE_CODEX_MODEL` to pin a model.
