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
./bin/meute install-timers        # writes, enables *and arms* both .timer units
loginctl enable-linger "$USER"    # REQUIRED, or timers only fire while you are logged in
systemctl --user list-timers 'meute-*'
```

The units set `Persistent=true`, so a slot missed while the machine was off runs
at next boot rather than being skipped — which plain cron does not do. Output
goes to the journal (`journalctl --user -u meute-daily`) as well as `state/log`.

**Enabled is not armed.** `systemctl --user enable` writes a symlink;
`--now` is what starts the timer, and a unit can hold both states at once —
enabled on disk with no next firing, so it never runs. `is-enabled` reads the
symlink and calls that "enabled". `install-timers` and `doctor` therefore assert
the next elapse instead, and an enabled-but-inert timer is reported as such:

```
warn  meute-daily.timer is enabled on disk but NOT armed: no next firing, so the daily slot will not run
warn  arm it with:  systemctl --user start meute-daily.timer
```

That state self-heals at your next login, when `systemd --user` restarts and
pulls `timers.target.wants` in. Until then the slot is dead.

**Being told when it stops.** `./bin/meute health` prints one line per reason
the fleet may have stopped and exits 1 if there is any: no `state/log` line
within twice the daily cadence, no `status=ok` for 3 days, 3 errors in a row,
an automatic (rate-limit) hold, the run lock held by a live run past the unit's
timeout, a timer not armed or lingering off, `state/` under `policy.min_free_mb`,
leftovers of killed runs, a quota snapshot over a day old, a policy override in
force. A healthy fleet prints nothing. `install-timers` also writes
`meute-health.timer` (hourly, `meute health --alert`) and adds
`OnFailure=meute-alert.service` to both run units. Under `--alert` the text goes
on stdin to `policy.alert_cmd`, a command line you choose; empty (the default)
sends nothing. The text never names a repository. For example:

```yaml
policy:
  alert_cmd: "notify-send 'meute' \"$(cat)\""     # or: curl -s --data-binary @- https://ntfy.sh/<topic>
```

Turn it off with `systemctl --user disable --now meute-health.timer`.

**If you run meute from inside a container** (toolbox, distrobox, devcontainer),
the *user* bus is usually reachable while the *system* bus is not — so
`systemctl --user` works and `loginctl` fails with `Host is down`. The units then
execute on the **host**, with the host's `PATH` and not the container's. `doctor`
reports lingering as *cannot tell* rather than guessing, because the remedy it
would otherwise print cannot run there. Check it on the host:

```sh
loginctl show-user "$USER" --property=Linger
```

And confirm the host has everything a run needs, under the `PATH` the *unit*
sets — not the wider one the user manager hands out, which is how you verify a
more permissive environment than the one that runs:

```sh
systemd-run --user --wait --pipe \
  --setenv=PATH=$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin \
  /bin/sh -c 'command -v jq python3 git claude codex; python3 -c "import yaml"'
```

`jq`, `python3` and `PyYAML` are as load-bearing as the engines — `meute` exits
immediately without `jq`, and the manifest will not parse without `PyYAML`. On
an immutable host those are exactly the packages that tend to live in the
container and not outside it.

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
if another run holds it. `--wait-lock SECS` waits up to SECS for it instead. Subscription auth works headless — credentials live in
`~/.claude/.credentials.json`, not a keychain agent that a cron job could not
reach.

### Exit codes

By default `run.sh` exits 0 on every skip and 1 on a failure, so cron and the
installed units behave as they always have. `--strict-exit` (or
`MEUTE_STRICT_EXIT=1`) makes the status name the outcome, so a loop can branch
on `$?` alone:

| status | meaning |
|-------:|---------|
| 0 | ran ok (a dry run included) |
| 1 | ran and failed |
| 2 | usage error |
| 10 | hold |
| 11 | another process holds the run or staged queue lock |
| 12 | budget (meute's own ceiling) |
| 13 | quota (below the floor, or the probe failed) |
| 14 | nothing eligible (or no queue) |
| 15 | host not healthy (load, disk) |
| 16 | already done: a forced staged item another fire finished (`--once`) |
| 17 | staged-only run stopped because the staged plan failed validation |
| 70 | the runner itself died |

The `code=` field of the `state/log` line uses the same vocabulary (`hold`,
`lock`, `budget`, `quota-floor`, `quota-unknown`, `nothing-eligible`,
`no-queue`, `load`, `disk`, `already-done`, `plan-invalid`, `ok`, `failed`, `died`).

`meute drain <daily|weekly> [--source plan|staged|manifest] [--max N] [--until HH:MM] [--repo R]...`
is that loop, written once. It runs the slot unforced, one fire after another
(each waits up to 900 s for the lock), so the cursor, the community share, the
tier-3 cap and the pool still apply; `--repo` narrows the queue without forcing,
on a cursor of its own, so the timers' rotation is not moved.
It ends with 0 after one full rotation, when the staged plan is drained, or at
`--max`/`--until`; with 1 after three failed fires in a row; and otherwise
with the status of the fire that declined. Use `--source staged` to limit the
drain to staged work even after a queue is exhausted or removed. Each fire
reads the current staged queue, so an authorized replacement can change the
work available to later fires. The default `plan` source allows manifest
fallback. Use `--source manifest` to drain configured repositories.

## Subscription-only

meute never runs on metered API billing. Claude Code silently prefers an API key
over subscription auth when one is present in the environment, so every
invocation is scrubbed of API credentials, Anthropic/OpenAI endpoint overrides,
Claude provider-routing flags, and upper- and lower-case proxy variables (with
a warning if any were set), and a zero-cost preflight
refuses to start unless the engine resolves to a real subscription:

```
meute: preflight: claude is not logged in. Run:  claude auth login
```

There is no API-key mode.

## Triage

Findings wait for one human decision each. The CLI is the reference interface;
the inbox is the same thing with a cursor:

```sh
./bin/meute findings                 # undecided findings, grouped by repo, severity first
./bin/meute show <report-id>         # the full report (marks it read)
./bin/meute promote <id> -f <n>      # -> a tier-3 draft on the next weekly slot
./bin/meute dismiss <id> -f <n> -r <reason> [-m why]
./bin/meute resolve <id> -f <n> -m "fixed in PR #12"

