# PRP-002 — Cheap-Tier Execution via OmniRoute

**Status:** Proposed — **gated on a measurement, not on effort** (see §0)
**Depends on:** PRP-001 (Meute fleet runner), phase 1 complete
**Blocks:** nothing — additive layer

---

## 0. The reading that authorizes this, and the one that kills it

PRP-003 §1 opens: *"The bottleneck is review capacity, not token supply."* This
document exists to raise token supply. Both cannot be the right next build. If
review is genuinely the constraint, PRP-002 raises the arrival rate at a queue
that is already backing up and makes the fleet worse while looking like
progress — and building it is the expensive way to discover that.

The tension is settled by a reading, not by argument. Two branches:

| Reading | Means | Verdict |
|---|---|---|
| Undecided findings rise week over week | review is the constraint | **kill or defer.** Build PRP-003's inbox instead; more output makes the queue worse |
| Undecided findings stay near zero *and* slots decline on the quota gate | token supply is the constraint | **build.** This is the case PRP-002 was written for |
| Neither — few findings, few declines | nothing is constrained yet | **wait.** The fleet is not producing enough for either to matter |

**The data is already being captured.** `state/reports` records every decision
with an ISO timestamp; `state/log` records every run with `week=` and its
`status=`, including `skipped` and the reason. Nothing is being lost while the
reader does not exist — so the reader is twenty lines whenever there is enough
data to read, and writing it earlier only produces a confident-looking line over
a sample too small to mean anything.

**As of 2026-08-29 the sample is four runs**, three of them on one day, and the
timers are not yet armed. The reading needs consecutive unattended days first.

**When the reader is built, count the same population on both sides.**
`cmd_findings` filters to `task == "audit-security"` (bin/meute), so "findings"
means audit findings only. A ratio whose numerator counts every report and whose
denominator counts only audit decisions is nonsense.

---

## Motivation

Two objectives, in priority order:

1. **Primary — spend subscription quota on work only strong models do well.** Planning, architecture, audits, adversarial review, and spec authorship stay on Claude and Codex subscriptions.
2. **Secondary — multiply throughput past quota exhaustion.** Mechanical implementation of already-specced work is routed to cheap models via `<your OpenAI-compatible gateway>`.

These do not compete. Offloading execution does not reduce subscription usage; it raises the ceiling on how much specced work can be completed per week, and it converts the weekly quota floor from a hard stop into a downgrade path.

### Consequence for the quota gate

PRP-001 has `quota.sh` exit 0 when remaining quota is below the floor. That behavior changes:

| Quota band | Planner tier (subscription) | Executor tier (OmniRoute) |
|---|---|---|
| healthy | runs | runs |
| low | skipped | runs |
| exhausted | skipped | runs |

The fleet never idles. It degrades to executor-only mode and works through the backlog of pending work orders.

---

## Design

Three tiers, one direction of flow.

**Planner (subscription).** `claude -p` and `codex exec`, unchanged from PRP-001. Tier 2 tasks (audits, architecture review, brainstorm) currently emit reports. They now additionally emit **work orders** for anything actionable.

**Executor (OmniRoute).** A coding agent pointed at `<your OpenAI-compatible gateway>`, consuming work orders and producing branches. Cheap, high-volume, mechanical.

**Verifier (local).** Not a model. The acceptance command in each work order either passes or it doesn't. Failures escalate back to the planner tier.

---

## Work orders

The unit of handoff. Stored at `workorders/<repo>/<id>.yaml`.

```yaml
id: netlens-0007
repo: netlens
title: Add retry with backoff to the DNS probe client
tier: 3
source: reports/netlens/audit-quality-2026-08-14.md#finding-4
files_in_scope:
  - src/probe/dns.rs
  - src/probe/mod.rs
change: >
  The DNS probe client makes a single attempt and returns Err on timeout.
  Add exponential backoff with jitter: 3 attempts, base 200ms, max 2s.
  Preserve the existing error type; only the retry loop is new.
constraints:
  - Do not add new dependencies; tokio::time is already available.
  - Do not change the public signature of DnsProbe::query.
acceptance: cargo test --package netlens probe::
max_attempts: 2
status: pending        # pending | executing | passed | failed | escalated
attempts: 0
branch: null
```

**The governing rule: a work order may contain no open questions.** If the planner cannot fully resolve scope, file list, or acceptance criteria, it writes `status: blocked` with a `blocker` field and stops. Cheap models fail badly on ambiguity and succeed well on mechanical precision. The planner's job is to convert one into the other — that conversion *is* the value the subscription tokens are buying.

Work orders without a runnable `acceptance` command are rejected at execution time. No command, no execution.

---

## Executor backend

`config/executors.yaml` defines backends. Default:

