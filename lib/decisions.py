#!/usr/bin/env python3
"""Durable finding decisions: `resolve`/`dismiss -f N --request-key K`.

    python3 lib/decisions.py decide resolve|dismiss --id=ID --finding=N [--message=T] [--pr=URL]
            [--reason=R] --request-key=K --expected-revision=REV [--operator=OP]
    python3 lib/decisions.py revision <report-id> <n>

bin/meute execs `decide` right after its argument loop, with the raw values, so
this file owns every check. One transaction under the flock the legacy writers
take (state/reports.lock): look the key up, compare the payload, check the
revision, write a pending receipt, write the finding row (bytes, fsynced), mark
the receipt, derive the report row, complete the receipt. A retry with the same
key and payload returns the same receipt and never consults the revision.

stdout is one JSON line. Exit: 0 ok, 2 invalid, 3 stale, 4 key conflict,
5 indeterminate, 75 busy, 70 internal (an uncaught exception is 70, never 1:
the caller must retry with the SAME key).
"""

from __future__ import annotations

import argparse
import fcntl
import itertools
import json
import os
import re
import sys
import tempfile
import time
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import receipt_keys as rk  # noqa: E402

VERSION = 1
DEFAULT_TTL_DAYS = 30
DEFAULT_LOCK_WAIT = 10.0
GC_BUDGET = 50
TMP_MAX_AGE = 3600
OPERATIONS = {"resolve": "finding.resolve", "dismiss": "finding.dismiss"}
STATES = {"resolve": "actioned", "dismiss": "dismissed"}
PHASES = ("pending", "state_written", "complete")
PR_RE = re.compile(r"https?://[^\s\x00-\x1f\x7f]+")


class Reject(Exception):
    """An outcome with its own exit code and JSON body (not a crash)."""

    def __init__(self, code: int, body: dict):
        super().__init__(body.get("error", ""))
        self.code = code
        self.body = body


def invalid(detail: str) -> Reject:
    return Reject(2, {"error": "invalid", "detail": detail})


# --------------------------------------------------------------- context ---

class Ctx:
    """Paths, validated config and the test-only hooks for one request."""

    def __init__(self, root: str, env):
        self.env = env
        self.test = env.get("MEUTE_TEST") == "1"
        self.state = os.path.join(root, "state")
        self.reports = os.path.join(self.state, "reports")
        self.receipts = os.path.join(self.state, "receipts", "decisions")
        self.ttl = self._ttl_days() * 86400
        self.lock_wait = self._lock_wait()
        self.now = self._now()

    def _ttl_days(self) -> int:
        raw = self.env.get("MEUTE_RECEIPT_TTL_DAYS")
        if raw is None:
            return DEFAULT_TTL_DAYS
        if not re.fullmatch(r"[0-9]{1,3}", raw) or not 1 <= int(raw) <= 365:
            raise Reject(2, {"error": "invalid_config", "var": "MEUTE_RECEIPT_TTL_DAYS"})
        return int(raw)

    def _lock_wait(self) -> float:
        raw = self.env.get("MEUTE_DECISIONS_LOCK_WAIT")
        if raw is None:
            return DEFAULT_LOCK_WAIT
        low_ok = lambda v: v > 0 if self.test else v >= 1  # noqa: E731
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", raw) or not (low_ok(float(raw)) and float(raw) <= 60):
            raise Reject(2, {"error": "invalid_config", "var": "MEUTE_DECISIONS_LOCK_WAIT"})
        return float(raw)

    def _now(self) -> int:
        raw = self.env.get("MEUTE_NOW")
        if self.test and raw is not None:
            if not re.fullmatch(r"[0-9]{1,12}", raw):
                raise Reject(2, {"error": "invalid_config", "var": "MEUTE_NOW"})
            return int(raw)
        return int(time.time())

    def iso_now(self) -> str:
        return datetime.fromtimestamp(self.now, tz=timezone.utc).astimezone().isoformat(timespec="seconds")

    def hook(self, step: str) -> None:
        """Test-only crash point: a hard exit, so no cleanup runs (MEUTE_TEST=1 only)."""
        if self.test and self.env.get("MEUTE_DECISIONS_FAIL_AFTER") == step:
            os._exit(70)


