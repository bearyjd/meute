# PR Review: #1 — fix: authenticate the HTTP surface and validate publish targets

**Reviewed**: 2026-08-29
**Repository**: bearyjd/immich-journal (private)
**Branch**: meute/draft-ticket-2026-08-29.2 → main
**Decision**: REQUEST CHANGES — **resolved 2026-08-29**, see Resolution

## Summary

Both fixes are well-built and the publish guard is genuinely defensive. One gap
undercuts the PR's central claim: FastAPI's auto-generated documentation routes
are **not** covered by the app-wide dependency, so the complete API surface is
readable without a credential. Verified by running the app, not by reading it.

## Resolution

The HIGH finding was fixed in `26f783e`: `docs_url`, `redoc_url` and
`openapi_url` set to `None`, with a regression test using the file's existing
`secured_client` fixture. Re-probed: all three paths now 404 unauthenticated,
protected routes still 401. 114 tests pass. Mutation-checked — deleting the three
arguments fails exactly the three new tests.

The two LOW findings were accepted as-is; both fail in the safe direction.

## Findings

### CRITICAL
None.

### HIGH

**1. `/openapi.json`, `/docs` and `/redoc` bypass authentication**
`src/immich_journal/server.py:206`

`FastAPI(dependencies=[...])` applies to routes registered through
`add_api_route`. The documentation endpoints are registered internally via
`add_route` during `FastAPI.setup()` and are therefore not covered. Measured with
a valid secret configured:

```
/openapi.json      200   <-- unauthenticated
/docs              200   <-- unauthenticated
/redoc             200   <-- unauthenticated
/api/v1/entries    401
/                  401
```

The protected routes are correct. But an unauthenticated attacker can still
retrieve the full schema: every path, method, parameter and model — including the
publish and photo-selection endpoints this PR exists to protect. That is not data
access, but it is a complete map for attacking the surface, and the PR describes
itself as closing the surface.

Fix, either:
```python
app = FastAPI(..., docs_url=None, redoc_url=None, openapi_url=None)
```
if the docs are not wanted in production, or keep them and gate them explicitly.
Disabling is the safer default for a self-hosted single-tenant app.

Add a regression test — an unauthenticated `GET /openapi.json` must not return
200 — otherwise this reappears the next time the app is constructed differently.

### MEDIUM
None.

### LOW

**2. One Immich round trip per photo id at publish**
`src/immich_journal/api/mobile.py` — publish validation

Each id triggers its own `GET /api/assets/{id}` before the `PUT`. On a section
with many photos this doubles the request count and adds latency. Acceptable: the
ticket specified correctness over efficiency, and the failure mode is slowness,
not incorrectness. Worth batching only if publish becomes slow in practice.

**3. Naive datetime comparison at week boundaries**
`src/immich_journal/api/mobile.py` — `taken.replace(tzinfo=None)`

Timezone info is stripped before the week-range comparison. Since the code prefers
`localDateTime` this is usually right, but an asset whose only usable stamp is
`fileCreatedAt` (UTC) captured near midnight on a week boundary could be
misclassified. Low impact: the failure is a spurious rejection, not a spurious
write, so it fails in the safe direction.

## What was verified, not assumed

- **All 28 declared route handlers are covered.** Two `dependencies=[...]` sites,
  one on `create_app()` and one on the mobile `APIRouter`; no route is decorated
  individually and none escapes.
- **Fail-closed startup is actually wired.** `require_api_key_configured` is
  called at `server.py:190`, not merely defined.
- **Constant-time comparison.** `hmac.compare_digest`, not `==`.
- **The publish guard fails closed.** A lookup exception, a 404, and an
  unparseable capture date each return a rejection reason; none falls through to
  the `PUT`.
- **The rejection tests have teeth.** Neutering the rejection branch makes exactly
  the two relevant tests fail. They assert on the absence of the outbound write,
  not just the response body.

## Mutation evidence

Every guard this PR adds was broken deliberately to confirm the suite catches it.
Each mutation asserted its pattern matched before applying, and `__pycache__` was
cleared between runs — a same-length edit does not invalidate a `.pyc`, and a
stale one silently re-runs the mutant.

| Guard broken | Suite result |
|---|---|
| Secret comparison always succeeds | **6 failed** |
| App-wide dependency removed from `create_app()` | **8 failed** |
| `require_api_key_configured` returns without raising | **1 failed** |
| Publish rejection branch neutered | **2 failed** |

Baseline and post-restore both 111 passed, working tree clean.

Worth recording: my first attempt at two of these produced `3 errors` rather than
failures. Those were syntactically invalid mutants — pytest never ran the suite,
and a classifier looking only for "failed" would have read the result as a
decorative test. A mutation that does not compile proves nothing; it has to be
valid code that is wrong.

## Validation Results

| Check | Result |
|---|---|
| Type check | Skipped — no typecheck target configured |
| Lint | Skipped — no lint target configured |
| Tests | **Pass** — 111 passed, 0 failed (`pytest -o pythonpath=src`) |
| Build | N/A |

Note: a plain `pytest` inside a worktree yields 13 spurious failures, because the
project is installed editable against the main checkout and imports resolve there.

## Files Reviewed

| File | Change |
|---|---|
| `src/immich_journal/auth.py` | Added |
| `src/immich_journal/server.py` | Modified |
| `src/immich_journal/api/mobile.py` | Modified |
| `src/immich_journal/config.py` | Modified |
| `.env.example` | Modified |
| `tests/test_auth.py` | Added |
| `tests/test_mobile_api.py` | Modified |
| `tests/test_server.py` | Modified |

## Reviewer independence

This review is **not** an independent one. The same session that orchestrated
these changes produced it, which is exactly the arrangement CLAUDE.md prohibits
for an approval pass. It is posted as REQUEST CHANGES, which a self-review can
legitimately do — finding fault in your own work carries no conflict of interest.

Had it come back clean, an approval from this session would not have been worth
anything, and should have been sought elsewhere.
