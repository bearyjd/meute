---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

Two findings.

## Findings

### [HIGH] Session token accepted after logout
- **Location:** `app/session.py:57`
- **Confidence:** confirmed

### [LOW] Lookup pattern backtracks on long input
- **Location:** `app/lookup.py:19`
- **Confidence:** suspected

## Verification notes

- **HIGH finding:** log in, log out, then replay the old cookie against `/me`.
- **HIGH finding.**
- **LOW finding, regex half:** open `app/lookup.py:19` and time the pattern on a long run of dashes.
- **LOW finding, runtime half:** this needs the app or a mocked file system.
- To reproduce the LOW finding without the app, run the pattern in a REPL.
