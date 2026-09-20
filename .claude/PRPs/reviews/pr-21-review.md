# PR Review: #21 — refactor: move status, discover, doctor, timers and statusline out of bin/meute

**Reviewed**: 2026-09-20 · **Decision**: APPROVE

## Findings

### HIGH — none. Checked:

- **It is a pure move.** `declare -f` over all 76 functions after sourcing
  `bin/meute`, plus `declare -p` of every global the moved code reads
  (`CRON_PATH_DEFAULT`, `DOCTOR_*`, `SEVERITY_RANK`, `DISMISS_REASONS`,
  `SCRUBBED`, `AUTH_MODE`, `ENGINE_ENV`, `PLAN_KNOWN_NAME`) and the readonly
  set, diffs empty against `main` with the root path normalised. Each new
  file's body after its header is a contiguous slice of the original;
  the only lines not landing exactly once are six blank separators.
- **Sourcing order.** `bin/meute:74-82` sources state, fleet, preflight,
  plan, then the five new libs, unconditionally and before `main`. The
  only top-level statements that moved are `doctor.sh`'s `readonly
  CRON_PATH_DEFAULT` and the two `DOCTOR_*` counters; nothing at source
  time needs `note`/`die`/`dir_id`, which are defined after the source
  lines and resolved at call time. No file double-sources a lib — a
  deliberate second `source lib/doctor.sh` dies on the `readonly`, which
  is the guard, not a hazard. `bin/run.sh` still sources only
  state/fleet/engines/preflight and is untouched.
- **Tests still reach every helper.** All thirteen sites that source
  helpers do `source "$REPO/bin/meute"`; the two that source libs directly
  take `state.sh` + `fleet.sh`, which did not move. `unit_path_line`,
  `dedup_dirs`, `timer_state`, `linger_state`, `repo_default_branch`,
  `cmd_web`, `tui_python`, `dir_id`, `usage` all resolve after sourcing.
  None of the 487 tests changed.
- **Live output.** `help` (48 lines, first and last lines pinned by
  `test_help`, no code), `doctor` (every section renders through the real
  systemd probes) and `status` all byte-identical before and after.
- **`lib/` still never mentions textual**; `tui`/`web` stayed in
  `bin/meute` for that reason.

### MEDIUM — none.

### LOW

- `lib/doctor.sh`'s "Expects from the caller" header omitted `die`, which
  `cmd_doctor` calls once. Fixed before commit.

## Validation

| Check | Result |
|---|---|
| `bash -n bin/meute lib/*.sh` | Pass |
| `git diff --check` | Pass |
| `bash tests/test_meute.sh` | Pass — 487 passed, 0 failed, no skips |
| `declare -f` identity vs `main` | Identical (76 functions) |
| Sizes | `bin/meute` 574 · `status.sh` 131 · `discover.sh` 155 · `doctor.sh` 231 · `timers.sh` 223 · `statusline.sh` 76 — all under 800 |

## Files Reviewed

`bin/meute` M (+5 source lines, −766) · `lib/status.sh` A · `lib/discover.sh` A ·
`lib/doctor.sh` A · `lib/timers.sh` A · `lib/statusline.sh` A
