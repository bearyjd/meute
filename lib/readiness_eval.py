"""Read-only evaluation of readiness reports, findings, evidence and deferrals."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Callable

import inbox
import report as report_lib
from evidence import SEGMENT, read_input, unique_object, verify_record, parse_binding, MAX_LOG
from readiness_rules import CATEGORIES, SCOPE, covers, expired, parse_utc

PURPOSES = ("docs", "codemap", "baseline", "acceptance", "audits")
EVIDENCE_FIELDS = {"version", "purpose", *SCOPE, "revision", "outcome"}
OPTIONAL_FIELDS = {"result", "fixes", "native", "preexisting"}
FINDING_HEADING = re.compile(r"^###\s", re.M)
BLOB_PURPOSES = ("docs", "codemap")
FIX_PURPOSES = ("acceptance", "audits")
PRECEDENCE = ("report_unreadable", "report_malformed", "report_repo_mismatch",
              "inventory_report_changed", "inventory_report_added", "inventory_report_removed")


@dataclass(frozen=True)
class Context:
    root: Path
    record: dict
    policy: dict
    git: Callable


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# -------------------------------------------------------------- inventory ---

def _parse_report(path: Path, directory: str, name: str, repo: str) -> dict:
    entry = {"digest": None, "error": None, "claimed": None, "findings": []}
    try:
        data, _ = read_input(path, report_lib.MAX_REPORT_BYTES)
    except (OSError, ValueError):
        return {**entry, "error": "report_unreadable"}
    entry["digest"] = sha256(data)
    try:
        text = data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except UnicodeDecodeError:
        return {**entry, "error": "report_malformed"}
    meta, body = report_lib.split_report(text)
    if not meta:
        return {**entry, "error": "report_malformed"}
    entry["claimed"] = meta.get("repo")
    if meta.get("repo", directory) != directory or directory != repo:
        return {**entry, "error": "report_repo_mismatch"}
    rid = f"{directory}/{name[:-3]}"
    fp_repo = report_lib.report_repo(meta, str(path))
    section = report_lib.has_findings_section(body)
    parsed = report_lib.parse_findings(body) if section else []
    if section and not parsed and FINDING_HEADING.search(body):
        return {**entry, "error": "report_malformed"}
    findings = [
        {"id": f"{rid}#{f['n']}", "report": rid, "n": f["n"], "severity": f["severity"],
         "fingerprint": report_lib.fingerprint(fp_repo, f["location"], f["title"])}
        for f in parsed
    ]
    return {**entry, "findings": findings}


def scan_reports(root: Path, repo: str) -> dict[str, dict]:
    """Every report in reports/<repo> plus readable reports elsewhere claiming the repo."""
    base = root / "reports"
    found: dict[str, dict] = {}
    if not base.is_dir():
        return found
    unreadable = {"digest": None, "error": "report_unreadable", "claimed": None, "findings": []}
    try:
        directories = sorted(os.listdir(base))
    except OSError:
        return {"reports/": unreadable}
    for directory in directories:
        folder = base / directory
        if folder.is_symlink():
            if directory == repo:
                found[f"{directory}/"] = unreadable
            continue
        if not folder.is_dir():
            continue
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            found[f"{directory}/"] = unreadable
            continue
        for name in names:
            path = folder / name
            if directory == repo and (path.is_symlink() or (name.endswith(".md") and not path.is_file())):
                found[f"{directory}/{name}"] = unreadable
                continue
            if not name.endswith(".md") or path.is_symlink() or not path.is_file():
                continue
            entry = _parse_report(path, directory, name, repo)
            if directory == repo or entry["claimed"] == repo:
                found[f"{directory}/{name}"] = entry
    return found


def report_digests(reports: dict[str, dict]) -> dict[str, str]:
    return {path: entry["error"] or entry["digest"] for path, entry in sorted(reports.items())}


def inventory_check(reports: dict[str, dict], expected: dict[str, str]) -> dict:
    items = []
    for path, entry in sorted(reports.items()):
        if entry["error"]:
            items.append({"path": path, "reason": entry["error"]})
        elif path not in expected:
            items.append({"path": path, "reason": "inventory_report_added"})
        elif expected[path] != entry["digest"]:
            items.append({"path": path, "reason": "inventory_report_changed"})
    items += [{"path": path, "reason": "inventory_report_removed"} for path in sorted(expected.keys() - reports.keys())]
    if not items:
        return {"check": "inventory", "status": "passed", "reason": "inventory_matches", "reports": len(reports)}
    reason = min((item["reason"] for item in items), key=PRECEDENCE.index)
    return {"check": "inventory", "status": "pending", "reason": reason, "reports": items}


# --------------------------------------------------------------- findings ---

def inbox_rows(root: Path) -> dict[str, dict]:
    """Inbox state for every finding, hidden ones included; load_reports never writes."""
    previous = inbox.ROOT
    inbox.ROOT = str(root)
    try:
        _, found = inbox.load_reports()
    finally:
        inbox.ROOT = previous
    return {f"{item['report']}#{item['n']}": item for item in found}


def resolve_findings(root: Path, reports: dict[str, dict]) -> tuple[list[dict], dict]:
    observed = [f for path in sorted(reports) if not reports[path]["error"] for f in reports[path]["findings"]]
    try:
        rows = inbox_rows(root)
    except (OSError, ValueError) as error:
        return [], {"check": "findings", "status": "pending", "reason": "findings_unavailable", "detail": str(error)}
    resolved, unresolved = [], []
    for finding in observed:
        row = rows.get(finding["id"])
        if row is None or row["fingerprint"] != finding["fingerprint"]:
            unresolved.append(finding["id"])
            continue
        resolved.append({**finding, "state": row["state"], "note": row["note"], "hidden": row["hidden"]})
    if unresolved:
        return resolved, {"check": "findings", "status": "pending",
                          "reason": "finding_identity_unresolved", "findings": unresolved}
    return resolved, {"check": "findings", "status": "passed", "reason": "findings_resolved",
                      "count": len(resolved), "hidden": sum(f["hidden"] for f in resolved)}


def assessment_check(assessment: dict, findings: list[dict], resolved_all: bool) -> dict:
    covered = {key: item for name in CATEGORIES for key, item in assessment[name]["findings"].items()}
    if not all(assessment[name]["affirmed"] for name in CATEGORIES):
        return {"check": "assessment", "status": "pending", "reason": "assessment_not_affirmed"}
    missing = [f["id"] for f in findings if f["id"] not in covered]
    if missing:
        return {"check": "assessment", "status": "pending", "reason": "assessment_incomplete", "findings": missing}
    wrong = [f["id"] for f in findings if covered[f["id"]]["fingerprint"] != f["fingerprint"]]
    if wrong:
        return {"check": "assessment", "status": "pending", "reason": "assessment_fingerprint_mismatch",
                "findings": wrong}
    if not resolved_all:
        return {"check": "assessment", "status": "pending", "reason": "assessment_unresolved_findings"}
    return {"check": "assessment", "status": "passed", "reason": "assessment_complete"}


def _blocker(finding: dict, ctx: Context, fixed: set[tuple[str, str]], now: datetime) -> tuple[str | None, datetime | None]:
    scope = ctx.record
    deferrals = [d for d in covers(ctx.policy["deferrals"], scope)
                 if d["finding"] == finding["id"] and d["fingerprint"] == finding["fingerprint"]]
    live = [d for d in deferrals if not expired(d, now)]
    if live:
        return None, max(parse_utc(d["expires_at"]) for d in live)
    if finding["state"] == "actioned" and finding["note"].startswith("resolved:"):  # what `meute resolve` writes
        return (None if (finding["id"], finding["fingerprint"]) in fixed else "fix_unverified"), None
    return ("deferral_expired" if deferrals else "finding_open"), None


def blockers_check(ctx: Context, findings: list[dict], fixed: set[tuple[str, str]], now: datetime) -> tuple[dict, list[datetime]]:
    applicable = {key for name in CATEGORIES for key, item in ctx.policy["assessment"][name]["findings"].items()
                  if item["applicable"]}
    open_, relied = [], []
    for finding in findings:
        if finding["id"] not in applicable:
            continue
        reason, expiry = _blocker(finding, ctx, fixed, now)
        if reason:
            open_.append({"id": finding["id"], "reason": reason})
        if expiry:
            relied.append(expiry)
    if open_:
        return {"check": "blockers", "status": "pending", "reason": open_[0]["reason"], "findings": open_}, relied
    return {"check": "blockers", "status": "passed", "reason": "blockers_clear"}, relied


# --------------------------------------------------------------- evidence ---

def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root.resolve(strict=True))
    except (OSError, ValueError, RuntimeError):
        return False
    return True


def _file_evidence(ctx: Context, ref: str, pin: str) -> tuple[bytes | None, str | None]:
    root = Path(ctx.policy["evidence_root"])
    path = Path(ref)
    if ".." in path.parts:
        return None, "evidence_path_invalid"
    if not path.is_absolute():
        path = root / path
    try:
        path = path.resolve(strict=True)  # open the resolved path, so no directory symlink is followed after the check
        data, _ = read_input(path, 1024 * 1024)
    except (OSError, ValueError, RuntimeError):
        return None, "evidence_unreadable"
    if sha256(data) != pin:
        return None, "evidence_digest_mismatch"
    if not _inside(path, root) and pin not in ctx.policy["attested_digests"]:
        return None, "evidence_unattested"
    return data, None


def _blob_evidence(ctx: Context, ref: str, pin: str) -> tuple[bytes | None, str | None]:
    commit = ctx.record["base_commit"]
    named = ctx.git("rev-parse", "--verify", "--end-of-options", f"{commit}:{ref}")
    if named.returncode or named.stdout.strip() != pin:
        return None, "evidence_blob_mismatch"
    blob = ctx.git("cat-file", "blob", pin)
    if blob.returncode:
        return None, "evidence_unreadable"
    return blob.stdout.encode("utf-8", "surrogateescape"), None


def _native_digest(ctx: Context, doc: dict) -> tuple[str | None, str | None]:
    run_id = doc["native"].get("run_id") if isinstance(doc["native"], dict) else None
    if not isinstance(run_id, str) or re.fullmatch(r"[0-9a-f]{32}", run_id) is None:
        return None, "evidence_native_unverified"
    try:
        raw, _ = read_input(ctx.root / "state/evidence" / f"{run_id}.json", 64 * 1024)
        binding = parse_binding(raw)
        ref = binding["ref"]
        if re.fullmatch(rf"reports/{SEGMENT}/{SEGMENT}\.md", ref) is None:
            raise ValueError("invalid native report ref")
        report, _ = read_input(ctx.root / ref, report_lib.MAX_REPORT_BYTES)
        log, _ = read_input(ctx.root / "state/log", MAX_LOG)
        row, _, _ = verify_record(ctx.record["repo"], binding, ctx.root / ref, report, log)
    except (OSError, ValueError, KeyError):
        return None, "evidence_native_unverified"
    if binding["commit"] != ctx.record["base_commit"]:
        return None, "evidence_wrong_revision"
    if row["outcome"] != "ok" or binding.get("repo", ctx.record["repo"]) != ctx.record["repo"]:
        return None, "evidence_failed_outcome"
    return sha256(raw + report + log), None


def load_evidence(ctx: Context, purpose: str, item: dict) -> dict:
    """{doc, digest, reason}: reason is None when the reference is affirmative and bound."""
    def bad(reason, digest=None):
        return {"ref": item["ref"], "doc": None, "digest": digest, "reason": reason}
    if item["revision"] != ctx.record["base_commit"]:
        return bad("evidence_wrong_revision")
    if "sha256" not in item and purpose not in BLOB_PURPOSES:
        return bad("evidence_blob_untrusted")  # a blob in the reviewed repo cannot vouch for itself
    loader = _file_evidence if "sha256" in item else _blob_evidence
    data, reason = loader(ctx, item["ref"], item.get("sha256") or item["git_blob"])
    if reason:
        return bad(reason)
    digest = sha256(data)
    try:
        doc = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (ValueError, RecursionError):
        return bad("evidence_malformed", digest)
    if "sha256" not in item and isinstance(doc, dict):
        doc = {"revision": ctx.record["base_commit"], **doc}  # a blob at the pinned commit is bound by it
    reason = _judge(ctx, purpose, doc)
    if reason is None and "native" in doc:
        native, reason = _native_digest(ctx, doc)
        digest = sha256((digest + (native or "")).encode("ascii"))
    return {"ref": item["ref"], "doc": None if reason else doc, "digest": digest, "reason": reason}


def _judge(ctx: Context, purpose: str, doc) -> str | None:
    if not (isinstance(doc, dict) and EVIDENCE_FIELDS <= doc.keys() <= EVIDENCE_FIELDS | OPTIONAL_FIELDS):
        return "evidence_malformed"
    if doc["version"] != 1 or type(doc["version"]) is not int:
        return "evidence_malformed"
    if doc["revision"] != ctx.record["base_commit"]:
        return "evidence_wrong_revision"
    if doc["purpose"] != purpose:
        return "evidence_wrong_purpose"
    if any(doc[key] != ctx.record[key] for key in SCOPE):
        return "evidence_wrong_scope"
    if doc["outcome"] != "ok":
        return "evidence_failed_outcome"
    if "result" not in doc:
        return "evidence_result_missing"
    return _result_reason(ctx, purpose, doc)


def _result_reason(ctx: Context, purpose: str, doc: dict) -> str | None:
    if doc["result"] == "pass":
        return None
    accepted = any(item["condition"] == "baseline_preexisting_failure"
                   for item in covers(ctx.policy["accepted_conditions"], ctx.record))
    if purpose == "baseline" and doc["result"] == "fail" and doc.get("preexisting") is True and accepted:
        return None
    return "evidence_failed"


def _fixes(doc: dict) -> set[tuple[str, str]]:
    claims = doc.get("fixes")
    return {(fix["id"], fix["fingerprint"]) for fix in claims if isinstance(fix, dict)
            and isinstance(fix.get("id"), str) and isinstance(fix.get("fingerprint"), str)} \
        if isinstance(claims, list) else set()


def evaluate_evidence(ctx: Context) -> tuple[list[dict], set[tuple[str, str]], dict[str, str]]:
    checks, fixed, digests = [], set(), {}
    for purpose in PURPOSES:
        loaded = [load_evidence(ctx, purpose, item) for item in ctx.record["evidence"][purpose]]
        for entry in loaded:
            digests[f"{purpose}:{entry['ref']}"] = entry["digest"] or entry["reason"]
            if entry["doc"] and purpose in FIX_PURPOSES:
                fixed |= _fixes(entry["doc"])
        checks.append(_purpose_check(ctx, purpose, loaded))
    return checks, fixed, digests


def _purpose_check(ctx: Context, purpose: str, loaded: list[dict]) -> dict:
    refs = [{"ref": e["ref"], "reason": e["reason"] or "evidence_passed"} for e in loaded]
    failure = next((e["reason"] for e in loaded if e["reason"]), None)
    if not loaded:
        accepted = purpose == "codemap" and any(
            item["condition"] == "codemap_missing" for item in covers(ctx.policy["accepted_conditions"], ctx.record))
        reason = "codemap_accepted_by_policy" if accepted else "evidence_missing"
        status = "passed" if accepted else "pending"
    else:
        status, reason = ("pending", failure) if failure else ("passed", "evidence_passed")
    return {"check": "evidence", "purpose": purpose, "status": status, "reason": reason, "references": refs}


def evidence_digests(ctx: Context) -> dict[str, str]:
    """Re-observe every mutable evidence reference, as evaluate_evidence keyed it."""
    return {
        f"{purpose}:{entry['ref']}": entry["digest"] or entry["reason"]
        for purpose in PURPOSES
        for entry in (load_evidence(ctx, purpose, item) for item in ctx.record["evidence"][purpose])
    }


def state_digests(root: Path) -> dict[str, str]:
    """Digests of the inbox decision files that decide each finding's state."""
    digests = {}
    for name in ("reports", "finding-status"):
        try:
            digests[name] = sha256((root / "state" / name).read_bytes())
        except FileNotFoundError:
            digests[name] = "absent"
        except OSError:
            digests[name] = "unreadable"
    return digests


def evaluate(ctx: Context, now: datetime) -> tuple[list[dict], dict, list[datetime]]:
    """(checks, observation snapshot, expiries of deferrals relied on)."""
    state = state_digests(ctx.root)
    reports = scan_reports(ctx.root, ctx.record["repo"])
    findings, found = resolve_findings(ctx.root, reports)
    evidence_checks, fixed, digests = evaluate_evidence(ctx)
    blockers, relied = blockers_check(ctx, findings, fixed, now)
    checks = [
        inventory_check(reports, ctx.policy["report_inventory"]), found,
        assessment_check(ctx.policy["assessment"], findings, found["status"] == "passed"),
        *evidence_checks, blockers,
    ]
    return checks, {"inventory": report_digests(reports), "evidence": digests, "state": state}, relied


def observe_mutable(ctx: Context) -> dict:
    """The report inventory and evidence digests, re-read from disk."""
    return {"inventory": report_digests(scan_reports(ctx.root, ctx.record["repo"])),
            "evidence": evidence_digests(ctx), "state": state_digests(ctx.root)}
