#!/usr/bin/env python3
"""Finding status derived from more than one report (P1.7, R5).

A decision in state/reports is keyed by `report#n`, so a repeat audit that
raises the same defect again starts as `new`. This module links occurrences by
fingerprint (lib/report.py) and lets a later occurrence inherit an earlier
decision. It never writes state/reports, the one authoritative record of
decisions: verify verdicts and claims live in state/finding-status alone, so
deleting that file restores the old behaviour.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile

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


# ------------------------------------------------- P1.7 (b): verify, claim ---
#
# state/finding-status is the only file written here: one row per finding,
# `report#n  verdict  head  checked_at  pr`. Deleting it undoes verify and
# claim; state/reports is never touched.

VERDICTS = ("gone", "changed", "current", "unknown")
# D7: hidden from `findings --new`; `--all` still lists them.
HIDDEN_VERDICTS = ("gone", "superseded")
_PR_NOTE = re.compile(r"\bpr: (\S+)")


def status_path(root: str) -> str:
    return os.path.join(root, "state", "finding-status")


def read_status(root: str) -> dict[str, list[str]]:
    """{key: [verdict, head, checked_at, pr]}; missing fields are ""."""
    rows: dict[str, list[str]] = {}
    try:
        with open(status_path(root), encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                rows.setdefault(parts[0], (parts[1:] + [""] * 4)[:4])
    except FileNotFoundError:
        pass
    return rows


def write_status(root: str, rows: dict[str, list[str]]) -> None:
    """Atomic: a temp file beside it, then a rename, as lib/state.sh does."""
    path = status_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".kv.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for key in sorted(rows):
                fh.write("\t".join([key, *rows[key]]) + "\n")
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def claim(root: str, key: str, pr: str) -> None:
    rows = read_status(root)
    row = rows.get(key, ["", "", "", ""])
    rows[key] = [row[0], row[1], row[2], pr]
    write_status(root, rows)


def pr_of(status_row: list[str] | None, note: str) -> str:
    """The PR covering a finding: a claim, else a `resolve --pr` note."""
    if status_row and status_row[3]:
        return status_row[3]
    m = _PR_NOTE.search(note or "")
    return m.group(1) if m else ""


def _git(path: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", path, "-c", "core.quotePath=false", *args],
                          capture_output=True, text=True, check=False)


def verify_report(repo_path: str, base: str, files: list[str]) -> tuple[str, list[str]]:
    """(head, verdict per file) for one report: its recorded `base: ref@sha`
    against the ref's current commit. One diff per report, never per finding.
    Reads the repository only: no fetch, no checkout."""
    ref, _, sha = str(base).rpartition("@")
    unknown = ("", ["unknown"] * len(files))
    if not sha or not repo_path or not os.path.isdir(repo_path):
        return unknown
    head = _git(repo_path, "rev-parse", "--verify", "-q", f"{ref or 'HEAD'}^{{commit}}")
    if head.returncode != 0:
        return unknown
    head_sha = head.stdout.strip()
    diff = _git(repo_path, "diff", "--name-status", "-M", "-z", sha, head_sha, "--")
    if diff.returncode != 0:
        return unknown
    touched: dict[str, str] = {}
    fields = diff.stdout.split("\0")
    i = 0
    while i < len(fields) - 1:
        status = fields[i]
        # A rename is changed, not gone: the defect may have moved with it.
        if status[:1] in ("R", "C"):
            touched[fields[i + 1]] = "changed"
            i += 3
            continue
        touched[fields[i + 1]] = "gone" if status == "D" else "changed"
        i += 2
    wanted = sorted({f for f in files if f and f not in touched})
    present: set[str] = set()
    if wanted:
        tree = _git(repo_path, "--literal-pathspecs", "ls-tree", "--name-only", "-z", head_sha, "--", *wanted)
        present = set(tree.stdout.split("\0")) if tree.returncode == 0 else set()
    verdicts = []
    for f in files:
        if not f:
            verdicts.append("unknown")
        elif f in touched:
            verdicts.append(touched[f])
        elif any(t.startswith(f.rstrip("/") + "/") for t in touched):
            verdicts.append("changed")
        else:
            # Untouched and present: current. In neither commit: the location
            # names no real file, so nothing can be said.
            verdicts.append("current" if f in present else "unknown")
    return head_sha, verdicts


def superseded(reports: list[dict]) -> set[str]:
    """Keys of findings a newer audit of the same repo, task and lens no longer
    raises. Only a report that ran (status ok) and has a Findings section
    counts as newer: a crashed run must not supersede anything.

    reports -- {"group", "order", "live", "findings": [(key, fp)]} per report
               with a Findings section
    """
    newest: dict[tuple, dict] = {}
    for r in reports:
        cur = newest.get(r["group"])
        if r["live"] and (cur is None or r["order"] > cur["order"]):
            newest[r["group"]] = r
    out: set[str] = set()
    for r in reports:
        latest = newest.get(r["group"])
        if latest is None or r["order"] >= latest["order"]:
            continue
        fps = {fp for _, fp in latest["findings"]}
        out.update(key for key, fp in r["findings"] if fp not in fps)
    return out


def view(own_state: str | None, inherited_state: str, verdict: str, pr: str) -> tuple[str, bool]:
    """(label, hidden from --new). A finding's own decision wins, then an
    inherited one, then a claim, then a verdict that hides (D7)."""
    if own_state is not None and own_state != "new":
        return own_state, True
    if inherited_state:
        return f"{inherited_state} (seen before)", True
    if pr:
        return "claimed", True
    if verdict in HIDDEN_VERDICTS:
        return verdict, True
    if verdict == "changed":
        return "changed", False
    return "new", False


def main(argv: list[str]) -> int:
    root = os.environ.get("MEUTE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if len(argv) == 4 and argv[1] == "claim":
        claim(root, argv[2], argv[3])
        return 0
    sys.stderr.write("usage: finding_status.py claim <report#n> <pr-url>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