# ------------------------------------------------------------ filesystem ---

def fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def ensure_dir(path: str) -> None:
    """mkdir 0700, fsyncing the new directory and its parent on first creation."""
    if os.path.isdir(path):
        return
    os.mkdir(path, 0o700)
    fsync_dir(path)
    fsync_dir(os.path.dirname(path))


def _write_temp(directory: str, prefix: str, data: bytes) -> str:
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=prefix)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
    except BaseException:
        os.unlink(tmp)
        raise
    return tmp


def _unlink_quiet(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _encode(rec: dict) -> bytes:
    return (json.dumps(rec, sort_keys=True) + "\n").encode("utf-8")


def create_receipt(directory: str, path: str, rec: dict) -> None:
    """Exclusive create: temp + fsync + link + fsync dir. EEXIST is an internal error."""
    tmp = _write_temp(directory, ".tmp-", _encode(rec))
    try:
        os.link(tmp, path)
    finally:
        _unlink_quiet(tmp)
    fsync_dir(directory)


def replace_receipt(path: str, rec: dict) -> None:
    directory = os.path.dirname(path)
    tmp = _write_temp(directory, ".tmp-", _encode(rec))
    try:
        os.replace(tmp, path)
    finally:
        _unlink_quiet(tmp)
    fsync_dir(directory)


def write_row(reports_path: str, key: str, state: str, when: str, note: str, hook=None) -> None:
    """kv_set_row at the byte level: drop every row of the key (awk `$1 != key`),
    keep the rest verbatim, terminate the last line, append the new row. Temp in
    the same directory, fsync, swap, fsync the directory."""
    directory = os.path.dirname(reports_path)
    os.makedirs(directory, exist_ok=True)
    try:
        with open(reports_path, "rb") as fh:
            old = fh.read()
    except FileNotFoundError:
        old = b""
    kb = key.encode("utf-8")
    kept = [ln for ln in rk.split_lines(old) if ln.split(b"\t", 1)[0] != kb]
    row = b"\t".join([kb, state.encode("utf-8"), when.encode("utf-8"), note.encode("utf-8")])
    tmp = _write_temp(directory, ".kv.", b"".join(ln + b"\n" for ln in kept) + row + b"\n")
    try:
        if hook:
            hook("6t")
        os.replace(tmp, reports_path)
        tmp = ""
        if hook:
            hook("6w")
        fsync_dir(directory)
    finally:
        if tmp:
            _unlink_quiet(tmp)


@contextmanager
def state_lock(ctx: Ctx):
    """flock(state/reports.lock) exactly as lib/state.sh's _kv_locked opens it."""
    os.makedirs(ctx.state, exist_ok=True)
    fd = os.open(os.path.join(ctx.state, "reports.lock"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + ctx.lock_wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Reject(75, {"error": "busy"})
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


# -------------------------------------------------------------- receipts ---

RECEIPT_STR_FIELDS = ("receipt_id", "operation", "operator", "request_key", "payload_sha256",
                      "report_id", "finding_key", "expected_revision", "before_revision",
                      "after_revision", "disposition", "row_state", "row_when", "row_note")


def _int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _readable(rec) -> bool:
    """Every field a replay, a resume or an expiry reads is present and typed;
    anything less is unreadable (exit 70) and the file is left untouched."""
    return (isinstance(rec, dict) and rec.get("version") == VERSION and rec.get("phase") in PHASES
            and rec.get("operation") in OPERATIONS.values()
            and _int(rec.get("expires_at")) and _int(rec.get("created_at"))
            and _int(rec.get("n")) and rec["n"] >= 1
            and all(isinstance(rec.get(k), str) for k in RECEIPT_STR_FIELDS))


def load_receipt(path: str):
    """None if absent. An unreadable file is exit 70 and is never touched."""
    try:
        with open(path, "rb") as fh:
            rec = json.loads(fh.read().decode("utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        rec = None
    if not _readable(rec):
        raise Reject(70, {"error": "receipt_unreadable"})
    return rec


def public(rec: dict) -> dict:
    return {k: v for k, v in rec.items() if not k.startswith("row_")}


def gc(ctx: Ctx) -> None:
    """Under the lock: look at most GC_BUDGET entries, drop expired receipts and
    stale temp files. A receipt lookup would call unreadable is skipped, never deleted."""
    try:
        with os.scandir(ctx.receipts) as it:
            entries = list(itertools.islice(it, GC_BUDGET))
    except FileNotFoundError:
        return
    removed = False
    for entry in entries:
        try:
            if entry.name.startswith(".tmp-"):
                stale = ctx.now - entry.stat().st_mtime > TMP_MAX_AGE
            elif entry.name.endswith(".json"):
                with open(entry.path, "rb") as fh:
                    rec = json.loads(fh.read().decode("utf-8"))
                stale = _readable(rec) and ctx.now >= rec["expires_at"]
            else:
                stale = False
            if stale:
                os.unlink(entry.path)
                removed = True
        except (OSError, ValueError):
            continue
    if removed:
        fsync_dir(ctx.receipts)


# ------------------------------------------------------------ validation ---

class Request:
    """A validated decision; everything bin/meute handed over, checked."""

    def __init__(self, ctx: Ctx, root: str, operation: str, operator: str, key: str, rid: str,
                 n_raw, message, pr, reason, expected):
        import inbox
        import report as report_lib
        if operation not in OPERATIONS:
            raise invalid("unknown operation")
        if not rk.OPERATOR_RE.fullmatch(operator or ""):
            raise invalid("operator must match [A-Za-z0-9._@:-]{1,64}")
        if not rk.KEY_RE.fullmatch(key or ""):
            raise invalid("--request-key must match [A-Za-z0-9._:-]{8,128}")
        if not expected:
            raise invalid("--expected-revision is required with --request-key")
        if n_raw is None:
            raise invalid("-f <n> is required with --request-key")
        if not re.fullmatch(r"[1-9][0-9]*", n_raw):
            raise invalid("-f takes a finding number: a positive integer without leading zeros")
        self.op, self.operator, self.key, self.expected = operation, operator, key, expected
        self.rid, self.n = rid or "", int(n_raw)
        self.text = (message or "").strip()
        self.pr, self.reason = pr or "", reason or ""
        if any(unicodedata.category(c) == "Cc" for c in self.text):
            raise invalid("text may not contain tabs, newlines or control characters")
        if operation == "dismiss":
            if self.reason not in inbox.DISMISS_REASONS:
                raise invalid("unknown reason; one of: " + " ".join(inbox.DISMISS_REASONS))
            if self.pr:
                raise invalid("dismiss takes no --pr")
        else:
            if self.reason:
                raise invalid("resolve takes no reason")
            if self.pr and not PR_RE.fullmatch(self.pr):
                raise invalid("--pr must be an http(s) URL with no spaces")
            if not (self.text or self.pr):
                raise invalid("-m <text> or --pr <url> is required (what was done)")
        self.total = self._total(report_lib, root)
        self.fkey = f"{self.rid}#{self.n}"
        self.fkey_b = self.fkey.encode("utf-8")
        self.state = STATES[operation]
        self.note = self._note()
        self.phash = rk.payload_hash({"report_id": self.rid, "n": self.n, "reason": self.reason,
                                      "message": self.text, "pr": self.pr})

    def _total(self, report_lib, root: str) -> int:
        if not rk.valid_report_id(self.rid):
            raise invalid("report id must be <repo>/<name>")
        path = os.path.join(root, "reports", self.rid + ".md")
        if not os.path.isfile(path):
            raise invalid(f"no such report: {self.rid}")
        try:
            _, body = report_lib.read(path)
        except Exception as exc:  # a malformed report is invalid input, not a crash
            raise invalid(f"unreadable report {self.rid}: {exc}")
        total = len(report_lib.parse_findings(body)) if report_lib.has_findings_section(body) else 0
        if self.n > total:
            raise invalid(f"no finding {self.n} in {self.rid}")
        return total

    def _note(self) -> str:
        if self.op == "dismiss":
            return self.reason + (f": {self.text}" if self.text else "")
        parts = [p for p in (self.text, f"pr: {self.pr}" if self.pr else "") if p]
        return "resolved: " + " ".join(parts)


# ----------------------------------------------------------- transaction ---

def _new_receipt(ctx: Ctx, req: Request, current: str) -> dict:
    row_when = ctx.iso_now()
    after = rk.revision({req.fkey_b: (req.state.encode(), row_when.encode(), req.note.encode())}, req.fkey)
    return {
        "version": VERSION, "receipt_id": uuid.uuid4().hex, "operation": OPERATIONS[req.op],
        "operator": req.operator, "request_key": req.key, "payload_sha256": req.phash,
        "report_id": req.rid, "n": req.n, "finding_key": req.fkey,
        "expected_revision": req.expected, "before_revision": current, "after_revision": after,
        "disposition": req.state, "phase": "pending", "created_at": ctx.now,
        "expires_at": ctx.now + ctx.ttl, "row_state": req.state, "row_when": row_when,
        "row_note": req.note,
    }


def _report_state(req: Request, rows: dict) -> str:
    """close_report_if_settled: `read` while any finding still reads `new`."""
    for i in range(1, req.total + 1):
        row = rows.get(f"{req.rid}#{i}".encode("utf-8"))
        if (row[0] if row else b"new") == b"new":
            return "read"
    return "actioned"


def _finish(ctx: Ctx, req: Request, path: str, rec: dict, replayed: bool):
    """Steps 8-9: derive the report row (idempotent), then complete the receipt."""
    state = _report_state(req, rk.read_rows(ctx.reports)) if req.total else "actioned"
    write_row(ctx.reports, req.rid, state, ctx.iso_now(), "")
    ctx.hook("8")
    rec = {**rec, "phase": "complete"}
    replace_receipt(path, rec)
    ctx.hook("9")
    return 0, {"receipt": public(rec), "replayed": replayed}


def _apply(ctx: Ctx, req: Request, path: str, rec: dict, row_written: bool, replayed: bool):
    if not row_written:
        write_row(ctx.reports, req.fkey, rec["row_state"], rec["row_when"], rec["row_note"], ctx.hook)
        ctx.hook("6")
    rec = {**rec, "phase": "state_written"}
    replace_receipt(path, rec)
    ctx.hook("7")
    return _finish(ctx, req, path, rec, replayed)


def _resume(ctx: Ctx, req: Request, path: str, rec: dict, rows: dict, current: str):
    """A live receipt for this scope: never consults the expected revision."""
    if rec["payload_sha256"] != req.phash:
        raise Reject(4, {"error": "key_conflict"})
    if rec["phase"] == "complete":
        return 0, {"receipt": public(rec), "replayed": True}
    if rec["phase"] == "state_written":
        return _finish(ctx, req, path, rec, True)
    intended = (rec["row_state"].encode(), rec["row_when"].encode(), rec["row_note"].encode())
    if rows.get(req.fkey_b) == intended:
        return _apply(ctx, req, path, rec, True, True)
    if current == rec["before_revision"]:
        return _apply(ctx, req, path, rec, False, True)
    raise Reject(5, {"error": "indeterminate", "receipt": public(rec), "current_revision": current})


def _locked(ctx: Ctx, req: Request):
    path = os.path.join(ctx.receipts, rk.scope_hash(req.operator, OPERATIONS[req.op], req.key) + ".json")
    rec = load_receipt(path)
    if rec is not None and ctx.now >= rec["expires_at"]:
        os.unlink(path)  # expired = absent; the path must be free for the exclusive create
        fsync_dir(ctx.receipts)
        rec = None
    rows = rk.read_rows(ctx.reports)
    current = rk.revision(rows, req.fkey)
    if rec is not None:
        return _resume(ctx, req, path, rec, rows, current)
    if current != req.expected:
        raise Reject(3, {"error": "stale_revision", "current_revision": current})
    rec = _new_receipt(ctx, req, current)
    for directory in (os.path.dirname(ctx.receipts), ctx.receipts):
        ensure_dir(directory)
    gc(ctx)
    create_receipt(ctx.receipts, path, rec)
    ctx.hook("5")
    return _apply(ctx, req, path, rec, False, False)


def run_decide(root: str, operation: str, operator: str, key: str, rid: str, n, message, pr, reason,
               expected, env=None):
    """(exit code, JSON body) for one decision. The library entry both surfaces share."""
    try:
        ctx = Ctx(root, os.environ if env is None else env)
        req = Request(ctx, root, operation, operator, key, rid, n, message, pr, reason, expected)
        with state_lock(ctx):
            return _locked(ctx, req)
    except Reject as out:
        return out.code, out.body


# ------------------------------------------------------------------- CLI ---

def _emit(code: int, body: dict, note: str = "") -> int:
    sys.stdout.write(json.dumps(body) + "\n")
    sys.stdout.flush()
    if note:
        sys.stderr.write(f"meute: {note}\n")
    return code


def _success_note(op: str, body: dict, reason: str) -> str:
    rec = body["receipt"]
    what, tail = ("resolved", "") if op == "resolve" else ("dismissed", f" ({reason})")
    return f"{what} finding {rec['n']} of {rec['report_id']}{tail}" + (" (replayed)" if body["replayed"] else "")


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="decisions.py", allow_abbrev=False)
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide", allow_abbrev=False)
    d.add_argument("operation", choices=sorted(OPERATIONS))
    for flag in ("id", "finding", "message", "pr", "reason", "request-key", "expected-revision", "operator"):
        d.add_argument(f"--{flag}", default=None)
    r = sub.add_parser("revision", allow_abbrev=False)
    r.add_argument("id")
    r.add_argument("n")
    return p


def _cmd_revision(root: str, args) -> int:
    if not rk.valid_report_id(args.id) or not re.fullmatch(r"[1-9][0-9]*", args.n):
        return _emit(2, {"error": "invalid", "detail": "usage: revision <repo>/<name> <n>"})
    rows = rk.read_rows(os.path.join(root, "state", "reports"))
    sys.stdout.write(rk.revision(rows, f"{args.id}#{args.n}") + "\n")
    return 0


def _cmd_decide(root: str, args) -> int:
    env = os.environ
    operator = args.operator if args.operator is not None else env.get("MEUTE_OPERATOR", "local")
    code, body = run_decide(root, args.operation, operator, args.request_key, args.id, args.finding,
                            args.message, args.pr, args.reason, args.expected_revision, env)
    if code == 0:
        return _emit(0, body, _success_note(args.operation, body, args.reason))
    detail = body.get("detail") or body.get("error", "")
    return _emit(code, body, f"{args.operation}: {detail}")


def main(argv=None) -> int:
    try:
        args = _parser().parse_args(argv)
        root = os.environ.get("MEUTE_ROOT") or os.path.dirname(HERE)
        return _cmd_revision(root, args) if args.cmd == "revision" else _cmd_decide(root, args)
    except Exception as exc:  # never exit 1: the caller reads 1 as "nothing happened"
        sys.stderr.write(f"meute: internal error: {type(exc).__name__}: {exc}\n")
        return _emit(70, {"error": "internal"})


if __name__ == "__main__":
    sys.exit(main())