./bin/meute tui                      # the inbox in the terminal
./bin/meute web                      # the web inbox + Run tab in a browser, loopback only
```

A decision can be made durable and safe to retry. Give `resolve` or `dismiss`
a finding (`-f`), a request key and the finding's revision, as
`meute findings --json` lists it (`revision`; `r1:absent` while it has no
decision):

```sh
./bin/meute dismiss <id> -f <n> -r <reason> --request-key K --expected-revision REV [--operator OP]
./bin/meute resolve <id> -f <n> -m "fixed in PR #12" --request-key K --expected-revision REV
```

`--request-key` (8-128 of `A-Za-z0-9._:-`) and `--expected-revision` go
together and need `-f`; `--operator` (else `$MEUTE_OPERATOR`, else `local`) is
a label, not a login. The result is one JSON line, `{"receipt": {...},
"replayed": false}`. If the finding changed since REV the decision is refused
(exit 3, `stale_revision`, with `current_revision`); a retry of the same key and
text returns the same receipt without looking at the revision, even after the
finding moved (`replayed: true`); the same key with other text is exit 4
(`key_conflict`). Exit 5 (`indeterminate`) means a pending receipt's row was
since changed by someone else: read the finding again and use a new key. Exit
70 or 75 (`busy`) means retry with the SAME key. `-r` must be exactly one of the
listed reasons. Receipts live under `state/receipts/decisions/` for 30 days
(`MEUTE_RECEIPT_TTL_DAYS`, 1-365); `MEUTE_DECISIONS_LOCK_WAIT` (1-60 seconds,
default 10) bounds the wait for `state/reports.lock`. Without `--request-key`
both commands behave exactly as before.

`tui` is a Textual app (PRP-003): `j`/`k` move, `Enter` shows the
finding with its evidence, `p` promotes, `d` dismisses (a reason is required —
it is the sole promoted-vs-dismissed signal per lens), `r` resolves, `/`
filters on any column, `g` jumps to the next repo, `a` shows decided findings
too. Every action goes through the CLI commands above, so the two can never
disagree. Tabs for the tier-3 drafts awaiting merge and for every report.

The Textual UI lives in its own uv venv under `tui/`, created on first use.
**The runner has no dependency on it**: `bin/run.sh` succeeds on a machine where
that venv was never created, and the suite pins that.

`meute web` is a separate, real web page (design:
`docs/superpowers/specs/2026-11-15-web-inbox-design.md`) served by the
stdlib-only `tui/webserver.py` under plain `python3` -- no venv, no Textual. It
has an inbox tab (triage findings) and a **Run tab** that launches the fleet's
work:

1. **Plan** -- read-only; lists the repos/tasks `meute plan` proposes. Copies
   of a repository are not offered: a line under each repo says how many
   duplicate copies were hidden (the paths are in its tooltip), and a summary
   above the list counts the copies collapsed and the repos skipped; the
   skipped paths are listed under it.
2. **Tick repos** -- nothing is ticked by default, and Enqueue stays disabled
   until at least one is.
3. **Enqueue** -- stages only the ticked repos, *adding* them to any staged
   queue (`--append`), so unattempted work and completion marks survive. A
   repo the CLI refuses is named in the notice; the others are still staged.
4. **Start** (after a confirm click) -- Go runs the daily slot, then the weekly
   slot, for the staged items only (staged read-only tasks are mostly
   weekly-only; repos.yaml lists at least one read-only task for both slots), one
   item at a time. The staged source runs through the ordinary scheduler
   gates, including the quota floor, pause, lock and budget. Choose the
   manifest source to run configured repositories. Stop lets the current
   item finish.
5. **Progress** -- the page polls the run status (current item, done/remaining,
   recent outcomes).

Safety model: it binds `127.0.0.1` by default (loopback only). Every POST needs
a per-process token plus Host/Origin checks. Start refuses while the fleet is
paused or a run is already going, and the runner's own quota floor still
applies. To bind off loopback, pass both `--host <addr>` and `--insecure-public`
(IPv4 only; IPv6 hosts are rejected). `<addr>` must be the specific address the
browser will use, such as a LAN or tailnet IP: wildcard binds (`0.0.0.0`, `0`,
`*`) are rejected, because the Host check would refuse every request. The
`--insecure-public` flag acknowledges that anyone who can
reach the listener can triage findings **and start fleet runs that spend your
Claude/Codex quota**. A tailnet address is the sensible way to use it from a
phone.

Host rule: the server accepts only the exact bound `host:port` as the Host
header. With the default bind, browse to `127.0.0.1:<port>`; with
`--host localhost` the browser must use `localhost:<port>` (`127.0.0.1:<port>`
then returns 403); a non-loopback bind must be browsed at the same address.

An authenticated gateway can use the separate managed Fleet listener:

```sh
meute web --port 8643 --fleet-finding 'repo/report#1'
```

It binds to `127.0.0.1`. Restrict access to the listener to the gateway
trust domain and authorize each request at the gateway. Its GET routes are
`/`, `/static/fleet.js`, `/api/fleet/status`, and the exact finding URL
(`/fleet/finding/repo/report/1` in this example).
The status is the serving process's controller observation. It includes
staged queue counts and the configured finding reference. The finding opens
as plain text from a regular report of up to 4 MiB. Continue to use
`meute web` for interactive triage and run controls.

Known limitation: if a scheduled timer finishes the same staged item between
the page's pending check (a `lib/manifest.py` subprocess) and `run.sh` taking
its lock -- a window of tens to hundreds of milliseconds -- one duplicate
read-only run can occur. Closing it needs a `run.sh` change, so it is accepted.

Browsers mark requests another site starts (an `<img>`, a no-cors fetch) with
`Sec-Fetch-Site: cross-site` or `same-site`; the server refuses those with 403
on every route, so a web page cannot make it run `meute plan` scans. A second
`meute web` on a busy port exits with `meute web: port <p> is already in use`.

## Quota gates

"Quota" is your plan's rolling 5-hour and weekly allowance, not a dollar budget.
Scheduled chores must never eat the window you wanted for interactive work —
that is the one constraint the whole design is shaped around. A run has to
clear **two** gates, and they answer different questions:

| Gate | Answers | Reads |
|---|---|---|
| subscription | *is there room in the pool I share with the fleet?* | the plan's own 5h/7d windows, snapshotted by the status line (Claude) or a probe (Codex) |
| self-budget | *has the fleet taken its agreed share this week?* | meute's own `state/log` against `policy.weekly_cost_usd` |

### The subscription gate

Quota is per engine: Claude's pool and Codex's pool are measured separately,
and the runner probes each candidate's engine while selecting, so a fleet that
mixes engines does not stall on the first entry whose engine cannot be measured.

#### Claude

Nothing on the CLI reports the balance (`claude auth status --json` gives the
plan tier, not the pools) — but the JSON Claude Code feeds its **status line**
does, for Pro/Max seats: `rate_limits.five_hour` and `rate_limits.seven_day`,
each with `used_percentage` and `resets_at`. So the source is a wrapper that
snapshots those fields every time you work interactively, which is exactly
when they change:

```sh
./bin/meute install-statusline
```

That puts `contrib/statusline-capture.sh` in front of whatever status line you
already have (kept verbatim as its argument; backup in
`settings.json.meute-bak`), and from the next turn on `state/rate-limits.json`
holds the real windows. `bin/quota.sh --engine claude --with-source` reads it
through `contrib/quota-subscription.sh`, reporting the **scarcer** of the two
pools. Below `policy.quota_floor_percent` the runner declines. A window whose
`resets_at` has passed counts as fresh — the fleet runs at 03:17, long after
your last session, and refusing until you next open one would idle it exactly
when the capacity is going spare; the 429 auto-pause is the backstop.

Until you install it the probe answers from a **stub returning 100**, and both
`meute status` and `meute doctor` say so in as many words. Every log line
records which source answered:

```
quota=100:stub                     ← the gate measures nothing yet
quota=61:quota-subscription.sh     ← the gate is real
```

Other Claude sources, in precedence order — an explicit `MEUTE_CLAUDE_QUOTA_CMD`
(`MEUTE_QUOTA_CMD` is its legacy alias) wins over the snapshot, which wins over
`state/quota-override`, which wins over the stub:

```sh
MEUTE_CLAUDE_QUOTA_CMD='my-probe --percent' ./bin/run.sh daily   # any command printing 0-100
echo 45 > state/quota-override                                   # or pin it by hand
MEUTE_CLAUDE_QUOTA_CMD='contrib/quota-llm-usage-tracker.sh' ./bin/run.sh daily  # llm-usage-tracker, if you run it
```

**A configured source that fails makes the runner decline the slot.** It does
not fall back to the stub — falling back would silently disable the gate at
exactly the moment you asked for it. Fail closed, always. That includes a
`state/rate-limits.json` that exists but cannot be read.

**Probes run bounded, with errexit on.** Each configured probe command runs
under `timeout 30` in `bash -Eeuo pipefail`, so a hung probe declines the slot
instead of stalling the fire. Because errexit is on, a probe whose earlier
command fails now declines even if its last command prints a value
(`false; echo 50` declines; before, it reported 50). This is a deliberate
fail-closed behaviour change: write probes so every command succeeds, or chain
them with `&&` or `||` where a failure is expected.

#### Codex

Codex has no built-in balance source, and none of the Claude sources — the
snapshot, the override, the stub — is ever presented as a Codex balance. Codex
jobs run only when `MEUTE_CODEX_QUOTA_CMD` names a probe; otherwise they decline:

```sh
MEUTE_CODEX_QUOTA_CMD='my-probe --percent' ./bin/run.sh daily
./bin/quota.sh --engine codex --with-source     # what the runner will see
```

The probe must be a trusted local command that prints one integer 0-100 — the
real remaining ChatGPT/Codex percentage. Do not point it at a constant
`echo 100` merely to enable Codex jobs: that defeats the human-quota protection
the gate exists for. The timers read the user session's environment, so
persist the variable there rather than in the repository —
`~/.config/environment.d/meute.conf` with one `MEUTE_CODEX_QUOTA_CMD=...` line
is read by `systemd --user` at login. `install-timers` does not do this for you.

### The self-budget gate

Declare a ceiling in the manifest and it applies with no environment at all:

```yaml
policy:
  weekly_cost_usd: 15.0     # or weekly_runs: 20 — one or the other
