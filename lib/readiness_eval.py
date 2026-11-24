"""Read-only evaluation of readiness reports, findings, evidence and deferrals.

Everything here fails closed. A filesystem error or an ambiguity (a symlink, a
non-directory, a path that cannot be stat'ed) at reports/ or under the enrolled
repo's reports is reported as report_unreadable; it is never read as "nothing
there". An unreadable or non-UTF-8 path in another repo's directory cannot be
shown not to claim the enrolled repo, so it is listed as ignored_unreadable and
keeps readiness pending (ignored_unreadable_paths). The policy has no field to
acknowledge such a path: make it readable or remove it.

Findings are not recognised by listing bad shapes. A report of the enrolled
repo (or one elsewhere claiming it) is report_malformed unless every line that
names a severity is either a finding line the inbox parser reads inside a
canonical `## Findings` section, or plain prose: see _unparsed_finding. Fenced
code blocks are not exempt, because the inbox parser does not exempt them.

An applicable finding stays open unless this record's own evidence or policy
clears it, intentionally: a decision inherited from an earlier report with the
same fingerprint, and a whole-report `meute resolve` with no per-finding row,
both leave the finding open here. Only a live scoped deferral, or the finding's
own `resolved:` row together with fix evidence binding its id and fingerprint,
clears a blocker, whatever the severity.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Callable

import inbox
import report as report_lib
from evidence import SEGMENT, read_input, unique_object, verify_record, parse_binding, MAX_LOG
from readiness_rules import CATEGORIES, SCOPE, covers, expired, parse_utc

PURPOSES = ("docs", "codemap", "baseline", "acceptance", "audits")
EVIDENCE_FIELDS = {"version", "purpose", *SCOPE, "revision", "outcome"}
OPTIONAL_FIELDS = {"result", "fixes", "native", "preexisting"}
FINDING_HEADING = re.compile(r"^###\s", re.M)
FINDINGS_SECTION = re.compile(r"^## Findings\s*$", re.M)  # report_lib.has_findings_section, every occurrence
NEXT_SECTION = re.compile(r"^##\s+", re.M)
# A severity word or its inbox abbreviation, but not a longer word or a path segment (highly, src/low.py).
SEVERITY_WORD = re.compile(
    r"(?<![^\W_])(?<![./])(?:crit(?:ical)?|high|med(?:ium)?|low)(?![^\W_]|/|\.\w)", re.I)
ORDERED_ITEM = re.compile(r"\d+[.):]")
SETEXT_UNDERLINE = re.compile(r"\s*(?:=+|-+)\s*$")
UNREADABLE = {"digest": None, "error": "report_unreadable", "claimed": None, "findings": []}
BLOB_PURPOSES = ("docs", "codemap")
FIX_PURPOSES = ("acceptance", "audits")
PRECEDENCE = ("report_unreadable", "report_malformed", "report_repo_mismatch",
              "inventory_report_changed", "inventory_report_added", "inventory_report_removed",
              "ignored_unreadable_paths")


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
        text = _normalise(data.decode("utf-8"))
    except UnicodeDecodeError:
        sniffed = report_lib.split_report(_normalise(data.decode("utf-8", "replace")))[0].get("repo")
        return {**entry, "error": "report_malformed", "claimed": sniffed, "undecodable": True}
    meta, body = report_lib.split_report(text)
    if not meta:
        return {**entry, "error": "report_malformed"}
    entry["claimed"] = meta.get("repo")
    spans = _findings_spans(body)
    listed = "\n".join(body[start:end] for start, end in spans)
    if repo in (directory, entry["claimed"]) and (
        _unparsed_finding(body, spans)
        or len(FINDING_HEADING.findall(listed)) != len(report_lib.parse_findings(listed))
    ):
        return {**entry, "error": "report_malformed"}
    if meta.get("repo", directory) != directory or directory != repo:
        return {**entry, "error": "report_repo_mismatch"}
    rid = f"{directory}/{name[:-3]}"
    fp_repo = report_lib.report_repo(meta, str(path))
    parsed = report_lib.parse_findings(body)  # as the inbox reads it; every match sits in a Findings section
    findings = [
        {"id": f"{rid}#{f['n']}", "report": rid, "n": f["n"], "severity": f["severity"],
         "fingerprint": report_lib.fingerprint(fp_repo, f["location"], f["title"])}
        for f in parsed
    ]
    return {**entry, "findings": findings}


def _normalise(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _findings_spans(body: str) -> list[tuple[int, int]]:
    """(start, end) offsets of the text under every canonical `## Findings` heading."""
    spans = []
    for match in FINDINGS_SECTION.finditer(body):
        following = NEXT_SECTION.search(body, match.end())
        spans.append((match.end(), following.start() if following else len(body)))
    return spans


def _plain_prose(line: str, following: str) -> bool:
    """A line that names a severity yet cannot be a finding title in any markup.

    Only running text qualifies: it starts with a letter or a digit, is not an
    ordered list item, and is not underlined into a setext heading. A heading
    of any level, emphasis, a list item, a table row, a quote, HTML or a
    leading bracket all start with something else, however they are indented.
    """
    text = line.strip()
    return text[0].isalnum() and not ORDERED_ITEM.match(text) and not SETEXT_UNDERLINE.match(following)


def _unparsed_finding(body: str, spans: list[tuple[int, int]]) -> bool:
    """Whether the report may hold a finding the inbox would not list.

    The inbox lists exactly the report_lib.FINDING_RE lines, and readiness
    accepts those only inside a canonical Findings section. Every other line
    naming a severity must be plain prose. Code fences are read like any other
    text, as the inbox parser reads them.
    """
    lines = body.split("\n")
    read: set[int] = set()
    for match in report_lib.FINDING_RE.finditer(body):
        if not any(start <= match.start() and match.end() <= end for start, end in spans):
            return True
        read.update(range(body.count("\n", 0, match.start()), body.count("\n", 0, match.end()) + 1))
    following = [*lines[1:], ""]
    return any(
        index not in read and SEVERITY_WORD.search(line) and not _plain_prose(line, following[index])
        for index, line in enumerate(lines)
    )


def _scan_file(folder: Path, directory: str, name: str, repo: str) -> tuple[dict | None, bool]:
    """(inventory entry or None, ignored as unreadable) for one .md name in a real directory."""
    mine = directory == repo
    try:
        mode = os.lstat(folder / name).st_mode
    except OSError:
        return (UNREADABLE, False) if mine else (None, True)
    if stat.S_ISLNK(mode) or (mine and not stat.S_ISREG(mode)):
        return UNREADABLE, False
    if not stat.S_ISREG(mode):
        return None, False
    entry = _parse_report(folder / name, directory, name, repo)
    if mine or entry["claimed"] == repo:
        return entry, False
    # Unreadable or not UTF-8: it cannot be shown not to claim the repo.
    return None, entry["error"] == "report_unreadable" or entry.get("undecodable", False)


def _scan_directory(base: Path, directory: str, repo: str) -> tuple[dict[str, dict], list[str]]:
    """(inventory entries, ignored unreadable paths) for one name under reports/."""
    folder = base / directory
    mine = directory == repo
    try:
        mode = os.lstat(folder).st_mode
    except OSError:  # lstat needs only search permission on reports/ itself
        return {(f"{directory}/" if mine else "reports/"): UNREADABLE}, []
    if stat.S_ISLNK(mode) or (mine and not stat.S_ISDIR(mode)):
        return {f"{directory}/": UNREADABLE}, []
    if not stat.S_ISDIR(mode):
        return {}, []
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return ({f"{directory}/": UNREADABLE}, []) if mine else ({}, [f"{directory}/"])
    found: dict[str, dict] = {}
    ignored: list[str] = []
    for name in (name for name in names if name.endswith(".md")):
        entry, skipped = _scan_file(folder, directory, name, repo)
        if entry is not None:
            found[f"{directory}/{name}"] = entry
        if skipped:
            ignored.append(f"{directory}/{name}")
    return found, ignored


def scan_reports(root: Path, repo: str) -> tuple[dict[str, dict], list[str]]:
    """Every report in reports/<repo> plus reports elsewhere claiming the repo.

    Also returns the unreadable or non-UTF-8 paths elsewhere, relative to
    reports/: their contents cannot be shown not to claim the repo, so
    inventory_check keeps readiness pending on them. Anything unreadable or
    ambiguous at reports/ itself or under reports/<repo> is an inventory
    entry with the error report_unreadable, never an absence.
    """
    base = root / "reports"
    try:
        if not stat.S_ISDIR(os.lstat(base).st_mode):  # a symlink or a file: `find reports` lists nothing
            return {"reports/": UNREADABLE}, []
        directories = sorted(os.listdir(base))
    except FileNotFoundError:
        return {}, []
    except OSError:
        return {"reports/": UNREADABLE}, []
    found: dict[str, dict] = {}
    ignored: list[str] = []
    for directory in directories:
        entries, skipped = _scan_directory(base, directory, repo)
        found.update(entries)
        ignored.extend(skipped)
    return found, ignored


def report_digests(reports: dict[str, dict]) -> dict[str, str]:
    return {path: entry["error"] or entry["digest"] for path, entry in sorted(reports.items())}


def inventory_check(reports: dict[str, dict], expected: dict[str, str], ignored: list[str]) -> dict:
    items = []
    for path, entry in sorted(reports.items()):
        if entry["error"]:
            items.append({"path": path, "reason": entry["error"]})
        elif path not in expected:
            items.append({"path": path, "reason": "inventory_report_added"})
        elif expected[path] != entry["digest"]:
            items.append({"path": path, "reason": "inventory_report_changed"})
    hidden = set(ignored)  # a pinned report behind an unreadable path is unreadable, not removed
    items += [
        {"path": path, "reason": "report_unreadable" if {path, f"{path.split('/')[0]}/"} & hidden
         else "inventory_report_removed"}
        for path in sorted(expected.keys() - reports.keys())
    ]
    named = {name for item in items for name in (item["path"], f"{item['path'].split('/')[0]}/")}
    items += [{"path": path, "reason": "ignored_unreadable_paths"} for path in ignored if path not in named]
    if not items:
        return {"check": "inventory", "status": "passed", "reason": "inventory_matches", "reports": len(reports)}
    reason = min((item["reason"] for item in items), key=PRECEDENCE.index)
    pending = {"check": "inventory", "status": "pending", "reason": reason, "reports": items}
    return {**pending, "ignored_unreadable": ignored} if ignored else pending


# --------------------------------------------------------------- findings ---

def inbox_rows(root: Path, repo: str) -> dict[str, dict]:
    """Inbox state for every finding, hidden ones included; load_reports never writes.

    Raises OSError when the inbox skipped reports/ itself or anything under reports/<repo>.
    """
    ids, skipped = inbox.scan_report_ids(str(root))
    mine = [path for path in skipped if path == "reports/" or path.startswith(f"{repo}/")]
    if mine:
        raise OSError(f"inbox could not read {', '.join(mine)}")
    _, found = inbox.load_reports(str(root), ids)
    return {f"{item['report']}#{item['n']}": item for item in found}


def resolve_findings(root: Path, repo: str, reports: dict[str, dict]) -> tuple[list[dict], dict]:
    observed = [f for path in sorted(reports) if not reports[path]["error"] for f in reports[path]["findings"]]
    try:
        rows = inbox_rows(root, repo)
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
    reports, ignored = scan_reports(ctx.root, ctx.record["repo"])
    findings, found = resolve_findings(ctx.root, ctx.record["repo"], reports)
    evidence_checks, fixed, digests = evaluate_evidence(ctx)
    blockers, relied = blockers_check(ctx, findings, fixed, now)
    checks = [
        inventory_check(reports, ctx.policy["report_inventory"], ignored), found,
        assessment_check(ctx.policy["assessment"], findings, found["status"] == "passed"),
        *evidence_checks, blockers,
    ]
    return checks, {"inventory": report_digests(reports), "evidence": digests, "state": state}, relied


def observe_mutable(ctx: Context) -> dict:
    """The report inventory and evidence digests, re-read from disk."""
    return {"inventory": report_digests(scan_reports(ctx.root, ctx.record["repo"])[0]),
            "evidence": evidence_digests(ctx), "state": state_digests(ctx.root)}
