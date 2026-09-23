# Plan: PRP-004 Phase 2a — the container invocation and the scratch clone

## Summary
Build `lib/container.sh` and the self-contained scratch clone (PRP-004 §4.2),
and prove the isolation boundary with non-engine commands. **Engine runs
inside the container are Phase 2b**, gated on `just auth` populating the
Atelier credential volumes — an owner decision held on the OAuth-rotation
risk (§5 item 3). Everything here is verifiable today, because the boundary
is provable without a credential: flags, uid mapping, dropped capabilities,
SELinux label, network profile, mounts, and what the clone does and does not
contain.

## Metadata
- **Complexity**: High — this is the isolation boundary and the phase with
  the largest blast radius in the PRP.
- **Source PRP**: `docs/prp/PRP-004-container-review-publish.md` §3, §4.2,
  §4.4, §5, Phase 2
- **PRD Phase**: 2a of 7
- **Build**: `executor` on Opus (PRP-004 assigns Sonnet; Phase 1's hardened
  scope justified the upgrade and this one is strictly harder — recorded so
  the deviation is visible)
- **Review**: `code-reviewer`, then **Codex adversarial (mandatory, not
  downgradable — PRP-004 Phase 2)**. Phase 1's Codex pass found a HIGH that
  three Claude passes read past; that is the precedent this phase honours.

## Decisions fixed before build (the executor does not re-decide these)

1. **`lib/container.sh` owns podman, and nothing else calls podman.** Move
   `podman_cmd`, `podman_available`, `PODMAN_TIMEOUT`, `image_digest_on_host`
   and `egress_running` out of `bin/meute` into `lib/container.sh`; `bin/meute`
   and `lib/doctor.sh` source it. Behaviour identical — prove it by the suite's
   existing `image bump` and `doctor` tests passing unchanged.
2. **`lib/engines.sh` builds argv; it does not run anything.** `invoke_claude`
   / `invoke_codex` become `engine_argv_claude` / `engine_argv_codex` that
   populate a global `ENGINE_ARGV` array, with no `cd`, no `timeout`, no
   redirection. Today's host behaviour is reconstructed by the caller:
   `( cd "$WORKDIR" && timeout --kill-after=30 "$TIMEOUT_SECONDS"
   "${ENGINE_ENV[@]}" "${ENGINE_ARGV[@]}" ) > "$out" 2> "$err"`. The
   `--cd`/`-o` paths codex needs become parameters, so the container caller
   can pass `/work` and `/out`. **The host path must stay byte-identical in
   behaviour** — the 677 tests are the proof.
3. **`container_run` signature.**
   `container_run <entry-json> <stage> <workdir> <outdir> -- <argv...>`,
   which assembles and executes the `podman run` and returns the command's
   exit status. It writes nothing to stdout of its own; the caller redirects.
   A separate `container_argv` builds the array so a test can assert the flag
   set without running anything.
4. **Flag set, exactly (PRP-004 §5, Atelier §4.3):**
   `run --rm --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL
   --security-opt=no-new-privileges --init --pids-limit=2048
   --volume <workdir>:/work:Z --volume <outdir>:/out:Z --workdir /work`
   plus the network profile (5) and `--stop-timeout`/`--timeout` from
   `timeout_seconds`. Image is referenced **by digest** (`<tag>@<digest>` is
   not valid for a local image without a registry, so: assert the digest
   first, then run the tag — the assert is what makes the tag safe).
5. **Network profiles.** `none` → `--network=none`, used only by Phase 2b's
   auth preflight; nothing in 2a runs an engine, so `none` is what the
   non-engine proof uses. `proxied` → `--network=atelier-internal`,
   `--add-host atelier-egress:<ip>` with `<ip>` read at run time from
   `podman inspect atelier-egress --format '{{(index .NetworkSettings.Networks
   "atelier-internal").IPAddress}}'`, and `--env HTTPS_PROXY=http://atelier-egress:3128`
   **and** `--env https_proxy=...` (both cases — Atelier's finding: curl
   ignores the uppercase form), `--env NO_PROXY=` empty. The host-side
   `ENGINE_ENV` scrub still applies to the `podman` process; the proxy vars
   are injected inside.
6. **Fail closed, as queue step-overs in `eligible()`** (never `skip()`, which
   ends the fire): image absent or not at the pinned digest; `atelier-egress`
   not running; its IP unreadable when the tier is `proxied`. Each notes a
   reason on stderr and the fire runs the next entry. `doctor` names each.