```

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
week's burn against the ceiling. The floor does not apply here: the ceiling is
already meute's allocation, so exhausted means 0 and 0 is what stops it.

### `meute policy` — an override that cannot be forgotten

To lower the floor or cap for a night without editing the manifest (and
remembering to put it back):

```sh
./bin/meute policy set quota_floor_percent=1 weekly_cost_usd=50 --for 8h -r "night run"
./bin/meute policy show
./bin/meute policy clear          # lift it early
MEUTE_QUOTA_FLOOR=1 ./bin/run.sh daily   # one invocation, nothing written
```

The override lives in `state/policy-override`, is read after the manifest, and
is checked by the manifest's own rules (a bad value is refused at `set`, judged
against the rows already in force; a non-finite number such as `nan` or
`inf` is refused, and a hand-edited one is ignored like an expired row). There is one weekly ceiling at a time:
setting `weekly_runs` drops a `weekly_cost_usd` row, and the reverse.
`--for` is mandatory and capped at 7 days; an expired row, or a hand-edited one
past the cap, is ignored. Every run
line carries `policy=override` while one is in force, and `status`/`doctor`
say so first. Overridable: `quota_floor_percent`, `weekly_runs`,
`weekly_cost_usd`, `community_share`, `tier3_max_in_flight`.

### `meute pause` — the gate cannot protect you from yourself

The gates read what they can measure. The snapshot is only as fresh as your
last interactive turn, a window that rolled over since then counts as fresh
whatever you have used in it, and no reading knows that you are *about* to
need the pool for something that matters. So there is a manual override:

```sh
./bin/meute pause --for 3d -r "saving the week for my own work"
./bin/meute resume        # lift it early
```

Every slot then declines, logged as `status=skipped`, before it takes the lock
or reads the manifest — and a declined run consumes none of the weekly budget.
`status` and `doctor` both lead with the pause, because a paused fleet reading
`quota 100% · ok` is how you conclude it is about to run.

**A hold always expires** (default 24h; `45m`, `6h`, `3d`, `2w`, up to a year)
and lifts itself when it does. There is deliberately no `forever`: a fleet
paused into silence is indistinguishable from a broken one, and `resume` already
says "indefinite, and I know I did it." The hold lives in `state/`, which is not
committed, so it is local to the machine that set it.

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

## Staging a read-only portfolio plan

`meute plan` takes a read-only inventory of every git checkout under a directory
(default: this checkout's parent), compared to the manifest. Repo identity is
`device:inode`, so `/home/<you>` and `/var/home/<you>` spellings of the same tree
agree. Linked worktrees, submodules, repos with no commits yet, and repos whose
git dir lives outside the scan root are skipped. The depth limit is
`MEUTE_PLAN_MAX_DEPTH` (default 4, max 16).

```sh
./bin/meute plan                        # inventory this checkout's parent; writes nothing
./bin/meute plan /path/to/scan          # inventory a specific directory
./bin/meute plan --enqueue              # stage exactly that plan for the timers
./bin/meute plan --enqueue --allow-web  # also stage tasks that use WebSearch / WebFetch
./bin/meute plan --enqueue --only /path/to/repo  # stage just that repo; no tree walk
./bin/run.sh daily --dry-run            # see which staged item the next fire would take
```

Without `--enqueue`, the command prints what it found and exits. With it, the
plan is staged in `state/plan-queue.json` — which lists every unconfigured repo
by absolute path, and is gitignored for that reason, as is the `state/.kv.*`
scratch its bookkeeping uses — and the runner prefers it until every entry is
attempted (or found missing), then archives it and returns to the manifest.
Enrollment in `repos.local.yaml` is never a side effect.

Staging over a queue that still has unattempted items is refused: pass
`--append` to add to it (completion marks kept) or `--replace` to discard it and
its marks. `--only` checks each named path without walking the tree, reports
every bad one in one run (`rejected<TAB>path<TAB>reason` on stdout) and stages
nothing; with `--skip-invalid` it stages the good ones and exits 3. Each repo's
root-commit identity is cached in `state/plan-cache` by path and HEAD, so an
unchanged repository costs one `rev-parse`; deleting the file is always safe.
`--only` dedups against enrolled repos, the other named paths, and copies a
previous scan recorded in that cache.

A scan usually finds the same repository more than once — scratch clones under
`output/` or `build/`, vendored upstream checkouts, a `--separate-git-dir`
checkout. `plan` keys each repository by its set of root commits (never its remote URL,
which can embed a credential; the whole set, so a repo that merged another
project's history is not mistaken for that project) and plans one copy per key. A copy of an enrolled
repository is not planned at all. Otherwise the canonical copy is the first by:
not scratch-looking (a path component such as `output`, `build`, `vendor`,
`upstream`, `tmp` or `.local-research`; the list is in `lib/plan_dedup.sh`), not
a `.git`-file checkout, fewest path components, shortest path, then byte order —
so the same tree always picks the same copy. The other copies are listed under
"Duplicates collapsed" and in `--json`'s `duplicates`, and never staged;
`--only` on one is refused with the canonical path to pass instead (or enroll
the copy to audit it separately). A copy whose HEAD commit the kept copy lacks
is *diverged*: it is kept and planned too, and listed under "Diverged copies
(kept)" and in `diverged`. A repository whose history cannot be read is listed
as skipped, with a hint (`git fsck`, a dangling alternates entry). A repository with no copies
is always kept, whatever its path looks like.

A staged plan only includes tasks whose tier tools are a subset of `Read,Grep,Glob`.
`--allow-web` adds tasks that also use `WebSearch,WebFetch` — note that this sends
queries derived from private, un-enrolled code to third parties, which is why it is
opt-in and recorded in the plan as `allow_web`. Tasks with `Bash` or any other tool
are never staged by `plan`; enroll those repositories in the manifest instead. The
runner re-validates every staged entry against the manifest on each fire and refuses
writing tiers and un-allowed web tiers even if state is hand-edited.

A staged run is read-only analysis, but it still creates a `meute/<task>-<date>`
branch and a temporary worktree in that repo (removed on exit). A killed run can
leave them behind.

`--dry-run` selects and renders without invoking an engine. It is not entirely
free of side effects: it records a vanished staged repo as missing, logs a repo
whose HEAD cannot be resolved as an error and steps past it (the cursor moves),
archives a plan whose every item has been attempted, and — as it always has —
appends a `status=skipped` log line when one of the gates before selection
declines.

`meute status` shows `staged plan: n of m attempted` when a plan is active, and
`next <slot>` reflects the plan while one is staged.

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

Nothing under `state/` or `reports/` is ever committed. The runner appends to
`state/log` after every invocation (including skipped runs), which means your
checkout is never dirty from meute. It never pushes.

## Task catalogue

| Task | Tier | Slot | What it does |
|---|---|---|---|
| `lint-sweep` | 1 | daily | runs the repo's **own** linter/formatter; caps the diff at 300 lines |
| `gen-tests` | 1 | weekly | writes tests, then breaks the code to prove they have teeth |
| `doc-regen` | 1 | weekly | regenerates derived docs and corrects source-backed factual errors without rewriting authored prose |
| `dep-audit` | 1 | weekly | dependency risk, sorted by whether the vulnerable path is actually reachable |
| `conventions` | 1 | weekly | conformance against the repo's **written** conventions only |
| `audit-security` | 2 | daily/weekly | security audit through one rotating lens |
| `audit-intent` | 2 | weekly | compares documented product claims with evidence at the audited commit, by explicit enrollment |
| `draft-ticket` | 3 | weekly | fixes a `specced: true` ticket, reproduction first |
| `scout` / `reproduce` / `draft` | community | weekly | the contribution pipeline |

Each maintenance task has a condition under which the right answer is to change
nothing — no linter configured, neither a doc generator nor a convention-derived
reference, or no written conventions — and
the templates state that declining is a successful run. Otherwise an unattended
agent under implicit pressure to look productive finds something to do, and for
maintenance work that means a large diff nobody asked for.

### Enable an intent audit

Add `audit-intent` to the chosen repository's `tasks` list in your active
manifest. With `meute discover`, select the task by number. The default
selection leaves it off, and portfolio plans leave it out of their queues.

`repos.local.yaml` and `MEUTE_MANIFEST` select standalone manifests. In an
existing private manifest, add this declaration under its `tasks:` mapping
and keep its existing task declarations. Use the shipped read-only `tier2`
definition from `repos.yaml`.

```yaml
  audit-intent:
    tier: tier2
    template: tasks/audit-intent.md
    slots: [weekly]
    portfolio: false
