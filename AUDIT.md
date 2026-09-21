# Meute — Phase 0 Audit of the Cross-Provider Dispatch PRP

**Date:** 2026-09-20
**Input:** the pasted PRP "Meute — Cross-Provider Agent Dispatch Fleet"
(2026-09-20; its surviving content is filed as `docs/prp/PRP-004-container-review-publish.md`)
**Audited against:** this repo at `819b515`, the live fleet on Tower, and
the sibling `atelier-harness` audit of the same date
**Method:** Read the PRP, then measured the repo, the host, `state/log`,
and the three existing PRPs. Everything below is verified on this machine
unless marked *unverified*. This pass ran on Opus, not Fable — the PRP
assigns Phase 0 to Fable; Section 8 asks whether a Fable pass is still
wanted for the spec/critique gate specifically.

---

## 1. Verdict

**The PRP is written as a greenfield design. It is not one.** This repo
already implements the same objective — spend idle Claude/Codex
subscription quota across the owner's repos, owner-first, 80/20 with a
community track — under PRP-001, and it is in production: the
`meute-daily.timer` fired at 11:18 today, `state/log` holds 75 slots
across three ISO weeks, 25 repos are tracked, and 92 tests pin the runner.
The repo contains **zero references** to pi-flow, Atelier, a `fleet` tmux
session, `ATELIER_VERSION`, Dagger, container-use, or cross-provider
review.

Five of the PRP's eight non-negotiables contradict decisions PRP-001
recorded and, in two cases, paid for (Section 3). So this audit does not
answer "is the design sound" in the abstract. It answers: **which parts of
this design are genuinely new value on top of what runs today, which parts
rebuild something that exists, and which parts invert a policy the owner
must re-affirm explicitly.**

The short form:

