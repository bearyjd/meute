---
repo: sample
task: audit-security
lens: security
status: ok
started: 2026-01-05T00:00:00Z
---
# Security audit

## Summary

No findings.

## Findings

None.

## Verification notes

- To refute the "no findings" conclusion, run the dependency audit and look for a high or critical advisory.

## Coverage

- **Read in full (high-risk paths first):** `app/auth/`, `app/upload.py`.
- **Skimmed:** `app/ui/`, judged low value for this lens.
- **Not read:** `vendor/`, medium-sized and unchanged since the last audit.
- `app/low_level.py` and `app/high/water.py` were read in full.
