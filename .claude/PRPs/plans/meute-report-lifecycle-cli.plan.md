# Plan: `bin/meute` — report lifecycle CLI

## Summary
Add a subcommand CLI (`bin/meute`) that gives reports a lifecycle — `new` → `read`
→ `actioned`/`dismissed` — and a `promote` verb that converts a tier-2 finding
into a tier-3 `specced: true` ticket. This closes the only open loop in the
system: today a security audit that finds a CRITICAL SQLi requires hand-editing
`repos.yaml` before tier 3 can act on it.

## User Story
As the operator of an unattended fleet,
I want to triage reports and promote findings to fixable tickets from one CLI,
So that findings become fixes instead of accumulating unread in `reports/`.

## Problem → Solution
Reports are written and inert (`bin/run.sh:366` writes the file; nothing ever
reads it back — a grep for `unread|dismiss|triage|reviewed` across `bin/ lib/
tasks/ repos.yaml` returns zero hits) → reports carry state, and a finding can be
promoted to a tier-3 ticket with one command.

## Metadata
- **Complexity**: Medium
- **Source PRD**: `docs/prp/PRP-001-meute.md` (this is phase-2 work, not listed there; add to §12)
- **PRD Phase**: standalone
- **Estimated Files**: 6 (3 new, 3 updated)

---

## UX Design

### Before
```
$ ls reports/netlens-android/
audit-security-2026-08-21.md   audit-security-2026-08-26.md
audit-security-2026-08-24.md   gen-tests-2026-08-27.md
        ↑ which have I read? which found anything? no idea.

$ $EDITOR repos.yaml       # to act on a finding, hand-write a ticket:
#   tickets:
#     - id: NL-15
#       specced: true      # ...and don't typo the schema
```