| Genuinely new, worth building | Rebuilds what exists — drop | Policy inversion — owner decides |
|---|---|---|
| Container execution path (kernel isolation; the only place Codex can run unattended here) | tmux `fleet` + 2-minute ensure timer | Autonomous push + merge (today: never push, by design and by incident) |
| A review stage (PRP-003 names review as the bottleneck) | pi-flow as coordinator in the core loop | Fable/critique/review on every task (week 37 already declined 41 % of slots on quota) |
| Egress allow-list (today's "cannot reach the network" is a tool permission, not a sandbox) | `plan.md` schema | — |
| Digest-pinned Atelier images | `ATELIER_VERSION` as a root file | — |

The phase order also needs to change: the container path is a
prerequisite for cross-provider review and the merge gate, not a
consequence of them (Section 4.4). Section 7 gives the reordered plan.

---

## 2. Facts

### 2.1 The fleet today

| Fact | Value | Source |
|---|---|---|
| Repo | 30 commits, 2026-08-28 → 2026-09-20, `main` clean at `819b515` | `git log` |
| PRPs on disk | PRP-001 (phase 1 implemented and accepted), PRP-002 (proposed, gated on a measurement), PRP-003 (screen 1 built, rest blocked on PRP-002) | `docs/prp/` |
| Scheduler | `meute-daily.timer` and `meute-weekly.timer` on the **host** (not the distrobox): daily last 11:18 today, next 15:18; weekly next Sat 04:43; `Linger=yes`; units are `Type=oneshot`, `ExecStart=bin/run.sh <slot>`, PATH set explicitly | `systemctl --user` via `distrobox-host-exec` |
| Slots logged | 75: **49 ok · 23 skipped · 3 error** | `state/log` |
| Every skip | `quota N% below floor 30%` — all 23 | `state/log` |
| Week 2026-37 | 23 ok, **17 skipped**, 1 error — 41 % of slots declined at the floor | `state/log` |
| Engine split | **52 of 52 engine runs `engine=claude`. Codex has never run unattended.** | `state/log` |
| Spend | $29.71 over 52 runs (≈ $0.57/run); tier-3 draft BB-1 $4.74 / 70 turns; market-comparison $1.62 | `state/log`, PRP-001 §11 |
| Tier mix | tier2 29 · tier1 20 · tier2-web 2 · **tier3 1** | `state/log` |
| Tickets | `tier3_max_in_flight: 3`; **0** `specced: true` tickets in `state/tickets.yaml` today | `repos.yaml`, `state/tickets.yaml` |
| Repos | 25 entries (24 on disk), **20 with ≥ 1 GitHub Actions workflow, 5 without** | `repos.local.yaml` + `.github/workflows` |
| Tests | 92 test functions | `tests/test_meute.sh` |
| Code path | `claude -p` / `codex exec` invoked on the host inside a `git worktree`; no container code path | `lib/engines.sh`, Atelier audit §2 |
| Codex adapter | exists; header admits "codex's failure shape is not yet observed" | `lib/engines.sh:11` |

### 2.2 The host

| Fact | Value | Why it matters |
|---|---|---|
| This shell | distrobox `dev`; `podman`/`docker` are aliases to `distrobox-host-exec` | The runner's unit executes on the host, the `meute` CLI in the distrobox — two environments, already true today |
| `claude` | on host (`~/.local/bin`); 52 unattended invocations, 49 successful, 3 errored | Works |
| `codex` | `~/.npm-global/bin/codex` is `#!/usr/bin/env node`; **`node` does not resolve under the unit's exact PATH** (`env -i PATH=<unit PATH> codex --version` → `env: 'node': No such file or directory`) | **Codex cannot run from the timer at all.** The Atelier audit's "needs node at install time only" is wrong for the shim |
| `gh` | in the distrobox (`/usr/bin/gh`); **does not resolve under the unit's PATH on the host** | Phase 5's `gh pr checks` and Phase 6 cannot run from the unit as-is. PRP-001 §10b's "gh … in /usr/bin and fine" can only have been measured in the distrobox, where it exists |
| `pi`, `pi-flow`, `dagger`, `container-use` | all absent; no `~/.pi` or `~/.config/pi` | Nothing in Section 3 of the PRP exists yet |
| tmux | on host and distrobox; one session `seed` (14 windows), no `fleet` | — |
| Podman images | no `agent-*` images | Atelier has produced nothing yet |
| `atelier-harness` | created today, **zero commits**, holds only its own `AUDIT.md` and PRP | Meute's stated dependency is a design, not an artifact |

### 2.3 What the Atelier audit already decided for Meute

These are Atelier's contract; Meute consumes them and should not re-decide
them.

- **Tag/pin:** Meute pins `agent-<project>:g<atelier-short-sha>` **and**
  records the `sha256:` digest; the runner asserts the digest with
  `podman image inspect` before dispatch (Atelier §3.2). `latest` is for
  humans only.
- **Auth:** three named volumes `atelier-auth-{claude,codex,gh}` populated
  by `just auth`; ephemeral containers mount them (§4.1).
- **Network:** Atelier §4.2 proposes `none` as Meute's default and
  `proxied` (internal network + CONNECT proxy `atelier-egress`) for
  anything that needs the web. **The first half does not hold**: it assumes
  a model-free build/test run, and every Meute run is a `claude -p` or
  `codex exec` call that needs the provider's API hosts. Every engine run
  is `proxied`; `none` is usable only for an in-container auth preflight.
  Goes back to Atelier (caught by the PRP-004 review, not by this audit's
  first pass).
- **Flags:** `--userns=keep-id:uid=1000,gid=1000`, `:Z` bind of the
  project dir, `--cap-drop=ALL`, `--security-opt=no-new-privileges`,
  `--init`, `--pids-limit` (§4.3, verified on Tower).
- **Podman wrapper** for distrobox callers (§4.4).
- **pi-flow** package identity is ambiguous — owner input required (§4.5).

---

## 3. The PRP against the repo, element by element

| PRP element | Meute as built | Relationship | Evidence |
|---|---|---|---|
| tmux `fleet` session + systemd 2-minute `fleet-ensure` | oneshot `meute-daily`/`meute-weekly` timers, `Persistent=true`, linger, `flock`; "one unit of work and exit" | **Conflict.** PRP-001 §2: "No … servers, parallel execution … Scheduling is cron's job." Two §11 findings were spent making timers trustworthy (enabled ≠ armed; PATH). Phase 1 rebuilds a proven layer incompatibly. | PRP-001 §2, §10b, §11 |
| Pi + pi-flow as coordinator | `bin/run.sh` + `lib/manifest.py` queue + `lib/engines.sh` adapters, `--engine` flag | **Conflict + unverified.** Not installed; package ambiguous; needs node (absent on host). Adds a third process between the runner and the CLIs to do what the runner already does. | §2.2, Atelier §4.5 |
| Ephemeral podman container per task, off Atelier image | `git worktree` + tier tool filter + `--allowed-tools` on the host | **Genuinely new.** See Section 6 for what it adds, 4.5 for what it must carry over. | PRP-001 §5, §11 |
| One task = one discrete PR | one task = one scratch branch `meute/<task>-<date>`, **never pushed**, tier-3 capped at 3 in flight | **Policy inversion.** Runner has never pushed by design; the one time autocommit pushed, a verified CRITICAL reached a public repo and history had to be rewritten. | PRP-001 §3 step 10, §10 |
| Cross-provider review mandatory | no review stage; Codex 0 / 52 runs; Codex unrunnable on host | **Not achievable on today's runtime.** Blocked on the container path or on node on the host. | §2.1, §2.2 |
| Merge gate = `gh pr checks` | nothing merges; `gh` absent on host; 5 of 25 repos have no CI | **Blocked and, as specified, vacuous for 20 % of the fleet.** See 4.2. | §2.1, §2.2 |
| Fable for spec/critique | no spec stage; `specced: true` is a human flip via `meute promote` | **New stage; quota cost unpriced.** See 4.3. | PRP-001 §10, `state/log` |
| `plan.md` (per repo or central) | `repos.yaml` + `repos.local.yaml` + `state/tickets.yaml` + `state/cursor` + `state/log` + `state/reports` | **Redundant, and rejected twice already.** See 5.5. | PRP-001 §10 |
| Egress allow-list from Atelier base | `WebFetch(domain:*)` and Bash allowlists — Claude-side tool permissions | **Genuinely new and strictly better.** §11 calls today's filter "a blast-radius reducer, not a sandbox": `pytest` runs agent-written code with the host's network and `$HOME`. | PRP-001 §11 |
| container-use / Dagger / docker-ce | — | Backlog; not audited. Note only that "an agent decides mid-session it wants a scratch environment" contradicts the tier tool filter and `dontAsk`. | — |
| GitHub MCP in review profiles | `tier2-scout` has read-only `gh`, no `gh api`, no bare `gh` | New. PAT scoping is the whole diff. | PRP-001 §12 |
| Repo layout `scripts/dispatch/`, `pi-flow/profiles/`, `systemd/` | `bin/`, `lib/`, `tasks/`, units generated by `lib/timers.sh` from the manifest | Conflict. Additions belong in the existing layout (Section 7). | tree |

---

## 4. Gaps and challenges, ordered by how much they change the plan

### 4.1 Autonomous merge is a policy inversion — the owner must affirm it in writing (decision required)

Today the runner cannot push: PRP-001 §3 step 10 says "Never push", and
§10 records why that rule got teeth — `commit_state()`'s autocommit pushed
an unfixed CRITICAL (route inventory, `0.0.0.0` bind, file paths) to a
public repository, and removing it meant rewriting history and recreating
the remote because GitHub keeps orphaned objects fetchable by SHA.

The PRP's §1 ("merge when green") and Phase 5 ("last line of defense
before anything merges unattended") give the runner push + merge on 25
repos. That is the single largest change in blast radius in the whole
document, and the PRP treats it as an implementation phase rather than a
decision.

**Recommendation:** split it. Phase 5 ships **"publish, don't merge"**:
push the scratch branch, open a **draft** PR, run `gh pr checks`, and
write the result into the report so the inbox shows it. The owner merges
from the inbox. Auto-merge becomes a separate, per-repo, per-tier opt-in
(`auto_merge: true`, default false, tier-1 only, and only where 4.2's
CI condition holds). This keeps every bit of the review stage's value —
the reviewer's comments land on a real PR — while the merge stays a human
act until the pipeline has a track record. The track record today for the
tier that would merge is one run.

### 4.2 `gh pr checks` is vacuous on repos with no CI, and cannot run from the unit (Phase 5 input)

- 5 of 25 fleet repos have no `.github/workflows` (`immich-journal`,
  `parent-review-program`, `sdr-surveytool`, `sdr-5gtool`, and
  `veille-finance`, which is not on disk). On those, "all checks green" is
  "no checks ran". The gate must treat *zero checks* as **fail**, not pass,
  and say so in the report. *Unverified:* `gh pr checks` exit status on a
  PR with no checks — Phase 5 must test it rather than assume.
- `gh` is not on the host, and the timer runs on the host. Either it goes
  into `agent-base` (Atelier already plans this) and the gate runs inside
  the container, or it is layered onto Bazzite. The container is the
  cleaner answer and is one more reason the container path comes first.
- "Merge gate is a deterministic script, never a model call" is right and
  should extend one step: the **decision to open the PR** is also
  deterministic (the build stage exited 0, the branch has commits, the
  reviewer's verdict field says `approve`). No model should be asked
  "should this be a PR".

### 4.3 The pipeline multiplies per-task quota 4–6× on a pool that is already binding (decision required)

Today a task is one model call. The PRP's pipeline is spec (Fable, ~2×
weight, *unverified*) → critique → build → review → resolve: four to five
calls, roughly six Sonnet-equivalents. Measured against `state/log`:

- Every one of the 23 skipped slots was `quota N% below floor 30%`.
- Week 2026-37 declined 17 of 41 slots.

Either the floor drops — which competes with interactive work, the one
constraint PRP-001 §1 says shapes everything — or throughput falls to
roughly a sixth of today's. Neither is what the PRP's §1 ("spends spare
quota") describes.

Priced against the tier the pipeline is for, not the fleet average: the
one tier-3 draft cost $4.74 at 70 turns. A 4–6× pipeline on top of that is
**$19–28 per merged draft**, before the Fable weighting. The fleet's entire
three-week spend was $29.71.

**Recommendation:** the full pipeline applies to **tier 3 only** — the
tier that changes production code unattended, that has run once in three
weeks, and whose input (`specced: true`) is exactly what a spec/critique
stage produces. Tier 1 and tier 2 stay single-call; their review is the
inbox. This also answers where Fable goes: `tasks/spec.md` replaces the
hand-drafted part of `meute promote`, and its output is a `specced: true`
ticket in `state/tickets.yaml`, so the existing gate is unchanged. Whether
that spec stage is worth 2× weight is measurable after ten tickets: count
how many the owner edits before flipping `specced`.

### 4.4 Codex is structurally unrunnable unattended today; the container path is a prerequisite, not Phase 4's implementation detail (reorders the plan)

`~/.npm-global/bin/codex` is a node shim and the host has no `node`.
`engine: codex` from the timer fails at preflight. Every "cross-provider"
sentence in the PRP is therefore contingent on one of:

- (a) layering `nodejs` (and `gh`) onto Bazzite — possible, but it puts
  the daily-driver host's package set on the dispatcher's critical path,
  which is what Atelier exists to avoid; or
- (b) running the engine inside `agent-<project>`, where Atelier bakes
  `node`, `codex`, `gh` and `pi` at pinned versions.

(b) is the design the PRP already wants. So the order is: **container
path → Codex observed → review stage → publish**. The PRP has it as
supervision → schema → profiles → dispatcher → gate, with the container as
a line item inside the dispatcher phase. Section 7 reorders.

A second consequence: `lib/engines.sh:11` says Codex's failure shape "is
not yet observed". Mandatory cross-provider review means every tier-3
task's completion depends on a provider whose error envelope the runner
has never parsed under real conditions. That is a week of observation
runs, not a config change (Section 5.2).

### 4.5 The container path is not "pull and run" — eight things that must survive the move (Phase 1 input, no decision)

Items 1–5 were measured findings in PRP-001 §11; 6–8 only appear once the
filesystem and network boundary moves, and were added after the PRP-004
review (§12 there) found them missing here:

1. **`worktree_files`** — gitignored build plumbing (`local.properties`
   for Android) copied into every worktree. The container bind-mounts the
   worktree, so this still runs on the host before `podman run`. Keep.
2. **The tier tool filter is a CLI flag, not a host property.**
   `--permission-mode`, `--allowed-tools`, `--tools` travel with the
   `claude -p` invocation into the container unchanged. The container adds
   kernel isolation *around* the filter; it does not replace it. Both stay.
3. **`REPO_PATH` must be the container path** (`/work`), not the host
   worktree path — the §11 finding that `dontAsk` refuses reads outside
   cwd applies with a different path string.
4. **Report extraction crosses the boundary.** `claude -p --output-format
   json` writes an envelope to stdout; `codex exec -o` writes to a file.
   Capture stdout from `podman run` and put `-o` under `/work`; parse on
   the host as today. The report contract (`lib/report.py`) is unchanged.
5. **Auth volumes race with interactive use.** The 2026-09-18 error is
   `Failed to refresh OAuth token: another Claude Code process is
   refreshing it or exited mid-refresh` — the fleet and the owner's
   session already collide on one `~/.claude/.credentials.json`. Atelier
   §4.1 proposes *copying* credentials into a volume. If the provider
   rotates refresh tokens on use (*unverified*), two independent copies
   will each refresh and invalidate the other. Phase 1 must test this
   with one interactive session open during an unattended run, and the
   result goes back to Atelier's §4.1 as a finding. The safe interim is
   what 4.1 rejected — a bind mount of the whole `~/.claude` — because at
   least it is one file with one refresher.
6. **There is no model-free run, so there is no `none` run.** Every
   container that runs an engine needs `proxied` with the provider hosts
   allow-listed; `tier2-scout` adds `github.com`; `tier2-web` needs
   `WebFetch(domain:*)`, a wildcard a CONNECT allow-list cannot express,
   so it stays `runtime: host`. Map tier → network profile in the manifest
   as a tier-only key.
7. **A linked worktree has no git inside the container.** Its `.git` is a
   file pointing at `$REPO_PATH/.git/worktrees/<name>` — a host path the
   container cannot see — so `git status`/`git diff`, which every
   template's output contract and the `verify_commands` allowlist rely
   on, fail. The scratch tree for container runs must be a self-contained
   clone (PRP-004 §4.2), or the owner's `.git` gets mounted into the
   agent's namespace.
8. **Preflight runs on the host, before the log line.** `preflight_codex`
   calls `codex login status` on the host, where `node` is absent, and
   `die`s without writing to `state/log`. For container runs the preflight
   must run inside the container against the volume the run will use, and
   fail through `abort_entry` so the cursor advances.

Also carry over: the `timeout --kill-after` wrapper becomes
`podman run --timeout` or `--stop-timeout`; `--rm` plus the digest assert
from Atelier §3.2; and `meute doctor` gains "image present at pinned
digest" as a check that fails closed, the same rule as the quota probe.

### 4.6 pi-flow adds a dependency to do what the runner does (decision required)

What the runner already does: reads a queue, picks an engine per task,
renders a prompt, invokes the CLI, captures the result, records the
outcome. What pi-flow would add on top: a profile-per-stage abstraction
and multi-turn handoff between backends.

The stages the PRP wants (spec → critique → build → review → resolve) are a
`stage:` field on a ticket and one `invoke_*` call per stage, with the
runner enforcing `review.engine != build.engine`. That is a manifest
addition and ~40 lines of `run.sh`, with no new runtime, no node on the
host, and no ambiguous npm package. The one thing pi-flow might genuinely
add — an in-session handoff where the reviewer talks back to the builder
— is the `resolve` stage, which is also the least defined stage in the
PRP.

**Recommendation:** do not put pi-flow in the dispatcher's critical path.
If it earns its place, it does so *inside* the container as the per-task
orchestrator for tier-3 only, which makes it an Atelier packaging concern
(§4.5) and leaves the host runner dependency-free. Decide after the
review stage has run once without it.

### 4.7 A non-429 `is_error` still logs its event name, not its cause (small, Phase 1 cleanup)

§11 fixed the `subtype: "success"` misread for 429s by checking
`api_error_status`. The 2026-09-18 OAuth-refresh failure has the same
shape (`status=error … detail=success cost=0 turns=1`) and is not a 429, so
the log line again says `success` for a failure. Capture the CLI's error
message into `detail=` whenever `is_error` is true and no
`api_error_status` is set. Not a PRP question, but the review stage will
generate more of these and they should be legible.

### 4.8 The reference `fleet-ensure` units should not be requested

PRP §8 says to request them from the prior session rather than re-derive.
Do not: `lib/timers.sh` already generates units from the manifest with the
`Persistent=true` / next-elapse assertions that §11 found necessary. A
2-minute ensure loop for a tmux session is scheduling a scheduler. If a
long-lived session is wanted later for the TUI (PRP-003), that is a
separate unit and a separate question.

---

## 5. Answers to the Section 7 open questions

### 5.1 What determines "ready" → **already answered: `specced: true`, human-flipped, capped at 3 in flight**

Tier-1 and tier-2 tasks are always ready — the manifest order and
`state/cursor` decide *which* runs next, owner's repos structurally before
community. Tier-3 (the only tier that changes code) requires a ticket with
`specced: true`, hand-written in `repos.yaml` or machine-drafted by `meute
promote` into `state/tickets.yaml`, gated by `tier3_max_in_flight: 3`.

Keep this. Do **not** pull from an issue tracker or label on the
autonomous path: PRP-001 §10's rule that machine-written tickets never
touch hand-curated config, and the public-harness incident, both argue for
the ticket file staying local. If GitHub issues should feed the queue,
that is a `meute promote --from-issue <url>` importer that still lands in
`state/tickets.yaml` behind the same `specced` flip.

The number that matters: there are **0** specced tickets right now and
tier 3 has run once. Readiness is not the bottleneck; the human flip is.
That is PRP-003 §1's thesis and it is what the spec/critique stage (4.3)
should be measured against.

### 5.2 Round-robin vs. route by strength → **neither yet; observe Codex first, then route per task from evidence**

Strict alternation makes every task's success depend on whichever provider
is weaker at it. Routing by an assumed Claude-vs-Codex strength split has
no evidence behind it in this fleet: Codex has run 0 times.

Sequence: (1) container path lands; (2) one week of the existing tier-1 /
tier-2 tasks with `engine: codex` in the container, so `lib/engines.sh`
observes Codex's failure envelope and `state/log` gets an `engine=codex`
population; (3) then set per-task `engine:` defaults in the manifest (the
field exists) from what the log shows. The cross-provider constraint is
enforced by the runner at the review stage (`review.engine != build.engine`)
regardless of how build was routed.

PRP-002 §0's reading gate — undecided findings rising vs. slots declining
on quota — is the same reading that should decide whether cheap-model
routing ever enters this picture. Do not decide routing policy twice.

### 5.3 Failure handling → **already answered; keep it; add demotion, not halting**

PRP-001 §10 and §11 settled this against real failures:

- The cursor **advances on failure** — a poisoned entry that stalled it
  would silently halt the fleet under a timer.
- A 429 sets an **automatic 24 h hold**; `meute pause --for` is the manual
  form for a foreseen squeeze; holds always expire.
- Every failure writes a report with the stderr tail; three failure kinds
  are logged distinctly.

Against the PRP's three options: *retry with the other provider* — no;
all three logged errors are environmental (429, OAuth race, one unread)
and a retry doubles spend on exactly the runs least likely to be the
model's fault. *Escalate after N* — the inbox already is the escalation;
reports carry a *Blocked* section. *Halt the repo's queue* — no; that is
the stalled-cursor failure by another name.

One addition: a per-repo consecutive-error count that **demotes** a repo
to tier-2-only (the same posture `meute discover` gives a new repo) until
a human resets it, rather than halting it. Demotion keeps the fleet
producing reports on a repo whose toolchain is broken for writes.

### 5.4 Atelier version pin → **fixed, owner-bumped, digest-asserted, per project, in private config — not a root `ATELIER_VERSION` file**

The PRP's own parenthetical is right and the incident record here shows
what "default to convenient" costs. No automatic adoption.

Concretely, adopting Atelier §3.2 as written:

- Each repo's private entry carries `image: {tag: agent-<project>:g<sha>,
  digest: sha256:…}`. `defaults.image` covers the base for repos with no
  overlay.
- Before dispatch the runner runs `podman image inspect --format
  '{{.Digest}}'` and **declines** (`status=skipped reason=image drift`) on
  mismatch — same fail-closed rule as a broken quota probe. `meute doctor`
  reports it.
- `meute image bump <repo>` records the current digest after the owner has
  run Atelier's `tests/smoke.sh`. That command is the only writer.

Why not a single `ATELIER_VERSION` at the repo root: images are
per-project, so one pin cannot express the fleet; and a root file naming
`agent-<private-project>` tags would put fleet composition in a public
harness, which PRP-001 §10 forbids ("the harness is public, everything
about your fleet is local"). It belongs in `repos.local.yaml`.

### 5.5 Where does `plan.md` live → **it does not; its columns already exist, and both proposed homes were rejected on the record**

| `plan.md` field | Where it already lives |
|---|---|
| Task ID | `state/tickets.yaml` id; `state/cursor` key |
| Stage | `state/log` `status=`/`tier=` (add `stage=` for the pipeline) |
| Assigned backend | `engine=` per run; manifest default |
| Repo / branch | `repo=` / `branch=meute/<task>-<date>` |
| Status | `state/reports` triage + `state/log` |
| PR link | absent — add `pr=` to `state/log` in Phase 5 |

*Per-repo* `plan.md` inside each target repo was rejected by two existing
decisions: machine-written state never touches hand-curated files (PRP-001
§10, PyYAML comment destruction), and reports/state are gitignored because
the fleet is private and the harness is public. A committed `plan.md` per
repo would republish the exact class of information that had to be purged
from history once. It is also the hazard Atelier §5 rejected for overlay
files: a file the agent can edit that defines the agent's own next
dispatch.

*Centralized* in meute is `repos.local.yaml` + `state/`, which exists.

If a human-readable per-repo view is wanted, it is `meute status --repo X`
(a read model) — not a file (a write model).

---

## 6. What the PRP adds that PRP-001 lacks — priced honestly

This audit should not read as a veto. Four things in the PRP are real
value that the running system does not have, and each has a concrete
anchor in the empirical record:

1. **Kernel-level isolation.** §11's own words: the allowlist is "a
   blast-radius reducer, not a sandbox — `pytest` executes test code the
   agent wrote seconds earlier." A tier-1 run today has the host's
   network, `$HOME`, SSH keys and every other repo one `../` away. The
   container with egress allow-listed to the provider and GitHub hosts,
   `--cap-drop=ALL`, and only the scratch clone plus one credential
   mounted narrows that to what the allow-list permits. This is the strongest argument in the PRP and it
   is under-sold there.
2. **Codex at all.** Only the container path makes the second provider
   usable unattended on this host (4.4).
3. **A review stage.** There is none. PRP-003 says review capacity is the
   bottleneck; a model review that shortens the owner's read of a tier-3
   diff attacks the bottleneck directly — *if* it shortens rather than
   lengthens it. Measurable: owner minutes per merged draft, before and
   after.
4. **Publishing branches.** Draft PRs put diffs where the owner already
   reviews code, with CI attached, instead of local `meute/*` branches
   that must be checked out to read. Independent of auto-merge.

What it costs: Atelier must exist first (it has zero commits); the six
carry-overs in 4.5; a week of Codex observation; and a 4–6× per-task quota
multiplier if the pipeline is applied fleet-wide instead of to tier 3.

---

## 7. Recommended shape: file as PRP-004, phased against the running system

Keep the PRP's build/review assignments per phase. Reorder and rescope:

| # | Phase | Replaces PRP phase | Build / Review | Gate to pass |
|---|---|---|---|---|
| 1 | **Container execution path** — `lib/container.sh`; manifest `runtime: host\|container` (default `host`), `image:` pin, `network:` profile; digest assert in preflight and `doctor`; the eight carry-overs in 4.5 | 4 (the container part) | Sonnet / Codex adversarial | The same `lint-sweep` and `audit-security` run green under both runtimes on one repo; a deliberately wrong pinned digest produces `status=skipped reason=image drift`, not a run on an unreviewed image; `tests/smoke.sh` from Atelier passes; OAuth-race test (4.5 #5) has a recorded result |
| 2 | **Manifest and log additions** — `stage=`, `pr=`, `engine` per stage, `auto_merge`, demotion counter | 2 (`plan.md` schema) | Sonnet / — | `test_meute.sh` covers each new field |
| 3 | **Codex observed** — one week of tier-1/2 slots with `engine: codex` in the container; `lib/engines.sh` failure-shape comment replaced by measured cases | new | Sonnet / — | `state/log` has ≥ 10 `engine=codex` runs; every non-ok has a legible `detail=` (4.7) |
| 4 | **Review stage** — `tasks/review.md`; runner enforces `review.engine != build.engine`; tier 3 only | 3 + 4 (profiles + loop) | Opus design → Sonnet / Codex adversarial | One tier-3 ticket goes build → review → report with the reviewer's verdict in the inbox |
| 5 | **Publish, don't merge** — push branch, draft PR, `gh pr checks` in-container, zero-checks = fail, result in report; `auto_merge` opt-in stays off | 5 | Sonnet / Codex adversarial | A draft PR appears on a repo with CI and one without; the second reports *no checks — not mergeable* |
| 6 | **GitHub MCP** in `review.md` only, PAT scoped per Phase 6 | 6 | Sonnet / Codex adversarial | as PRP |
| 7 | **Spec/critique on Fable** — `tasks/spec.md` → `specced: true` ticket; tier 3 only | 3 (spec/critique profiles) | Sonnet / — | Ten tickets; count owner edits before flip (4.3) |

*Superseded in one respect by PRP-004 §6 after its review: Phases 1 and 2
are swapped there (schema and plumbing before the container path, because
the container path dispatches on manifest fields the schema phase adds).*

Dropped: tmux `fleet` + `fleet-ensure` (exists as `lib/timers.sh`);
pi-flow in the core loop (4.6); `plan.md` (5.5); root `ATELIER_VERSION`
(5.4); `scripts/dispatch/`, `pi-flow/profiles/`, `systemd/` directories
(additions go in `lib/`, `tasks/`, `repos.local.yaml`).

Deferred, unchanged from the PRP: container-use / docker-ce; the TUI
manager (PRP-003 already owns it).

The blast-radius note on the PRP's Phase 4 still holds and moves with the
work: Phases 1, 4 and 5 above are the ones that touch isolation, unattended
code change, and push access, and each keeps a mandatory Codex adversarial
review.

---

## 8. Decisions needed from the owner before Phase 1

1. **4.1** Autonomous merge: affirm, or accept "publish, don't merge" with
   `auto_merge` as a later per-repo opt-in? *Recommended: the latter.*
2. **4.3** Pipeline scope: tier 3 only, or fleet-wide with the throughput
   cut? *Recommended: tier 3 only.*
3. **4.4 / 7** Accept the reorder — container path first, Codex observation
   before any cross-provider mandate?
4. **4.6** pi-flow out of the dispatcher's critical path; revisit inside the
   container after the review stage runs once without it?
5. **5.4** Pin lives in `repos.local.yaml` per repo, digest-asserted, not
   in a root `ATELIER_VERSION`?
6. **Filing.** The pasted PRP names its own path `docs/prp/meute-prp.md`;
   this repo numbers PRPs. File it as `docs/prp/PRP-004-<name>.md` with
   this audit's Section 7 as its phase table, and mark PRP-001 §2's
   non-goals as amended where 7 overrides them (servers: still no; push:
   yes, draft PRs, from Phase 5).
7. **Fable.** Phase 0 was assigned to Fable and ran on Opus. Is a Fable
   pass still wanted — specifically on the spec/critique gate design
   (Phase 7), which is the one part of this plan Fable would later run?

Items 1–5 have a stated default; if unanswered, PRP-004 is drafted with
them as written. Item 6 is filing. Item 7 changes nothing in Phases 1–6.

Blocking on the other repo: **Atelier has zero commits.** Phase 1 here
cannot pass its gate until `agent-base` builds and `tests/smoke.sh` exists
there. Atelier's own audit lists its blockers (`agent-enter.sh` reference,
pi-flow identity); neither blocks Meute's Phase 1 if pi-flow is dropped
from the core loop.
