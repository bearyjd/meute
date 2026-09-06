# PR Review: #10 — fix: make the test suite hermetic against an ambient MEUTE_ROOT

**Reviewed**: 2026-09-05
**Repository**: bearyjd/meute
**Branch**: fix/test-suite-hermetic → main
**Decision**: APPROVE

## Summary

Two small hygiene fixes to things this session shipped, both found by
verifying someone else's work rather than by looking for them. Neither
changes runtime behaviour of the fleet.

## Findings

### CRITICAL / HIGH
None.

### MEDIUM

- **A test suite that fails differently depending on the shell it runs in is
  worse than one that fails honestly.** The five budget assertions read the
  *real* `state/log` under an ambient `MEUTE_ROOT`, so their numbers drift
  with whatever the fleet actually did that week — meaning they could also
  have *passed for the wrong reason* rather than only failing. Worth fixing
  for that reason more than for the confusion it caused me.
- Checked that `unset MEUTE_ROOT` is the right lever rather than patching
  `quota-self-budget.sh`: that script's preference for an inherited value is
  deliberate and load-bearing (`lib/fleet.sh:174` exports it so the adapter
  resolves the runner's root, not the symlink's). The bug is the suite not
  isolating itself, not the adapter honouring its contract.

### LOW
- `repos.local.yaml.bak` gitignore. Untracked noise after every `discover`.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` (clean shell) | Pass — 218/218 |
| `MEUTE_ROOT=$(pwd) bash tests/test_meute.sh` — before fix | **213 passed, 5 failed** |
| `MEUTE_ROOT=$(pwd) bash tests/test_meute.sh` — after fix | Pass — 218/218 |
| `git status` after a `discover` run | Clean; `.bak` no longer listed |

The before/after pair is the mutation evidence: the failure is reproducible
on demand by exporting the variable, and removing the `unset` line brings it
straight back.

## Note on how this was found

I sourced `bin/meute` to independently check a claim in #9 (that the new
`command -v` allowlist entry would otherwise inject `.` into the systemd
unit's PATH — it would have, and #9's guard is correct), then ran the suite
in that same shell and read `213 passed, 5 failed` as "main is red". It
wasn't. The lesson worth keeping is that the verification step needs to be
as trustworthy as the thing it verifies.

## Files Reviewed

- `tests/test_meute.sh` (Modified) — `unset MEUTE_ROOT` + rationale comment
- `.gitignore` (Modified) — `repos.local.yaml.bak`
