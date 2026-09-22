# PRP-004 — Container execution, a review stage, and publishing

**Status:** Proposed — hardened from the 2026-09-20 "Cross-Provider Agent
Dispatch Fleet" PRP by `AUDIT.md`, then rewritten after an adversarial
review of the first draft (§12). **Phase 2 is blocked on Atelier**
producing `agent-base` and `tests/smoke.sh` (zero commits there at filing).
**Created:** 2026-09-21
**Depends on:** PRP-001 (complete); Atelier (`../atelier-harness`, contract
in its `AUDIT.md` §3.2, §4.1–4.4, with the four changes §5 sends back)
**Blocks:** nothing — every phase leaves the host runner working with the
new path absent. Shares one measurement with PRP-002 (Phase 3 here is the
Codex population PRP-002 §0 also needs). Adds a `pr=` column PRP-003's
screens can render.
**Amends:** PRP-001 §3 step 10 ("Never push") for repos that opt in, from
Phase 5: the runner may push a **tier-3, reviewer-approved** scratch branch
and open a **draft** PR. It still never merges. PRP-001 §2's "no servers"
is unchanged for Meute; Meute gains a dependency on one long-lived process
Atelier owns (`atelier-egress`).
**Licence:** AGPL-3.0

---

## 0. Provenance — what survived the audit and what did not

The source PRP was written as a greenfield design. `AUDIT.md` measured it
against the running fleet (75 slots, 25 repos, both timers armed) and
sorted it. This document is the surviving part, in the order the
measurements dictate. Where a decision below was one of the audit's §8
items, its stated default is taken; the owner can overturn any of them
before the phase that depends on it starts.

| Source PRP | Here | Why (`AUDIT.md` §) |
|---|---|---|
| tmux `fleet` session, 2-minute `fleet-ensure` timer | dropped — `lib/timers.sh` already generates the units | 3, 4.8 |
| Pi + pi-flow as coordinator | out of the dispatcher's critical path; may return inside the container for tier 3 later | 4.6 |
| Ephemeral podman container per task | **Phase 2**, behind `runtime:` with `host` as default, on a self-contained scratch clone | 4.4, 4.5, 6 |
| One task = one PR, "merge when green" | one task = one scratch branch → one **draft** PR, tier 3 with verdict `approve` only; `auto_merge` reserved, rejected if set | 4.1 |
| Cross-provider review mandatory | mandatory **for tier 3**, enforced by the runner, after a week of observed Codex runs | 4.3, 5.2 |
| Merge gate = `gh pr checks` | kept, in-container, as a **snapshot** written into the report; zero checks = *no CI*, never green; it reports, it does not merge | 4.2 |
| Fable spec/critique gate | **Phase 7**, tier 3 only, output is a ticket the owner still flips | 4.3 |
| `plan.md` | dropped — its columns exist in `state/`; new columns added | 5.5 |
| `ATELIER_VERSION` root file | per-repo `image: {tag, digest}` in `repos.local.yaml`, written by `meute image bump` | 5.4 |
| Egress allow-list from Atelier | kept: **every engine run is `proxied`** — there is no model-free run in Meute, so Atelier's "`none` as Meute's default" is returned as a finding (§5). `none` is used only for the in-container auth preflight | 4.5, corrected by §12 |
| container-use / Dagger / docker-ce | backlog, unchanged | 3 |
| GitHub MCP in review profiles | **Phase 6**, `tasks/review.md` only, on its own read-scoped credential | 3 |
| Repo layout `scripts/dispatch/`, `pi-flow/profiles/`, `systemd/` | additions go in `lib/`, `tasks/`, `repos.local.yaml` | 7 |

## 1. Problem — the delta over PRP-001

PRP-001 runs. Three things it does not have, each anchored in its own
record:

1. **Isolation is a tool permission, not a sandbox.** PRP-001 §11: the
   allowlist is "a blast-radius reducer, not a sandbox — `pytest` executes
   test code the agent wrote seconds earlier." A tier-1 run has the host's
   network, `$HOME`, SSH keys and every other repo one `../` away. What a
   container can honestly give: egress limited to the provider and GitHub
   hosts on an allow-list, no capabilities, and a filesystem that holds
   only the scratch clone and the one credential the stage needs.
2. **There is one provider.** `state/log`: 52 of 52 engine runs are
   `engine=claude`. Codex cannot run from the timer — under the unit's
   PATH on the host `node` does not resolve, so the `codex` shim dies —
   and even where it could, `bin/quota.sh` has no Codex probe, so
   `eligible()` steps over every Codex entry. `lib/engines.sh:11` admits
   its failure shape "is not yet observed".
3. **There is no review stage and no publishing.** Tier-3 output is a
   local `meute/*` branch the owner must check out to read. PRP-003 §1
   names review capacity as the bottleneck; the one tier-3 draft in three
   weeks was reviewed by nobody but the owner.

The constraint that shaped PRP-001 still shapes this: **scheduled work must
never compete with interactive work.** Every one of the fleet's 23 declined
slots was `quota below floor`; week 2026-37 declined 41 %. Nothing here may
raise per-task quota on tiers 1 and 2.

## 2. Non-negotiables

Kept from the source PRP:

- **Rootless Podman** for the ephemeral per-task containers, off images
  Atelier publishes. Meute never builds an image, never owns a
  Containerfile.
- **One task = one discrete scratch branch**, and from Phase 5 one draft
  PR. No long-lived shared branches.