```

```sh
./bin/run.sh --validate
./bin/run.sh weekly --source manifest --repo YOUR_REPO --task audit-intent --dry-run
```

The rendered prompt in `state/dry-run-prompt.md` includes the exact Git
commit the runner resolved. Free-form audits file a normal Markdown report
with unvalidated claim references. If you have État-Major progress
evidence for the same commit, you can supply a brief record with its full SHA
and evidence identifiers in the repository's private manifest `spec`. The
runner includes `spec` in every task prompt for that repository.

To compare exact claim IDs across runs, supply a version 1 JSON claim list to
an explicitly enrolled, read-only `audit-intent` task.

```sh
./bin/run.sh weekly --source manifest --repo YOUR_REPO --task audit-intent \
  --audit-claims /path/to/claims.json --strict-exit
```

The `revision` must be the full commit ID the runner resolves for the repo.
Each claim needs a tracked, repo-relative regular file `path`, a stable
`section` and `key` in lowercase hyphenated form, and a display `title`.
Optional `start_line` and `end_line` specify an inclusive range in the pinned
file. Optional `id` preserves an operator's requirement ID verbatim. IDs can
use up to 128 ASCII letters, digits, and `._:/#-`, starting with a letter or
digit. With `id` omitted, Meute derives it from the exact path, section and
key. Use `root` for unheaded source material. See the
[six-claim Meute fixture](tests/fixtures/meute-audit-claims.json) for the shape.
The list may have 1 to 25 claims and must fit in 16 KiB both before and after
normalization. The rendered audit prompt must fit in 96 KiB. Pinned audits
use the Git checkout without copying manifest `worktree_files` into it.

