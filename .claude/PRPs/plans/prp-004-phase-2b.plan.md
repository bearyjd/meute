# Plan: PRP-004 Phase 2b — the engine runs inside the boundary

## Summary
Dispatch a real engine inside the container Phase 2a built: the in-container
auth preflight, the engine invocation with `/work` and `/out`, and the
removal of the Phase 1 abort so a timer fire can finally run a container
entry. The credential volumes now exist (`just auth`, 2026-09-23), which is
what 2a was gated on.

## Metadata
- **Complexity**: High — this is the phase where an unattended agent first
  runs inside the boundary, so the blast radius is real rather than latent.
- **Source PRP**: `docs/prp/PRP-004-container-review-publish.md` §3, §4.4,
  §5, Phase 2
- **PRD Phase**: 2b of 7
- **Build**: `executor` on Opus
- **Review**: `code-reviewer`, then **Codex adversarial (mandatory, not
  downgradable)**. 2a took four Codex rounds; three returned Block. Budget
  for the same.

## What is already measured (do not re-derive)

Run by the coordinator on 2026-09-23, against the real image and the live
proxy, before this plan was written:

- `just auth` created `atelier-auth-{claude,codex,gh}`. The import is
  read-only on the source: the host credential's md5 is unchanged after it.
- Under `--userns=keep-id:uid=1000,gid=1000` the agent user reads its own
  credential. Atelier's earlier uid-999 bug is gone.
- **A real `claude -p` ran inside `agent-base:g691e067`** on the `proxied`
  profile with the claude volume mounted: `auth status` reported
  `loggedIn: true`, the call returned `stop_reason: end_turn`, $0.067.
- **Rotation did not occur, and now we know why**: the access token had 3.9
  hours left, so no refresh was needed and no copy was written. Host
  credential and container copy are both byte-identical afterwards.

So §5 item 3 is not "unknown" any more; it is **scoped**: rotation can only
matter at refresh, and refresh only happens near expiry. The access token
lives ~4 hours and the daily timer fires every 4 hours, so a container run
will frequently be the thing that needs to refresh. That is an operational
collision, not a theoretical one — see the open item below.

## Decisions fixed before build

1. **The preflight runs in the container, on `--network=none`.** For
   `runtime: container`, `preflight_claude` / `preflight_codex` execute
   inside the image with that engine's auth volume mounted and no network:
   `claude auth status --json` / `codex login status`. Zero cost. Failure
   routes through `abort_precondition` — it is a precondition the operator
   can remediate (`just auth`, or a re-login), so a forced run stays
   retryable, and an unforced one advances as the rule in 2a requires.
2. **One auth volume per stage, per §4.4.** The build stage mounts only the
   build engine's volume; the review stage only the review engine's. Never
   both, never `atelier-auth-gh` on an engine stage. `atelier-auth-gh` as
   `just auth` populates it is the owner's interactive token and is **not**
   mounted by any unattended stage — publishing waits for the two fine
   grained PATs (§5 item 2).
3. **Mount the engine's credential read-write, and record what it does.**
   `claude` and `codex` write to their config directories. Mounting `:ro`
   would break a refresh rather than prevent one. The volume is a copy, so
   a write there does not touch the host file — already verified.
4. **`/out` carries everything the runner reads back.** Codex's `-o` file
   goes under `/out`, never `/work`, so `commit_worktree`'s `git add -A`
   cannot sweep it into the branch. `{{REPO_PATH}}` renders as `/work`.
5. **The Phase 1 abort is removed — and that is the whole risk of this
   phase.** After this, a timer fire can dispatch a container. Everything
   2a built to fail closed (digest assert, proxy check, the readiness
   step-over, `abort_precondition`) is now load-bearing rather than
   precautionary. The `stage entries are not runnable before Phase 4` abort
   at the other call site **stays**.
6. **Structural parity is the gate, not byte equality** — same frontmatter
   keys, same section headings, `status=ok`, same `commit=` class, same log
   column set. Lens rotation, `cost=` and `dur=` make byte equality
   impossible, as Phase 2a already established.
