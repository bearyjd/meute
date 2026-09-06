# PR Review: #12 — feat: the quota gate finally measures the subscription pool it exists for

**Reviewed**: 2026-09-06
**Repository**: bearyjd/meute
**Branch**: feat/real-subscription-gate → main
**Decision**: APPROVE

## Summary

The most consequential change since phase 1 landed, and the one that makes
the project do what §1 says it is for. Reviewed as the highest-risk PR of the
series: it touches the gate that decides whether the fleet runs at all, it
edits a file outside the repo, and its wrapper executes on every status-line
render of every Claude Code session on this machine.

## Findings

### CRITICAL / HIGH
None. Checked specifically:

- **The wrapper can never break the status line.** Hammered the *installed*
  command (not a fixture): empty stdin, garbage stdin, `jq` shadowed with a
  failing stub, `state/` unwritable. All four: exit 0, wrapped HUD output
  intact, nothing on stdout but the HUD's line. The only path that reaches
  `exec sh -c "$wrapped"` is the one that always does.
- **Fail-closed is preserved end to end.** Three distinct failure sources —
  a broken `MEUTE_QUOTA_CMD`, an unreadable snapshot, a self-budget adapter
  error — all decline the slot. None fall through to the stub. The
  snapshot case is the new one and has its own mutation.
- **The two gates cannot mask each other.** `test_two_gates` runs the real
  `run.sh` against a fixture where exactly one gate fails, and asserts the
  *reason string* names the right one. Removing the self-budget check from
  `run.sh` (the pre-PR behaviour) fails precisely those assertions.
- **`install-statusline` edits settings.json safely.** Backup first; original
  command preserved byte-for-byte as a single POSIX-quoted argument
  (`shlex.quote`, verified against a command containing both `$HOME` and a
  single quote — it runs unchanged inside the wrapper); idempotent by
  detecting its own prefix; refuses non-JSON and non-object files without
  touching them; other keys untouched (diffed the real file against its
  backup).
- **The optimism is bounded and named.** A rolled-over window counting as
  fresh is the one place this can be wrong in the dangerous direction
  (running when the pool is fuller than assumed). It is deliberate, documented
  in three places, and backstopped by the existing 429 auto-pause. The
  alternative — refusing to run until the next interactive turn — contradicts
  §1 directly.

### MEDIUM

- **Wrapper overhead**: ~20ms per render, process-startup dominated (bare
  `jq` is ~4ms). Acceptable for a status line, and writes are throttled to
  once/minute-or-on-change so there is no per-render disk churn. Worth
  re-measuring if the HUD's own latency budget ever tightens.
- **The suite was not hermetic against the live snapshot** — `test_quota_gate`
  called the real `bin/quota.sh`, which found the real `state/rate-limits.json`
  the moment `install-statusline` ran and answered 60 instead of the stub's
  55. Same bug class as #10, caught by the same discipline (run the suite
  after every environment change, not just every code change). Fixed by
  pointing the test at a fixture root.

### LOW
- `state/rate-limits.json` gitignored alongside the other machine state.

## Validation Results

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` | Pass — 249/249 (was 220) |
| Same, with the live snapshot present in the checkout | Pass — 249/249 |
| Mutation: self-budget gate removed from `run.sh` | 3 `gates:` assertions fail, only those |
| Mutation: unreadable snapshot falls through to stub | `fails closed` fails, only that |
| Mutation: rolled-over window not treated as fresh | `counts as fresh` fails, only that |
| Mutation: `min` for `max` (less scarce pool) | 2 `subscription:` assertions fail |
| Installed command: empty / garbage stdin, jq broken, state/ read-only | HUD renders, exit 0, all four |
| **Live**: real settings.json wrapped, one command later | snapshot 5h 39% / 7d 30%, gate reads **61**, not 100 |
| `meute doctor` | both gates `ok`, subscription named as the source |
| `run.sh daily --dry-run` | clears both gates, reaches selection |

## Note

The comment this replaced — "only exposed interactively via /usage" — was
written in good faith against the CLI's subcommands and was simply never
re-checked once the status-line contract grew. The lesson kept: a stub that
reads as `ok` is worse than a stub that reads as `UNMEASURED`, because the
first one stops anyone looking.

## Files Reviewed

- `contrib/statusline-capture.sh` (Added)
- `contrib/quota-subscription.sh` (Added)
- `bin/quota.sh`, `bin/run.sh`, `lib/fleet.sh` (Modified) — source precedence, two gates
- `bin/meute` (Modified) — `install-statusline`, `status`, `doctor`
- `tests/test_meute.sh` (Modified) — `test_subscription_gate`, `test_two_gates`, hermetic `test_quota_gate`
- `README.md`, `docs/prp/PRP-001-meute.md`, `.gitignore` (Modified)
