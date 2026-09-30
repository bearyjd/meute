# Handoff — Meute

**As of:** 2026-09-27 (updated after `#28` merged and the claude secret branch was built). **Repo:** `https://github.com/bearyjd/meute` (public, `main`).
**Read first:** `docs/prp/PRP-004-container-review-publish.md` — §5 is the Atelier
contract, §8 the open items, §11 what each phase disclosed, §12 how reviews are
run. This file says only where things stand and what to do next.

## State

| Item | Status |
|---|---|
| PRP-004 Phase 1 (schema, plumbing, log columns) | Merged, `#23` |
| PRP-004 Phase 2a (container boundary, no credential) | Merged, `#27` |
| PRP-004 Phase 2b (engine runs inside the boundary) | Merged, `#28` as `7e24a49` |
| Claude token secret (step 4) | **Built on `feat/claude-token-secret`** (worktree `../meute-wt-claude-secret`), 1048 / 0. Review round one (2 MEDIUM, 5 LOW), Codex rounds one and two (Warning each) and Codex round three (Block, 1 MEDIUM: claude's own exit 125 was relabelled as the preflight's failure; now decided by podman's `--pidfile`) are addressed. Proxied claude runs carry `atelier-claude-token` as `CLAUDE_CODE_OAUTH_TOKEN`, and the claude precondition is a host-side `podman secret exists` that refuses when the secret is missing. Real-container run green on `g691e067` (§11). Still to do: a Codex re-check of round three's fix, then a PR. The host Codex CLI went 401 on 2026-09-27 when the first `just auth-login codex` revoked the tokens the volume shared with the host (a one-time cost of the old copy, §5); the owner re-ran `codex login` and it works again |
| Live fleet | The live checkout is on `main` at `7e24a49` (read 2026-09-27). Its health has not been re-checked since `baa0137`. Timers armed; last run `status=ok` 2026-09-27. **No repo is `runtime: container`**, so nothing above changes what a fire does |
| Atelier pin | `agent-base:g691e067` = `sha256:9ac5558d…`. `g9d76449` = `sha256:ba67b80e…` is built and its diff is read; the bump waits on step 4 |
| `atelier-auth-claude` | **Revoked** and left that way on purpose (§5): the host refreshed and invalidated the copy (§11, Phase 2b). It is still mounted as claude's config directory. The credential is now the `atelier-claude-token` secret, which the owner populated 2026-09-27 |
| `atelier-auth-codex` | Working; its own copy, not yet refreshed out from under it |

## In flight

- **Worktree** `../meute-wt-claude-secret`, branch `feat/claude-token-secret`
  off `7e24a49`, not pushed. The live checkout stays on `main` — the timers
  run `bin/run.sh` from it.
- **Contract change, built on both sides** (§5): Claude moves from a mounted
  `.credentials.json` to the `atelier-claude-token` secret injected as
  `CLAUDE_CODE_OAUTH_TOKEN`. Atelier built its side in `317b951` (the `:z`
  fix is `e779ec0`). Meute's side is on the branch above and has not had
  its review yet. The secret is populated.

## Decisions the owner holds, in order

1. ~~Merge `#28`~~ -- done, `7e24a49`.
2. ~~Give Atelier its go~~ — done; `:z` and `just auth-login` are pushed.
3. **Run the logins**, in the Atelier repo: `just auth-login claude` and
   `just auth-login codex` — one browser step each. Claude's is done:
   `atelier-claude-token` exists as of 2026-09-27. Do **not** re-run
   `just auth` for claude or codex; it now copies only gh, by design.
4. Then Meute. **Built on `feat/claude-token-secret` and verified in a real
   container** (§11, "Claude token secret"): the secret goes on proxied
   claude runs, and the claude precondition is host-side and fails closed.
   Codex rounds one to three are addressed. Still open: a Codex re-check of
   round three's fix, the PR, and `meute image bump` to `g9d76449`.
   Treat the bump as a test of the command too: check the backup lands beside
   the resolved file and the digest written is what `podman image inspect`
   returns — both have only ever been asserted with stubs.
5. **Before Phase 3**: a Codex quota probe, and the credential fixed. A green
   codex run beside a 401'd claude run reads as a provider difference and is a
   credential one (§8).
6. ~~Before Phase 5: mint the two fine-grained PATs~~ — done 2026-09-27, both authenticate from a proxied container; they expire **2026-12-27** (§5 item 2).
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
