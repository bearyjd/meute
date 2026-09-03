# PR Review: #6 — feat: add market-comparison tier-2 task on a new web-reaching tier

**Reviewed**: 2026-09-03
**Repository**: bearyjd/meute
**Branch**: feat/market-comparison-task → main
**Decision**: APPROVE

## Summary

Second Phase-2 roadmap item off PRP-001 §12. Unlike `architecture-review`
(PR #5), this task needed real design work before the template: whether
WebSearch reintroduces metered billing (it doesn't, under subscription auth),
and whether a `dontAsk` tier should reach the network at all (yes, scoped —
new `tier2-web` tier, not an addition to shared `tier2`). Also explicitly
declines "feature brainstorm," the other item on that list, with a documented
reason rather than silence.

## Findings

### CRITICAL / HIGH
None. Checked specifically for:

- **Tier isolation** — the one property this PR depends on: `tools` resolves
  per-tier (`lib/manifest.py:build_entry`, `"tools": tier["tools"]`), not
  per-task, confirmed by reading the function directly, not assumed. Verified
  live: `architecture-review` and `market-comparison` share a fixture
  manifest in `test_market_comparison_queued`, and the test asserts the
  former's `.tools` does NOT contain `WebSearch`.
- **Billing claim** — the PR asserts WebSearch draws from subscription usage,
  not metered billing. This is asserted, not merely believed: fetched Claude
  Code's own `docs/en/costs` page directly rather than relying on third-party
  pricing blogs (which do describe a $10/1,000-search API rate, but that's
  the Console/API billing path, which `lib/preflight.sh` already refuses to
  run under). No code change was needed to act on this finding — `preflight`
  already gates on subscription auth for every engine invocation regardless
  of which tools are enabled.
- **Blast radius of a hostile fetched page** — tier2-web has no Bash, Edit,
  or Write (confirmed by tools string), so a prompt-injection attempt from a
  fetched page's content cannot escalate past shaping report prose. Same
  argument the pre-existing `tier2-scout` tier already relies on for `gh`
  reads; not a new risk class.
- **Template placeholder correctness** — rendered `tasks/market-comparison.md`
  through `manifest.py render` with realistic values; no unresolved `{{VAR}}`.
- **`FILE_BUDGET` reuse** — the template reuses the existing `FILE_BUDGET`
  manifest field as a "web-lookup budget" rather than inventing a new
  template variable `run.sh` doesn't populate. Confirmed `run.sh`'s render
  call passes `FILE_BUDGET` unconditionally for every task, so this needs no
  runner change.
- **URL-fabrication risk** — the template explicitly forbids citing a URL not
  returned by `WebSearch`/`WebFetch` in this run, addressing the specific
  failure mode where an LLM "recalls" a real project's URL from training data
  that's since moved or died. Not verified by a live run (no run against a
  configured repo has happened yet — this task hasn't fired once), so this is
  a design mitigation, not yet an empirically confirmed one.

### MEDIUM
None outstanding. Considered and accepted:

- Three lenses (vs. four for the other tier-2 tasks) — the narrower domain
  (comparing against external sources rather than an open-ended code
  surface) doesn't obviously support a fourth non-overlapping lens; adding
  one for parity alone would risk lens-boundary ambiguity for no evidentiary
  gain. Can grow later against real report output if lenses turn out to
  collide in practice.

### LOW
None.

## Validation Results

| Check | Result |
|---|---|
| `python3 lib/manifest.py validate repos.yaml` | Pass |
| `python3 lib/manifest.py validate repos.local.yaml` | Pass |
| Template render smoke test | Pass — no unresolved placeholders |
| Tests (`bash tests/test_meute.sh`) | Pass — 184/184 |
| Mutation: fixture's `market-comparison` task pointed at `tier2` instead of `tier2-web` | Pass — 3 assertions failed as expected (tier, WebSearch, WebFetch) |
| Manual: real weekly queue inspection (`repos.local.yaml`) | Pass — 3 new `market-comparison` entries across all three repos, `tier2-web` tools confirmed present, no Bash |

No type checker / linter / build step applies (this PR touches a prompt
template, a YAML schema doc, a doc file, and tests — no executable logic
changed in `lib/` or `bin/`).

## Files Reviewed

- `tasks/market-comparison.md` (Added)
- `repos.yaml` (Modified) — new tier, new task registry entry, removed stale Phase-2 comment
- `tests/test_meute.sh` (Modified) — `test_market_comparison_queued`
- `docs/prp/PRP-001-meute.md` (Modified) — §11, §12
- `repos.local.yaml` (gitignored, not part of this diff) — wired to all three
  configured repos, verified live via `manifest.py queue`
