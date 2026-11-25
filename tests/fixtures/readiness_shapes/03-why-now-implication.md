---
repo: sample
task: suggest-features
status: ok
started: 2026-01-05T00:00:00Z
---
# Feature suggestions

## Summary

One suggestion, grounded in code that already exists.

## Findings

### [MEDIUM] Export the weekly digest as a file
- **Location:** `app/digest.py:88`
- **Why now:** The renderer and the single injection point already exist, so the effort is low and the risk is low.
- **Implication:** Leave the scheduler alone: a medium-sized change there would outweigh the feature.
- **Sketch:** Add a writer beside the mail sender.

## Coverage

- Read the digest module and its tests.
