---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

One finding and two things checked and dismissed.

## Findings

### [LOW] Thumbnailer runs on attacker-supplied containers
- **Location:** `app/thumbs.py:30`
- **Confidence:** suspected

### Not a finding: replay of the upload path
The replay needs the signing key, which never leaves the host.

### No path from untrusted input to the template loader
Every caller passes a constant.

### not exploitable today, but worth knowing
The parser is pinned to a patched release.

## Coverage

- Read `app/thumbs.py` and the upload path.
