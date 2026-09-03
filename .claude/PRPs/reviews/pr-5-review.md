# PR Review: #5 — feat: add architecture-review tier-2 task

**Reviewed**: 2026-09-02
**Repository**: bearyjd/meute
**Branch**: feat/architecture-review-task → main
**Decision**: APPROVE

## Summary

First item off PRP-001 §12's Phase 2 roadmap. Adds a new tier-2 task
(`architecture-review`) that mirrors `audit-security`'s proven shape exactly
— same lens-rotation mechanism, same falsifiability discipline, adapted from
"trace input to sink" to "name evidence a skeptical reader can count or
reproduce." No new tool dependency, no changes to `bin/run.sh` or
`lib/manifest.py` — pure task-registry addition, reusing existing generic
machinery.

## Findings

### CRITICAL / HIGH / MEDIUM
None. Checked specifically for:

- **Template placeholder correctness** — every `{{VAR}}` in
  `tasks/architecture-review.md` is one `bin/run.sh` already passes to every
  task; confirmed by an actual render (`manifest.py render`), not by
  inspection alone.
- **Manifest wiring** — `python3 lib/manifest.py validate` passes against
  both `repos.yaml` and `repos.local.yaml`; the real weekly queue was
  inspected directly and shows `architecture-review` at `tier2`,
  `model: opus`, all four lenses, for all three configured repos.
- **Lens taxonomy overlap** — `coupling` and `boundaries` are conceptually
  adjacent (both about modules touching what they shouldn't). Judged
  acceptable: each lens's table row names concrete, distinguishable evidence
  types, matching how `audit-security`'s own lenses (`auth` vs `injection`)
  have similar adjacency without operational ambiguity.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| `python3 lib/manifest.py validate repos.yaml` | Pass |
| `python3 lib/manifest.py validate repos.local.yaml` | Pass |
| Template render smoke test | Pass — no unresolved placeholders |
| Tests (`bash tests/test_meute.sh`) | Pass — 176/176 |
| Mutation: corrupt `repos.yaml`'s new task's tier | Pass — new public-manifest test fails as expected |
| Mutation: empty the fixture task's lenses | Pass — new queue-shape test fails as expected |
| Manual: real weekly queue inspection | Pass — 12 items, 3 new `architecture-review` entries, correctly shaped |

No type checker / linter / build step applies (this PR touches no shell or
Python logic, only a prompt template, a YAML schema doc, and tests).

## Files Reviewed

- `tasks/architecture-review.md` (Added)
- `repos.yaml` (Modified) — new task registry entry
- `tests/test_meute.sh` (Modified) — `test_public_manifest_valid`,
  `test_architecture_review_queued`
- `repos.local.yaml` (gitignored, not part of this diff) — wired to all
  three configured repos, verified live via `manifest.py queue`