```yaml
default: omniroute-cheap-code
backends:
  omniroute-cheap-code:
    kind: codex-cli           # reuse codex exec with a second provider profile
    base_url: ${OMNIROUTE_BASE_URL}   # https://<your-gateway-host>/v1
    model: cheap-code
    stream: false
  omniroute-cheap-tools:
    kind: codex-cli
    base_url: ${OMNIROUTE_BASE_URL}
    model: cheap-tools
    stream: false
  omniroute-research:
    kind: http                # plain completions, no agent loop
    base_url: ${OMNIROUTE_BASE_URL}
    model: research
```

**Why Codex CLI as the executor shell:** it supports a custom `model_provider` with an arbitrary OpenAI-compatible `base_url`, so `run.sh` shells out with the same call shape it already uses for the subscription path. Only the provider profile changes. Alternatives if that proves awkward: `aider` (`--openai-api-base`) or `opencode`, both of which take a base URL directly.

**`research` combo has a second use.** Before planning a repo, run a full-codebase inventory through the `research` combo (Gemini 2.5 Pro, 1M context) and hand the resulting summary to the subscription planner as context. This spends free capacity on the token-heavy read and reserves subscription tokens for the reasoning. Add as `tasks/inventory.md`.

---

## Environment isolation — required

PRP-001's subscription guard strips `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` from the environment so Claude Code cannot silently switch to metered API billing. The executor needs an OpenAI-compatible key pointed at OmniRoute. These must not collide.

Rules:

1. Stripping is **scoped to planner subprocess invocations only**, not to the runner process as a whole.
2. The executor subprocess gets a **freshly constructed** env containing `OPENAI_BASE_URL=${OMNIROUTE_BASE_URL}` and `OPENAI_API_KEY=${OMNIROUTE_KEY}`, and nothing inherited that could reach a planner call.
3. `OMNIROUTE_KEY` is read from the environment or a gitignored `.env`. It is never written into a repo file, a task template, or a report.
4. Preflight asserts both invariants and fails loudly if either is violated.

**Related cleanup:** the gateway bearer token must never be hardcoded in a skill or config file. Keep it in `${OMNIROUTE_KEY}` and have callers reference the variable.

---

## Known OmniRoute gotcha to encode

Model strings routed through OpenRouter for Gemini (`openrouter/google/gemini-2.5-flash`) fail on streaming — 400 or empty response. Direct-provider routes (`gemini/gemini-2.5-flash`) work.

Therefore: executor backends default to `stream: false`, and any combo added later that relies on a Gemini tier must use the direct-provider route if streaming is enabled. Note this in `config/executors.yaml` as a comment so it survives.

---

## Escalation ladder

```
work order → executor attempt
  ├─ acceptance passes → status: passed, branch left for human review
  ├─ fails, attempts < max → retry with test output appended as context
  └─ fails, attempts = max → status: escalated
                              ↓
                    next healthy-quota planner run picks it up,
                    receives the failed diffs + test output,
                    either fixes it directly or rewrites the work
                    order to be more tractable
```

Escalation is the feedback signal that tunes the planner. A work order that escalates was under-specified. Track the escalation rate per task template; if `tasks/plan-workorders.md` produces a high rate, the template needs tightening, not the executor.

---

## Cost guard

OmniRoute is metered where it is not free. The executor enforces a per-run ceiling from `config/executors.yaml` (`max_spend_per_run`, `max_workorders_per_run`) and hard-stops on breach, logging remaining pending work orders. Free-tier combos are preferred where the work order's tier allows it.

---

## Build order

1. Work order schema + `workorders/` layout, with two hand-written examples.
2. `bin/execute.sh` — reads pending work orders, runs the default backend, enforces acceptance, updates status, handles retry and escalation.
3. `config/executors.yaml` with the three backends above.
4. Env isolation preflight + scoped stripping in `bin/run.sh`.
5. Amend `tasks/audit-security.md` and `tasks/gen-tests.md` to emit work orders alongside their reports.
6. `tasks/inventory.md` using the `research` combo.
7. Quota gate becomes a router: `quota.sh` returns `healthy|low|exhausted`; `run.sh` branches on it.

---

## Acceptance

- A hand-written work order executes end-to-end through `<your OpenAI-compatible gateway>`, produces a branch, passes its acceptance command, and updates to `status: passed`.
- A deliberately impossible work order exhausts `max_attempts` and lands at `status: escalated` with test output preserved.
- Preflight fails when `ANTHROPIC_API_KEY` is present in a planner invocation env, and fails when `OMNIROUTE_KEY` is missing for an executor invocation.
- `run.sh` with a forced `exhausted` quota band skips planners and still drains the work order queue.

---

## Out of scope

Per-work-order model selection heuristics, parallel executor workers, spend dashboards, automatic promotion of `passed` branches to PRs. All of these are v3 decisions to be made from observed usage, not now.
