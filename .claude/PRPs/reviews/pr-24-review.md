# PR Review: #24 — fix: ignore every copy of the private manifest, not two names

**Reviewed**: 2026-09-23
**Author**: bearyjd (drafted by the coordinating assistant)
**Branch**: `chore/ignore-private-manifest-backups` → `main`
**Reviewer**: `code-reviewer`, independent lane — the change was authored by
the assistant that requested the review, which is the case this repo's rule
about not self-approving exists for.
**Decision**: APPROVE WITH COMMENTS → all findings fixed in `0d9f1dd`

## Summary
The leak is real and the fix closes the documented path. On `main`,
`repos.local.yaml.orig`, `repos.local.yaml.2026-09-22` and
`.repos.local.abc123` come back NOT IGNORED; at the head all of them match,
`repos.yaml` stays unmatched, and no tracked path starts with either prefix.
The review's substantive point was that the rule covers every copy of a
manifest *named* `repos.local.yaml`, which is not the same as every copy of
the private manifest.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. **A manifest under any other basename is exposed along with its backup.**
   `bin/meute` takes `MEUTE_MANIFEST` verbatim and `write_with_backup` puts
   the `.bak` beside whatever it resolves to; `refuse_tracked_manifest`
   refuses only `repos.yaml`. Confirmed empirically at the PR head:
   `fleet.local.yaml` and `fleet.local.yaml.bak` both NOT IGNORED, and
   `git status -uall` lists the former. Pre-existing, not introduced here.
   **Fixed** — not by guessing more names, but by asking git: `doctor` now
   resolves the manifest and requires that it and its `.bak` are ignored
   when it lives inside the harness, recognising `repos.yaml` as the tracked
   schema doc and a manifest kept outside the checkout as unpublishable.
   Follows the existing warning about tracked files under `state/`/`reports/`.
2. **Six assertions, all positive — the over-reach half was unasserted.**
   `check-ignore` proves pattern match, not commit-exclusion; nothing held
   the unanchored rule back from swallowing the tracked schema doc.
   **Fixed** — negative control added (`repos.yaml` must stay tracked).

### LOW
3. **Not hermetic.** `check-ignore` also consults `core.excludesFile` and
   `.git/info/exclude`; a global `*.bak`/`*.orig` would let two assertions
   pass without `.gitignore` doing any work. Verified not the case on this
   machine. **Fixed** — the test now asserts the rule's *source file* via
   `check-ignore -v`, not just its exit status.
4. **`.repos.local.*` is grounded, but its fixture did not exercise it.**
   The dot-prefixed temp name is this repo's atomic-write convention
   (`lib/state.sh`, `lib/plan.sh`), and §11 carries `write_with_backup`'s
   conversion as planned, so the rule defends a named future change.
   **Fixed** — fixture is now the name that convention produces, and the
   rule carries a note that a Python conversion must pass
   `prefix=".repos.local.yaml."` because `tempfile`'s default `tmp` matches
   neither rule.
5. **`state/tickets.yaml` had the same one-name-at-a-time shape.** No live
   leak (nothing writes a backup of it today). **Fixed** — prefixed.

## Judgement calls the review was asked for
- **Unanchored is right.** A copy in `docs/` or `tests/` is the same private
  list; the cost is the silently-ignored-fixture case, which finding 2 covers.
- **No live exposure today.** Swept `state/`, `reports/` and
  `git status -uall`: everything private is ignored, only the two `.gitkeep`
  files are tracked. The statusline backup writes outside the repo.

## Validation Results

| Check | Result |
|---|---|
| Type check | N/A — no typed project manifest |
| Lint (shellcheck) | Pass — warning profile identical to `main`; new lines clean |
| Tests | Pass — 677/0 at review head; 684/0 after the fixes |
| Build | N/A |
| Mutation — ignore rule | Pass — reverting `.gitignore` fails exactly 4 assertions |
| Mutation — doctor check | Pass — turning its FAIL into an ok takes the suite red |

## Files Reviewed
- `.gitignore` — Modified
- `tests/test_meute.sh` — Modified
- `lib/doctor.sh` — Modified (in the fix commit)
