# PRP-003 — Triage TUI and Visualization Layer

**Status:** Proposed — **blocked on PRP-002**
**Depends on:** PRP-001 (fleet runner, complete), PRP-002 (work orders, executor — **not implemented**)
**Blocks:** nothing — the runner must remain fully functional with this absent

> **Filing note (2026-08-28).** Recorded as received. It is not buildable yet, and
> the gap is structural rather than a matter of effort — see §0.

---

## 0. Blocking dependency, and what is buildable today

Every v1 screen in this document is defined over `workorders/*.yaml` and the
statuses `pending` / `executing` / `passed` / `failed` / `escalated`. None of that
exists. Measured against the repo at the time of filing:

| PRP-003 needs | Present today |
|---|---|
| `workorders/*.yaml` | absent — no directory, no schema, no writer |
| work-order statuses | absent — nothing emits or stores them |
| an executor tier | absent — tiers are tier1 / tier2 / tier2-scout / tier3 |
| escalation (respec vs kill) | absent — no concept of a failed work order |
| `delta` diff review of `passed` branches | branches exist; `passed` does not |

So screens 2–5 (work order editor, queue, escalation review, diff review) — four
of the six v1 screens — have no data to render. **PRP-002 must be implemented
first.** Building the TUI against a schema that does not exist would mean
inventing the work-order format inside the UI layer, which is exactly where a
data model should not be decided.

**What is buildable today**, because it reads what PRP-001 already produces:

- **Screen 1, the triage inbox**, over `reports/**/*.md` — findings already parse
  via `lib/report.py findings`, and triage state already lives in `state/reports`
  with `new` / `read` / `actioned` / `dismissed`.
- **A narrowed `w` action.** `meute promote` already converts a finding into a
  tier-3 `specced: true` ticket in `state/tickets.yaml`. That is the existing
  human gate and it is a strictly smaller thing than a work order.
- **The dismiss-reason enum.** `meute dismiss -m` already stores free text; adding
  the fixed enum is small and starts accumulating the promoted-versus-dismissed
  signal immediately — which is the input the lens-retirement chart later needs.

**Built 2026-08-29, as a CLI rather than a TUI:** `meute findings` is screen 1's
substance — findings grouped by repo, severity-first inside a group, with
per-finding state and the fixed dismiss-reason enum. It needed no uv, no Textual
and no new dependency, and it exposed a real defect on the way: report-level
state meant promoting one finding marked the whole report actioned and hid its
siblings. A report now closes only when every finding in it has a decision.

What Textual would still add is rendering and keybindings, not capability. That
is worth having, but it is worth having *after* the work-order schema exists,
not instead of it.

Recommended sequencing: build the inbox against reports and tickets now, and
treat the work-order screens as PRP-002's second phase. That preserves the
document's own priority (the inbox is the bottleneck) without inventing a schema.

---

## 1. Motivation

The bottleneck is review capacity, not token supply. Every hour of agent output
converges on one human decision: *is this finding worth acting on?* This layer
compresses that decision; it does not display metrics.

**This is an inbox with keyboard actions, not a dashboard.** If a screen does not
lead to a decision, it does not ship in v1.

---

## 2. Stack decision

**Python + Textual.** `textual serve` exposes the identical app over HTTP, so the
terminal UI and the browser view over Tailscale are one codebase and one set of
keybindings. Given that mobile triage over Tailscale is a likely usage pattern, a
second frontend is a cost with no offsetting benefit.

Rejected: Rust + ratatui — better fit for the existing Rust work and yields a
single static binary, but the browser view becomes a separate implementation.
Revisit only if startup latency or distribution becomes a real complaint.

Runtime is a `uv`-managed venv inside the repo. No system Python dependency.

**Consequence for PRP-001:** meute currently depends on bash, git, jq, and
python3 + PyYAML — nothing more. Textual, `textual-plotext`, a uv venv and
`delta` are a materially larger surface. The hard invariant below is what keeps
that from reaching the runner.

---

## 3. Architecture

### State ownership

**Files remain authoritative.** The TUI reads and mutates `workorders/*.yaml` and
`reports/**/*.md` in place. Git stays the store; every triage decision is a
diffable commit.

`state/index.json` is a **derived, gitignored** cache built on launch and
refreshed by a filesystem watch. It exists purely so the inbox renders instantly
across a few dozen repos. It is never authoritative and may be deleted at any
time without loss.

**Hard invariant: the runner has no dependency on the TUI.** Cron must succeed
whether or not the TUI has ever been launched, and must never read `index.json`.

> This invariant is the reason to build the inbox over `state/reports` rather
> than replacing it: the runner already writes that file, and it stays readable
> with `awk` when the TUI is not installed.

### Concurrency

The runner and the TUI can both write. Every mutation takes an advisory lock on
the target file, re-reads before writing, and rejects the write if the file
changed underneath. The TUI surfaces the conflict rather than merging silently.

> PRP-001 already has the primitives: `state/.lock` via `flock`, and atomic
> mktemp+mv writes in `lib/state.sh`. The TUI should reuse them, not invent a
> second locking scheme.