- **Cross-provider review** on the autonomous path: the engine that built
  a tier-3 branch never reviews it. The runner derives the review engine
  as the other one; nothing in the manifest, a template, or the `--engine`
  CLI override can make them equal. If the review engine is unavailable
  (quota, preflight, 429), the ticket surfaces as *review unavailable* —
  **never** a same-engine fallback.
- **The merge gate is a deterministic script**, never a model call — and
  so is the decision to open the PR (build exited 0, branch has commits,
  reviewer verdict is `approve`, repo has `push: true`).
- **Fable is reserved for the spec stage** (Phase 7). Never build, test,
  review.
- **Egress is allow-listed at the container level.** Every engine run
  goes through Atelier's `proxied` profile; nothing in Meute runs a
  container with unrestricted egress.

Changed from the source PRP:

- **The runner never merges.** "Merge when green" becomes "publish as a
  draft PR and report the checks snapshot". `auto_merge` is parsed and
  rejected if `true`; it gets its own PRP after Phase 5 has a track record.
- **The full pipeline (spec → critique → build → review → resolve) applies
  to tier 3 only.** Tiers 1 and 2 stay single-call; their review is the
  inbox.
- **No coordinator process.** A stage is one queue item; each timer fire
  advances a ticket by one stage (§4.3). pi-flow is not on the host.
- **No long-lived session.** The scheduler stays oneshot timers.

Preserved from PRP-001, restated because this PRP touches them:

- The harness is public; everything about the fleet is local
  (`repos.local.yaml`, `state/`, `reports/`).
- Machine-written state never touches hand-curated config.
  `repos.local.yaml` is the one machine-writable manifest, through
  `lib/manifest.py`'s validated, backed-up path that `discover` already
  uses.
- A decline is a successful run with a stated reason — and a decline that
  belongs to one entry steps over that entry; only a fleet-wide condition
  (quota, hold) stops the fire.
- The engine never writes a Meute state file. The runner parses the final
  message.
- Check the property the system acts on, not the one that is easiest to
  read.

## 3. Architecture

| Layer | Today | After this PRP |
|---|---|---|
| Scheduler | `meute-daily`/`meute-weekly` oneshot timers from `lib/timers.sh` | unchanged |
| Runner | `bin/run.sh`: lock, scrub, preflight, gates, queue, worktree, render, invoke, capture, report, cleanup, cursor, log | + `runtime:` dispatch; image-digest and egress-proxy checks as queue step-overs; in-container preflight; stage advance for tier 3; publish step |
| Scratch tree | linked `git worktree` under `.worktrees/` | `runtime: host`: unchanged. `runtime: container`: a self-contained clone (§4.2) mounted at `/work` |
| Execution | `claude -p` / `codex exec` on the host, cwd = worktree | or `podman run --rm` off `agent-<project>` with the clone at `/work`, one auth volume, `proxied` egress |
| Engines | `lib/engines.sh` adapters run the command | adapters build an argv; `run.sh` runs it on the host or hands it to `lib/container.sh` |
| Isolation | tier tool filter + `--allowed-tools` | the same filter, inside `--cap-drop=ALL`, allow-listed egress, no `$HOME`, one credential |
| Review | none | `tasks/review.md` on tier `tier3-review`, opposite engine, verdict parsed by `lib/report.py` |
| Publishing | none | `lib/publish.sh`: push over HTTPS with a publish-only token, draft PR, checks snapshot; in-container |
| GitHub | `tier2-scout` read-only `gh` | + GitHub MCP in `review.md` only, on a read + PR-comment token |

The runner stays on the host. Rendering, report parsing, `worktree_files`,
cursor, log, and `commit_worktree` stay host-side. What moves into a
container: the auth preflight, the engine invocation, and the publish
step.

## 4. Schema and mechanics

This is what the source PRP wanted from `plan.md`, put where PRP-001
already keeps each concern. Everything here is "from the text" for the
phase that builds it.

### 4.1 Manifest fields

```yaml
defaults:
  runtime: host              # host | container   (CLI --runtime overrides; see rule 5)

tiers:                       # existing blocks gain one key; no other override level
  tier1:       { …existing…, network: proxied }
  tier2:       { …existing…, network: proxied }
  tier2-web:   { …existing…, runtime: host }     # WebFetch(domain:*) is a wildcard;
                                                  # a CONNECT allow-list cannot express it
  tier2-scout: { …existing…, network: proxied }
  tier3:       { …existing…, network: proxied }
  tier3-review:                                   # new; the review stage's blast radius
    description: Reads a tier-3 branch and renders a verdict. Never edits.
    tools: "Read,Grep,Glob,Bash"
    permission_mode: dontAsk
    allowed_tools: "Bash(git diff:*) Bash(git log:*) Bash(git show:*)"
    writes_code: false                            # codex gets -s read-only
    network: proxied

repos:                       # repos.local.yaml — private
  - name: netlens-android
    runtime: container
    image:
      tag: agent-netlens-android:g3f9a1c2      # Atelier's immutable tag; <project> is this name:
      digest: sha256:<64 hex>                  # asserted before every dispatch
    push: true               # Phase 5: tier-3 branches with verdict approve → draft PR
    auto_merge: false        # reserved; validation rejects true
    tickets:
      - id: NL-14
        specced: true
        engine: claude       # build engine; review engine is derived as the other
```

Rules, enforced by `lib/manifest.py validate`:

1. `image:` with both `tag` and `digest` is required when the resolved
   `runtime` is `container`; `digest` matches `^sha256:[0-9a-f]{64}$`.
   Missing → validation error, not a default.