7. **`--read-only` root and `/work:ro` (§5 item 4)**: test whether the CLIs
   tolerate them. Report the result; adopt only what holds. Do not block the
   phase on it.

## Proof

- `lint-sweep` (tier 1, writes) and `audit-security` (tier 2, read-only) run
  green on one repo under `runtime: host` and `runtime: container`, with
  structural parity between the two reports.
- The in-container preflight fails closed with a stated reason when the
  volume is empty or absent, and that failure is retryable under `--force`.
- A container run's commits reach the owner's repo through the §4.2 import,
  and `/out` content never appears in the branch.
- `state/log` carries `runtime=container image=<12 hex>` on those runs.
- The engine's own tool restrictions still apply inside: a tier-2 run cannot
  write to `/work` (the tier filter is a CLI flag and travels with it).

## Open item carried forward, for §8 and Atelier

**Refresh-token collision is now an operational question with a known
window.** Two copies of one refresh token exist: the host's and the
volume's. Whichever refreshes first wins if the provider enforces
single-use refresh tokens. The access token's ~4h life and the fleet's 4h
cadence make that likely rather than hypothetical. Atelier's own preferred
design removes it entirely — `just auth-login`, a headless login per volume
so each holds its own refresh token — and that is now worth doing rather
than waiting to be bitten. It needs an interactive login per volume, so it
is the owner's action. Phase 2b should record the first observed refresh
inside a container either way.

## Out of scope
The review stage, publishing, demotion, `meute prune` — Phases 4 and 5.
The image bump to `g9d76449` is a separate deliberate act.

## Outcome (2026-09-23)

Built as ten commits and **five Codex adversarial rounds**: Block, Warning,
Warning, Warning, Approve. Four of the five found something, and three of
those four were in one branch — the credential check — each time because a
guard was correct for exactly the inputs its author could imagine:

- a lexical `grep` for a spelling, which passed for any other spelling;
- a literal `claude|codex` match on argv[0], which passed for an absolute
  path, a wrapper or an env prefix;
- an unset claim, which passed because the check was skipped rather than
  failed.

The fifth round finding nothing is what makes the first four trustworthy
rather than merely numerous. Phase 2a ended the same way at four rounds.

**The coordinator's errors**, recorded as 2a's outcome records them. I told
the builder that "no claim means no credential" held as a rule; it held for
the probe and nowhere else, and `lib/preflight.sh` reached a
credential-bearing dispatch with no claim at all. I also relayed Codex's
"make the invariant syntax-aware or remove it" without noticing that the
builder's answer — remove it, because a bash test parsing bash is a weaker
guard than the behavioural one beside it — was the better one.

**Found by building rather than by reasoning:**

- `jq -r '.writes_code // true'` returns true when the value is `false`,
  because jq's `//` treats `false` as empty. It silently disabled `/work:ro`
  on every read-only container run.
- `:Z` on a shared credential volume rewrites its SELinux MCS categories and
  steals the label from the interactive containers that share it. We
  introduced it and caught it within the hour; it would have surfaced as an
  intermittent "not logged in" indistinguishable from the refresh race.
- **§5 item 3 stopped being hypothetical.** During verification, a container
  run returned 401 `OAuth access token has been revoked`: the host had
  refreshed and the volume's copy was revoked. Single-use refresh semantics,
  demonstrated. Two consequences are named in §8 and §11 and deliberately
  not repaired — the preflight reads a local file and so reports
  `loggedIn: true` against a revoked token, and only an authenticated call
  could know better, which would end the zero-cost probe.

`just auth` was **not** re-run. Re-copying makes both credentials identical
again, and the next refresh could come from a container — revoking the
owner's session mid-work. The fix is per-volume `just auth-login`, which is
the owner's action.

Three tests written during this phase were themselves wrong, and the
mutations caught them rather than their author: one passed because `set -u`
aborted rather than because the rule refused, one could not see a stage
outside its own candidate list, and one built an empty needle that could
never fail. All three are the same family as the defects being fixed — a
check whose truth value does not depend on the code.

Cost: $0.67 across the phase, nothing on the community track.
