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

import json
import os
import sys

from manifest import (
    VALID_ENGINES,
    VALID_SLOTS,
    ManifestError,
    build_queue,
    load,
    repo_root,
)

# state/stages rows (PRP-004 s4.3): a tier-3 ticket advances one stage per
# fire. `preflight` and `build` appear in state/log's stage= column only; a
# row exists once a build has committed, so its stage is one of these.
ROW_STAGES = ("review", "resolve", "review-2", "publish", "done")
STAGES_COLUMNS = ("stage", "branch", "base", "build_report", "engine")
# A branch is reviewed by the engine that did not write it.
OTHER_ENGINE = {"claude": "codex", "codex": "claude"}
# The tier a review stage runs on (PRP-004 s4.4). Not a task's tier: no task
# names it, the queue builder puts a ticket there itself.
REVIEW_TIER = "tier3-review"
# Publish runs no engine and gets no tier, but git push and gh need the egress
# proxy: s4.4 pins it, whatever network the build tier was allowed.
PUBLISH_NETWORK = "proxied"


def stages_path(root: str) -> str:
    return os.path.join(root, "state", "stages")


def load_stages(root: str) -> dict:
    """Where every in-flight tier-3 ticket stands, keyed `<repo>/<ticket>`.

    lib/state.sh kv_set_row format: the key, then STAGES_COLUMNS, tab-separated.
    Hand-written and machine-written tickets alike are looked up here; neither
    ticket source is touched to record progress. A row the builder cannot read
    stops the queue -- the alternative is guessing which stage to run -- and so
    does a duplicate key: kv_row takes the first match, and the two readers
    must never disagree about which row is the ticket's.
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
            if key in rows:
                raise ManifestError(f"state/stages: {key}: duplicate row")
            rows[key] = checked_row(key, dict(zip(STAGES_COLUMNS, fields[1:])))
    return rows


def checked_row(key: str, row: dict) -> dict:
    """Every column filled: a stage with no branch or base has nothing to run on."""
    if row["stage"] not in ROW_STAGES:
        raise ManifestError(f"state/stages: {key}: unknown stage {row['stage']!r}")
    if row["engine"] not in VALID_ENGINES:
        raise ManifestError(f"state/stages: {key}: engine must be claude or codex")
    for column in ("branch", "base", "build_report"):
        if not row[column]:
            raise ManifestError(f"state/stages: {key}: {column} is empty")
    return row


def consumed_keys(entries: list) -> set:
    """The `<repo>/<ticket>` keys whose rows became stage entries, across the queues given."""
    return {f"{entry['repo']}/{entry['ticket_id']}" for entry in entries if entry["stage_entry"]}


def unconsumed_rows(stages: dict, consumed: set) -> tuple:
    """Rows nothing will run, in key order.

    A ticket gone from both sources, present but `specced: false`, or in a repo
    with no ticket-consuming task: each leaves a row that yields no stage
    entry in any slot, and the branch it names waits for nobody. A `done` row
    is finished, not stranded, and is not reported.
    """
    return tuple(sorted(key for key, row in stages.items()
                        if row["stage"] != "done" and key not in consumed))


def warn_unconsumed_rows(stages: dict, consumed: set) -> None:
    """A stranded row is a warning, not a wedge: the queue still builds.

    stderr, because stdout is JSON lines. Called from validate and nowhere
    else: the runner validates once a fire but builds the queue three times,
    and `meute promote` reads queue's output with stderr merged in.
    `meute doctor` shows the same rows to the owner through list-stages.
    """
    stranded = unconsumed_rows(stages, consumed)
    if stranded:
        sys.stderr.write(
            f"meute/manifest: state/stages: {len(stranded)} row(s) that no task consumes: "
            f"{', '.join(stranded)}\n")


def expand_tickets(entry: dict, project: dict, stages: dict, tiers: dict,
                   want_specced: bool = True) -> list:
    """One queue entry per ticket on the right side of the human gate.

    want_specced=True  -- tier 3: only tickets a human marked specced: true.
                          A ticket with a live state/stages row yields its next
                          stage entry instead of a build.
    want_specced=False -- the reproduce stage: candidates awaiting that decision.
                          Stages are tier 3's pipeline; candidates never have one.

    The build engine is settled here and not in build_entry's setting(): that
    runs with no ticket in scope, and the ticket outranks task, repo and defaults.

    A row is keyed by ticket, not by task: two requires_specced_ticket tasks on
    one repo each emit a stage entry for the same row. Phase 4 must dedupe by
    row when it runs one, not by task.
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
            item = stage_entry(item, row, tiers)
        out.append(item)
    return out


def stage_entry(item: dict, row: dict, tiers: dict) -> dict:
    """The ticket's next stage as a queue item (PRP-004 s4.3).

    The engine is written into the entry because eligible() and main gate
    quota on it: a review is charged to the reviewing engine's pool, not the
    builder's. Publish runs no engine at all. The cap exemption is the
    `stage_entry` flag itself -- run.sh reads it in eligible().

    The profile is re-resolved from the stage's tier, because run.sh
    dispatches on `tools`, `permission_mode`, `writes_code`, `allowed_tools`
    and `network`, not on the tier's name: a review that kept the build
    tier's profile could edit the branch it is judging and run the repo's
    build allowlist. That allowlist is the builder's; a review gets the
    review tier's alone.
    """
    stage = row["stage"]
    if stage in ("review", "review-2"):
        if REVIEW_TIER not in tiers:
            raise ManifestError(
                f"tiers.{REVIEW_TIER}: required -- state/stages has a review row "
                f"for {item['repo']}/{item['ticket_id']}")
        tier = tiers[REVIEW_TIER]
        profile = {**tier_profile(tier), "allowed_tools": tier.get("allowed_tools", "")}
        engine, tier_name = OTHER_ENGINE[row["engine"]], REVIEW_TIER
    elif stage == "resolve":
        # The builder returns to its own branch under its own tier; the
        # task/repo allowlist it built with stays, so it can still verify.
        profile = tier_profile(tiers[item["tier"]])
        engine, tier_name = row["engine"], item["tier"]
    else:
        profile = {"tools": "", "permission_mode": "", "writes_code": False,
                   "allowed_tools": "", "network": PUBLISH_NETWORK}
        engine, tier_name = "", item["tier"]
    return {**item,
            **profile,
            "stage_entry": True,
            "stage": stage,
            "branch": row["branch"],
            "base": row["base"],
            "build_report": row["build_report"],
            "engine": engine,
            "tier": tier_name,
            "key": f"{item['key']}/{stage}"}


def tier_profile(tier: dict) -> dict:
    """What run.sh dispatches on, taken from one tier block and nothing else."""
    return {"tools": tier["tools"],
            "permission_mode": tier["permission_mode"],
            "writes_code": bool(tier["writes_code"]),
            "network": tier.get("network", "")}


def cmd_list_stages(args: list) -> int:
    """Every state/stages row as JSON, flagged `unconsumed` when no slot's queue runs it.

    `meute doctor` reads this to show the owner rows the runner can only
    mutter about on stderr.
    """
    manifest = args[0]
    root = repo_root(manifest)
    data = load(manifest)
    stages = load_stages(root)
    consumed = consumed_keys([entry for slot in VALID_SLOTS
                              for entry in build_queue(data, slot, root)])
    stranded = unconsumed_rows(stages, consumed)
    for key, row in stages.items():
        print(json.dumps({"key": key, **row, "unconsumed": key in stranded}))
    return 0
