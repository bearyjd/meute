#!/usr/bin/env python3
"""Prepare operator claims and reconcile the IDs in audit-intent reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

from redact import redact
from report import ReportError, read


ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/#-]{0,127}")
KEY = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
REVISION = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
RESULT_FENCE = "```audit-intent-results"
MARKDOWN_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
VERDICTS = ("implemented", "partial", "missing", "diverged", "unverified")
MAX_CLAIMS = 25
MAX_CLAIM_BYTES = 16 * 1024


class AuditError(ValueError):
    """Invalid input or unreconciled result."""


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise AuditError("duplicate JSON field")
        obj[key] = value
    return obj


def versioned_records(text, field):
    try:
        obj = json.loads(text, object_pairs_hook=unique_object)
    except AuditError:
        raise
    except (ValueError, RecursionError) as error:
        raise AuditError("invalid audit JSON") from error
    keys = {"version", field}
    if field == "claims":
        keys.add("revision")
    if (not isinstance(obj, dict) or set(obj) != keys or type(obj["version"]) is not int
            or obj["version"] != 1 or not isinstance(obj[field], list)):
        raise AuditError(f"expected a version 1 audit {field} document")
    return obj


def valid_id(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        return False
    encoded = value.encode("ascii")
    return redact(encoded) == encoded


def read_claim_list(path):
    if not path.is_file():
        raise AuditError("claim list must be a regular file")
    with path.open("rb") as handle:
        data = handle.read(MAX_CLAIM_BYTES + 1)
    if len(data) > MAX_CLAIM_BYTES:
        raise AuditError("claim list exceeds 16 KiB")
    obj = claim_list(data.decode("utf-8"))
    if len(canonical(obj)) > MAX_CLAIM_BYTES:
        raise AuditError("normalized claim list exceeds 16 KiB")
    return obj


def claim_list(text):
    obj = versioned_records(text, "claims")
    revision = obj["revision"]
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise AuditError("claim list revision must be a full lowercase Git commit ID")
    if not 1 <= len(obj["claims"]) <= MAX_CLAIMS:
        raise AuditError(f"claim list must contain 1 to {MAX_CLAIMS} claims")
    claims = []
    required = {"path", "section", "key", "title"}
    optional = {"id", "start_line", "end_line"}
    for index, entry in enumerate(obj["claims"], 1):
        if not isinstance(entry, dict) or not required <= set(entry) <= required | optional:
            raise AuditError(f"claim {index} requires path, section, key and title")
        path, section, key, title = (entry[field] for field in ("path", "section", "key", "title"))
        if (not isinstance(path, str) or not path.isprintable() or "\\" in path
                or any(part in ("", ".", "..") for part in path.split("/"))):
            raise AuditError(f"claim {index} has an invalid repo-relative path")
        if any(not isinstance(value, str) or not KEY.fullmatch(value) for value in (section, key)):
            raise AuditError(f"claim {index} requires lowercase hyphenated section and claim keys")
        if not isinstance(title, str) or not title.strip() or not title.isprintable():
            raise AuditError(f"claim {index} requires a nonempty printable title")
        start, end = entry.get("start_line"), entry.get("end_line")
        if ("start_line" in entry or "end_line" in entry) and (
            type(start) is not int or type(end) is not int or not 1 <= start <= end
        ):
            raise AuditError(f"claim {index} has invalid line bounds")
        if "id" not in entry:
            anchor = json.dumps([path, section, key], ensure_ascii=True, separators=(",", ":"))
            entry["id"] = "intent:" + hashlib.sha256(anchor.encode("ascii")).hexdigest()
        if not valid_id(entry["id"]):
            raise AuditError(f"claim {index} has a malformed ID")
        claims.append(entry)
    duplicates = duplicate_ids(claim["id"] for claim in claims)
    if duplicates:
        raise AuditError("duplicate input IDs (" + ", ".join(duplicates) + ")")
    obj["claims"] = sorted(claims, key=lambda claim: claim["id"])
    return obj


def duplicate_ids(ids):
    return sorted(claim_id for claim_id, count in Counter(ids).items() if count > 1)


def git(repo, *args):
    result = subprocess.run(
        ["git", "--no-replace-objects", "-C", repo, *args], capture_output=True,
    )
    if result.returncode:
        raise AuditError(f"cannot inspect pinned Git source ({args[0]})")
    return result.stdout


def check_sources(obj, repo, base):
    if obj["revision"] != base:
        raise AuditError(f"claim list revision does not match selected audit commit {base}")
    object_ids = {}
    line_counts = {}
    for claim in obj["claims"]:
        path = claim["path"]
        if path not in object_ids:
            tree = git(repo, "ls-tree", "-z", "--full-tree", base, "--", f":(literal){path}")
            descriptor, _, stored_name = tree.rstrip(b"\0").partition(b"\t")
            fields = descriptor.split()
            if (stored_name != path.encode("utf-8") or len(fields) != 3
                    or fields[0] not in (b"100644", b"100755")):
                raise AuditError(f"source for claim {claim['id']} is not a tracked regular file")
            object_ids[path] = fields[2].decode("ascii")
        if "end_line" in claim:
            if path not in line_counts:
                blob = git(repo, "cat-file", "blob", object_ids[path])
                line_counts[path] = len(blob.splitlines())
            if claim["end_line"] > line_counts[path]:
                raise AuditError(f"source line bounds for claim {claim['id']} exceed the pinned file")


def canonical(obj):
    return json.dumps(obj, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n"


def result_ids(body, expected):
    lines = body.replace("\r\n", "\n").replace("\r", "\n").rstrip(" \t\n").split("\n")
    markers = []
    fence = ""
    in_comment = False
    for index, line in enumerate(lines):
        if not fence and (in_comment or re.match(r"^ {0,3}<!--", line)):
            in_comment = "-->" not in line
            continue
        match = MARKDOWN_FENCE.match(line)
        if not match:
            continue
        delimiter, info = match.groups()
        if fence:
            if delimiter.startswith(fence) and not info.strip():
                fence = ""
        else:
            fence = delimiter
            if line.rstrip(" \t") == RESULT_FENCE:
                markers.append(index)
    if len(markers) != 1:
        raise AuditError("expected exactly one audit-intent-results block")
    if fence or lines[-1] != "```" or markers[0] >= len(lines) - 2:
        raise AuditError("audit-intent-results block must end the report")
    obj = versioned_records("\n".join(lines[markers[0] + 1:-1]), "results")
    ids = []
    for index, entry in enumerate(obj["results"], 1):
        if not isinstance(entry, dict) or set(entry) != {"id", "verdict"}:
            raise AuditError(f"result {index} requires id and verdict")
        if not valid_id(entry["id"]):
            raise AuditError(f"result {index} has a malformed ID")
        if entry["verdict"] not in VERDICTS:
            raise AuditError(f"result {index} has an invalid verdict")
        ids.append(entry["id"])
    actual = set(ids)
    issues = []
    for issue, values in (
        ("duplicate", duplicate_ids(ids)), ("missing", sorted(expected - actual)),
        ("unknown", sorted(actual - expected)),
    ):
        if values:
            issues.append(f"{issue} audit claim IDs ({', '.join(values)})")
    if issues:
        raise AuditError(" | ".join(issues))
    return sorted(ids)


def expected_ids(obj):
    return {claim["id"] for claim in obj["claims"]}


def verify_report(obj, path):
    meta, body = read(str(path))
    if meta.get("task") != "audit-intent":
        raise AuditError("expected an audit-intent report")
    status = meta.get("audit_claim_ids", "unvalidated")
    if status == "unvalidated":
        return {"audit_claim_ids": status, "reason": "no validated machine IDs"}
    if status == "unverified":
        return {"audit_claim_ids": status, "reason": meta.get("audit_claim_ids_detail", "run failed validation")}
    if status != "verified" or meta.get("status") != "ok":
        raise AuditError("report lacks runner confirmation of claim ID validation")
    if meta.get("base", "").rpartition("@")[2] != obj["revision"]:
        raise AuditError("report base does not match the claim list revision")
    if meta.get("audit_claim_list_sha256") != hashlib.sha256(canonical(obj).encode("ascii")).hexdigest():
        raise AuditError("report was produced with a different claim list")
    return {"audit_claim_ids": "verified", "ids": result_ids(body, expected_ids(obj))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("claims", type=Path)
    prepare.add_argument("repo")
    prepare.add_argument("base")
    output = commands.add_parser("check-output")
    output.add_argument("claims", type=Path)
    verify = commands.add_parser("verify", help="check a saved Markdown report against its claim list")
    verify.add_argument("claims", type=Path)
    verify.add_argument("report", type=Path)
    args = parser.parse_args()

    try:
        obj = read_claim_list(args.claims)
        if args.command == "prepare":
            check_sources(obj, args.repo, args.base)
            sys.stdout.write(canonical(obj))
        elif args.command == "check-output":
            # Verify the byte sequence the normal report writer will retain.
            body = redact(sys.stdin.buffer.read()).decode("utf-8")
            result_ids(body, expected_ids(obj))
        else:
            state = verify_report(obj, args.report)
            print(json.dumps(state, sort_keys=True))
            return int(state["audit_claim_ids"] != "verified")
    except (AuditError, ReportError, OSError, UnicodeError) as error:
        if args.command == "verify":
            print(json.dumps({"audit_claim_ids": "unverified", "reason": str(error)}))
        else:
            print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
