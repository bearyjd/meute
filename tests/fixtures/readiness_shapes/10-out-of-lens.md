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

### [MEDIUM] Archive extraction follows symlinks
- **Location:** `app/unpack.py:64`
- **Confidence:** suspected

## Out-of-lens sightings

- `lib/low_level.py:10` swallows every error; the churn there is high, but it is not a security issue.
- `docs/setup.md` promises "low latency" without a measurement.
- Docs: the changelog calls the last release a critical fix, yet names no issue.
- `app/reporting.py` webhook URL: only the scheme is checked; the impact is low because the caller is the operator.
