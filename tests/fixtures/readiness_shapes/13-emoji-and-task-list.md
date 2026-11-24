---
repo: sample
task: security-review
lens: security
status: ok
started: 2026-01-06T00:00:00Z
---
# Security review

## Summary

- 🔴 **HIGH, confirmed:** the login query is built by string concatenation.
- ⚠️ **HIGH** (1 finding): see below.
- [ ] write the high-level overview
- [x] checked the low-level helpers

## Findings

### [HIGH] SQL injection in login
- **Location:** `src/login.py:9`
- **Confidence:** confirmed

## Coverage

- 🟢 Read every entry point.
