# PR Review: #3 — fix: derive the timer's PATH from what the manifest actually needs

**Reviewed**: 2026-09-02
**Repository**: bearyjd/meute
**Branch**: fix/unit-path-from-manifest-toolchains → main
**Decision**: APPROVE — additional robustness coverage added before merge, see Resolution

## Summary

Live failure, not a hypothetical: veille-finance's `lint-sweep` blocked under
the timer this morning because `cargo` isn't near `unit_path_line`'s fixed
five (`git jq python3 claude codex`). Fix derives the PATH from what every
tier's `allowed_tools` actually names instead of extending the fixed list —
avoids repeating the exact mistake `unit_path_line` was written to fix, one
binary later.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
None found in the diff itself. Probed the failure modes this project has
repeatedly had trouble with (silent `set -e` aborts, swallowed errors reading
as success) directly:

- A malformed manifest (`not: valid: yaml: [[[`) and a nonexistent manifest
  path both leave `unit_path_line` returning the fixed-five PATH with exit 0
  — verified by hand before writing the regression test, since this is
  exactly the shape of prior bugs in this file (`dedup_dirs`, the doctor
  `set -e` crash). The `while read ... done < <(python3 ...)` construction is
  safe by the same mechanism as other process-substitution reads in this
  file: a process substitution's exit status is never checked by the
  enclosing `set -e`, unlike a plain assignment or a bare pipeline.
- No test pinned this before merge. **Added** two cases (missing manifest,
  unparseable manifest) asserting exit 0 and the fallback tail still present.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| Syntax (`bash -n bin/meute`) | Pass |
| Tests (`bash tests/test_meute.sh`) | Pass — 164/164 |
| Mutation check (disable manifest-scan loop) | Pass — new test fails as expected |
| Manual probe (malformed / missing manifest) | Pass — degrades gracefully, exit 0 |

No type checker / linter / build step applies.

## Follow-up required after merge (not part of this PR)

The code fix alone does not change anything already deployed: `unit_path_line`
is only read when `install-timers` writes the unit files. The real installed
`meute-daily.service` / `meute-weekly.service` on this machine still carry the
old PATH until `./bin/meute install-timers` is re-run.

## Files Reviewed

- `bin/meute` (Modified) — `unit_path_line`
- `tests/test_meute.sh` (Modified) — `test_unit_path_line`
- `docs/prp/PRP-001-meute.md` (Modified) — new §11 finding
