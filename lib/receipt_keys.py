#!/usr/bin/env python3
"""The one grammar, hash shape and revision every durable-receipt writer shares.

lib/decisions.py (finding decisions) imports this; later receipt writers must
too, so an operator, a request key and a scope hash mean the same thing
everywhere:

    OPERATOR_RE / KEY_RE / REPORT_ID_RE   -- enforced with re.fullmatch, never
                                             re.match + `$` (a trailing newline
                                             passes `$`)
    scope_hash(operator, operation, key)  -- the receipt's file name
    payload_hash(obj)                     -- canonical-JSON sha256
    read_rows(path) / revision(rows, key) -- a finding's revision, from bytes
    fs_selftest(state_dir)                -- the storage guarantees receipts rely on
    writes_enabled(state_dir)             -- the default-off owner flag
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import uuid

OPERATOR_RE = re.compile(r"[A-Za-z0-9._@:-]{1,64}")
KEY_RE = re.compile(r"[A-Za-z0-9._:-]{8,128}")
_PART_RE = re.compile(r"[A-Za-z0-9._-]+")
REPORT_ID_RE = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
OPERATIONS = ("finding.resolve", "finding.dismiss", "run.select", "run.start", "run.stop",
              "run.reconcile")

ABSENT = "r1:absent"


def valid_report_id(rid: str) -> bool:
    """`repo/name`: two parts, neither `.` nor containing `..` (no traversal)."""
    if not REPORT_ID_RE.fullmatch(rid):
        return False
    return all(part != "." and ".." not in part for part in rid.split("/"))


def scope_hash(operator: str, operation: str, key: str) -> str:
    return hashlib.sha256(f"{operator}\0{operation}\0{key}".encode("utf-8")).hexdigest()


def payload_hash(obj) -> str:
    canon = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canon.encode("ascii")).hexdigest()


# ------------------------------------------------------------- revision ---

def split_lines(data: bytes) -> list[bytes]:
    """Lines as awk sees them: LF only, a missing final newline tolerated."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    return lines


def read_rows(path: str) -> dict[bytes, tuple[bytes, bytes, bytes]]:
    """state/reports as {key: (state, when, note)} over RAW bytes.

    Split on LF only, nothing decoded, first row for a key wins (as kv_row and
    inbox._state_rows), a key-only row is ("", "", ""). A missing file is {}.
    """
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return {}
    rows: dict[bytes, tuple[bytes, bytes, bytes]] = {}
    for line in split_lines(data):
        parts = line.split(b"\t")
        rows.setdefault(parts[0], (parts[1] if len(parts) > 1 else b"",
                                   parts[2] if len(parts) > 2 else b"",
                                   parts[3] if len(parts) > 3 else b""))
    return rows


def revision(rows: dict, key: str) -> str:
    """`r1:` + sha256(state TAB when TAB note) of the key's row, or `r1:absent`.

    Absence is decided by row presence, never by a defaulted ("new", "", "").
    """
    row = rows.get(key.encode("utf-8"))
    if row is None:
        return ABSENT
    return "r1:" + hashlib.sha256(b"\t".join(row)).hexdigest()


# ----------------------------------------------------------- filesystem ---

def _fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fs_selftest(state_dir: str) -> dict:
    """Does this filesystem give exclusive create, no rename-over-directory and
    a working directory fsync? Leaves nothing behind."""
    probe = os.path.join(state_dir, f".selftest-{uuid.uuid4().hex}")
    results: dict[str, bool] = {}
    try:
        os.mkdir(probe, 0o700)
        a, b = os.path.join(probe, "a"), os.path.join(probe, "b")
        for path in (a, b):
            with open(path, "wb") as fh:
                fh.write(b"x")
        try:
            os.link(a, b)
            results["link_exclusive"] = False
        except FileExistsError:
            results["link_exclusive"] = True
        full = os.path.join(probe, "full")
        os.mkdir(full)
        with open(os.path.join(full, "f"), "wb") as fh:
            fh.write(b"x")
        try:
            os.rename(a, full)
            results["rename_onto_nonempty_dir_fails"] = False
        except OSError:
            results["rename_onto_nonempty_dir_fails"] = True
        try:
            _fsync_dir(probe)
            results["dir_fsync"] = True
        except OSError:
            results["dir_fsync"] = False
    except OSError:
        results.setdefault("error", True)
    finally:
        for root, dirs, files in os.walk(probe, topdown=False):
            for name in files:
                os.unlink(os.path.join(root, name))
            for name in dirs:
                os.rmdir(os.path.join(root, name))
        if os.path.isdir(probe):
            os.rmdir(probe)
    results["ok"] = all(results.get(k) is True for k in
                        ("link_exclusive", "rename_onto_nonempty_dir_fails", "dir_fsync"))
    return results


def writes_enabled(state_dir: str) -> bool:
    """The owner's default-off flag for web/fleet receipt writers.

    `state/fleet-writes.enabled` must parse as a JSON object with
    `m2_ack: true` and a passing `selftest` record (`{"ok": true}`); a bare
    touch, malformed JSON or anything else leaves writes disabled. The record
    shape is provisional until the command that writes it lands.
    """
    try:
        with open(os.path.join(state_dir, "fleet-writes.enabled"), "rb") as fh:
            flag = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(flag, dict) or flag.get("m2_ack") is not True:
        return False
    selftest = flag.get("selftest")
    return isinstance(selftest, dict) and selftest.get("ok") is True
