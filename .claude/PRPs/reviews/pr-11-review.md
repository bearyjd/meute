# PR Review: #11 — fix: derive the unit PATH from every allowlist level, not just tiers

**Reviewed**: 2026-09-05
**Repository**: bearyjd/meute
**Branch**: fix/unit-path-all-allowlist-levels → main
**Decision**: APPROVE

## Summary

Third bug in the same lineage: the unit's PATH must cover every binary the
fleet is permitted to run, and each fix has found one more place those
binaries are declared. #3 found the fixed-five guess was wrong, #4 found the
ordering was wrong, this one finds the *scan* was incomplete.

## Findings

### CRITICAL / HIGH
None.

### MEDIUM

- **The scan disagreed with the resolver it exists to serve.** That's the
  real defect, more than the specific missing binaries: `build_entry` picks
  the first non-empty of `(task, project, tier)`, and `unit_path_line` looked
  at one of those three. Any future allowlist level would have the same
  problem. Verified `build_entry`'s precedence directly in
  `lib/manifest.py` rather than trusting the report's summary of it, and
  confirmed a task-level list *replaces* rather than merges — which is what
  makes `dep-audit` unable to fall back on its tier's tools.
- **Checked whether the fix could over-broaden the PATH.** It can only add
  directories that some declared, resolvable binary actually lives in, and
  the existing `[[ "$path" == /* ]]` guard (#9) plus `$PATH`-order
  preservation and dedup (#4) all still apply — confirmed by the derived
  PATH being byte-identical on this machine before and after.

### LOW
- Severity is stated as latent rather than live, with the reason
  (three scanners not installed, `pip` coincidentally covered by `/usr/bin`).
  Resisting the urge to inflate this to a live finding is the honest call;
  the `~/go/bin` trigger is what justifies fixing it now anyway.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 220/220 (was 218) |
| Mutation: revert scan to tiers-only | Pass — both new assertions fail, and only those two (`218 passed, 2 failed`) |
| Derived PATH before vs. after, this machine | Identical — confirms zero blast radius here |
| `python3 lib/manifest.py validate` both manifests | Pass |
| Real manifest scan now surfaces `osv-scanner`, `pip`, `pip-audit` | Confirmed |

## Note on provenance

Found by the executor subagent that shipped #9, while reasoning about which
of the four allowlist anchors its own change needed to touch. It flagged the
gap and deliberately did not fix it — the right call, since it's a distinct
bug in code its change didn't introduce. Its claim was verified here
independently (by computing the task/project-vs-tier binary set difference
against both real manifests) before any code was written.

## Files Reviewed

- `bin/meute` (Modified) — `unit_path_line` manifest scan
- `tests/test_meute.sh` (Modified) — two assertions in `test_unit_path_line`
