# PR Review: #15 — feat: suggest-features task; findings keyed on content, not one task name

**Reviewed**: 2026-09-06
**Repository**: bearyjd/meute
**Branch**: feat/suggest-features → main
**Decision**: APPROVE, with one thing stated plainly

## Summary

Reverses an earlier decision of mine on the operator's explicit scope, and
fixes a visibility bug that the reversal exposed.

## Findings

### CRITICAL / HIGH
None.

### MEDIUM

- **The template is unit-tested but not yet proven live.** The first forced
  run was declined by the subscription gate (14% < 30% floor) after a day
  of interactive work. That is the gate working, not the template failing —
  but it means I cannot yet say whether `suggest-features` produces anchored
  suggestions or a wishlist on real code. Merging on the strength of the
  template's structure (mirrors three templates that *have* been proven
  today) and the unit tests; the live run is queued for after the window
  rolls at 18:20 and its result goes in §11 either way.
- **The reversal is a reversal, and says so.** §12 previously said "not
  building it, on purpose." The new text keeps the reasoning that was right
  (free-form ideas have no anchor) and names what changed (the anchor is
  the repository itself; the operator asked for it).
- **The findings gate was a latent bug with real cost.** Eight findings from
  today's architecture-review and market-comparison runs were invisible to
  per-finding triage. The fix keys on `## Findings` presence rather than a
  task allowlist, so the next findings-shaped task needs no change here.
  `gen-tests` (no such section) is still refused, pinned.

### LOW
- Findings priority reuses the `[HIGH]/[MEDIUM]/[LOW]` tags so the existing
  parser and `meute findings` sort work unchanged; the template says in
  words that it means priority, not severity.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 272/272 (was 262) |
| Both manifests validate | Pass |
| Template render smoke | No unresolved placeholders |
| Real: `meute findings --all` after the fix | 8 previously-hidden findings listed with counts |
| Real: forced `suggest-features` run | **Declined by the gate**: `quota 14% below floor 30%` |

## Files Reviewed

- `tasks/suggest-features.md` (Added)
- `lib/report.py`, `bin/meute` (Modified) — content-driven findings
- `repos.yaml` (Modified) — task registered; §12 note retracted
- `tests/test_meute.sh` (Modified) — `test_findings_are_content_driven`, `test_suggest_features_queued`
- `docs/prp/PRP-001-meute.md` (Modified) — §11 ×2, §12
- `repos.local.yaml` (gitignored) — wired to all four repos
