---
repo: sample
task: architecture-review
lens: architecture
status: ok
started: 2026-01-05T00:00:00Z
---
# Architecture review

## Summary

- **HIGH, confirmed:** the cooldown protocol is driven from two places that can disagree.
- **MEDIUM, suspected:** adding a field to the sync payload needs edits in four modules.
- **LOW, suspected:** there are four package-level import cycles.

## Findings

### [HIGH] Cooldown state has two writers
- **Location:** `service/cooldown.py:22`
- **Confidence:** confirmed

### [MEDIUM] Sync payload shape is repeated in four modules
- **Location:** `sync/payload.py:5`
- **Confidence:** suspected

### [LOW] Import cycles between packages
- **Location:** `core/__init__.py:1`
- **Confidence:** suspected

## Coverage

- Read every package entry point.
