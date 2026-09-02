# PR Review: #2 — fix: promote warns when the repo has no task to draft the ticket

**Reviewed**: 2026-09-01
**Repository**: bearyjd/meute
**Branch**: fix/promote-warn-no-draft-task → main
**Decision**: APPROVE — findings resolved before merge, see Resolution

## Summary

Small, well-scoped fix: `cmd_promote` now checks whether the ticket it just
wrote actually shows up in either slot's queue for that repo, and warns
instead of unconditionally claiming "tier-3 will pick it up." Real trigger:
BB-1 was promoted for a repo with no `draft-ticket` task wired at all. Two
MEDIUM issues found on review, both fixed on the same branch before merge.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM

1. **Queue-failure swallowed as "nothing queued."** The original check piped
   `python3 "$MANIFEST_PY" queue ... 2>/dev/null` into `jq -e`, discarding
   stderr on both slot invocations. `cmd_queue` in `lib/manifest.py` never
   writes anything but JSON lines to stdout on success, so a genuine failure
   there (as opposed to a legitimately empty queue) would have printed the
   same "no task wired to draft specced tickets" warning as the real case —
   inconsistent with the rest of `cmd_promote`, which treats a broken
   manifest as fatal (`fleet_load_policy || die ...`).
   **Fixed** in `0ab8d3d`: stderr is now captured and surfaced via `die` on a
   nonzero exit, distinguishing "queue command failed" from "nothing found."
   Not independently regression-tested — constructing a fixture where
   `manifest.py queue` fails while `add-ticket`/`fleet_load_policy` on the
   same manifest succeed isn't a natural failure mode to fabricate; noted
   here rather than forcing an artificial test.

2. **Happy-path branch had no assertion.** The new `if (( picked ))` / `else`
   only had a dedicated test for the `else` (beta, no drafting task) side.
   Mutation-tested by inverting the condition to `if (( ! picked ))`: only 1
   of 12 promote-related assertions failed, and none caught alpha (a repo
   that *does* have `draft-ticket` wired) silently getting the wrong
   ("WARNING: ... no task wired") message.
   **Fixed** in `0ab8d3d`: captured alpha's own `promote` stdout and added
   assertions pinning both that it contains the real message and does not
   contain the warning text. Re-ran the same mutation: now 3 assertions fail
   instead of 1.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| Syntax (`bash -n bin/meute`) | Pass |
| Tests (`bash tests/test_meute.sh`) | Pass — 159/159 |
| Mutation check (condition inversion) | Pass — now caught on both branches |

No type checker / linter / build step applies (bash + Python stdlib CLI, no
package.json / Cargo.toml / go.mod).

## Files Reviewed

- `bin/meute` (Modified) — `cmd_promote`, +36/-2 across both commits
- `tests/test_meute.sh` (Modified) — new beta fixture report, `test_listing`
  count fix, `test_promote` assertions, +71/-5 across both commits
