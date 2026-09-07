#!/usr/bin/env python3
"""The triage inbox as data: everything a UI needs, nothing it should decide.

    python3 lib/inbox.py dump              -- the whole inbox as one JSON object
    python3 lib/inbox.py report <id>       -- one report's body (markdown)
    python3 lib/inbox.py promote <id> <n>
    python3 lib/inbox.py dismiss <id> <n> <reason> [message]
    python3 lib/inbox.py resolve <id> <n> <message>

Reads what the runner writes (reports/**/*.md, state/reports, state/log) with the
same parser the CLI uses (lib/report.py). Every WRITE goes through `bin/meute`,
so promote/dismiss/resolve have exactly one implementation and the TUI cannot
drift from the CLI. The runner never imports this file: PRP-003's hard
invariant is that cron succeeds whether or not any UI exists.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("MEUTE_ROOT") or os.path.dirname(HERE)
# The runner's python, not whichever interpreter imported this file: the TUI
# runs in its own venv, which deliberately has no PyYAML, and manifest.py
# needs it. sys.executable there silently failed the policy read.
SYSTEM_PYTHON = os.environ.get("MEUTE_PYTHON", "python3")
sys.path.insert(0, HERE)
import report as report_lib  # noqa: E402

SEVERITY_RANK = {s: i for i, s in enumerate(report_lib.SEVERITIES)}
_LOG_FIELD = re.compile(r"(\w+)=([^\t]*)")


def _meute(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [os.path.join(ROOT, "bin", "meute"), *args],
        capture_output=True, text=True, check=check, cwd=ROOT,
    )


# ---------------------------------------------------------------- state ---

def _state_rows() -> dict[str, tuple[str, str, str]]:
    """state/reports as {key: (state, when, note)}. Keys are report ids or
    `report#n` for a single finding -- the same shape bin/meute writes."""
    path = os.path.join(ROOT, "state", "reports")
    rows: dict[str, tuple[str, str, str]] = {}
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                rows[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "",
                                  parts[3] if len(parts) > 3 else "")
    return rows


def _report_ids() -> list[str]:
    base = os.path.join(ROOT, "reports")
    ids: list[str] = []
    if not os.path.isdir(base):
        return ids
    for repo in sorted(os.listdir(base)):
        d = os.path.join(base, repo)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".md"):
                ids.append(f"{repo}/{name[:-3]}")
    return ids


def report_path(rid: str) -> str:
    return os.path.join(ROOT, "reports", rid + ".md")


# --------------------------------------------------------------- reports ---

def load_reports() -> tuple[list[dict], list[dict]]:
    """(reports, findings). A finding row carries everything a list needs."""
    rows = _state_rows()
    reports: list[dict] = []
    findings: list[dict] = []
    for rid in _report_ids():
        try:
            meta, body = report_lib.read(report_path(rid))
        except Exception as e:  # a malformed report is a row, not a crash
            reports.append({"id": rid, "repo": rid.split("/")[0], "task": "?",
                            "state": "unreadable", "summary": f"unreadable: {e}"})
            continue
        state, when, note = rows.get(rid, ("new", "", ""))
        entry = {
            "id": rid,
            "repo": meta.get("repo") or rid.split("/")[0],
            "task": meta.get("task", "?"),
            "lens": meta.get("lens", ""),
            "date": str(meta.get("started", "")).split("T")[0],
            "status": meta.get("status", ""),
            "cost": meta.get("cost_usd", ""),
            "state": state,
            "decided_at": when,
            "note": note,
            "summary": report_lib.summarise(meta, body),
            "findings": 0,
        }
        if report_lib.has_findings_section(body):
            for f in report_lib.parse_findings(body):
                fstate, fwhen, fnote = rows.get(f"{rid}#{f['n']}", ("new", "", ""))
                findings.append({
                    "report": rid,
                    "n": f["n"],
                    "repo": entry["repo"],
                    "task": entry["task"],
                    "lens": entry["lens"],
                    "date": entry["date"],
                    "severity": f["severity"],
                    "rank": SEVERITY_RANK.get(f["severity"], 9),
                    "title": f["title"],
                    "location": f.get("location", ""),
                    "state": fstate,
                    "decided_at": fwhen,
                    "note": fnote,
                })
                entry["findings"] += 1
        reports.append(entry)
    findings.sort(key=lambda f: (f["repo"], f["rank"], f["report"], f["n"]))
    return reports, findings


def finding_body(rid: str, n: int) -> str:
    """The markdown of one finding, from its `###` header to the next."""
    _, body = report_lib.read(report_path(rid))
    heads = list(report_lib.FINDING_RE.finditer(body))
    if n < 1 or n > len(heads):
        return ""
    start = heads[n - 1].start()
    end = heads[n].start() if n < len(heads) else len(body)
    chunk = body[start:end]
    # The last finding runs into the next top-level section; cut there.
    # Search from the second line so the finding's own `### ` header is skipped.
    first_nl = chunk.find("\n")
    nxt = re.search(r"^## ", chunk[first_nl + 1:], re.M) if first_nl >= 0 else None
    return chunk[: first_nl + 1 + nxt.start()] if nxt else chunk


# ---------------------------------------------------------------- status ---

def _week() -> str:
    return subprocess.run(["date", "+%G-%V"], capture_output=True, text=True).stdout.strip()


def load_status() -> dict:
    out: dict = {"quota": None, "quota_source": None, "budget": None, "week": _week(),
                 "runs": 0, "cost": 0.0, "last_run": None, "declined": 0}
    try:
        probe = subprocess.run([os.path.join(ROOT, "bin", "quota.sh"), "--with-source"],
                               capture_output=True, text=True, check=True).stdout.split()
        out["quota"], out["quota_source"] = int(probe[0]), probe[1]
    except Exception:
        pass
    try:
        policy = json.loads(subprocess.run(
            [SYSTEM_PYTHON, os.path.join(HERE, "manifest.py"), "policy",
             os.environ.get("MEUTE_MANIFEST") or _manifest()],
            capture_output=True, text=True, check=True).stdout)
        out["floor"] = policy.get("quota_floor_percent")
        out["ceiling"] = policy.get("weekly_cost_usd") or policy.get("weekly_runs")
    except Exception:
        out["floor"] = None
        out["ceiling"] = None
    log = os.path.join(ROOT, "state", "log")
    if os.path.isfile(log):
        with open(log, encoding="utf-8") as fh:
            for line in fh:
                fields = dict(_LOG_FIELD.findall(line))
                if fields.get("week") != out["week"]:
                    continue
                if fields.get("status") == "skipped":
                    out["declined"] += 1
                    continue
                out["runs"] += 1
                try:
                    out["cost"] += float(fields.get("cost", "0") or 0)
                except ValueError:
                    pass
                out["last_run"] = line.split("\t")[0]
    out["cost"] = round(out["cost"], 2)
    return out


def _manifest() -> str:
    local = os.path.join(ROOT, "repos.local.yaml")
    return local if os.path.isfile(local) else os.path.join(ROOT, "repos.yaml")


def load_branches() -> list[dict]:
    try:
        out = _meute("branches", "--json").stdout
    except subprocess.CalledProcessError:
        return []
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def dump() -> dict:
    reports, findings = load_reports()
    return {
        "status": load_status(),
        "reports": reports,
        "findings": findings,
        "branches": load_branches(),
        "dismiss_reasons": ["false-positive", "wont-fix", "out-of-scope",
                            "duplicate", "too-large", "other"],
    }


# --------------------------------------------------------------- actions ---

def act(verb: str, rid: str, n: int, *rest: str) -> dict:
    """promote | dismiss | resolve, through bin/meute. Returns {ok, message}."""
    args = [verb, rid, "-f", str(n)]
    if verb == "dismiss":
        reason = rest[0] if rest else ""
        args += ["-r", reason]
        if len(rest) > 1 and rest[1]:
            args += ["-m", rest[1]]
    elif verb == "resolve":
        args += ["-m", rest[0] if rest else ""]
    elif verb != "promote":
        return {"ok": False, "message": f"unknown action {verb!r}"}
    proc = _meute(*args, check=False)
    text = (proc.stderr or proc.stdout).strip()
    return {"ok": proc.returncode == 0, "message": text}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write(__doc__ or "")
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "dump":
        print(json.dumps(dump()))
    elif cmd == "report" and args:
        _, body = report_lib.read(report_path(args[0]))
        _meute("show", args[0], check=False)  # marks it read, same as the CLI
        sys.stdout.write(body)
    elif cmd in ("promote", "dismiss", "resolve") and len(args) >= 2:
        result = act(cmd, args[0], int(args[1]), *args[2:])
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    else:
        sys.stderr.write(__doc__ or "")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