2. `network` is a tier key only. No repo, task, or ticket override.
   `runtime: host` on a tier (`tier2-web`) wins over any repo `runtime`.
3. `push: true` is legal only under `repos:`, never `community:`, and only
   affects tier-3 branches whose review verdict is `approve`. Tier-1
   branches are never pushed by this PRP.
4. `auto_merge: true` is a validation error.
5. `--runtime container` from the CLI on a repo with no `image:` fails
   closed at run time with the same message as rule 1.
6. Per-ticket `engine:` is honoured in `expand_tickets` (ticket > task >
   repo > defaults) — `setting()` runs inside `build_entry`, which has no
   ticket in scope. A ticket's review engine is not a field; it is derived
   there too, and written into the stage entry's `engine`, because
   `eligible()` and `main` gate quota on the entry's engine.
7. Stage state lives in **`state/stages`**, a machine file keyed by
   `<repo>/<ticket>` (`stage`, `branch`, `base`, `build_report`), through
   `lib/state.sh`. It applies to hand-written and machine-written tickets
   alike; neither ticket source is modified. `expand_tickets` consults it
   and emits the ticket's next stage entry instead of a build entry.
8. A repo with no Atelier overlay pins `agent-base:g<sha>`.
9. `repo: owner/name` is required under `repos:` when `push: true`, and
   is the only source of the push URL, the `-R` for `gh`, and the
   publish-token scope test. It is never derived from `git remote`.

`meute image bump <repo>` records the current `podman image inspect`
digest for the repo's `tag` into `repos.local.yaml` through the same
validated, backed-up write path `add-repo` uses. It refuses to write
`repos.yaml`. It is the only writer of `image.digest`.

`state/log` gains `runtime=`, `image=` (12-hex digest prefix or `-`),
`stage=` (`preflight|build|review|resolve|publish|-`), `pr=` (URL or `-`).
`state/stages` and `state/prs` are added to `.gitignore` in the phase that
creates them: every `state/` file is listed there individually.

### 4.2 The scratch tree under `runtime: container`

A linked worktree's `.git` is a file pointing at
`$REPO_PATH/.git/worktrees/<name>` — a host path that does not exist
inside the container, so `git status`, `git diff` and every template's
output contract fail there. Two ways out were weighed:

- **Mount `$REPO_PATH/.git` into the container** at its host path,
  read-only. Rejected: it puts the owner's real refs, including `main`,
  inside the agent's namespace; it relabels the owner's `.git` on every
  run; and the label collides with Atelier's persistent `agent-<project>`
  container, which mounts the same project directory `:Z` with its own
  MCS category.
- **A self-contained clone.** Chosen.

Mechanics, build stage: `git clone --no-local --single-branch [--branch
<default_branch>] "$REPO_PATH" "$SCRATCH"`, then `git -C "$SCRATCH"
checkout -b meute/<task>-<date> <BASE_SHA>`. `--branch` is passed only
when the manifest's `default_branch` resolves; otherwise the clone takes
the source's `HEAD` and `BASE_SHA` is that commit, matching today's
fallback. `--no-local` is deliberate and load-bearing: a local-path clone
copies the **entire** object store — every branch, and purged history of
the kind PRP-001 §10 had to rewrite out of a public repo — whereas the
transport path honours `--single-branch` and cannot hardlink, so
relabelling the clone touches no owner inode. `BASE_SHA` is recorded in
`state/stages` as `base`. `worktree_files` are copied into the clone
exactly as into a worktree. The clone is mounted at `/work:Z`; the
owner's checkout and its `.git` are never mounted and never relabelled.

Later stages clone `--branch <branch>` from the main repo and set
`BASE_SHA` from the recorded `base`, so `cleanup()`'s empty-branch delete
(which compares the branch tip to `BASE_SHA`) never fires on a stage that
adds no commit. If the branch no longer exists in the main repo (deleted
by hand or by `meute prune`), the clone fails and the ticket goes to
`done` as *Blocked — branch missing*, with a report and `mark-delivered`.

After the run, host-side: `commit_worktree` commits inside the clone
(host user can read `container_file_t`; host uid is 1000, matching
`keep-id`). If the branch has commits, the runner imports it: `git -C
"$REPO_PATH" fetch "$SCRATCH" <branch>:<branch>`. That fetch is **refused**
when the branch is checked out in the owner's checkout or any worktree —
the expected way to read a draft today — and on a non-fast-forward. So:
before the run, `git worktree list --porcelain` is checked and an entry
whose branch is checked out is stepped over with a stated reason; after
the run, a refused fetch imports with `+<branch>:refs/meute/import/<branch>-<date>`
instead — a non-branch ref is never checked out, the `+` and the date make
a second refusal on the same branch importable too — logs
`detail=branch-imported-aside`, reports the ref under *Blocked*, and takes
the ticket to `done`: a stage must not advance onto a `branch` that lacks
the commits. Work is never left only in the clone `cleanup` removes. `tier3_in_flight`
counts `meute/*` branches and not aside refs; that is acceptable because
an aside ref is a ticket the owner already has to touch. Cost of the
clone: a pack transfer of one branch per run, recorded in §11 when first
measured. `--rm` plus the digest assert means drift is exactly one bit.

Under `runtime: host`, a stage entry re-creates its tree with `git
worktree add "$WORKTREE" "$BRANCH"` — no `-b`, and the branch-uniqueness
rename that gives a fresh build a `.2` suffix is skipped.

### 4.3 Stages as queue items

