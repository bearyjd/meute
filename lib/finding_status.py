#!/usr/bin/env python3
"""Finding status derived from more than one report (P1.7, R5).

A decision in state/reports is keyed by `report#n`, so a repeat audit that
raises the same defect again starts as `new`. This module links occurrences by
fingerprint (lib/report.py) and lets a later occurrence inherit an earlier
decision. It only reads: state/reports stays the one authoritative record, so
deleting this logic restores the old behaviour exactly.
"""

from __future__ import annotations

# D7: only a dismissal carries over. A promoted or resolved finding raised
# again may mean the fix did not land, and that is worth seeing.
INHERITED_STATES = ("dismissed",)


def inherited(occurrences: list[tuple[str, str, tuple]],
              own: dict[str, tuple]) -> dict[str, str]:
    """{key: state} for each occurrence with no decision of its own whose
    fingerprint's latest decision in a strictly earlier report is inherited.
    The latest, not the first: a dismissal later reversed must not hide the
    finding again.

    occurrences -- (key `report#n`, fingerprint, order) per finding, where
                   order sorts reports oldest first
    own         -- state/reports rows as {key: (state, ...)}
    """
    decided: dict[str, list[tuple]] = {}
    for key, fp, order in occurrences:
        if key in own:
            decided.setdefault(fp, []).append((order, own[key][0]))
    out: dict[str, str] = {}
    for key, fp, order in occurrences:
        earlier = [d for d in decided.get(fp, ()) if d[0] < order]
        if key in own or not earlier:
            continue
        state = max(earlier, key=lambda d: d[0])[1]
        if state in INHERITED_STATES:
            out[key] = state
    return out
