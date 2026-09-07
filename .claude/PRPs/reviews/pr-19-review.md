# PR Review: #19 — feat: the triage inbox (PRP-003 screen 1, terminal + browser)

**Reviewed**: 2026-09-06 · **Decision**: APPROVE

## Findings

### HIGH — none. Checked:

- **The runner is untouched by any of this.** Grepped, and pinned by three
  assertions: `run.sh` has no reference to `tui/`, `lib/` never imports
  textual, `tui/model.py` has no textual import. The venv is created only
  by `meute tui`/`meute web`, on demand. PRP-003 §7's "run.sh completes on a
  machine with no venv and no Textual" holds by construction.
- **One implementation of every write.** `inbox.py` shells out to
  `bin/meute promote|dismiss|resolve`; a test dismisses through `inbox.py`
  and reads the result back through `meute findings` and `state/reports`.
  A bad reason is refused by the CLI and surfaced, not swallowed.
- **`meute web` has no auth** and says so in three places (help text, the
  README, a WARNING when bound to anything but loopback). Verified it binds
  `127.0.0.1:8642` only by default (`ss -ltnp`). This is textual-serve's
  nature; a tailnet address is the documented way to reach it from a phone.
- **The header cannot lie about the gate.** The stub source reads
  `UNMEASURED`, mutation-tested; below-floor reads `BELOW FLOOR`.

### MEDIUM

- **Two bugs found by the headless smoke test, both mine.** The hidden
  filter `Input` was the first focusable widget and took the keyboard on
  mount (j/k typed into it; Enter submitted "jj" as a query). And
  `inbox.py` ran `manifest.py` with `sys.executable`, which inside the venv
  has no PyYAML — the policy read failed silently, so the header could not
  say BELOW FLOOR even at 12%. Both would have shipped without a test that
  actually drives the widgets.
- **Rendered and looked at it**, twice: the first cut split the list into
  five equal columns and truncated titles to ~20 chars. Titles are the
  decision; task/lens moved into the detail header, and the title column's
  width is computed from the pane on resize.

### LOW
- Screens 2–5 remain blocked on PRP-002, as the document says. Nothing here
  invents a work-order schema.

## Validation

| Check | Result |
|---|---|
| `bash tests/test_meute.sh` (system python3, no Textual) | 306/306 (was 282) |
| Headless smoke via Textual's pilot on real data | 12 rows, filter → 5, modal opens/cancels, 3 tabs populated |
| Mutation: state key `id#n` → `id:n` in inbox.py | "undecided count matches meute findings" fails, only that |
| Mutation: stub reads ok | "a stub reads UNMEASURED" fails, only that |
| Mutation: finding body runs on | "stops before the next finding" fails, only that |
| `meute web` live | HTTP 200 on `127.0.0.1:8642`, loopback only, clean stop |
| `ruff check lib/inbox.py tui/` | clean |
| Screenshot | rendered via `save_screenshot`, reviewed by eye |
