#!/usr/bin/env python3
"""Report reader for meute.

bin/meute shells out to this to turn a report on disk into something a list view
can show. The runner writes reports (bin/run.sh:write_report); nothing here ever
modifies one -- a report is immutable once written, and its triage state lives
separately in state/reports.

Subcommands
    meta     <path>   -- front-matter as a JSON object
    summary  <path>   -- one-line digest for a list view
    findings <path>   -- JSON list of findings, for `meute promote` to index into
"""

from __future__ import annotations

import json
import re
import sys

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")
ABBREV = {"CRITICAL": "CRIT", "HIGH": "HIGH", "MEDIUM": "MED", "LOW": "LOW"}

FINDING_RE = re.compile(r"^###\s+\[(CRITICAL|HIGH|MEDIUM|LOW)\]\s*(.*)$", re.M)
TEST_RE = re.compile(r"^###\s+\d+\.\s*(.*)$", re.M)
LOCATION_RE = re.compile(r"^-\s+\*\*Location:\*\*\s*(.*)$", re.M)
FAILED_MARKER = "# Run produced no report"


class ReportError(Exception):
    """Raised for a report this tool cannot make sense of."""


def read(path: str) -> tuple[dict, str]:
    """Split a report into (front-matter, body)."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise ReportError(f"{path}: {error.strerror}") from error

    meta: dict = {}
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            for line in text[4:end].splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    meta[key.strip()] = value.strip()
            body = text[end + 5:]
    return meta, body


def section(body: str, heading: str) -> str:
    """Return the text under a `## heading`, up to the next `##`."""
    match = re.search(rf"^##\s+{re.escape(heading)}\s*$", body, re.M)
    if not match:
        return ""
    rest = body[match.end():]
    nxt = re.search(r"^##\s+", rest, re.M)
    return rest[:nxt.start()] if nxt else rest


def parse_findings(body: str) -> list:
    """Findings from an audit report, numbered from 1 in document order."""
    out = []
    matches = list(FINDING_RE.finditer(body))
    for index, match in enumerate(matches, 1):
        end = matches[index].start() if index < len(matches) else len(body)
        block = body[match.end():end]
        location = LOCATION_RE.search(block)
        out.append({
            "n": index,
            "severity": match.group(1),
            "title": match.group(2).strip(),
            "location": location.group(1).strip().strip("`") if location else "",
            "block": block.strip(),
        })
    return out


def summarise(meta: dict, body: str) -> str:
    """One line for a list view. Never raises -- an odd report still gets a row."""
    if FAILED_MARKER in body or meta.get("status") not in (None, "ok"):
        detail = meta.get("status", "error")
        return f"run failed ({detail})"

    task = meta.get("task", "")
    if task == "audit-security":
        findings = parse_findings(body)
        if not findings:
            return "no findings"
        counts = {}
        for finding in findings:
            counts[finding["severity"]] = counts.get(finding["severity"], 0) + 1
        return " ".join(f"{ABBREV[s]}×{counts[s]}" for s in SEVERITIES if s in counts)

    if task == "gen-tests":
        tests = TEST_RE.findall(section(body, "Tests added"))
        if not tests:
            return "no tests added"
        env = section(body, "Environment").lower()
        state = "green" if "green" in env else ("failing" if "fail" in env else "unverified")
        return f"+{len(tests)} tests, {state}"

    summary = section(body, "Summary").strip()
    first = next((ln.strip() for ln in summary.splitlines() if ln.strip()), "")
    return (first[:57] + "...") if len(first) > 60 else (first or "-")


def cmd_meta(args: list) -> int:
    meta, _ = read(args[0])
    print(json.dumps(meta))
    return 0


def cmd_summary(args: list) -> int:
    meta, body = read(args[0])
    print(summarise(meta, body))
    return 0


def cmd_findings(args: list) -> int:
    meta, body = read(args[0])
    if meta.get("task") == "gen-tests":
        raise ReportError("findings: only audit-style reports carry findings")
    print(json.dumps(parse_findings(body)))
    return 0


COMMANDS = {"meta": cmd_meta, "summary": cmd_summary, "findings": cmd_findings}


def fail(message: str) -> int:
    sys.stderr.write(f"meute/report: {message}\n")
    return 2


def main(argv: list) -> int:
    if len(argv) < 3 or argv[1] not in COMMANDS:
        sys.stderr.write(__doc__ or "")
        return 2
    try:
        return COMMANDS[argv[1]](argv[2:])
    except ReportError as error:
        return fail(str(error))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
