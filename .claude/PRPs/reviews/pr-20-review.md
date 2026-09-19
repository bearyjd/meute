# PR Review: #20 — feat: meute plan (portfolio inventory, explicit read-only staging)

**Reviewed**: 2026-09-19 · **Decision**: APPROVE (after REQUEST CHANGES on the
first head, `bef3813`; three fix rounds, each re-probed by the same reviewer)

## Findings

### HIGH — three on the first head, all closed by probe

- **A mixed-engine fleet wedged on its first Codex entry.** Quota was probed
  after selection, so a failing Codex probe was a *global* skip that never
  advanced the cursor: alpha(claude) → beta(codex) → gamma(claude) pinned
  the cursor at alpha forever, exit 0. Not reachable on this host (no Codex
  entries) and invisible to the suite (Codex-only fixture). Now `eligible()`
  gates each candidate by its own engine through a per-fire cache, the
  round-robin steps past a gated entry, and the nothing-eligible log line
  names every pool it measured. `test_mixed_engine_quota` runs three real
  fires and asserts the rotation.
- **`plan` staged a repo with no commits; the runner then died every fire
  without a log line, a mark, or a cursor move.** `git init` under the scan
  root was enough. The classifier now requires `HEAD^{commit}`, and the
  runner's `BASE_SHA` read goes through `abort_entry` — `status=error
  detail=no-head`, plan mark, cursor advance — which also closes the same
  stall for the pre-existing `worktree-add-failed` path.
- **The egress gate inferred capability from a tool string and missed
  `Bash`.** The shipped `scout` task (`Read,Grep,Glob,Bash` + a `gh`
  allowlist, `writes_code: false`) was ranked and staged by default. Now
  `plan_tier_class` is a positive classification — tools ⊆ {Read,Grep,Glob}
  is *local*, ⊆ local ∪ {WebSearch,WebFetch} is *web* (staged only under
  `--allow-web`), anything else is *other* and never plan-eligible;
  `WebFetch(domain:x)` classifies by its name prefix. The validator refuses
  *other* unconditionally, so planner and runner cannot disagree.

### MEDIUM — four, three closed

- A staged "read-only" run still cuts a `meute/<task>-<date>` branch and a
  worktree in the un-enrolled repo. The footer, the `--enqueue` message and
  the README now say so, and "paste into a ticket" is gone — the preview
  prints absolute paths.
- `meute status` ignored a staged plan. It now prints `staged plan: n of m
  attempted`, its `next <slot>` walks the plan on `plan-cursor.<slot>` and
  applies the same per-engine quota gate as the runner, and a plan file the
  runner would refuse reads `invalid — <reason>` rather than `0 of 0`.
- README had nothing on `plan`, `--allow-web`, per-engine quota or the
  Codex fail-closed default. Added, and checked line by line against the
  code; `MEUTE_CODEX_QUOTA_CMD` persistence points at
  `~/.config/environment.d/`, which `systemd --user` actually reads.
- **Open:** `bin/meute` is 1319 lines against the 800-line rule. The plan
  logic moved to `lib/plan.sh` (largest function 43 lines; `cmd_plan` is
  34), but the file was already 1207 on `main`; moving `status`/`doctor`/
  `discover` out is a refactor for its own PR.

### LOW — seventeen reported, all closed except the notes below

Validate-first and refuse an empty `--enqueue`; single `jq` per candidate;
separate plan and manifest cursors; `--repo/--task` can re-run an attempted
plan item; the symlink-component walk uses an array (`a/a` was skipped
early); a `.git` file whose gitdir points outside the scan root is refused;
depth capped at 16; `--help` prints the comment block instead of a
hardcoded line range; `commit_state` and `MEUTE_NO_AUTOCOMMIT` removed —
every `state/` and `reports/` path is ignored, so it was dead code and the
only channel that could ever have committed private paths; synthetic names
are `plan-<stem>-<6 hex of sha1(f_fsid:inode)>`, stable across re-staging
and across the `/home` ↔ `/var/home` bind-mount spellings; a hand-edited
plan with a list-valued `task` is a `ManifestError`, not a traceback; one
real (non-dry-run) plan run through a stub engine pins worktree creation
and removal, the report path, the mark, and an unchanged git history.

Notes, not fixes: a filesystem reporting `f_fsid=0` collapses the name hash
to `0:<inode>` (still unique within that filesystem); the three-spelling
name assertions are characterization tests — the btrfs reboot case that
motivated `f_fsid` over `st_dev` cannot be reproduced in-suite.

## Validation

| Check | Result |
|---|---|
| `bash -n bin/meute bin/run.sh lib/*.sh` | Pass |
| `python3 -m py_compile lib/manifest.py lib/inbox.py tui/model.py` | Pass |
| `git diff --check` | Pass |
| `bash tests/test_meute.sh` | Pass — 487 passed, 0 failed (main: 343); bind-mount variants ran, not skipped |
| Nothing under `state/` or `reports/` in the diff | Pass |
| Added-line hygiene (home paths, tokens, private repo names) | Pass — only `/home/<you>` placeholders |
| `./bin/meute plan` on the real tree, read-only | 64 discovered / 24 configured / 40 unconfigured under every path spelling; `state/` untouched |

## Files Reviewed

`.gitignore` M · `README.md` M · `bin/meute` M · `bin/quota.sh` M ·
`bin/run.sh` M · `lib/inbox.py` M · `lib/manifest.py` M · `lib/plan.sh` A ·
`lib/preflight.sh` M · `tests/test_meute.sh` M · `tui/model.py` M
