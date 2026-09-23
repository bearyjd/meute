# PR Review: #25 — docs: Atelier's first commit exists, and the pin met a real image

**Reviewed**: 2026-09-23
**Author**: bearyjd (drafted by the coordinating assistant)
**Branch**: `docs/atelier-pin-verified` → `main`
**Reviewer**: `code-reviewer`, independent lane
**Decision**: APPROVE WITH COMMENTS → finding fixed in `1d8afab`

## Summary
Docs only, one file. Every digest and the commit SHA were checked against
the host and Atelier's repo rather than taken on the document's word, and
all of them hold. The one finding is that the PR updated two places the
fact appears and missed the third.

## Findings

### CRITICAL / HIGH
None.

### MEDIUM
1. **The Status header still named as Phase 2's blocker the two things this
   PR documents as delivered** — "blocked on Atelier producing `agent-base`
   and `tests/smoke.sh` (zero commits there at filing)", in the present
   tense, while `tests/smoke.sh` exists, `containers/agent-base/` exists and
   `agent-base:g691e067` is on the host. §5's row and §8's struck row were
   updated; the header was not. **Fixed** — it now names the real remaining
   blocker, the owner's `just auth`, and says what the old wording was true
   of. A status line naming a blocker that has cleared is how a document
   starts lying about the thing it exists to track.

### LOW
None.

## Verification performed by the reviewer
- Atelier's first commit `691e067` — `git log --reverse` in `../atelier-harness`
- `agent-base:g691e067` = `sha256:9ac5558d3ffd…` ✓
- `agent-example:g691e067` = `sha256:10878437f596…` ✓
- §11's migration claim against the live manifest: tier1/tier2/tier3
  `network: proxied`, tier2-web `runtime: host` with no `network` ✓
- The struck §8 row cites "(§11)" and §11 carries the entry; nothing else
  referenced that row — no dangling reference.

## Validation Results

| Check | Result |
|---|---|
| Type check / Lint / Tests / Build | N/A — documentation only, no code touched |
| Factual verification | Pass — every digest and SHA confirmed against the host |

## Files Reviewed
- `docs/prp/PRP-004-container-review-publish.md` — Modified