A tier-3 ticket advances one stage per timer fire. `state/stages` holds
the ticket's `stage`, `branch`, `base` and `build_report`; the queue
builder puts in-progress tickets ahead of new work in their repo's
position and exempts stage entries from `tier3_max_in_flight` — the cap
gates **new builds** only; at cap, which is the designed steady state, a
`resolve` must still be able to run on a branch that is itself one of the
counted ones. Each fire: re-create the scratch tree from `branch` (§4.2),
run the stage, record it, advance `stage`. The review stage's diff is
`git diff <base>...HEAD` with the recorded `base` SHA, which resolves in a
single-branch clone because it is an ancestor; the default branch's ref
is not there and the template must not name it.

```
build   (ticket.engine)        → commits → stage: review
                               → commit=none → done; report *nothing to review*; no PR
review  (the other engine)     → approve → stage: publish   (or done, if push is off)
                               → changes → stage: resolve
                               → reject  → done; report Blocked; branch kept; no PR
resolve (ticket.engine, findings injected, same branch) → stage: review-2
review-2                       → approve → publish / done
                               → anything else → done; Blocked; no PR
publish (no engine)            → done; pr= recorded
```

Why per-fire rather than one fire running the loop: it keeps PRP-001 §3's
one-unit-of-work model, so the quota gate is checked **per engine, per
stage** (a build-engine reading says nothing about the review engine's
pool), a review-engine 429 sets the hold exactly as any run does, and the
lock is never held for four `timeout_seconds`. `mark-delivered` fires at
`done`, not after build.

The verdict is a fenced block the template must emit:

```
verdict: approve | changes | reject
findings:
  - <numbered, file:line, one sentence>
```

`lib/report.py verdict` parses it. Missing, malformed, or duplicated →
the stage is an error, the ticket goes to `done` as *Blocked — no
verdict*, no PR.

### 4.4 Per-stage container profile

| Stage | Tier | Engine | Network | Auth volume mounted | Mounts | Tools |
|---|---|---|---|---|---|---|
| preflight | — | build or review engine's CLI | `none` | that engine's volume, `:ro` if tolerated | none | `claude auth status --json` / `codex login status` |
| build | tier1 / tier3 | `ticket.engine` | `proxied` | that engine's volume only | `/work:Z`, `/out:Z` | tier's `tools`/`allowed_tools` |
| tier-2 report | tier2 / tier2-scout | repo default | `proxied` | that engine's volume only (+ `atelier-auth-gh-review` for scout) | `/work:Z`, `/out:Z` | tier's |
| review, review-2 | tier3-review | the other engine | `proxied` | that engine's volume (+ `atelier-auth-gh-review` from Phase 6) | `/work:Z` (`:ro` if the CLI tolerates it), `/out:Z` | tier3-review's |
| resolve | tier3 | `ticket.engine` | `proxied` | that engine's volume only | `/work:Z`, `/out:Z` | tier3's |
| publish | — | none | `proxied` | `atelier-auth-gh-publish` only | `/work:Z`, `/out:Z` (`pr-body.md`, written host-side from the build report and the verdict) | `git`, `gh` |

No stage mounts more than one engine credential. No engine stage mounts a
GitHub credential except scout and review, which get the read-scoped one
— scout's allowlist uses only its read half; one review token rather than
a third is deliberate. A preflight failure logs `stage=preflight` so the
demotion counter (§7) can exclude it.
The publish stage mounts no engine credential. `/out` receives Codex's
`-o` file and any capture files so nothing the runner reads lands in the
branch (`commit_worktree` runs `git add -A`).

## 5. The Atelier contract Meute consumes — and four changes it needs

Fixed by Atelier's audit; Meute does not re-decide them:

