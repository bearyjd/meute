# Web inbox: a real web page for the meute triage inbox

Status: v1 + v2 approved 2026-11-15; implemented on branch feat/web-inbox

## Intent
`meute web` currently shows the Textual TUI in a browser via textual-serve. The user wants a real web page instead: ordinary HTML, not a terminal in a browser. Same inbox, same decisions, no new screens.

## Goals
- A findings table with filter, an evidence panel, and Promote / Dismiss (reason required) / Resolve (message required) buttons.
- Tabs for tier-3 drafts awaiting merge and for all reports (parity with the TUI).
- Every action goes through `lib/inbox.py` (`dump`, `act`), which shells out to `bin/meute`, so the page and CLI can never disagree.

## Non-goals
- No quota charts or repo enrollment. (The Run tab below is the one addition beyond the TUI's screens.)
- No accounts or multi-user support.
- No change to the runner; `bin/run.sh` must still work without the UI venv.

## Anti-goals
- Any dependency or build step (node, bundler, web framework).
- Any way for a random website in the user's browser to change triage state.

## Constraints
- Python standard library only (`http.server`), run from `tui/` next to `serve.py`.
- Binds 127.0.0.1 by default; off-loopback keeps the existing `--host` + `--insecure-public` acknowledgement; wildcard hosts (`0.0.0.0`, `0`, `*`) are rejected because the Host check would refuse every request.
- Every request (GET included) is refused with 403 when `Sec-Fetch-Site` is `cross-site` or `same-site` (`same-origin`, `none` and absent pass), so another site's `<img>`/no-cors fetch cannot trigger a `meute plan` scan; `plan()` is single-flight (a concurrent scan gets 409).
- State-changing endpoints (POST) require a per-process random token (embedded in the served page, sent as a header) and reject requests whose `Host` is not the bound address (blocks DNS rebinding) or whose `Origin` mismatches.
- Evidence text is untrusted report content: render with `textContent`, never `innerHTML`.
- Files stay small (<400 lines each); no mutation of shared state in handlers beyond calling `act`.

## Approaches considered
- **A. stdlib server + static HTML/JS (chosen).** No new deps, no build, fits "on demand like `meute web`". Cost: hand-written vanilla JS; clumsy if the UI grows into a dashboard.
- B. Flask/FastAPI + htmx. Same shape, nicer templating, but adds a dependency for one screen.
- C. JS SPA (React/Vite). Richest UI, but needs node and a build step; conflicts with the no-daemon, no-dependency stance.

## Design
- `tui/webserver.py`: the HTTP server. `GET /` serves the page with the token injected; `GET /api/inbox` returns `inbox.dump()`; `GET /api/finding?id=&n=` returns `finding_body`; `POST /api/act` (JSON: verb, id, n, reason/message) calls `inbox.act` and returns its result.
- `tui/web/index.html` + `app.js` + `style.css`: the page.
- `bin/meute web` switches to `webserver.py`. The Textual app stays for `meute tui`; textual-serve is kept only if removal is non-trivial (builder's call).
- Tests: handler tests for token/Host/Origin rejection, verb validation, and that `act` receives exactly the CLI arguments the TUI sends.

## Left to the builder
Exact layout and styling (simple, keyboard-friendly like the TUI: j/k, Enter, `/` filter is a nice-to-have), how tab data is paginated, and whether to delete textual-serve.

## Calls I made (not yet confirmed by you)
Loopback-only default; token + Host/Origin checks; same scope as the TUI; `meute web` repointed to the new page.

## Addendum v2: Run tab ("Go" button) -- plan, review, enqueue, execute, track
Added 2026-11-15 at the user's request: a button that launches the fleet's work, with progress.

### Flow
1. **Plan** (read-only): the page calls `GET /api/plan`, which runs `meute plan --json` and lists proposed repos/tasks.
2. **Review**: the user ticks the repos to stage. Nothing is ticked by default, and Enqueue is disabled until at least one is ticked, so a stray click cannot stage e.g. a private-documents repo or vendored code.
3. **Enqueue**: `POST /api/enqueue {paths: [...]}` runs `meute plan --enqueue --only <path> ...`. The server re-runs the plan and rejects any path not in the fresh result (never an arbitrary path).
4. **Execute**: `POST /api/run/start` starts one background loop that runs the daily slot, then the weekly slot, for the staged items only (staged read-only tasks are mostly weekly-only; repos.yaml lists at least one read-only task for both slots). Each item is forced individually via `--repo/--task` (quota floor, pause, lock and budget still apply), one item per call, strictly one loop at a time. It stops when nothing is eligible, the quota gate or a pause says skip, 3 consecutive errors occur, or the user presses Stop (`POST /api/run/stop`, lets the current item finish). A confirm click is required before Start.
5. **Track**: `GET /api/run/status` returns state (idle/running/stopping), the current item, counts (total, done, remaining) from the staged queue plus `state/log`, and the last results with outcome. The page polls every 2s.

### Changes to meute itself
- `meute plan --json`: machine-readable plan (repo path, name, task, reason). Human output unchanged.
- `meute plan --enqueue --only <abs-path>` (repeatable): stage only those repos. With `--only` and no match, stage nothing and exit non-zero.
- `--json` combined with `--enqueue` is a usage error.

### Safety
- All new POSTs use the same token and Host/Origin guard.
- Start refuses (409) while the fleet is paused (`meute pause`) or a loop is already running; the runner's own quota floor still applies and is never bypassed.
- The loop runs in the server process; closing the server stops the loop after the current item (the in-flight item is allowed to finish, not killed).
- Added to the plan's tests: unlisted path rejected, empty selection rejected, Start while paused/running -> 409, loop stops on nothing-eligible / 3 errors / Stop, status counts match a fixture queue and log.

### Left to the builder
Exact parse of `state/log` and the staged queue file for progress (read `lib/plan_queue.py` and `state.sh`), and the page layout of the Run tab.
