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

### [HIGH] Template renders a user-supplied fragment unescaped
- **Location:** `app/render.py:73`
- **Confidence:** confirmed

### [MEDIUM] Rate limit is keyed on a spoofable header
- **Location:** `app/limits.py:14`
- **Confidence:** suspected

## Verification notes

- **[HIGH] finding:** submit a fragment with a script tag and load the page.
- The [HIGH] finding reproduces with curl alone.

**MEDIUM finding:** send two requests that differ only in the forwarded-for header.
