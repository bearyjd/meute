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

### [HIGH] Webhook URL is fetched without a host allowlist
- **Location:** `app/hooks.py:30`
- **Confidence:** confirmed

### [LOW] Error page names the framework version
- **Location:** `app/errors.py:8`
- **Confidence:** confirmed

## Verification notes

- **Finding 1 (HIGH):** point the webhook at a local listener and watch the request arrive.
- **Webhook fetch (HIGH)** was also checked against the redirect path.
- **Version banner (LOW):**
  request a missing page and read the footer.
- **Cross-check (LOW):** the banner is absent from the JSON error body.