| Item | Value | Atelier § |
|---|---|---|
| Image name | `agent-<project>` where `<project>` is the repo's manifest `name:`; no `localhost/`, no registry prefix | 3.3 |
| Tag Meute pins | `agent-<project>:g<atelier-short-sha>` — immutable | 3.2 |
| Digest assert | `podman image inspect --format '{{.Digest}}'` must equal the manifest's `digest` | 3.2 |
| Run flags | `--userns=keep-id:uid=1000,gid=1000 --volume "$SCRATCH:/work:Z" --cap-drop=ALL --security-opt=no-new-privileges --init --pids-limit=2048 --rm` | 4.3 |
| Podman wrapper | `distrobox-host-exec podman` when `/run/.containerenv` exists; `MEUTE_PODMAN` override | 4.4 |
| Egress proxy | `atelier-egress` on the internal network; `HTTPS_PROXY` **and** `https_proxy` (curl ignores the uppercase form) injected at `podman run`; the internal subnet is pinned in Atelier's Justfile and the proxy's `Allow` is narrowed to it | 4.2, response below |
| Proxy name resolution | `atelier-internal` is created with `--disable-dns` (podman ordered the proxy's nameservers non-deterministically on two networks; ~1 start in 4 lost public DNS), so container names do not resolve there. Every `proxied` run passes `--add-host atelier-egress:<ip>`, `<ip>` read at run time: `podman inspect atelier-egress --format '{{(index .NetworkSettings.Networks "atelier-internal").IPAddress}}'`. `HTTPS_PROXY=http://atelier-egress:3128` unchanged; `none` unaffected | 4.2, Atelier Phase 2 finding 2026-09-21 |
| Tag availability | `g<sha>` is emitted only from a clean committed tree; until Atelier's first commit there is no pinnable tag, and the digest assertion is the thing Meute relies on | response below |
| Credential import | `scripts/auth-import.sh <volume> <file>` (generic); the owner mints the two PATs. Volumes populated before 2026-09-21 are invalid (files landed as uid 999 under `keep-id`; fixed that day) | response below |
| Smoke test | Atelier's `tests/smoke.sh` is Phase 2's precondition | 5 |

Four things go **back** to Atelier, raised by this PRP's review (§12).
Only the first blocks Meute's Phase 2. The second is two volume names in
Atelier's README plus two PATs the owner mints — Meute can create the
volumes itself. The third is a test result. Of the fourth, only the
`--read-only` root is Atelier's; `/work:ro` is a Meute mount flag:

1. **`none` is not Meute's default.** Atelier §4.2 assumed "build/test
   runs that only need the worktree and the toolchain". Every Meute run
   is a `claude -p` or `codex exec` call and needs the provider's API
   hosts. Meute uses `none` only for the in-container auth preflight; every
   engine run is `proxied`. The base allow-list Atelier §4.2 lists is
   therefore load-bearing for Meute on day one, and the exact OAuth
   refresh hosts it marks *unverified* must be verified before Phase 2's
   gate.
2. **Two GitHub credentials, two volumes.** `atelier-auth-gh` as one
   volume holding the owner's interactive `hosts.yml` gives an unattended
   process full-scope push to every repo the owner can write to. Meute
   needs `atelier-auth-gh-publish` (fine-grained PAT, fleet repos only,
   `contents: write` + `pull_requests: write`) mounted only by the publish
   stage, and `atelier-auth-gh-review` (`contents: read`, `pull_requests:
   write` for comments, `checks: read`) for scout and review. Neither is
   the owner's token.
3. **The OAuth refresh race.** `state/log` 2026-09-18: `Failed to refresh
   OAuth token: another Claude Code process is refreshing it`. Atelier
   §4.1 copies credentials into a volume; if the provider rotates refresh
   tokens on use (*unverified*), the volume and the host copy will
   invalidate each other. Phase 2 tests it with one interactive session
   open during a run; the result decides whether the volume is a copy or
   a bind of the single file.
4. **Read-only root.** Whether `claude` and `codex` tolerate `--read-only`
   with Atelier §4.3's tmpfs mounts, and whether the review stage can take
   `/work:ro`. Phase 2 reports; Atelier's smoke test adopts what holds.

**Atelier's response, 2026-09-21** (cross-session, recorded here as the
agreed contract): all four accepted. (1) `none` is documented as
auth-preflight only; every engine run is `proxied`. The OAuth-refresh
hostnames stay *unverified* until real credentials go into a volume, which
is a `just auth` run Atelier will not do unilaterally because of item 3 —
**it is the owner's call, and it blocks Meute's Phase 2 gate, not
Atelier's Phase 1.** (2) `atelier-auth-gh-publish` and
`atelier-auth-gh-review` reserved with the scopes above; `atelier-auth-gh`
is owner-interactive only and never mounted by an unattended run. (3)
Open; Atelier's preferred design if rotation-on-use is real is **no copy
at all** — each volume gets its own token from the CLI's headless login
run once inside a container (`just auth-login`, planned as their Phase 2
follow-up if Meute's test shows invalidation). (4) Carried on both sides;
whichever result lands first, the smoke test adopts it.

## 6. Phases

Build and review assignments follow the source PRP. Each phase leaves the
host path working with the new path absent, and each gate is a runnable
check, not a claim.

### Phase 1 — Schema, plumbing, and log columns
*Build: Sonnet, from §4.1 directly — no design judgment left. Review:
Codex, light pass.*

`lib/manifest.py`: the fields and the eight rules in §4.1; `build_entry`
carries `runtime`, `image`, `network`, `push`, `repo`; `expand_tickets`
honours per-ticket `engine`, consults `state/stages`, and emits stage
entries with the derived engine and the cap exemption. `bin/run.sh`: the
four log columns, written as `-` until the phase that fills them, and
`eligible()` reading the stage-entry flag to bypass the tier-3 cap. The new
`tier3-review` block in `repos.yaml`. `meute image bump`. `state/stages`
(rule 7) and its `.gitignore` line. `meute doctor` gains, per container
repo, "image present at pinned digest", and fleet-wide "`atelier-egress`
running" — a step-over is visible only on stderr under the timer, so
`doctor` and `status` are where drift and a stopped proxy surface to the
owner. Tests: one per rule, including the rejections (`push` on
community, `auto_merge: true`, bad digest, `--runtime container` without
`image:`, `push: true` without `repo:`).

**Gate:** `meute validate` accepts a manifest containing the §4.1 example
merged into the existing tier blocks, and rejects each rule's violation
with a message naming the field; `state/log` lines on `main` and on this
branch differ only by the four appended columns; `meute image bump` on a
repo refuses `repos.yaml` and writes `repos.local.yaml` with a backup.

### Phase 2 — Container execution path
*Build: Sonnet. Review: Codex, mandatory adversarial — this is the
isolation boundary.*

`lib/container.sh`: resolve the podman wrapper; assert the egress proxy
container is running and the image is present at the pinned digest — both
as **step-overs in `eligible()`**, so the queue moves past the repo and
the next fire selects a different entry (`skip()` exits without
`advance_past`; a per-entry condition must not use it); build the flag set
from §5 and the stage's row in §4.4; inject `HTTPS_PROXY`/`NO_PROXY` for
`proxied` **inside** the container (the host-side `ENGINE_ENV` scrub of
those variables stays and applies to the `podman` process, not the
engine); mount one auth volume per §4.4; `/out` for captures; `--timeout`
from `timeout_seconds`, with a SIGKILL'd run reported as
`detail=timeout`, distinct from "non-json output".

`lib/engines.sh`: `invoke_*` become argv builders (`cd`, `--cd`, `-o`,
`timeout` were host-side assumptions); `run.sh` executes the argv on the
host or through `container.sh`.

Preflight moves inside the container for `runtime: container`: `podman
run --network=none` with the engine's auth volume, `claude auth status
--json` / `codex login status`, zero cost. Failure routes through
`abort_entry` so a `state/log` line is written and the cursor advances —
today's host-side `die` writes nothing, and the credential it checks is
not the one the run would use.

The scratch tree per §4.2. `{{REPO_PATH}}` renders as `/work`.
`worktree_files` copied host-side before `podman run`.

**Gate:** on one repo, `lint-sweep` and `audit-security` run under
`runtime: host` and `runtime: container` with **structural parity**: same
report frontmatter keys, same section headings per the template contract,
`status=ok`, same `commit=` class (`none` vs a sha), same log column set —
not byte equality, which lens rotation, `cost=` and `dur=` preclude. A
deliberately wrong `digest` is a **step-over**: the entry is passed in
`eligible()` with a note on stderr, no `state/log` line is written for it
(one line per fire is the contract `week_runs` and the inbox consume),
no container starts, and **this fire runs the next eligible entry** —
asserted with the suite's stub-binary harness (`$root/stub` on PATH: a
`podman` stub returning a wrong digest, two synthetic repos, `--dry-run`
showing `would run: key=<other>`, and after a real fire the drifted key
absent from `state/log`). `meute doctor` names the drifted repo. With
`atelier-egress` stopped, the same, and `doctor` names the proxy. Inside a tier-1
container `gh auth status` reports not logged in and `curl
https://example.com` fails. Atelier's `tests/smoke.sh` passes on the image
used. The OAuth-race test has a recorded result in §11. A Codex preflight
failure produces a `status=error` line with the CLI's message in
`detail=`.

### Phase 3 — Codex observed
*Build: Sonnet. Review: none — this phase produces data, not code.*

Precondition, an owner decision (§8): a Codex quota source. `bin/quota.sh`
exits 1 for `codex` without `MEUTE_CODEX_QUOTA_CMD`, and `eligible()`
steps over the entry. Either a real probe is named, or the observation
week runs with an explicit self-budget cap (`policy.weekly_cost_usd`
already exists) and the Codex probe stubbed to a fixed reading, logged as
such so the reading is never mistaken for a measurement.

One week of the existing tier-1 and tier-2 tasks with `engine: codex`
under `runtime: container` on two repos. `lib/engines.sh`'s "failure shape
not yet observed" comment is replaced by the observed cases;
`extract_codex` handles each; a non-ok run's `detail=` carries the CLI's
message (this also fixes the non-429 `is_error` line for Claude, `AUDIT.md`
4.7).

**Gate:** `state/log` has ≥ 10 `engine=codex` runs across both tiers;
every `status=error` line has a `detail=` a reader can act on; PRP-002 §0's
reading is re-taken with the Codex population included.

### Phase 4 — Review stage
*Design: Opus, interactive — the stage model in §4.3 is the design; the
interactive part is walking its failure modes before building. Build:
Sonnet. Review: Codex, mandatory adversarial — this is the stage that
decides whether unattended code change proceeds.*

`tasks/review.md` on `tier3-review`: prompt carries the ticket, the build
report, and `git diff <base>...HEAD`; output ends with the verdict block
(§4.3). `run.sh`: the stage advance, the `--engine` CLI override confined to
the build stage, stage-entry tree re-creation without `-b` and without
the uniqueness rename, `mark-delivered` at `done`. The review-engine
derivation and the cap exemption are already in `expand_tickets` from
Phase 1; this phase is the first to exercise them. **Demotion** (§7) is built here, after Phase 3 has shown which
errors exist to count.

**Gate — three negative tests, each asserting no PR and a *Blocked*
report:** a review report with no verdict block; a review stage that exits
non-zero; the review engine's quota below floor at the review fire (the
ticket waits; a hand-set `MEUTE_CODEX_QUOTA_CMD` proves the fallback is
absent — the build engine is never invoked for review). Plus the positive:
one hand-written `specced: true` ticket runs build → review → `done` with
the verdict and findings in the inbox, and `--engine codex` on the CLI
does not change which engine reviews.

