# Plan: PRP-004 Phase 1 — schema, plumbing, and log columns

## Summary
Add the manifest fields, validation rules, queue-builder plumbing, log
columns, `state/stages` file, `meute image bump` command and two `doctor`
checks that PRP-004 §4.1 and Phase 1 specify. No container code, no clone
logic, no publish — those are Phase 2 and Phase 5 and would be written
against an unbuilt schema.

## Metadata
- **Complexity**: Medium
- **Source PRP**: `docs/prp/PRP-004-container-review-publish.md` §4.1, §4.3, §4.4, Phase 1
- **PRD Phase**: 1 of 7
- **Estimated Files**: 7 (0 new code files; `repos.yaml`, `.gitignore`, `lib/manifest.py`, `bin/run.sh`, `bin/meute`, `lib/doctor.sh`, `tests/test_meute.sh`)
- **Build**: Opus executor (PRP-004 assigned Sonnet; the hardened Phase 1 rewires the queue builder and carries a test bar, so the stronger model was used — recorded here so the deviation is visible)
- **Review**: `code-reviewer`, then the PRP-004 critic (context loaded), then a Codex light pass per the PRP

## Decisions fixed before build (the executor does not re-decide these)

1. **`expand_tickets` signature.** Today `expand_tickets(entry, project,
   want_specced)` is pure. It becomes
   `expand_tickets(entry, project, stages, want_specced)`, where `stages` is
   a dict loaded **once** in `build_queue` from `state/stages` (rows keyed
   `<repo>/<ticket>`; fields `stage`, `branch`, `base`, `build_report`).
   A ticket with a row whose `stage` is not `done` yields a **stage entry**
   instead of a build entry:
   - `stage_entry: true`, `stage`, `branch`, `base`, `build_report` copied in
   - `engine`: for `review`/`review-2`, the *other* engine (claude↔codex)
     from the build engine recorded in the row (`row.engine`, written at
     build); for `resolve`, the build engine; for `publish`, `""`
   - `key`: `<repo>/<task>/<ticket>/<stage>`
   - `tier`: `tier3-review` for review stages, `tier3` for resolve, the
     entry's own tier otherwise
   Stage entries are emitted **ahead of** the repo's other entries. A ticket
   with no row or a `done` row yields the build entry as today, with
   `stage_entry: false`.
2. **Per-ticket `engine`.** Honoured in `expand_tickets` for the build entry
   (ticket > task > repo > defaults). `build_entry`'s `setting()` is not
   changed; it has no ticket in scope.
3. **Cap exemption.** `eligible()` in `bin/run.sh` skips the tier-3 in-flight
   check when the entry has `stage_entry == true`. Nothing else in `run.sh`
   acts on stage entries yet — Phase 4 does. Until then a stage entry that
   gets selected must **not** run: `run_entry` aborts it through
   `abort_entry` with `detail=stage entries are not runnable before Phase 4`,
   so a stray `state/stages` row can never invoke an engine.
4. **`repo:` is one field with one meaning.** `repo: owner/name` already
   exists as the community upstream and flows into the entry as
   `upstream`. Rule 9 reuses it: under `repos:` it is the owner's GitHub
   repository, same `owner/name` format (`SAFE_NAME/SAFE_NAME`), required
   when `push: true`, and it reaches the entry under the same `upstream` key.
   No second field.
5. **`state/stages` is created by this phase** (`lib/state.sh` `kv_row`
   format, one row per `<repo>/<ticket>`) and its `.gitignore` line lands in
   the same commit. `state/prs` is Phase 5's.
6. **Log columns** `runtime=`, `image=`, `stage=`, `pr=` are appended in that
   order after every existing column, always `-` in this phase, on every
   line class `log_run` writes (ok, error, skipped). Nothing that parses
   `state/log` (`lib/fleet.sh week_runs`, `lib/status.sh`, `lib/report.py`,
   the inbox) may break on the extra columns — run the suite to prove it.
7. **`meute image bump <repo>`**: resolves the repo's `image.tag` from the
   merged manifest, runs `podman image inspect --format '{{.Digest}}'`
   through the same podman resolution the PRP §5 wrapper will use
   (`MEUTE_PODMAN`, else `distrobox-host-exec podman` when
   `/run/.containerenv` exists, else `podman`), and writes `image.digest`
   into `repos.local.yaml` through a new `manifest.py set-image-digest`
   that reuses `cmd_add_repo`'s validate-merged-then-write-with-backup path
   and its hard refusal of `repos.yaml`. Refuses if the repo has no
   `image.tag`.