The Markdown report includes a versioned JSON result block and the runner's
`audit_claim_ids` status. `verified` means the exact ID set matched, including
one record per ID. A missing, duplicate, unknown or malformed result marks
the audit unverified and fails the run. You can check a saved report with
the original claim list. Older reports remain readable and replay reports
their IDs as `unvalidated`.

```sh
python3 lib/audit_intent.py verify /path/to/claims.json reports/YOUR_REPO/REPORT.md
```

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

### Validate feature readiness

```sh
./bin/meute readiness validate readiness.json --owner-policy owner-policy.json
```

Use two UTF-8 JSON documents. Each takes integer `version` set to `1`.

| Document | Required fields besides `version` |
| --- | --- |
| Readiness record | `repo` (enrollment name), `ref` (literal `refs/heads/…`), `base_commit` (full commit ID), `slice_id`, `intent_ref`, `plan_revision`, and `evidence` |
| Operator policy | `repo`, `slice_id`, `plan_revision`, `record_sha256`, `manifest_path`, `manifest_sha256`, `checkout`, `report_inventory`, `evidence_root`, `attested_digests`, `assessment`, `deferrals`, and `accepted_conditions` |

The record's `evidence` object has arrays for `docs`, `codemap`, `baseline`,
`acceptance`, and `audits`. Use empty arrays for missing evidence. Each supplied
reference has `ref`, `revision`, and either the lowercase `sha256` digest or a
full `git_blob` ID. An optional `command` appears in output as text.