### Phase 5 — Publish, don't merge
*Build: Sonnet. Review: Codex, mandatory adversarial — this is push access
to the owner's repos.*

`lib/publish.sh`, deterministic, no model, runs as the `publish` stage in
a `proxied` container with `atelier-auth-gh-publish` only:

```
git -c core.hooksPath=/dev/null push --no-verify \
    https://github.com/<repo>.git <branch>        # <repo> is the manifest's owner/name
gh pr create -R <repo> --draft --base <default_branch> --head <branch> \
    --title … --body-file /out/pr-body.md
gh pr checks -R <repo> <n>   # one snapshot, no --watch; exit status recorded
```

Push goes to an explicit HTTPS URL because the token serves HTTPS only and
the owner's `origin` may be SSH; the clone's own `origin` is a local path,
which is why every `gh` call carries `-R`. `<repo>` is manifest rule 9's
`owner/name`, never derived from a remote. Hooks are disabled because a pre-push
hook in the tree is agent-written code that would run with the publish
credential. `--base` is the manifest's `default_branch`, which is what
the branch was cut from.

The checks result is a **snapshot**: `pending`, `pass`, `fail`, or `none`.
`none` is reported as *no CI — not mergeable*, never as green
(*unverified*: the CLI's exit status on zero checks; the script tests for
it explicitly). The PR URL and the snapshot go to `pr=` in `state/log`, a
*Checks* section in the report, and `state/prs` (`branch → pr`, gitignored
by this phase). The unit never waits on CI.

