---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

One finding. The upload path trusts a client-supplied name.

## Findings

### [HIGH] Upload handler writes outside the media root
- **Location:** `app/upload.py:41`
- **Confidence:** confirmed
- **Consequence:** Arbitrary file write as the service user, which is a high-privilege account on this host class.
- **Fix:** Resolve the target and refuse anything outside the media root.

## Verification notes

- Read `app/upload.py` in full and traced the name from the request to `open()`.

## Coverage

- Read: `app/`. Not read: `vendor/`.

## Out-of-lens sightings

None.
