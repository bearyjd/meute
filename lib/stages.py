"""The tier-3 stage machine, queue side: state/stages -> stage entries.

PRP-004 s4.3. A tier-3 ticket advances one stage per timer fire -- build,
review, resolve, review-2, publish -- and where it stands lives in
state/stages, one row per <repo>/<ticket> in lib/state.sh's kv_set_row
format. This module reads those rows and, expanding a repo's tickets for
the queue, turns a ticket mid-pipeline into its next stage entry;
lib/manifest.py's queue builder calls it by name.

Separate from manifest.py because it is a feature, not schema: the stage
vocabulary, the row format and the engine derivation change with the
pipeline (Phase 4 runs a stage, Phase 5 publishes one) and the manifest's
validation rules do not. Imported by manifest.py after every name below is
defined there, so `from manifest import` here resolves; import manifest
first, never this module on its own.
"""

from __future__ import annotations

import os

from manifest import ManifestError, VALID_ENGINES

# state/stages rows (PRP-004 s4.3): a tier-3 ticket advances one stage per
# fire. `preflight` and `build` appear in state/log's stage= column only; a
# row exists once a build has committed, so its stage is one of these.
ROW_STAGES = ("review", "resolve", "review-2", "publish", "done")
STAGES_COLUMNS = ("stage", "branch", "base", "build_report", "engine")
# A branch is reviewed by the engine that did not write it.
OTHER_ENGINE = {"claude": "codex", "codex": "claude"}


def stages_path(root: str) -> str:
    return os.path.join(root, "state", "stages")


def load_stages(root: str) -> dict:
    """Where every in-flight tier-3 ticket stands, keyed `<repo>/<ticket>`.

    lib/state.sh kv_set_row format: the key, then STAGES_COLUMNS, tab-separated.
    Hand-written and machine-written tickets alike are looked up here; neither
    ticket source is touched to record progress. A row the builder cannot read
    stops the queue -- the alternative is guessing which stage to run.
    """
    path = stages_path(root)
    if not os.path.isfile(path):
        return {}
    rows = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            key = fields[0]
            if len(fields) != 1 + len(STAGES_COLUMNS):
                raise ManifestError(
                    f"state/stages: {key}: expected {', '.join(STAGES_COLUMNS)}")
            row = dict(zip(STAGES_COLUMNS, fields[1:]))
            if row["stage"] not in ROW_STAGES:
                raise ManifestError(f"state/stages: {key}: unknown stage {row['stage']!r}")
            if row["engine"] not in VALID_ENGINES:
                raise ManifestError(f"state/stages: {key}: engine must be claude or codex")
            rows[key] = row
    return rows


def expand_tickets(entry: dict, project: dict, stages: dict, want_specced: bool = True) -> list:
    """One queue entry per ticket on the right side of the human gate.

    want_specced=True  -- tier 3: only tickets a human marked specced: true.
                          A ticket with a live state/stages row yields its next
                          stage entry instead of a build.
    want_specced=False -- the reproduce stage: candidates awaiting that decision.
                          Stages are tier 3's pipeline; candidates never have one.

    The build engine is settled here and not in build_entry's setting(): that
    runs with no ticket in scope, and the ticket outranks task, repo and defaults.
    """
    out = []
    for ticket in project.get("tickets") or []:
        if bool(ticket.get("specced")) is not want_specced:
            continue
        ticket_id = str(ticket["id"])
        item = {**entry,
                "ticket_id": ticket_id,
                "ticket_title": ticket.get("title", ""),
                "ticket_notes": ticket.get("notes", ""),
                "key": f"{entry['repo']}/{entry['task']}/{ticket_id}",
                "engine": ticket.get("engine") or entry["engine"]}
        row = stages.get(f"{entry['repo']}/{ticket_id}") if want_specced else None
        if row and row["stage"] != "done":
            item = stage_entry(item, row)
        out.append(item)
    return out


def stage_entry(item: dict, row: dict) -> dict:
    """The ticket's next stage as a queue item (PRP-004 s4.3).

    The engine is written into the entry because eligible() and main gate
    quota on it: a review is charged to the reviewing engine's pool, not the
    builder's. Publish runs no engine at all. The cap exemption is the
    `stage_entry` flag itself -- run.sh reads it in eligible().
    """
    stage = row["stage"]
    if stage in ("review", "review-2"):
        engine, tier = OTHER_ENGINE[row["engine"]], "tier3-review"
    elif stage == "resolve":
        engine, tier = row["engine"], "tier3"
    else:
        engine, tier = "", item["tier"]
    return {**item,
            "stage_entry": True,
            "stage": stage,
            "branch": row["branch"],
            "base": row["base"],
            "build_report": row["build_report"],
            "engine": engine,
            "tier": tier,
            "key": f"{item['key']}/{stage}"}