### After
```
$ meute status
  quota 82%  ·  next: netlens-android/audit-security (daily)
  week 2026-35: 4 personal · 0 community · 1 tier-3 in flight · $2.10

$ meute reports --new
  NEW  netlens-android  audit-security  08-28  CRIT×1 HIGH×2
  NEW  carnet           gen-tests       08-27  +4 tests, green
       relais           audit-security  08-26  no findings

$ meute show netlens-android/audit-security-2026-08-28    # marks it read
$ meute promote netlens-android/audit-security-2026-08-28 -f 1
  → ticket NL-15 written to state/tickets.yaml (specced: true)
  → tier-3 will pick it up next weekly slot (1 of 3 slots free)
$ meute dismiss relais/audit-security-2026-08-26 -m "no reachable sink"
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| "did it run?" | `cat state/log`, parse tabs by eye | `meute status` | Same data, summarised |
| "what's new?" | `ls reports/**` | `meute reports --new` | State-aware |
| Read a report | `$EDITOR reports/...` | `meute show <id>` | Marks read; pipes to `bat`/`less` |
| Act on a finding | hand-edit `repos.yaml` | `meute promote <id> -f N` | The closed loop |
| Drop a finding | nothing | `meute dismiss <id> -m` | Auditable, with reason |
| Tier-3 in flight | `git branch --list` × N repos | `meute branches` | Already computed in `run.sh:tier3_in_flight` |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `bin/run.sh` | 55–100 | `note`/`die`/`skip`/`log_run` idioms; the house error + logging style |
| P0 | `bin/run.sh` | 64–82 | `state_get`/`state_set` — the tab-separated kv store to extract and reuse |
| P0 | `bin/run.sh` | 388–412 | `write_report` — the exact front-matter keys `meute` must parse |
| P0 | `lib/manifest.py` | 290–327 | Subcommand dispatch, `ManifestError`, `fail()` — extend, don't reinvent |
| P1 | `lib/manifest.py` | 236–248 | `expand_tickets` — the tier-3 contract `promote` must satisfy |
| P1 | `bin/run.sh` | 419–435 | `commit_state` — pathspec-scoped autocommit `meute` must not fight |
| P1 | `bin/run.sh` | 145–170 | `tier3_in_flight` — reuse for `meute branches` |
| P2 | `tasks/audit-security.md` | 100–120 | `### [SEVERITY] desc` heading format that finding-counting parses |
| P2 | `repos.yaml` | 117–134 | Ticket schema `promote` must emit |

## External Documentation
No external research needed — this extends established internal patterns. The one
external fact that matters was verified locally, not from docs (see GOTCHA-1).

---

## Patterns to Mirror

### NAMING_CONVENTION
```bash
# SOURCE: bin/run.sh:61-62, 145
# lower_snake_case functions; UPPER_SNAKE globals; `local` for everything else.
note() { printf 'meute: %s\n' "$*" >&2; }
die()  { printf 'meute: %s\n' "$*" >&2; exit 1; }
week_runs() {
  local kind="${1:-}"
```

### ERROR_HANDLING
```bash
# SOURCE: bin/run.sh:31, 61-62, 98
set -Eeuo pipefail
die()  { printf 'meute: %s\n' "$*" >&2; exit 1; }
# "not this time" is exit 0, never a failure — cron must not see a decline as an error:
skip() { log_run "skipped" "reason=$1" "${@:2}"; exit 0; }
```

### STATE_PATTERN
```bash
# SOURCE: bin/run.sh:64-82
# Tab-separated kv, read with awk, written atomically via mktemp+mv. NOT a database.
state_get() {
  [[ -f "$CURSOR_FILE" ]] || return 0
  awk -F'\t' -v key="$1" '$1 == key { print $2; exit }' "$CURSOR_FILE"
}
state_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${STATE_DIR}/.cursor.XXXXXX")"
  if [[ -f "$CURSOR_FILE" ]]; then
    awk -F'\t' -v key="$1" '$1 != key' "$CURSOR_FILE" > "$tmp"
  fi
  printf '%s\t%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$CURSOR_FILE"
}
```

### LOGGING_PATTERN
```bash
# SOURCE: bin/run.sh:85-96
# One tab-separated key=value line per event, appended, also echoed to stderr.
line="$(printf '%s\tweek=%s\tslot=%s\tstatus=%s' "$STARTED_AT" "$THIS_WEEK" "${SLOT:-none}" "$status")"
for field in "$@"; do line+="$(printf '\t%s' "$field")"; done
```

### PYTHON_SUBCOMMAND_PATTERN
```python
# SOURCE: lib/manifest.py:290-327
COMMANDS = {
    "validate": (cmd_validate, 1),
    "policy": (cmd_policy, 1),
    "queue": (cmd_queue, 2),
    "render": (cmd_render, 1),
}
class ManifestError(Exception):
    """Raised for any manifest content the runner refuses to act on."""
def fail(message: str) -> int:
    sys.stderr.write(f"meute/manifest: {message}\n")
    return 2
```

### REPORT_FRONT_MATTER
```yaml
# SOURCE: bin/run.sh:390-412 — written by the runner, parsed by `meute`.
---
repo: sample-repo
task: audit-security
tier: tier2
lens: injection
slot: daily
engine: claude
model: sonnet
auth: claude.ai/max
branch: meute/audit-security-2026-08-28
base: main@4d77284a...
started: 2026-08-28T15:31:23-04:00
status: ok
cost_usd: 0.1053972
turns: 9
---
```

### TEST_STRUCTURE
**There are no tests in this repo.** Validation today is `./bin/run.sh --validate`
plus `bash -n`. This plan adds the first test file; see Task 7. Follow the shell
style already used for smoke checks in the session log: a plain `bash` script with
`set -u`, numbered assertions, non-zero exit on failure. No framework.

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `lib/state.sh` | CREATE | Extract `state_get`/`state_set` so `run.sh` and `meute` share one kv implementation instead of duplicating awk |
| `bin/meute` | CREATE | The subcommand entry point |
| `lib/report.py` | CREATE | Front-matter + finding parsing; Python because it is text parsing, matching the `manifest.py` precedent |
| `state/tickets.yaml` | CREATE | Machine-written tickets, kept out of hand-authored `repos.yaml` (GOTCHA-1) |
| `lib/manifest.py` | UPDATE | Merge `state/tickets.yaml` into `expand_tickets`; add `cmd_add_ticket` |
| `bin/run.sh` | UPDATE | Source `lib/state.sh`; drop the now-duplicated helpers |
| `README.md` | UPDATE | Document the CLI |

## NOT Building
- No TUI, no web UI, no server, no daemon, no database — explicitly out per PRP-001 §2.
- No changes to how the runner selects or executes work. `bin/meute` never invokes an engine.
- No `git push`, no PR creation, no branch merging. `meute branches` lists; you decide.
- No editing of `repos.yaml` by machine — ever (GOTCHA-1).
- No report content rewriting. Reports are immutable once written.
- No new runtime dependency. bash + git + jq + python3/PyYAML only. Not ruamel (GOTCHA-1).

---

## Step-by-Step Tasks

### Task 1: Extract the kv store to `lib/state.sh`
- **ACTION**: Move `state_get`/`state_set` out of `bin/run.sh` into `lib/state.sh`.
- **IMPLEMENT**: Parameterise the file. Signature becomes `kv_get <file> <key>` /
  `kv_set <file> <key> <value>`; keep the mktemp+mv atomicity exactly.
- **MIRROR**: STATE_PATTERN above, verbatim.
- **IMPORTS**: `source "${MEUTE_ROOT}/lib/state.sh"` in `run.sh` beside the existing
  `source lib/engines.sh` / `lib/preflight.sh` lines (`bin/run.sh:32-33`).
- **GOTCHA**: `run.sh` calls `state_get "cursor.${SLOT}"` in 4 places. Keep thin
  wrappers `state_get()/state_set()` bound to `$CURSOR_FILE` so call sites don't change.
- **VALIDATE**: `bash -n bin/run.sh && ./bin/run.sh daily --dry-run` still prints a selection.

### Task 2: `lib/report.py` — parse a report
- **ACTION**: New Python helper, subcommand dispatch mirroring `manifest.py`.
- **IMPLEMENT**: `meta <path>` → front-matter as JSON. `summary <path>` → a one-line
  digest keyed off `task`: for `audit-security`, count `^### \[(CRITICAL|HIGH|MEDIUM|LOW)\]`
  → `CRIT×1 HIGH×2`, or `no findings` when the Findings section holds the literal
  "No findings" sentence; for `gen-tests`, count `^### \d+\.` → `+N tests` plus green/red
  from the Environment section. `findings <path>` → JSON list of
  `{n, severity, title, location}` for `promote` to index into.
- **MIRROR**: PYTHON_SUBCOMMAND_PATTERN; raise `ReportError`, return via `fail()`.
- **IMPORTS**: `import json, re, sys, pathlib` — no yaml needed, front-matter is flat
  `key: value` and hand-parsing avoids a dependency on ordering.
- **GOTCHA**: A failed run's report has no findings section at all — `write_report`
  emits `# Run produced no report` plus a stderr tail (`bin/run.sh:414-416`).
  `summary` must return `run failed` for those, not crash.
- **VALIDATE**: `python3 lib/report.py summary <a real report>` prints one line.

### Task 3: `bin/meute` skeleton + `status`
- **ACTION**: New executable entry point with subcommand dispatch.
- **IMPLEMENT**: `case "$1" in status|reports|show|promote|dismiss|branches|help)`.
  `status` prints: quota (`bin/quota.sh`), next queue item (reuse
  `manifest.py queue` + the cursor), this week's counts (`week_runs` logic), tier-3
  in flight, and week cost summed from `state/log` `cost=` fields.
- **MIRROR**: NAMING_CONVENTION, ERROR_HANDLING; `usage()` via the `sed -n` header
  trick at `bin/run.sh:100`.
- **IMPORTS**: `source lib/state.sh`; shell out to `bin/quota.sh`, `lib/manifest.py`.
- **GOTCHA**: `week_runs`, `tier3_in_flight`, `community_allowed` live in `run.sh`
  and are *not* sourceable (run.sh executes `main "$@"` at the bottom, line 456).
  Either extract them to `lib/fleet.sh` alongside Task 1, or reimplement. **Extract** —
  duplicating the 80/20 arithmetic in two places guarantees drift.
- **VALIDATE**: `./bin/meute status` on a fresh checkout prints without error and
  reports zero runs.

### Task 4: `reports` and `show`
- **ACTION**: List and display, with lifecycle state.
- **IMPLEMENT**: Report id = its path minus `reports/` and `.md`
  (`netlens-android/audit-security-2026-08-28`). `reports [--new|--all]` walks
  `reports/*/*.md`, joins each against `state/reports` (TSV:
  `id <TAB> state <TAB> iso8601 <TAB> note`), defaults missing ids to `new`, prints
  `STATE  repo  task  date  <summary from lib/report.py>`. `show <id>` cats the file
  and sets state to `read`.
- **MIRROR**: STATE_PATTERN (`kv_get`/`kv_set` against `state/reports`).
- **GOTCHA**: `show` must stay pipe-friendly — write the state change to
  `state/reports`, print the report to stdout, and print nothing else to stdout so
  `meute show x | bat` works. Status messages go to stderr via `note`.
- **GOTCHA**: A report on disk with no `state/reports` row is `new`; a row whose
  file is gone is stale — skip it silently rather than erroring.
- **VALIDATE**: `./bin/meute reports --new`, then `show`, then `reports --new` again
  and confirm the entry moved out of `new`.

### Task 5: `state/tickets.yaml` + manifest merge
- **ACTION**: Give machine-written tickets a home, and teach the manifest to read it.
- **IMPLEMENT**: `state/tickets.yaml` shape:
  `tickets: { <repo-name>: [ {id, title, specced, notes, source, created} ] }`.
  In `manifest.py`, load it in `build_queue` and concatenate into each project's
  ticket list before `expand_tickets` runs.
- **MIRROR**: `lib/manifest.py:236-248` — the `specced` gate must apply identically
  to machine tickets. No special-casing.
- **IMPORTS**: reuse the module-level `yaml`; add nothing.
- **GOTCHA**: Ticket ids must not collide with hand-written ones. Validate uniqueness
  per repo across both sources and raise `ManifestError` on a clash — that is a
  config error the operator must see, not something to auto-rename.
- **GOTCHA**: `state/tickets.yaml` must exist-or-be-absent gracefully; a fresh clone
  has none.
- **VALIDATE**: Write a ticket by hand into `state/tickets.yaml`, then
  `MEUTE_ROOT=$PWD python3 lib/manifest.py queue repos.yaml weekly | jq -r .key`
  shows the `<repo>/<task>/<ticket-id>` entry.

### Task 6: `promote` and `dismiss`
- **ACTION**: The closed loop.
- **IMPLEMENT**: `promote <id> -f N [--title T]` reads finding N via
  `lib/report.py findings`, generates a ticket id (`<REPO-INITIALS>-<n>`, n from the
  max existing +1), and appends to `state/tickets.yaml` with `specced: true`,
  `source: <report id>`, and `notes` carrying the finding's location + exploit line.
  Sets report state to `actioned`. `dismiss <id> -m <reason>` sets state `dismissed`
  with the reason in the note column.
- **MIRROR**: The ticket schema at `repos.yaml:126-134`.
- **GOTCHA-1 (CRITICAL)**: **Never write to `repos.yaml`.** Verified locally:
  `yaml.safe_dump(yaml.safe_load("# a vital comment\nkey: 1"))` → `"key: 1\n"` — every
  comment is destroyed. `repos.yaml` is 152 lines that are mostly hand-written
  documentation. `ruamel.yaml` *is* installed here and would round-trip, but adding a
  dependency to mutate a hand-curated config is the wrong trade: machine-written state
  belongs in its own file. This is why Task 5 exists.
- **GOTCHA**: Refuse to promote when tier-3 in-flight is already at
  `policy.tier3_max_in_flight` — warn and record nothing, rather than queueing work
  the runner will silently skip.
- **VALIDATE**: `promote` a finding, then `manifest.py queue repos.yaml weekly` lists
  the new tier-3 entry, and `git diff repos.yaml` is empty.

### Task 7: First test file
- **ACTION**: `tests/test_meute.sh` — the repo's first automated check.
- **IMPLEMENT**: Fixture: temp dir, `git init`, fake `reports/x/audit-security-<date>.md`
  with known front-matter and 3 findings. Assert: `report.py summary` → `CRIT×1 HIGH×2`;
  `reports --new` lists it; `show` flips it to `read`; `promote -f 1` writes
  `state/tickets.yaml` and leaves `repos.yaml` byte-identical; `dismiss` records the
  reason; the tier-3 cap blocks a 4th promote.
- **MIRROR**: TEST_STRUCTURE — plain bash, numbered assertions, exit non-zero on fail.
- **GOTCHA**: Must not touch the real `state/` or `reports/` — set `MEUTE_ROOT` to
  the fixture dir, and assert the real repo is untouched at the end.
- **VALIDATE**: `bash tests/test_meute.sh` exits 0.

### Task 8: Wire up docs
- **ACTION**: Document the CLI in `README.md`; add this work to PRP-001 §12.
- **IMPLEMENT**: A "Reviewing the output" section with the six subcommands, and the
  `state/tickets.yaml` vs `repos.yaml` split with its one-line rationale.
- **VALIDATE**: Every command in the README runs as written.

---

## Testing Strategy

### Unit Tests
| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| summary, audit with findings | report w/ 1 CRITICAL, 2 HIGH | `CRIT×1 HIGH×2` | no |
| summary, audit clean | report w/ "No findings under the..." | `no findings` | yes |
| summary, failed run | report w/ `# Run produced no report` | `run failed` | yes |
| summary, gen-tests | report w/ 4 `### N.` | `+4 tests` | no |
| state default | report on disk, no TSV row | listed as `new` | yes |
| state stale | TSV row, file deleted | skipped silently | yes |
| promote | finding 1 of a report | ticket in `state/tickets.yaml`, `repos.yaml` unchanged | no |
| promote at cap | 3 tier-3 branches live | refused, nothing written | yes |
| ticket id collision | same id hand-written + machine | `ManifestError` | yes |
| show is pipe-clean | `meute show x \| cat` | report only on stdout | yes |

