---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

One finding, of limited reach.

## Findings

### [LOW] Debug endpoint echoes request headers
- **Location:** `app/debug.py:12`
- **Confidence:** confirmed
- **Why LOW:**
  The route is only mounted when the debug flag is set, and the flag is off in every shipped profile.
- **Why LOW:** it needs local access as well.
- **Fix:** Drop the echo or redact the cookie header.

## Verification notes

- Started the app with the debug flag and requested the route.