7. **The scratch clone (§4.2), host-side.** Build stage:
   `git clone --no-local --single-branch [--branch <default_branch>]
   <repo> <scratch>` then `checkout -b <branch> <BASE_SHA>`; `--branch` only
   when the ref resolves. `--no-local` is load-bearing and must be asserted:
   a local-path clone copies the whole object store, including branches the
   agent must not see. `worktree_files` copied in after the clone, host-side.
   Later stages clone `--branch <branch>` and take `BASE_SHA` from
   `state/stages`'s `base`. Import after the run: `git -C <repo> fetch
   <scratch> <branch>:<branch>`; on refusal (branch checked out anywhere, or
   non-fast-forward) fall back to `+<branch>:refs/meute/import/<branch>-<date>`,
   log `detail=branch-imported-aside`, report under *Blocked*, ticket to
   `done`. Before the run, `git worktree list --porcelain` is checked and an
   entry whose branch is checked out is **stepped over** with a stated reason.
8. **Phase 2a does not dispatch an engine.** `run.sh` keeps Phase 1's abort
   for container-resolved entries, with the detail updated to name Phase 2b
   (`container runtime needs the credential volumes; see PRP-004 §5 item 3`).
   The container path is reached only by the test harness and by
   `meute container probe` (9). This is deliberate: an unverifiable engine
   run must not become reachable by a timer fire.
9. **`meute container probe <repo>`** — a human-run command that does what
   Phase 2b will do minus the engine: assert the pin, cut a clone of the
   repo's default branch, run `container_run` with `--network=none` over a
   fixed diagnostic script, and print uid, `CapBnd`, `NoNewPrivs`, the
   `/work` git status, whether `/out` is writable, and whether name
   resolution fails. It is how a human checks a repo is container-ready
   before Phase 2b exists, and it is what the tests drive.

## Proof (the phase's own standard — no credential needed)

Tests run the **real** `agent-base:g691e067`, not a stub, and skip with a
stated reason if it is absent (CI has no images; this machine does).

- **Isolation**: inside the container, `id -u` is 1000; `capsh --print`'s
  bounding set is empty; `/proc/self/status` has `NoNewPrivs: 1`; `/work` is
  writable and its files are owned by the caller on the host afterwards;
  `$HOME` holds no host files; under `none`, name resolution fails.
- **The clone is not the repo**: create a source repo with a `secret` branch
  holding a blob reachable from nowhere else; after
  `--no-local --single-branch`, that object is **absent** from the clone
  (`git cat-file -e` fails) — the §4.2 claim, asserted rather than argued.
  With `--local` it is present: the test pins both directions so the flag
  cannot be dropped later.
- **Git works inside**: `git -C /work status` and `git -C /work diff
  <base>...HEAD` succeed in the container — the defect that made §4.2 choose
  a clone over a linked worktree, now proven on the other side of the
  boundary.
- **Import**: a branch checked out in the source repo is stepped over before
  the run; a non-fast-forward import lands on `refs/meute/import/<branch>-<date>`
  and the work is never only in the removed clone.
- **Flag set**: `container_argv` output asserted field by field against
  decision 4, including both proxy env cases and `--add-host` under
  `proxied`.
- **Fail closed**: wrong digest, `atelier-egress` stopped, and an unreadable
  proxy IP each step the entry over, leave `state/log` without a line for it,
  let the fire run the next entry, and are named by `doctor`.
- **Host path unchanged**: all 677 existing assertions pass, and a host-runtime
  run's log line and report are unchanged in shape.

## Out of scope (Phase 2b, blocked on `just auth`)
The in-container auth preflight; running `claude -p` / `codex exec` inside
the container; the OAuth-rotation test (§5 item 3); `--read-only` root and
`/work:ro` (§5 item 4); removing the Phase 1 abort so a timer fire can
dispatch a container entry. Also out: the review stage, publishing, demotion.

## Risk
This is the phase that, when 2b lands, decides what an unattended agent can
reach. Nothing in 2a may widen what runs today: the only new reachable code
paths are a human-run probe and the tests. The Codex adversarial review is
mandatory and its findings are fixed before merge, not deferred.

## Outcome (2026-09-23)
Built as six commits and **four Codex adversarial passes**, which the PRP
marks mandatory and non-downgradable for this phase. Rounds one to three
returned Block; the fourth returned Approve. 671 → 835 assertions.

What the passes found, in order: a TOCTOU between the digest assert and the
run; the *same* TOCTOU moved rather than closed, because the coordinator's
fix instruction specified a second `image inspect`; a stale verified image ID
that could put one repo's image into another repo's run; and a forced
refusal that retired the staged plan item it was refusing. Each was fixed
and re-reviewed rather than argued with.

Two reachability arguments were wrong in opposite directions before being
settled by running the thing: the coordinator named `:525` as the plan-loss
path, narrowed it, and the builder showed it is unreachable in plan mode at
all — a staged entry's `image` is always null — and that `:521`, the
downgrade refusal, is what actually archives a plan.
