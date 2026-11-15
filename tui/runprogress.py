"""Read-only views of the runner's state files, for tui/runctl.py.

Nothing here writes or runs anything. The formats are bin/run.sh's and
lib/fleet.sh's, not this module's:

  state/hold          `hold<TAB><epoch><TAB><reason>`; in force only while the
                      epoch is in the future (an expired hold lifts itself)
  state/log           one line per run.sh call: ISO timestamp (the run's
                      start), then key=value fields (status=, repo=, task=, ...)
  state/plan-queue.json  {version, scan, allow_web, entries: [{name, path, task, spec}]}
  state/plan-queue.completed-<ts>.json  the same file, archived by run.sh once
                      every staged item was attempted
  state/plan-complete key/value: `plan/<name>/<task>` -> when it was attempted
"""

from __future__ import annotations

import glob
import json
import os
import time
from datetime import datetime

RECENT = 10
COUNTED = ("ok", "error")


# ------------------------------------------------------------------ hold ---

def hold_reason(state_dir: str, now: float) -> str | None:
    """Why the fleet is paused, or None when no hold is in force."""
    try:
        with open(os.path.join(state_dir, "hold"), encoding="utf-8") as f:
            rows = f.read().splitlines()
    except FileNotFoundError:
        return None
    for row in rows:
        fields = row.split("\t")
        if fields[0] != "hold":
            continue
        until = fields[1] if len(fields) > 1 else ""
        if not until.isdigit() or int(until) <= now:
            return None
        when = time.strftime("%a %Y-%m-%d %H:%M", time.localtime(int(until)))
        why = fields[2].strip() if len(fields) > 2 else ""
        return f"the fleet is paused until {when}" + (f" ({why})" if why else "")
    return None


# ------------------------------------------------------------------- log ---

def parse_line(line: str) -> dict | None:
    fields = line.rstrip("\r\n").split("\t")
    if not fields[0]:
        return None
    rec = {"time": fields[0]}
    for field in fields[1:]:
        key, sep, value = field.partition("=")
        if sep and key not in rec:
            rec[key] = value
    return rec


def line_epoch(rec: dict) -> float | None:
    try:
        return datetime.fromisoformat(rec["time"]).timestamp()
    except ValueError:
        return None


def _at_or_after(rec: dict, since: float) -> bool:
    epoch = line_epoch(rec)
    return epoch is not None and epoch >= since


def log_size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except FileNotFoundError:
        return 0


def read_log(path: str, offset: int = 0) -> list[dict]:
    """Parsed lines from byte `offset` on (from 0 if the file shrank)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(offset if offset <= f.tell() else 0)
            data = f.read()
    except FileNotFoundError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    return [rec for rec in map(parse_line, lines) if rec]


def classify(records: list[dict], returncode: int, slot: str, since: float) -> dict:
    """The outcome of one run.sh call, from the log lines appended during it.

    Only a line for this call's slot that started at or after the call counts:
    a timer firing the other slot (or a late line from an older run) writes
    to the same log and is not this call's outcome.
    """
    own = [rec for rec in records
           if rec.get("slot") == slot and _at_or_after(rec, since)]
    if not own:
        return {"status": "error", "repo": None, "task": None,
                "reason": f"run.sh exited {returncode} without a log line"}
    last = own[-1]
    status = last.get("status")
    return {"status": status if status in ("ok", "skipped") else "error",
            "repo": last.get("repo"), "task": last.get("task"),
            "reason": last.get("reason") or last.get("detail")}


# ----------------------------------------------------------------- queue ---

def _entries(path: str) -> list[tuple[str, str]]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    raw = data.get("entries") if isinstance(data, dict) else None
    return [(e["name"], e["task"]) for e in raw or []
            if isinstance(e, dict) and isinstance(e.get("name"), str)
            and isinstance(e.get("task"), str)]


def load_queue(state_dir: str) -> tuple[list[tuple[str, str]], bool, float | None]:
    """(entries as (name, task), archived?, file mtime) of the current plan.

    The live queue if there is one, else the newest archive run.sh left.
    """
    live = os.path.join(state_dir, "plan-queue.json")
    if os.path.isfile(live):
        return _entries(live), False, os.path.getmtime(live)
    pattern = os.path.join(glob.escape(state_dir), "plan-queue.completed-*.json*")
    archives = sorted(glob.glob(pattern), key=os.path.getmtime)
    if archives:
        return _entries(archives[-1]), True, os.path.getmtime(archives[-1])
    return [], False, None


def completed_keys(state_dir: str) -> set[str]:
    try:
        with open(os.path.join(state_dir, "plan-complete"), encoding="utf-8") as f:
            return {row.split("\t", 1)[0] for row in f.read().splitlines() if row}
    except FileNotFoundError:
        return set()


def progress(entries: list[tuple[str, str]], records: list[dict],
             since: float | None) -> tuple[int, list[dict]]:
    """(distinct staged items with an ok/error line, recent lines) since `since`."""
    staged, seen, recent = set(entries), set(), []
    for rec in records:
        if since is not None:
            epoch = line_epoch(rec)
            if epoch is None or epoch < since:
                continue
        recent.append({k: rec.get(k) for k in ("time", "status", "repo", "task")})
        key = (rec.get("repo"), rec.get("task"))
        if key in staged and rec.get("status") in COUNTED:
            seen.add(key)
    return len(seen), recent[-RECENT:]
