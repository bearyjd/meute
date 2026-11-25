---
repo: sample
task: market-comparison
status: ok
started: 2026-01-05T00:00:00Z
---
# Market comparison

## Summary

- Two gaps against comparable tools: one (MEDIUM), one (LOW).
- 1 finding (MEDIUM), 1 finding (LOW).

One gap (MEDIUM) matters for the next release.

## Findings

### [MEDIUM] No import from the common export format
- **Location:** `app/importers/__init__.py:1`
- **Why now:** Three comparable tools ship it; the effort is low.

### [LOW] No dark theme
- **Location:** `ui/theme.py:3`
- **Why now:** Cheap to add, low priority.

## Coverage

- Compared against three public tools by reading their documentation.