Supply the policy from an operator-controlled path. Use the canonical absolute
paths for `manifest_path` and `checkout`, and lowercase SHA-256 digests of the
record and manifest bytes. The effective manifest is `MEUTE_MANIFEST` if set
and nonempty, otherwise `repos.local.yaml` if present, then `repos.yaml`.
`report_inventory` maps report paths relative to `reports/` to lowercase
SHA-256 digests. An empty inventory is `{}`.

Every policy field is required and no other field is accepted:

- `evidence_root`: the absolute directory evidence files are trusted from.
- `attested_digests`: SHA-256 digests of evidence files outside
  `evidence_root` that the operator vouches for. Use `[]` for none.
- `assessment`: `security` and `cleanup`, each `{"affirmed": true|false,
  "findings": {"<report id>#<n>": {"fingerprint": "<40 hex>", "applicable":
  true|false}}}`. Both must be affirmed and every finding of the repo's
  reports must be listed with its current fingerprint.
- `deferrals`: a list of `{finding, fingerprint, repo, slice_id,
  plan_revision, reason, expires_at}`. `expires_at` is a UTC timestamp
  (`…Z` or `…+00:00`) and is exclusive: at that instant the deferral has
  already expired.
- `accepted_conditions`: a list of `{condition, repo, slice_id,
  plan_revision, reason}` where `condition` is `codemap_missing` or
  `baseline_preexisting_failure`.