`tier3_in_flight` counts local `meute/*` branches; a draft merged on
GitHub would hold its slot forever. `meute prune` reads `state/prs`, asks
`gh` (in the distrobox, or in-container) for each PR's state, and deletes
local branches whose PR is merged or closed. `meute status` shows the
snapshot from `state/prs` and refreshes it the same way.

Amends PRP-001 §3 step 10 for these repos: the tier-3 branch is pushed.
The invariant that replaces "never push": **nothing in `bin/` or `lib/`
calls `git push` except `lib/publish.sh`, and only for `<branch>` to that
one URL.** `reports/` stays gitignored and every `state/` file, the two new
ones included, is listed in `.gitignore` individually.

**Gate:** a draft PR appears from an approved tier-3 branch on a repo with
CI, and the report's *Checks* section shows the snapshot; the same on a
repo without CI reports *no CI — not mergeable*; a repo without `push:
true` produces the same branch and no PR; a community entry with `push:
true` fails validation; the publish token **cannot** push to a repo absent from the
manifest's `repo:` values that the owner can write to (tested by
attempting it); a repo with a
`pre-push` hook in `core.hooksPath` sees the hook not run.

### Phase 6 — GitHub MCP in the review stage
*Build: Sonnet. Review: Codex, mandatory adversarial — PAT scoping is
credential handling regardless of diff size.*

Wire the GitHub MCP server into `tasks/review.md` only, on
`atelier-auth-gh-review`, so the reviewer can read the PR's existing
comments and CI status and post its findings as one review comment. The
token's scopes are in §5 item 2; it is never in the manifest or the
environment.

**Gate:** the reviewer's findings appear as one PR review comment; the
review token cannot push (tested by attempting it); no other template can
reach the server; the publish token is not mounted in the review
container.

### Phase 7 — Spec and critique on Fable
*Build: Sonnet. Review: none — output is a ticket a human still flips.*

`tasks/spec.md` (`engine: claude`, `model: fable` — full id
`claude-fable-5-1` if the alias is not accepted) turns a promoted finding
into a ticket draft: problem, expected behaviour, acceptance, files in
scope. `tasks/critique.md` (`engine: codex`, `tier3-review` tools)
challenges it. Each emits its ticket as a fenced block in the final
message; **the runner** parses it and calls `manifest.py add-ticket` with
`specced: false`. The engine writes no Meute file. This replaces the
hand-drafted half of `meute promote` and nothing else.

**Gate:** ten tickets through spec → critique; the count of tickets the
owner edited before flipping `specced` is recorded in §11 and decides
whether the 2× Fable weight (*unverified*) is worth keeping.

### Backlog, unchanged

- `auto_merge` — its own PRP, after Phase 5 has a track record.
- container-use / Dagger / docker-ce.
- pi-flow inside the container as tier-3 orchestrator — only if §4.3's
  one resolve round proves insufficient.
- `tier2-web` in a container — only if the proxy grows a policy that can
  express `WebFetch(domain:*)`.
- TUI manager — PRP-003.

## 7. Failure handling and routing

Carried from PRP-001 §10, §11 and `AUDIT.md` 5.2–5.3; normative here so a
phase cannot quietly change them.

- The cursor advances on failure. A 429 on **any** stage sets the
  automatic 24 h hold. `meute pause --for` remains the manual form.
- No retry on the other provider on the autonomous path. Every error so far
  was environmental; a retry doubles spend on exactly those.
- **Per-entry conditions step over; fleet-wide conditions stop the fire.**
  Image drift, egress proxy down, in-container preflight failure, review
  engine's quota below floor: step over that entry (`eligible()`), log
  the reason, run the next. Quota below floor for the fire's engine, a
  hold: `skip()`, exit 0.
- **Demotion, not halting** — built in Phase 4. Three consecutive
  `status=error` results from **build-stage engine runs** on one repo
  (tier 1 or tier 3; not `stage=preflight` lines, not image drift, not
  review or publish stages, which have their own terminal states) demote it to
  its tier-2 tasks until `meute undemote <repo>`. Community repos demote
  the same way. `meute status` shows demoted repos. The fleet keeps
  producing reports on a repo whose toolchain is broken for writes.
- Review unavailable (quota, preflight, 429, no verdict) never falls back
  to the build engine. The ticket waits (quota) or goes to `done` as
  *Blocked* (the rest).
- Routing: per-ticket `engine:`, then task, repo, `defaults.engine`. No
  alternation, no strength table, until Phase 3's population exists. The
  only routing rule the runner enforces is the review-stage inversion.

## 8. Open items carried forward

| Item | Resolved by |
|---|---|
| A Codex quota probe, or an explicit stubbed reading for the observation week | owner, before Phase 3 |
| `just auth` — putting real credentials into the Atelier volumes, which is what verifies the OAuth-refresh hostnames and unblocks Phase 2's gate; held by Atelier because of the rotation risk (§5 item 3) | **owner** |
| Atelier's first commit — no `g<sha>` tag exists before it | Atelier |
| OAuth refresh-token rotation across the host copy and the auth volume | Phase 2 test; finding to Atelier §4.1 |
| `gh pr checks` exit status on a PR with zero checks | Phase 5 test |
| `claude -p --model fable` alias vs. full id | Phase 7 first run |
| Fable's ~2× quota weight | Phase 7 measurement |
| Whether a Fable pass on Phase 7's design is wanted before it is built (`AUDIT.md` §8 item 7) | owner |
| `--read-only` root and `/work:ro` for the review stage | Phase 2, if the CLIs tolerate it |
| Pack-transfer cost of `--no-local --single-branch` clones on the largest fleet repo | Phase 2, recorded in §11 |

