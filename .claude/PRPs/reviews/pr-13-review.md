# PR Review: #13 — fix: allow the web tools under dontAsk; tell the agent where it actually is

**Reviewed**: 2026-09-06
**Repository**: bearyjd/meute
**Branch**: fix/web-tools-allowed-and-worktree-path → main
**Decision**: APPROVE

## Summary

Two bugs found by the only method that could find them: forcing a
never-executed path through the real unit environment and reading the
output. Neither is reachable by the unit test suite — both live in the
contract between the rendered prompt, the CLI's permission model, and the
agent's cwd.

## Findings

### CRITICAL / HIGH
None.

### MEDIUM

- **Both fixes were verified in isolation before being applied**, with
  headless calls at ~$0.03 each rather than by re-running the $1.60 task and
  hoping. Control (`WebSearch` offered, not allowed) → `DENIED`; fix → live
  URL. `WebFetch` needed four probes to find that a bare `WebFetch` rule is
  silently ignored while `WebFetch(domain:*)` works — that would have been
  a second wasted forced run had I guessed.
- **The worktree-path bug was latent in every tier-2 run to date.** Agents
  got away with it by using relative paths. This task tripped it because
  research prompts push the agent to `Read` the absolute path it was handed.
  Fixed at the root (prompt rendering) rather than in the one template that
  surfaced it.
- **The first failed run is itself evidence the template works.** Zero
  fabricated findings, budget reported as 0 of 25, a table of exactly what
  was attempted and refused, and an explicit "treat this as a failed run".
  Worth keeping as the reference for what a correct empty report looks like.

### LOW
- The re-run dropped two candidates (403 on first-party pages) rather than
  source them from mirrors. That is the discipline the template asks for,
  observed for real.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 253/253 (was 249) |
| Isolation: `WebSearch` offered only | `DENIED` |
| Isolation: `WebSearch` allowed | live URL, $0.03 |
| Isolation: `WebFetch` bare rule | `DENIED` |
| Isolation: `WebFetch(domain:*)` | `FETCHED` |
| Dry run: prompt names the worktree | confirmed, and pinned by two assertions |
| **Real forced re-run** | `status=ok`, 39 turns, 20/25 budget, 5 sourced findings |
| Real forced `lint-sweep` (cargo under unit env) | fmt + clippy + 175 tests, `$0.18` |

## Files Reviewed

- `bin/run.sh` (Modified) — `WORKTREE` computed before render; `REPO_PATH` = worktree
- `repos.yaml` (Modified) — `tier2-web.allowed_tools`
- `tests/test_meute.sh` (Modified) — 4 assertions
- `docs/prp/PRP-001-meute.md` (Modified) — §11
- `repos.local.yaml` (gitignored) — synced
