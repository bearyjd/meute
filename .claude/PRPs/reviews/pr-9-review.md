# PR Review: #9 — feat: a blocked run can say why, not just that it was blocked

**Reviewed**: 2026-09-05
**Repository**: bearyjd/meute
**Branch**: fix/allowlist-binary-resolution → main
**Decision**: APPROVE

## Summary

Closes the diagnostic half of the `veille-finance` lint-sweep failure. The
PATH bug itself was fixed in #3/#4; what remained is that when a toolchain
*is* absent, nothing on any allowlist can resolve a binary, so the report
dead-ends at `command not found` with nothing actionable. Adds
`Bash(command -v:*) Bash(which:*)` to all four anchors, plus one guard in
`unit_path_line` that the addition itself makes necessary.

## Findings

### CRITICAL / HIGH

None outstanding. One was found during the change and fixed in it:

- **A shell builtin on the allowlist poisons the timer's PATH.**
  `unit_path_line` derives the systemd unit's PATH from these same
  `allowed_tools` strings (`bin/meute:690`, `re.finditer(r'Bash\(([^:)]+)')`
  then `.split()[0]`). Every name it had ever seen was a real binary;
  `Bash(command -v:*)` makes the first word the builtin `command`, and
  `command -v command` answers with the bare word, not a path. `dirname`
  turns that into `.`. Confirmed empirically, not reasoned about: with the
  guard removed the derived line is literally `.:/usr/bin:/usr/bin:/bin`.

  This matters because a relative PATH entry resolves against the unit's
  working directory, which is a worktree of the repo being worked on — on the
  community track, a third party's code, where a planted `./git` would win.
  The output is filtered to directories already in the caller's own `$PATH`,
  so this only fires where the operator already has `.` there; that converts a
  shell-hygiene wart into an unattended-execution vector rather than creating
  one from nothing. Fixed with `[[ "$path" == /* ]] || continue`.

  **Scope note:** this is the one part of the PR touching executable logic
  rather than YAML. The widening was deliberate — without it the allowlist
  change introduces the latent bug — but it should be seen, not slipped past.

### MEDIUM

- **Whether the permission layer honors a builtin-prefixed pattern was the
  load-bearing unknown.** Every prior entry was a real binary name, so
  `Bash(command -v:*)` had no precedent on this list. If unhonored, the change
  would be inert and `which` would silently carry it alone — on machines where
  `which` may not be installed. Asserted rather than believed, per this repo's
  own standard (see pr-6-review.md):

  | Allowlist passed to `claude -p` | `command -v cargo` |
  |---|---|
  | `Bash(command -v:*)` | executed, returned `/home/user/.cargo/bin/cargo` |
  | `Bash(which:*)` only | **denied** — "This command requires approval" |

  The negative control is what makes this meaningful: it proves the allowlist
  is the operative mechanism, not a permissive `--permission-mode`.

- **`audit_commands` — added, deliberately.** `dep-audit` has the identical
  dead-end when `osv-scanner`/`grype`/`pip-audit` is absent, and it does not
  inherit the tier's list (it overrides `allowed_tools` at task level, so
  `build_entry`'s `allowlist()` returns the audit anchor and never consults
  the tier). Fixing `verify_commands` alone would have left it untouched. The
  test pins both routes separately for that reason.

  `gh_read_commands` and `verify_and_gh` got the same line. The rule applied
  is uniform — every allowlist backing a Bash-bearing tier can hit a missing
  binary — which is easier to reason about later than a per-list carve-out.

  One of the four is not symmetric with the others and the uniform rule should
  not hide it: `gh_read_commands` backs `tier2-scout`, the only tier here at
  `permission_mode: dontAsk` rather than `acceptEdits`. Checked rather than
  waved through — that tier's `tools` string is `Read,Grep,Glob,Bash`, with no
  Edit or Write, and `command -v gh` executes nothing, so the blast-radius
  argument in that anchor's own comment ("nothing it does reaches the
  project") is untouched. A probe that resolves a name is if anything a better
  fit for a read-only tier than for a writing one.

### LOW

- The comment deliberately does **not** claim what the original bug report
  wished for ("...and is not at `~/.cargo/bin` either"). `command -v` cannot
  answer that, and `ls ~/.cargo/bin` was already on the allowlist and still
  refused — by the sandbox's working-directory limit, which no allowlist entry
  can lift. The comment claims only the true, narrower thing: a definite "not
  on PATH" in place of an ambiguous failure.

## Validation Results

| Check | Result |
|---|---|
| `python3 lib/manifest.py validate repos.yaml` | Pass |
| `python3 lib/manifest.py validate repos.local.yaml` | Pass |
| Tests (`bash tests/test_meute.sh`) | Pass — 218/218 (was 207) |
| Mutation 1: remove all 4 probe additions from `repos.yaml` | Pass — 4 assertions failed; the two fixture-anchor assertions still passed, proving content failure not fixture failure |
| Mutation 2: remove `[[ "$path" == /* ]] || continue` | Pass — `expected [0], got [1]`; companion assertion still passed, isolating it to the relative entry |
| Restore between mutations | Pass — back to 218/218, so the mutations were the only variable |
| Live permission-layer probe (`claude -p`, both directions) | Pass — see table above |
| Real fleet wiring (`manifest.py queue repos.local.yaml`) | Pass — all 6 Bash-bearing entries across 3 repos carry the probe |
| `repos.local.yaml` round-trip | Pass — parsed structures identical apart from the probes; key order preserved |

### On the tests themselves

Two things were deliberate, both from scar tissue already in this file:

- The guard test splits the derived line on `:` and compares fields exactly.
  `.` is a substring of no directory and a regex matching every character, so
  a `has`/`grep` assertion would have passed without proving anything — the
  same silent-no-match class the colon-join dedup at `bin/meute:710-714` was
  written for.
- The allowlist test asserts on the **resolved queue entry**, not on
  `repos.yaml` text. A text assertion would be near-tautological and would
  fail for a textual reason under mutation. It also asserts the fixture
  actually queued something first, because the three `hasnt` assertions would
  otherwise pass vacuously on an empty string. That guard earned itself: the
  test's first run failed because `MEUTE_ROOT` was unset and templates did not
  resolve, which surfaced as an empty queue.

## Files Reviewed

- `repos.yaml` (Modified) — four anchors, plus the rationale paragraphs
- `bin/meute` (Modified) — one-line absolute-path guard in `unit_path_line`
- `tests/test_meute.sh` (Modified) — `test_binary_probe_allowlisted`, and two
  assertions added to `test_unit_path_line`
- `repos.local.yaml` (gitignored, not in this diff) — all five flattened
  sites: top-level `verify_commands`/`audit_commands`, `tier1`/`tier3`
  `allowed_tools`, `dep-audit.allowed_tools`. The top-level two are vestigial
  once the anchors are expanded; the three that actually reach `run.sh` are
  the tier and task ones. Verified live through `manifest.py queue`.

## Known gap — reported, not fixed here

`unit_path_line` scans only `tiers` (`bin/meute:689`), never task-level
`allowed_tools`. So `dep-audit`'s scanners — `osv-scanner`, `grype`,
`pip-audit`, typically in `~/.local/bin` — never reach the timer's PATH. That
is the same bug #3/#4 fixed for `cargo`, still open for the audit list, and it
means `dep-audit` under the timer can still fail the exact way lint-sweep did.
Out of scope for a change about diagnosis; it wants its own PR, and now has a
better failure report waiting for it when it fires.