---

## 4. Screens, in build order

### 1. Triage inbox (v1 core) — buildable today

Findings awaiting a decision. Grouped by repo, sorted by severity within group.
Each row: repo, source task, one-line finding, severity badge, file reference,
reproduction status.

| Key | Action |
|---|---|
| `w` | Open work order editor, prefilled from the finding |
| `d` | Dismiss — **requires a reason** |
| `↵` | Expand finding detail |
| `/` | Filter (repo, severity, task, age) |
| `g` | Jump to repo group |

Grouping by repo is deliberate: three findings in one codebase is cheaper to
review than three context switches. Severity-first ordering across repos is
available under `/` but is not the default.

The dismiss reason is mandatory because it is the sole source of the
promoted-versus-dismissed signal per audit lens. Without it, a noisy template and
a noisy repo are indistinguishable. Fixed enum plus free text: `false-positive`,
`wont-fix`, `out-of-scope`, `duplicate`, `too-large`, `other`.

### 2. Work order editor (v1 core) — blocked on PRP-002

The workhorse. Opens prefilled from a finding; the human confirms or edits
`files_in_scope`, `change`, `constraints`, and types the `acceptance` command.

PRP-002 forbids open questions in a work order, so this screen is where ambiguity
gets resolved. **If this step feels heavy, the entire pipeline stalls here:**

- Acceptance command defaults to the repo's known test invocation from the
  manifest; the common case is pressing enter.
- File picker autocompletes against the repo tree with fuzzy match.
- `Ctrl-S` writes and returns to the inbox, which advances to the next finding.
- Saving with an empty `acceptance` field is refused with an inline error.

Target: a routine finding becomes a work order in under 20 seconds.

### 3. Work order queue (v1) — blocked on PRP-002

Filter by status. Actions: kill, requeue, edit, force-escalate to subscription tier.

### 4. Escalation review (v1) — blocked on PRP-002

Separate from the inbox by design: "respec versus kill" on a failed work order is
a different mental mode from triaging fresh findings. Failed diffs and captured
test output side by side with the original work order.

### 5. Diff review (v1) — blocked on PRP-002

For `passed` branches. Shells out to `delta` in a pane. Actions: approve (leaves
the branch for manual merge), request rework, kill branch.

### 6. Fleet overview (v2)

Repos × tasks × last run, with the current quota band. Useful, least actionable,
therefore last.

### 7. Community shortlist (v2)

Scout output with the in-flight cap rendered as a hard counter. Promoting a
fourth is refused, not warned.

> PRP-001 already enforces this cap in the queue builder, and `meute promote`
> already refuses at the cap. The screen should render that refusal, not
> reimplement the check.

---

## 5. Visualization

Four charts, all of which tune prompts rather than admire throughput. **Gated
behind roughly four weeks of run history** — before that there is nothing to plot.

| Chart | Decision it drives |
|---|---|
| Escalation rate per task template | Which planner template is under-specifying work orders |
| Promoted vs dismissed per audit lens | Which lens to retire. Dismissing 28 of 30 findings means stop running it |
| Pending work order age distribution | Whether the executor is keeping pace with triage |
| Quota burn across the week | When to schedule cron relative to the reset window |

Rendered with `textual-plotext`. No separate web dashboard, no metrics database.
Source data is `state/log` and work order status history.

Explicitly excluded: total tokens consumed, lines of code changed, work orders
completed per week. Vanity numbers that do not change behavior.

> The quota-burn chart needs `quota=` in the run log, which PRP-001 now records
> as `quota=<pct>:<source>` on every line. Note that a history of `:stub` values
> is not quota data and must not be plotted as if it were.

---

## 6. Build order

1. Dismiss-reason enum in `meute dismiss` — starts the lens signal accumulating now.
2. Triage inbox over `reports/` + `state/reports`, with `d` / `↵` / `/`.
3. **PRP-002** — work order schema, executor, statuses.
4. `index.json` derivation and file watch.
5. Work order editor with the acceptance default and the 20-second target.
6. Work order queue and escalation review.
7. Diff review with `delta`.
8. `textual serve` over Tailscale, including keybinding parity on mobile browsers.
9. Fleet overview, community shortlist.
10. Charts, once history exists.

Steps 1–2 are available immediately. Step 3 gates 5–7.

---

## 7. Acceptance

- A finding becomes a committed work order in under 20 seconds of keyboard input,
  no mouse, no shell.
- Dismissing a finding writes the reason to the report file and removes it from
  the inbox permanently.
- Deleting `state/index.json` and relaunching produces an identical inbox.
- `bin/run.sh` completes normally on a machine where the TUI has never been
  launched — and on one with no venv and no Textual installed.
- A work order edited concurrently by the runner and the TUI produces a visible
  conflict, not a silent overwrite.
- `textual serve` renders the inbox in a mobile browser over Tailscale with
  working keybindings.

---

## 8. Out of scope

Web dashboard separate from `textual serve`, metrics database, notifications,
multi-user access, automatic merging of approved branches, mouse-driven
interaction as a primary path.