8. **`doctor`**: for each `repos:`/`community:` entry with resolved
   `runtime: container`, `ok`/`FAIL` "image `<tag>` present at pinned
   digest" (inspect digest equals manifest digest; absent image is FAIL).
   Fleet-wide, only when at least one repo is `container`: `ok`/`FAIL`
   "`atelier-egress` running" (`podman container inspect --format
   '{{.State.Running}}' atelier-egress` is `true`). Both use the same podman
   resolution as item 7. When no repo is `container`, neither check prints.

## Validation rules (PRP-004 §4.1, one test each — RED first)

| # | Rule | Error names |
|---|---|---|
| 1 | `image.tag` and `image.digest` required when resolved `runtime` is `container`; digest matches `^sha256:[0-9a-f]{64}$` | the repo and the missing/invalid field |
| 2 | `network` is a tier key only (`none`\|`proxied`); any repo/task/ticket `network` is an error; a tier `runtime: host` beats a repo `runtime` | the offending level |
| 3 | `push: true` only under `repos:`; on `community:` it is an error | the repo |
| 4 | `auto_merge: true` is an error; `false`/absent is fine | the repo |
| 5 | `--runtime container` from the CLI on a repo with no `image:` fails closed with rule 1's message (`run.sh`, at selection) | the repo |
| 6 | per-ticket `engine` honoured; review engine derived, never a field (a ticket `review_engine:` key is an error) | the ticket |
| 7 | `state/stages` row → stage entry with the fields in decision 1; `done` or absent → build entry | — |
| 8 | a repo with `runtime: container` and no `image.tag` prefix `agent-` … *no rule*: tag format is `agent-<name>:g<hex>` or `agent-base:g<hex>`; anything else is an error | the repo and the tag |
| 9 | `push: true` requires `repo: owner/name` under `repos:` | the repo |

Plus: `defaults.runtime` accepts `host`\|`container` only; every existing
test still passes; `tier3-review` exists in `repos.yaml` with the §4.1
block and validates.

## Files
- `repos.yaml` — `defaults.runtime: host`; `network:` on each existing tier
  (`tier1`, `tier2`, `tier2-scout`, `tier3`: `proxied`; `tier2-web`:
  `runtime: host`); the `tier3-review` block; commented example of `image:`,
  `push:`, `repo:` on the example repo entry; comments in the file's voice.
- `.gitignore` — `state/stages`.
- `lib/manifest.py` — rules 1–4, 6, 8, 9 in `checked_tiers` /
  `checked_projects`; `build_entry` emits `runtime`, `image`, `network`,
  `push`, `stage_entry: false`; `build_queue` loads stages; `expand_tickets`
  per decision 1–2; `cmd_set_image_digest`; `REQUIRED_TIER_KEYS` unchanged
  (`network` has a default of `proxied` for tiers that omit it? **No** —
  every tier must state it, so a new tier cannot inherit egress by
  omission; add `network` to `REQUIRED_TIER_KEYS` and set it on every tier
  in `repos.yaml`).
- `bin/run.sh` — four log columns; `eligible()` cap exemption; rule 5 at
  selection; stage entries abort before invoke (decision 3).
- `bin/meute` — `image bump <repo>` subcommand and `usage` line.
- `lib/doctor.sh` — the two checks.
- `tests/test_meute.sh` — one test per rule, the decision-3 abort, the log
  column assertion (`main` line vs. branch line differ only by the four
  appended columns — build the fixture, run the stub engine, diff), the
  `image bump` refusal of `repos.yaml` and its `.bak`, the `doctor` checks
  with a `podman` stub on `$root/stub`.

## Gate (PRP-004 Phase 1)
- `meute validate` accepts the §4.1 example merged into the existing tier
  blocks and rejects each rule's violation with a message naming the field.
- `state/log` lines differ from `main`'s only by the four appended columns.
- `meute image bump` refuses `repos.yaml` and writes `repos.local.yaml`
  with a backup.
- `bash tests/test_meute.sh` green; count of tests reported before/after.

## Out of scope
`lib/container.sh`, the clone, in-container preflight, the review
template, `lib/publish.sh`, `state/prs`, demotion, `meute prune`.
