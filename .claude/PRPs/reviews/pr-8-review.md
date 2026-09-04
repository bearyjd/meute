# PR Review: #8 — feat: meute resolve -- record a finding fixed directly, not promoted

**Reviewed**: 2026-09-04
**Repository**: bearyjd/meute
**Branch**: feat/resolve-command → main
**Decision**: APPROVE

## Summary

Small, real gap fixed as it was hit rather than speculatively designed: no
verb existed for "I fixed this finding directly, outside the tier-3 flow."
`resolve` mirrors `dismiss`'s exact shape with one semantic change (outcome
`actioned`, requires `-m`) and no ticket side effect.

## Findings

### CRITICAL / HIGH
None. Checked specifically for:

- **State correctness.** `resolve` must record `actioned`, never `dismissed`
  — dismissing something that was actually fixed would misrepresent the
  finding as declined. Mutation-tested: flipping the outcome string caught
  by the test, but only after fixing the test itself — the first version
  checked `cat state/reports` for the substring "actioned" anywhere in the
  *whole* shared state file, which other tests' rows already contained
  regardless of this test's own outcome, so the mutation went uncaught on
  the first pass. Fixed by grepping the specific finding key's row and
  checking column 2 directly (matching `finding_state()`'s own convention).
  Re-ran the mutation: caught correctly.
- **Fixture isolation.** The new `resolve` test needed its own untouched
  finding — `alpha/audit-security-2026-08-28`'s findings are already
  consumed across `test_promote`/`test_finding_level_triage`, and reusing
  finding #3 there would have broken `test_finding_level_triage`'s
  assumption that it stays `new` until that test runs. Added a dedicated
  one-finding fixture report instead of reusing shared state.
- **The unread count.** Adding a 6th fixture report file required bumping
  `test_listing`'s hardcoded `reports: N unread` assertion (5 → 6) — this is
  the same class of bug the session hit before when architecture-review's
  fixtures were added; caught this time by actually running the suite
  before treating the addition as done, not by memory of the prior fix.

### MEDIUM / LOW
None.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 207/207 |
| Mutation: `resolve`'s outcome flipped to `dismissed` | Pass — caught (after fixing the test's own scoping bug) |

No type checker / linter / build step applies beyond the test suite (shell
script, no separate lint pipeline in this repo).

## Files Reviewed

- `bin/meute` (Modified) — `cmd_resolve`, header/usage
- `tests/test_meute.sh` (Modified) — `test_resolve`, new fixture report, `test_listing` count bump
