# PR Review: #4 — fix: unit_path_line preserves the caller's own PATH precedence

**Reviewed**: 2026-09-02
**Repository**: bearyjd/meute
**Branch**: fix/unit-path-preserves-precedence → main
**Decision**: APPROVE

## Summary

Follow-up to #3, found while manually verifying that fix against the real
installed timer rather than only the test suite. Two real bugs, both caught
and fixed during development (mutation-tested before the PR was opened, not
discovered in a separate review pass afterward): a precedence bug where
`unit_path_line` could pick a different `cargo` than the operator's shell or
CI would, and a mechanical `IFS`-scoping bug in the fix for the first one that
let directories duplicate into the derived PATH.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
None. Additional probes run during this review, beyond what the diff's own
tests cover:

- Empty `PATH` segments (`PATH="::/usr/bin:/bin"`, POSIX "current directory")
  are correctly skipped rather than treated as a needed directory or crashing
  — confirmed by hand, not asserted in a test (a defensive property, not a
  behavior this PR's fix depends on).
- Nested-loop cost (`$PATH` entries × needed directories) is trivial in
  practice — this machine's real interactive `$PATH` has ~40 entries, needed
  directories typically under a dozen; `unit_path_line` only runs from
  `install-timers`/`doctor`, an occasional interactive command, not a hot
  path.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| Syntax (`bash -n bin/meute`) | Pass |
| Tests (`bash tests/test_meute.sh`) | Pass — 169/169 |
| Mutation: revert precedence-preservation to insertion order | Pass — new cross-binary-order test fails as expected |
| Mutation: remove the `seen` dedup guard | Pass — new repeated-`$PATH`-entry test fails as expected |
| Manual: real double-cargo resolution (`/usr/bin` 1.97.1 vs `~/.cargo/bin` 1.95.0) | Pass — resolves to the rustup one, matching CI's `dtolnay/rust-toolchain@stable` |
| Manual: empty `PATH` segment | Pass — skipped, no crash |

No type checker / linter / build step applies.

## Files Reviewed

- `bin/meute` (Modified) — `unit_path_line`
- `tests/test_meute.sh` (Modified) — `test_unit_path_line`, four new cases
- `docs/prp/PRP-001-meute.md` (Modified) — new §11 finding