Blockers: every finding the assessment marks `applicable` blocks readiness,
whatever its severity, until this record clears it. Only two things clear it: a
live deferral naming the finding, its fingerprint and the record's scope, or the
finding's own `meute resolve` row together with `acceptance` or `audits`
evidence whose `fixes` name its id and fingerprint. A decision inherited from an
earlier report with the same fingerprint, and a whole-report `meute resolve`
with no per-finding row, both leave the finding open.

Reports fail closed:

- Anything unreadable or ambiguous at `reports/` or under the repo's own
  directory (a symlink, a non-directory, a permission error) is
  `report_unreadable`.
- An unreadable or non-UTF-8 path in another repo's directory might claim this
  repo, so readiness stays pending with `ignored_unreadable_paths`, and the
  paths are listed relative to `reports/` under `ignored_unreadable`. The policy
  has no field to acknowledge such a path: make it readable or remove it.
- A report is `report_malformed` when it may show a finding the inbox does not
  list. The inbox lists exactly the `### [SEVERITY] title` lines, and readiness
  accepts those only inside a `## Findings` section. Any other line naming a
  severity (`critical`, `high`, `medium`, `low`, `crit`, `med`, in any case) is
  judged by its shape:
  1. Structure. After indentation, `>` and list markers the line starts with
     `#`, `<`, `=` or a link or footnote definition; or it is underlined as a
     heading; or it holds an HTML heading tag (`<h1>` to `<h6>`) anywhere, even
     in the middle of a sentence; or it is a table row with a cell that is only
     a severity, with an optional trailing parenthesis (`| High (confirmed) |`).
     A row that opens with a pipe is checked in every cell; a row without one
     (`CRITICAL | SQL injection`) in its first cell only, because a pipe inside a
     sentence is prose. Always malformed.
  2. Title. The line starts with `[SEV]` or `(SEV, qualifier)` followed by
     anything but the word `finding`, in any emphasis and after any list
     marker, `A)` and `I.` included. Always malformed.
  3. Field or label. `Severity: High`, or running text that opens with
     `HIGH - ...` or `High: ...`. Always malformed.
  4. Reference. A list, quote or emphasis line that leads with a severity
     (`- **HIGH:** ...`, `- **LOW finding:**`), brackets one
     (`- **Finding 1 (HIGH):**`), or is bold from end to end (`**Why LOW:**`).
     Malformed only when no parsed finding in the same report has that
     severity.
  List markers include task-list boxes (`- [ ] **HIGH** x`, `- [x] HIGH x`),
  and emoji before a severity are ignored (`- **🔴 CRITICAL:** x`, `⚠️ HIGH: x`,
  `| 1 | **🔴 Critical** | x |`), so both are judged as the same line without
  them. Only Unicode categories `So` and `Sk` (emoji, dingbats, emoji
  modifiers) are dropped, not every symbol; see "Not caught" below.
  A severity in the middle of a list item or a field value
  (`- **Consequence:** ... a high-privilege account`) and in running text is
  accepted. The report templates put severities in exactly these places: the
  `Consequence`, `Why now` and `Why LOW` fields, the per-finding bullets under
  `## Verification notes`, and the `Summary`, `Coverage` and `Out-of-lens
  sightings` sections. An earlier rule refused every such line and kept about
  one clean report in five pending.
