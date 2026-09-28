# Handoff — Meute

**As of:** 2026-09-27 (updated after Atelier `317b951`). **Repo:** `https://github.com/bearyjd/meute` (public, `main`).
**Read first:** `docs/prp/PRP-004-container-review-publish.md` — §5 is the Atelier
contract, §8 the open items, §11 what each phase disclosed, §12 how reviews are
run. This file says only where things stand and what to do next.

## State

| Item | Status |
|---|---|
| PRP-004 Phase 1 (schema, plumbing, log columns) | Merged, `#23` |
| PRP-004 Phase 2a (container boundary, no credential) | Merged, `#27` |
| PRP-004 Phase 2b (engine runs inside the boundary) | **PR `#28` open**, 15 commits, head `665ddf6`, 932 / 0; Codex round five Approve |
| Live fleet | Healthy on `main` (`baa0137`). Timers armed; last run `status=ok` 2026-09-27. **No repo is `runtime: container`**, so nothing above changes what a fire does |
| Atelier pin | `agent-base:g691e067` = `sha256:9ac5558d…`. `g9d76449` = `sha256:ba67b80e…` is built and its diff is read; bump waits on `#28` |
| `atelier-auth-claude` | **Revoked.** Host refreshed and invalidated the copy (§11, Phase 2b). Container claude runs 401 at cost 0 |
| `atelier-auth-codex` | Working; its own copy, not yet refreshed out from under it |

## In flight

- **Worktree** `../meute-wt-prp004-phase1`, branch `feat/prp-004-phase-2b`, level
  with origin, clean. The live checkout stays on `main` — the timers run
  `bin/run.sh` from it.
- **Contract change, half built** (§5): Claude moves from a mounted
  `.credentials.json` to the `atelier-claude-token` secret injected as
  `CLAUDE_CODE_OAUTH_TOKEN`. **Atelier built it** (`317b951`, with the `:z`
  fix in `e779ec0`); **Meute has not**, and the secret is not populated yet.

## Decisions the owner holds, in order

1. **Merge `#28`.** Changes no fire until a repo opts into `runtime: container`.
2. ~~Give Atelier its go~~ — done; `:z` and `just auth-login` are pushed.
3. **Run the logins**, in the Atelier repo: `just auth-login claude` and
   `just auth-login codex` — one browser step each. Do **not** re-run
   `just auth` for claude or codex; it now copies only gh, by design.
4. Then Meute: add the secret to proxied claude runs in `lib/container.sh`
   (not `--network=none` ones), make the claude precondition check the
   secret host-side rather than the stale volume file (§8), re-verify
   claude-in-container, and `meute image bump` to `g9d76449`. The secret
   change touches the credential path, so it gets a Codex round.
   Treat the bump as a test of the command too: check the backup lands beside
   the resolved file and the digest written is what `podman image inspect`
   returns — both have only ever been asserted with stubs.
5. **Before Phase 3**: a Codex quota probe, and the credential fixed. A green
   codex run beside a 401'd claude run reads as a provider difference and is a
   credential one (§8).
6. **Before Phase 5**: mint the two fine-grained PATs (§5 item 2).
7. First container repo: pick one low-stakes repo, not the fleet.

## How to resume

- Build with an `executor` subagent from a plan in `.claude/PRPs/plans/` whose
  "Decisions fixed before build" are binding. Review with `code-reviewer`, then
  **Codex adversarial — mandatory for any change touching the boundary or
  credentials**. 2a took four rounds, 2b five; three found things in one branch.
- Run Codex with `< /dev/null`. Without it `codex exec` blocks on
  `Reading additional input from stdin...` and looks like a slow review that
  never ends (§12). Codex quota resets 9:39 PM local.
- Verify claims in an **isolated checkout of the commit**, never inside a
  worktree an agent is editing. Verify claims about a machine without podman
  with podman *absent from PATH*, not merely failing — they take different
  branches.
- Peer session `atelier-harness-41` owns the image contract; record any
  contract change in PRP-004 §5 and message it.

## Hazards learned (do not rediscover)

- `jq '.x // true'` returns true when `.x` is `false`.
- A guard that is skipped rather than failed when its input is missing will
  pass for every future caller that forgets it. Three rounds of 2b were this.
- `:Z` on a shared volume steals its SELinux label; credential volumes take
  `:z`, per-run `/work` and `/out` take `:Z`.
- `claude auth status` reads a local file and reports `loggedIn: true` against
  a revoked token. The preflight cannot see revocation (§8, named, not fixed).
- A command that silently does nothing and reports success has bitten this
  project twice; check the artefact, not the exit status.
