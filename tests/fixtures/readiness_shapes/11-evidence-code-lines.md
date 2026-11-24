---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

One finding.

## Findings

### [LOW] Log level is taken from an unvalidated header
- **Location:** `app/logging.py:12`
- **Confidence:** suspected. Unverified hop: whether the proxy strips the header; if it does, the reach is low.
- **Evidence:**

  app/logging.py:12          level = header or "low"
  app/logging.py:13          if level == "high": verbose()
    // low: falls through to the default
  - `set_level` accepts `high`, `low` and anything else without complaint
- **Credential headers** (`app/http.py:65`): the token is logged at the high level only.
- **Fix:** Accept a fixed set of names.