## 9. Acceptance

The PRP is accepted when Phases 1–5 have passed their gates, which
concretely means: one repo has run every task it is configured for under
`runtime: container` with structural parity to `host` (Phase 2's
definition); `state/log` holds a Codex population; one **hand-written**
`specced: true` ticket — there are none today and no phase before 7
produces one — has gone build → review → publish with its stage record in
`state/stages` and the ticket source untouched, and its draft PR's link
and checks snapshot are in the inbox; and the host path is untouched —
`runtime: host` repos produce log lines identical to the ones before
Phase 1 except for the four appended columns.

Phases 6 and 7 are accepted independently on their own gates.

## 10. Out of scope

Merging. Anything that runs on the daily-driver host's package set beyond
what PRP-001 already needs. Building or editing images. A coordinator
process. Per-repo state files committed into target repos. GitHub Actions
as a build surface. Pushing tier-1 branches.

## 11. Findings

Empty at filing. Each phase appends what running it disclosed, in the
form PRP-001 §11 uses.

## 12. Review record

**2026-09-21, first draft, adversarial review (Opus critic, read-only,
against this repo, PRP-001, and Atelier's audit): rejected.** One
CRITICAL and seven HIGH findings, all confirmed against the code, all
folded in above:

- `--network=none` for engine runs makes the model call impossible; the
  audit and the first draft had inherited Atelier's assumption of a
  model-free build/test run. → §0, §2, §4.4, §5 item 1.
- A linked worktree's `.git` file points at a host path. → §4.2, the
  self-contained clone, with the mount alternative rejected on the record.
- Host-side preflight kills a Codex-in-container run before any log line.
  → Phase 2, in-container preflight through `abort_entry`.
- No Codex quota probe; `eligible()` steps over every Codex entry.
  → Phase 3 precondition, §8.
- One gh volume made Phase 5's push and Phase 6's "cannot push" gate
  contradictory, and the push credential was the owner's full-scope token.
  → §5 item 2, §4.4, Phase 5 and 6 gates.
- Every auth volume was mounted into every container. → §4.4.
- `image drift` as `skip()` wedged the cursor on the drifted repo. → §7
  step-over rule, Phase 2 gate.
- Phase 1 dispatched on fields Phase 2 delivered. → phases swapped.

MEDIUM findings folded in: `ENGINE_ENV` scrubs the proxy variables the
`proxied` profile needs; Codex's `-o` under `/work` would be committed;
the review stage needs its own tier; single-fire vs. per-fire stage loop
was unstated; published branches never free a tier-3 slot; a bounded
`gh pr checks` wait under `flock`; byte-equality gates that no run could
pass; a vacuous Phase 4 gate; nobody started or checked `atelier-egress`;
demotion had no owner or semantics; `tier2-web`'s wildcard under a CONNECT
proxy; publish mechanics (HTTPS URL, hooks, `--base`). LOW findings
folded in: `commit_state` no longer exists; tier fragments would fail
validation; digest format; per-ticket `engine` unsupported by `setting()`;
`network` precedence; "mergeable" used for two things; `meute image bump`
dropped without a reason; Phase 7 had the engine writing a state file.

**2026-09-21, second pass on the rewrite: revise, then ship.** Four HIGH,
verified empirically by the reviewer with git 2.55 in a scratch repo, all
folded in: `cleanup()` would delete a tier-3 branch after any no-commit
stage because `BASE_SHA` was re-read from the branch tip → `base` in
`state/stages` (§4.2); `git fetch <branch>:<branch>` is refused when the
owner has the branch checked out or amended it, losing the run's commits
with the clone → pre-check plus the aside ref (§4.2); a hand-written
ticket had nowhere legal to keep stage state — writing it to
`state/tickets.yaml` clashes on the id and halts the fire → `state/stages`
for both sources (§4.1 rule 7); the drift gate asked for a `status=skipped`
line a step-over must not write → gate rewritten around the stub harness,
`doctor` restored (Phase 1, Phase 2). MEDIUM, folded in: `--branch` with
`default_branch` omitted; a local-path clone copies the whole object store
including purged history → `--no-local`; the review diff's `<base>` absent
from a single-branch clone → the recorded SHA; stage re-creation under
`runtime: host` hitting `-b` and the uniqueness rename; `resolve` blocked
by the tier-3 cap at steady state → stage entries exempt; no source for
`<owner>/<repo>` → rule 9; `state/prs` not gitignored; a branch deleted
mid-pipeline; preflight errors indistinguishable for demotion →
`stage=preflight`. LOW: `weekly_cost_usd`; `-u` inert with a URL;
`pr-body.md`'s writer; rule 6's home is `expand_tickets`; §5's attribution
to Atelier over-claimed; the review-engine derivation must be in the queue
entry; scout's token scope stated as deliberate.

**2026-09-21, third pass: ship as-is.** B1–B19 resolved; two MEDIUM
one-liners folded in before commit: a second refused fetch on the same
branch needs a forced, dated aside ref and terminates the ticket (§4.2);
a build with `commit=none` goes to `done` as *nothing to review* rather
than advancing onto an empty branch (§4.3).
