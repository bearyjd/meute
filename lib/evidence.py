"""Publish a recorded Meute snapshot from owner-issued report bindings."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

if __package__:
    from .native_evidence import CLAIM_FIELDS, CLAIM_VERSION, RUN_ID
    from .report import MAX_REPORT_BYTES
else:
    from native_evidence import CLAIM_FIELDS, CLAIM_VERSION, RUN_ID
    from report import MAX_REPORT_BYTES

MAX_ROWS = 256
MAX_EXPORT = 256 * 1024
MAX_PROVENANCE = 16 * 1024
MAX_REPORT = MAX_REPORT_BYTES
MAX_LOG = 16 * 1024 * 1024
MAX_HEADER = 16 * 1024
PROJECT = r"[a-z0-9][a-z0-9_-]*"
SEGMENT = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
OID = r"(?:[0-9a-f]{40}|[0-9a-f]{64})"
SHA256 = r"[0-9a-f]{64}"
TIMESTAMP = (
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])"
)
BINDING_FIELDS = {
    "task", "ref", "source", "engine", "auth", "commit",
    "started_at", "outcome", "report_sha256",
}
AUDIT_FIELDS = {"task_reference_in_report", "task_reference_source", "submission_sha256"}
NATIVE_REPORT_FIELDS = {"run_id", "report_ref", "product_task"}
NATIVE_LOG_FIELDS = {b"run_id", b"product_task", b"report_sha256"}
ROOT = Path(os.environ.get("MEUTE_ROOT") or Path(__file__).resolve().parents[1])


def read_input(path: Path, limit: int) -> tuple[bytes, tuple[int, int]]:
    # Nonblocking opens let us reject FIFOs without waiting for a writer.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("expected a regular input file")
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"input exceeds {limit} bytes")
    return data, (info.st_dev, info.st_ino)


def unique_object(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key in provenance")
        result[key] = value
    return result


def parse_binding(data: bytes) -> dict:
    binding = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    if isinstance(binding, dict) and "version" in binding:
        if (
            not CLAIM_FIELDS <= binding.keys() <= CLAIM_FIELDS | {"task"}
            or type(binding["version"]) is not int
            or binding["version"] != CLAIM_VERSION
            or any(not isinstance(value, str) or not value
                   for key, value in binding.items() if key != "version")
            or not re.fullmatch(RUN_ID, binding["run_id"])
        ):
            raise ValueError("invalid native run claim")
        return binding
    if (
        not isinstance(binding, dict)
        or not BINDING_FIELDS <= binding.keys() <= BINDING_FIELDS | AUDIT_FIELDS
        or any(not isinstance(binding[key], str) or not binding[key] for key in BINDING_FIELDS)
    ):
        raise ValueError("invalid provenance fields")
    if (
        "task_reference_in_report" in binding
        and not isinstance(binding["task_reference_in_report"], bool)
    ):
        raise ValueError("invalid task_reference_in_report")
    if "task_reference_source" in binding and not isinstance(binding["task_reference_source"], str):
        raise ValueError("invalid task_reference_source")
    if "submission_sha256" in binding:
        submission = binding["submission_sha256"]
        if not isinstance(submission, str) or not re.fullmatch(SHA256, submission):
            raise ValueError("invalid submission digest")
    return binding


def native_header(report: bytes) -> dict[str, str]:
    # The runner writes flat key/value lines. Decode only the native header.
    opening, _, rest = report[:MAX_HEADER].partition(b"\n")
    header, closing, _ = rest.partition(b"\n---\n")
    if opening != b"---" or not closing:
        raise ValueError("expected a bounded native report header")
    fields = {}
    for line in header.decode("utf-8").split("\n"):
        key, separator, value = line.partition(": ")
        if not separator or not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            raise ValueError("malformed native report header")
        if key in fields:
            raise ValueError("duplicate key in native report header")
        fields[key] = value
    return fields


def verify_terminal_log(log: bytes, ref: str, meta: dict[str, str], digest: str) -> None:
    timestamp = meta["started"].encode("utf-8")
    reference = f"report={ref}".encode("utf-8")
    run_id = meta.get("run_id")
    correlation = f"run_id={run_id}".encode("utf-8") if run_id else None
    if log and not log.endswith(b"\n"):
        raise ValueError("partial terminal log line")
    candidate = None
    for line in io.BytesIO(log):
        if not correlation and not line.startswith(timestamp + b"\t"):
            continue
        time, *entries = line[:-1].split(b"\t")
        if reference not in entries and correlation not in entries:
            continue
        if candidate is not None:
            raise ValueError("ambiguous terminal log records")
        candidate = time, entries
    if candidate is None:
        raise ValueError("missing terminal log record for the report")

    time, entries = candidate
    if time != timestamp:
        raise ValueError("timestamp does not match terminal log record")
    fields = {}
    for field in entries:
        key, separator, value = field.partition(b"=")
        if not separator or not key:
            raise ValueError("malformed terminal log field")
        if key in fields:
            raise ValueError("duplicate key in terminal log record")
        fields[key] = value
    required = {b"week", b"slot", b"code", b"dur", b"runtime", b"image", b"stage", b"pr"}
    if not required <= fields.keys() or not re.fullmatch(rb"[0-9]+s", fields[b"dur"]):
        raise ValueError("partial terminal log record")
    for key in ("repo", "task", "slot", "engine", "auth", "status"):
        native = meta.get(key)
        if not native:
            raise ValueError(f"missing {key} in native report header")
        if fields.get(key.encode("ascii")) != native.encode("utf-8"):
            raise ValueError(f"{key} does not match terminal log record")
    code = {"ok": b"ok", "error": b"failed"}.get(meta["status"])
    if code is None or fields[b"code"] != code:
        raise ValueError("code does not attest a completed runner attempt")
    if run_id:
        if fields.get(b"run_id") != run_id.encode("utf-8") or reference not in entries:
            raise ValueError("run ID or report ref does not match terminal log record")
        if fields.get(b"report_sha256") != digest.encode("utf-8"):
            raise ValueError("report digest does not match terminal log record")
        task = meta.get("product_task")
        if fields.get(b"product_task") != (task.encode("utf-8") if task else None):
            raise ValueError("product task does not match terminal log record")
    elif NATIVE_LOG_FIELDS & fields.keys():
        raise ValueError("native terminal log record requires a native run claim")


def verify_record(
    project: str, binding: dict, path: Path, report: bytes, log: bytes
) -> tuple[dict, datetime, tuple[str, ...]]:
    if binding["source"] != "meute-runner":
        raise ValueError("expected meute-runner provenance")
    task = binding.get("task")
    if task is not None and (len(task) > 160 or not re.fullmatch(rf"{re.escape(project)}/[0-9]+", task)):
        raise ValueError("expected a task key in the requested project")
    digest = hashlib.sha256(report).hexdigest()
    meta = native_header(report)
    ref = binding["ref"]
    if (
        len(ref) > 512
        or not re.fullmatch(rf"reports/{SEGMENT}/{SEGMENT}\.md", ref)
        or ref != f"reports/{meta.get('repo', '')}/{path.name}"
    ):
        raise ValueError("report ref does not match native repo and report filename")
    run_id = binding.get("run_id")
    if run_id:
        for key, field in (("run_id", "run_id"), ("repo", "repo"), ("slot", "slot"),
                           ("meute_task", "task"), ("ref", "report_ref"), ("task", "product_task")):
            if binding.get(key) != meta.get(field):
                raise ValueError(f"{field} does not match the native run claim")
        if run_id in ref:
            raise ValueError("public report ref contains the internal run ID")
    else:
        if NATIVE_REPORT_FIELDS & meta.keys():
            raise ValueError("native report requires a native run claim")
        if binding["report_sha256"] != digest:
            raise ValueError("report digest does not match provenance")
        if binding["outcome"] != meta.get("status"):
            raise ValueError("outcome does not match native report header")
    for key, field in (("engine", "engine"), ("auth", "auth"), ("started_at", "started")):
        if binding[key] != meta.get(field):
            raise ValueError(f"{key} does not match native report header")
    if binding["engine"] not in {"claude", "codex"}:
        raise ValueError("unknown native report engine")
    base, _, commit = meta.get("base", "").rpartition("@")
    if not base or not re.fullmatch(OID, commit) or commit != binding["commit"]:
        raise ValueError("commit does not match native report base")
    started = binding["started_at"]
    if not re.fullmatch(TIMESTAMP, started):
        raise ValueError("expected an RFC 3339 started_at timestamp")
    instant = datetime.fromisoformat(started.replace("Z", "+00:00"))
    outcome = meta.get("status", "")
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", outcome):
        raise ValueError("invalid outcome token")
    verify_terminal_log(log, ref, meta, digest)
    native_identity = (digest, *(meta[key] for key in (
        "repo", "task", "slot", "engine", "auth", "base", "started", "status"
    )))
    row = {"ref": ref, "recorded_at": started, "outcome": outcome}
    if task is not None:
        row["task"] = task
    return row, instant, native_identity


def check_output(path: Path, input_ids: set[tuple[int, int]]) -> int | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if (info.st_dev, info.st_ino) in input_ids:
        raise ValueError("output collides with an input")
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("output must be a regular file")
    return info.st_mode & 0o777


def write_snapshot(path: Path, data: bytes, input_ids: set[tuple[int, int]]) -> None:
    path = path.parent.resolve(strict=True) / path.name
    for directory in ("state", "reports"):
        if path.is_relative_to((ROOT / directory).resolve()):
            raise ValueError("output must be outside Meute state and reports")
    check_output(path, input_ids)
    fd, temporary = tempfile.mkstemp(prefix=".meute-evidence-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            mode = check_output(path, input_ids)
            if mode is not None:
                os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def export(project: str, output: Path, records: list[list[Path]]) -> None:
    if len(project) > 128 or not re.fullmatch(PROJECT, project):
        raise ValueError("invalid project ID")
    if len(records) > MAX_ROWS:
        raise ValueError(f"expected at most {MAX_ROWS} records")
    rows = {}
    run_refs = {}
    input_ids = set()
    latest = datetime.min.replace(tzinfo=timezone.utc)
    for index, (binding_path, report_path, log_path) in enumerate(records, 1):
        try:
            data, binding_id = read_input(binding_path, MAX_PROVENANCE)
            binding = parse_binding(data)
            report, report_id = read_input(report_path, MAX_REPORT)
            log, log_id = read_input(log_path, MAX_LOG)
            row, instant, native_identity = verify_record(
                project, binding, report_path, report, log
            )
        except (OSError, RecursionError, ValueError) as error:
            raise ValueError(f"record {index}: {error}") from error
        record = (row, native_identity)
        if rows.setdefault(row["ref"], record) != record:
            raise ValueError(f"record {index}: conflicting report rows")
        run_id = binding.get("run_id")
        if run_id and run_refs.setdefault(run_id, row["ref"]) != row["ref"]:
            raise ValueError(f"record {index}: conflicting references for the native run ID")
        input_ids.update((binding_id, report_id, log_id))
        latest = max(latest, instant)

    now = datetime.now(timezone.utc)
    if latest > now:
        raise ValueError("report timestamp is later than the snapshot")
    snapshot = {
        "version": 1,
        "project": project,
        "exported_at": now.isoformat(),
        "reports": [row for row, _ in rows.values()],
    }
    data = (json.dumps(snapshot, indent=2) + "\n").encode("utf-8")
    if len(data) > MAX_EXPORT:
        raise ValueError(f"snapshot exceeds {MAX_EXPORT} bytes")
    write_snapshot(output, data, input_ids)


def main() -> int:
    parser = argparse.ArgumentParser(prog="meute evidence")
    commands = parser.add_subparsers(required=True)
    publish = commands.add_parser(
        "export", help="write a recorded project snapshot",
        epilog=(
            "For native runs, pass state/evidence/<run-id>.json, the matching report, and state/log. "
            "For older runs, pass an explicit operator-issued binding instead of the claim. "
            "Required legacy JSON keys: task, ref, source (meute-runner), "
            "engine, auth, commit, started_at, outcome, report_sha256. "
            "The exporter checks agreement among the binding, report, and log. "
            "Use records from a trusted operator and trusted parent directories."
        ),
    )
    publish.add_argument("--project", required=True)
    publish.add_argument("--output", type=Path, required=True, help="local snapshot file")
    publish.add_argument(
        "--record", type=Path, nargs=3, metavar=("CLAIM_OR_BINDING", "REPORT", "TERMINAL_LOG"),
        action="append", required=True,
        help="native claim or legacy binding JSON, copied report and runner state/log (repeatable)",
    )
    args = parser.parse_args()
    try:
        export(args.project, args.output, args.record)
    except (OSError, ValueError) as error:
        print(f"meute evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