### Edge Cases Checklist
- [ ] Empty `reports/` (fresh clone)
- [ ] Report with no findings section at all (failed run)
- [ ] `state/tickets.yaml` absent
- [ ] Report id that doesn't exist → `die` with a clear message
- [ ] Concurrent access — `meute` runs while `run.sh` holds `state/.lock`
- [ ] Report filename with the `.2.md` de-collision suffix (`bin/run.sh:317`)

---

## Validation Commands

### Static Analysis
```bash
bash -n bin/meute bin/run.sh lib/state.sh
python3 -c "import ast;[ast.parse(open(f).read()) for f in ['lib/report.py','lib/manifest.py']]"
```
EXPECT: no output, exit 0

### Manifest integrity
```bash
./bin/run.sh --validate
```
EXPECT: `ok: .../repos.yaml`

### Unit Tests
```bash
bash tests/test_meute.sh
```
EXPECT: all assertions pass, exit 0

### Regression — the runner still works
```bash
./bin/run.sh daily --dry-run
```
EXPECT: prints a selection; `git diff --stat` clean

### Manual Validation
- [ ] `meute status` on a fresh clone reports zero runs without erroring
- [ ] `meute reports --new` after a real run lists the report as NEW
- [ ] `meute show <id> | bat` renders with nothing extra on stdout
- [ ] `meute promote <id> -f 1` then `git diff repos.yaml` is **empty**
- [ ] The promoted ticket appears in `manifest.py queue repos.yaml weekly`