- Rule 4 is a trade-off. `- **HIGH:** second SQL injection` in a report that
  already has a parsed `[HIGH]` finding is read as a reference to it, so a
  second finding written that way, at a severity the report already lists, is
  not caught. At a severity the report does not list, it is.
- Severities are matched on a folded copy of each line: Unicode compatibility
  forms (fullwidth `ＨＩＧＨ`, `Ⅰ.`), zero-width and other format characters,
  combining marks, emoji and other symbols, and a fixed table of 33 Cyrillic and
  Greek letters drawn like the letters of the severity words (capitals
  included). No other lookalike is folded.
- A heading that holds a `[` is malformed whatever it names (`### [SEVERE] x`,
  `### [P0] x`), unless it is indented as code. Under `## Findings` every
  `###` heading must be a finding the inbox reads, except a heading starting
  with `Not ` or `No ` that holds no severity and no bracket
  (`### Not a finding: ...`). Fenced code blocks are not exempt, because the
  inbox parser does not exempt them.
- Deliberately not caught: a severity mid-sentence or after a title
  (`Note: [HIGH] SQL injection`, `SQL injection (HIGH)`); running text opening
  with a severity and no dash or colon; a rating under another field name
  (`Risk: High`); an unknown label outside a heading (`- [SEVERE] x`); a
  severity spelled with digits or spaces, or split across lines outside a
  heading; lookalikes outside that table; a severity cell after the first one
  in a table row with no leading pipe.
- This check is a best-effort shape screen, not proof that a report holds no
  unlisted finding. Readiness stays pending, never ready, whenever it flags
  anything. Not caught (each verified to leave readiness ready):
  - Symbols outside `So` and `Sk` before a severity: `• **CRITICAL:** x` (a
    `Po` bullet), `‼️ CRITICAL: x`, `→ CRITICAL: x` (`Sm`), `– **CRITICAL:** x`
    (a `Pd` dash), `1️⃣ CRITICAL: x` (keycap). These classes are not dropped
    because the pipe, colon and label rules depend on them.
  - Task boxes that are not GFM: `- [ ]HIGH x`, `- [-] HIGH x`.
  - Table cells that are more than a severity and an optional parenthesis:
    `| High: | x |`, `| High - confirmed | x |`, `| High (see a) (b) | x |`.
  - The gaps listed above: a severity with no dash or colon (`High SQL injection`)
    or no space after the colon (`Critical:SQL injection`), a bracketed
    severity mid-sentence, `Risk:`, `Priority:` and `Impact:` fields, a trailing
    `(HIGH)`, a severity in a non-first cell of a row without a leading pipe,
    lookalikes outside the 33-letter table, and a severity split across lines
    outside headings.
  - Known false positive, which fails closed: `Low | latency is the goal of this
    design` is flagged by the first-cell table rule.
- A report in another repo's directory whose front matter names this repo
  only once a byte order mark, key case, value case and quotes are set aside
  (`repo: "sample"`, `Repo: sample`) is `report_repo_mismatch`. The inbox reads
  the same file differently: it files it under the literal value or the
  directory, never under this repo, so its findings do not appear among this
  repo's. Readiness stays pending until the front matter is corrected or the
  file removed.
- A symlinked directory under `reports/` is `report_unreadable` here and is
  skipped, and named, by the inbox.

The result is versioned JSON containing individual checks and a UTC timestamp.
Exit `2` means invalid input. Exit `1` means readiness is pending: a check
names the reason. A deleted or moved branch also exits `1` and reports the
expected and observed commits. Exit `0` means ready.
The command reads local inputs, leaves runner state untouched, and never
executes commands from the record.

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
