# PR Review: #14 — feat: carry gitignored build plumbing into worktrees (worktree_files)

**Reviewed**: 2026-09-06
**Repository**: bearyjd/meute
**Branch**: feat/worktree-files → main
**Decision**: APPROVE

## Summary

Closes the one structural gap the first real tier-3 draft disclosed, and
brings the suite its first end-to-end test of the runner past the gates.

## Findings

### CRITICAL / HIGH
None. Checked specifically:

- **The copy cannot reach outside the repo.** Validator rejects absolute
  paths and any `..` segment; both rejections are mutation-tested. The copy
  itself is `cp -p` from `$REPO_PATH/$rel` to `$WORKTREE/$rel` with
  `mkdir -p` on the destination only — no globbing, no following of the
  source through symlinks beyond what `cp` does by default.
- **Missing sources are skipped, not errors.** A repo that lists a file it
  does not currently have (a fresh clone before first build) still runs.
  Pinned.
- **The main checkout is never modified.** Pinned by `git status
  --porcelain` on the source repo after the run.
- **Nothing leaks into the deliverable.** The copied file is gitignored in
  the target repo by construction (that is the whole reason it needs
  copying), so it cannot appear in a tier-1/3 commit.

### MEDIUM

- **Did not build for the JAVA_HOME claim.** The report said `gradlew` died
  on `JAVA_HOME` and `java` was not on PATH. Reproduced the exact conditions
  — real unit PATH, real CLI sandbox, real worktree — and `command -v java`
  resolves to `/usr/bin/java`, `./gradlew --version` runs. Whatever the agent
  hit, it was not the environment; building a JAVA_HOME derivation for an
  unreproducible failure would be guessing. Recorded in §11 so the next
  person does not re-chase it.
- **The stub engine is the real win.** It is 4 lines and it turns `run.sh`
  from gate-tested into path-tested. Future runner changes (report writing,
  commit_worktree, ticket retirement) can now be covered without an engine.

### LOW
- `note "carried X into the worktree"` on stderr — visible in the journal so
  an operator can see the copy happened. Cheap, worth having.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 262/262 (was 253) |
| Both manifests validate | Pass |
| Mutation: copy call removed | 2 assertions fail, only those |
| Mutation: `..` check dropped | 2 assertions fail, only those |
| Real: `bascule-bluetooth/dep-audit` queue entry carries `["local.properties"]` | Confirmed |

## Files Reviewed

- `bin/run.sh` (Modified) — `copy_worktree_files`
- `lib/manifest.py` (Modified) — validation + pass-through
- `repos.yaml` (Modified) — documented on the example repo
- `tests/test_meute.sh` (Modified) — `test_worktree_files` with the stub engine
- `docs/prp/PRP-001-meute.md` (Modified) — §11
- `repos.local.yaml` (gitignored) — both Android repos wired