---

## Acceptance Criteria
- [ ] All 8 tasks completed
- [ ] All validation commands pass
- [ ] `tests/test_meute.sh` passes
- [ ] `repos.yaml` is never written by any code path
- [ ] No new runtime dependency
- [ ] `bin/run.sh` behaviour unchanged (dry-run output identical pre/post)

## Completion Checklist
- [ ] Follows `note`/`die` + tab-separated-kv patterns
- [ ] `set -Eeuo pipefail` in every new shell file
- [ ] No hardcoded values — policy comes from `manifest.py policy`
- [ ] `bin/meute` stays under 400 lines; split to `lib/` if it grows
- [ ] README + PRP-001 §12 updated
- [ ] Self-contained — no codebase searching needed during implementation

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `promote` corrupts `repos.yaml` comments | Medium | High — the manifest's docs are its comments | Never write it; machine tickets go to `state/tickets.yaml` (Task 5) |
| Extracting helpers breaks the runner | Medium | High — the runner is the product | Task 1 first, `--dry-run` regression after each extraction |
| Finding-count parser drifts from templates | Medium | Medium — wrong summaries | Parse the heading format the template mandates; test both task types |
| `meute` and `run.sh` race on `state/` | Low | Medium — lost writes | `kv_set` is already atomic (mktemp+mv); take `state/.lock` for `promote` |
| Report-state TSV diverges from disk | Low | Low | Disk is truth; missing row = `new`, missing file = skip |

## Notes
- The `--new` default is deliberate: the failure mode of this system is unread
  reports, so the default view is the unread queue, not everything.
- `state/reports` and `state/tickets.yaml` land under `state/`, which `run.sh`
  already autocommits via a pathspec (`bin/run.sh:432`) — so triage decisions get
  committed with the next run for free, no extra plumbing.
- Report ids intentionally match the on-disk path so anything printed can be fed
  straight back into another subcommand, and tab-completion is trivial later.
