# PR Review: #7 — feat: meute discover -- scan a directory and add repos interactively

**Reviewed**: 2026-09-03
**Repository**: bearyjd/meute
**Branch**: feat/discover-repos → main
**Decision**: APPROVE

## Summary

First feature in this fleet that writes to the user's own configuration
(`repos.local.yaml`) on request rather than only reading it. That raises the
bar on safety: a bug here doesn't just misfire a scheduled task, it can
corrupt the file the whole fleet's personal setup lives in. Reviewed with
that specifically in mind, not just the interactive UX.

## Findings

### CRITICAL / HIGH
None. Checked specifically for:

- **The `repos.yaml` guard is real, not decorative.** `cmd_add_repo` refuses
  by `os.path.basename(manifest) == "repos.yaml"`, enforced in
  `lib/manifest.py` — the tool that actually writes the file — not just as a
  `bin/meute`-side convenience check. Confirmed live: `add-repo` against the
  real `repos.yaml` prints the refusal and exits 2; the file is untouched
  (git status confirms no diff to the tracked file at any point in this PR).
- **Validate-before-write, not write-then-rollback.** `cmd_add_repo` builds
  the merged dict, runs it through `checked_tiers`/`checked_tasks`/
  `checked_projects`/`merged_policy`/`build_queue` (the same calls
  `cmd_validate` makes) entirely in memory, and only then backs up and
  writes. Mutation-tested by reordering write-before-validate in a scratch
  copy: the `validate runs before any write, not after` assertion caught it
  immediately (content-diff assertion, not just exit code — this is the one
  that actually distinguishes the two orderings).
- **Self-exclusion is load-bearing, not cosmetic.** meute-ai-trader lives
  inside `~/Documents/vibe-code`, the default scan target — without the
  `$MEUTE_ROOT` filter, `discover` would list itself as a candidate to add to
  its own fleet. Mutation-tested by removing the filter: the test caught it.
  Confirmed against the real directory too (38 real candidates listed,
  meute-ai-trader correctly absent).
- **Backup-before-overwrite.** `add-repo` writes `<manifest>.bak` from the
  original file content before writing the new one, on every call (rolling,
  not timestamped — acceptable for a personal, single-operator config file
  where the previous version is the one that matters).
- **No anchor/alias corruption risk.** Checked `repos.local.yaml` for real
  YAML anchors/aliases before relying on a `safe_load`/`safe_dump`
  round-trip (`grep -n '[&*]'` — the only matches are `Bash(cmd:*)` glob
  suffixes inside strings, not anchor syntax). A round-trip is safe for this
  file as it stands today.
- **Dedup checks both name and path**, in both directions (a duplicate name
  under a new path, and a duplicate path under a new name) — both are
  separately mutation-relevant since either alone would let a real
  duplicate slip through the other axis.
- **Default task selection doesn't silently grant write access.** Freshly
  discovered repos default to the read-only tier-2 set only; tier-1 tasks
  (`lint-sweep`, `dep-audit`, `gen-tests`) require an explicit opt-in during
  the interactive prompt.

### MEDIUM
None outstanding. Considered and accepted:

- `discover`'s `die()` on an invalid numeric selection aborts the whole
  command rather than re-prompting. Matches this CLI's existing style
  (`dismiss` does the same for an invalid `-r` reason) — consistent, not a
  regression.
- The rolling `.bak` (not timestamped) means only the immediately-prior
  version is recoverable. Acceptable for a config file with one operator and
  git-adjacent editing habits; revisit only if this ever needs multi-step
  undo.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 203/203 |
| Mutation: remove `$MEUTE_ROOT` self-exclusion filter | Pass — targeted test failed as expected |
| Mutation: write before validate in `add-repo` | Pass — targeted test failed as expected |
| Manual: `add-repo` against real `repos.yaml` | Pass — refused, file untouched |
| Manual: `discover` against real `~/Documents/vibe-code`, cancelled | Pass — 38 real candidates, self and 3 configured repos correctly excluded |
| Manual: end-to-end `discover` happy path against scratch fixtures | Pass — added with custom spec/tasks, manifest scaffolding intact |

No type checker / linter / build step applies beyond the test suite itself
(this repo has no separate lint/typecheck pipeline for its own shell/Python).

## Files Reviewed

- `bin/meute` (Modified) — `cmd_discover`, header/usage
- `lib/manifest.py` (Modified) — `cmd_add_repo`, `cmd_list_repos`, `cmd_list_tasks`
- `tests/test_meute.sh` (Modified) — `test_add_repo`, `test_discover`
- `docs/prp/PRP-001-meute.md` (Modified) — §12
