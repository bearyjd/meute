#!/usr/bin/env python3
"""The triage inbox as data: everything a UI needs, nothing it should decide.

    python3 lib/inbox.py dump              -- the whole inbox as one JSON object
    python3 lib/inbox.py report <id>       -- one report's body (markdown)
    python3 lib/inbox.py counts            -- `reports_new=<n>`, for `meute status`
    python3 lib/inbox.py findings [--new|--all] --tsv
                                           -- one row per finding, for `meute findings`
    python3 lib/inbox.py findings [--new|--all] --json
                                           -- the same findings as a JSON array
    python3 lib/inbox.py verify [--repo R] < list-repos JSON lines
                                           -- verdicts into state/finding-status
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

import io
import json
import os
import re
import stat
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
import finding_status  # noqa: E402
import receipt_keys  # noqa: E402

SEVERITY_RANK = {s: i for i, s in enumerate(report_lib.SEVERITIES)}
DISMISS_REASONS = ("false-positive", "wont-fix", "out-of-scope",
                   "duplicate", "too-large", "other")
_LOG_FIELD = re.compile(r"(\w+)=([^\t]*)")


def _meute(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [os.path.join(ROOT, "bin", "meute"), *args],
        capture_output=True, text=True, check=check, cwd=ROOT,
    )


# ---------------------------------------------------------------- state ---

def _state_snapshot(root: str | None = None) -> tuple[dict[str, tuple[str, str, str]], dict]:
    """(rows, raw rows) from ONE read of state/reports.

    rows: {key: (state, when, note)} as text; raw rows: receipt_keys.read_rows'
    bytes shape, from the same bytes, so a finding's displayed state, note and
    revision can never come from two different versions of the file.
    """
    path = os.path.join(ROOT if root is None else root, "state", "reports")
    if not os.path.isfile(path):  # a directory, a FIFO: no decisions
        return {}, {}
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return {}, {}
    rows: dict[str, tuple[str, str, str]] = {}
    # Decoded exactly as open(path, encoding="utf-8") iterates the file.
    with io.TextIOWrapper(io.BytesIO(data), encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            # First row for a key wins, as bin/meute's kv_row; a key-only row
            # (no tab) is a decision with an empty state, not "new".
            rows.setdefault(parts[0], (parts[1] if len(parts) > 1 else "",
                                       parts[2] if len(parts) > 2 else "",
                                       parts[3] if len(parts) > 3 else ""))
    return rows, receipt_keys.parse_rows(data)


def _state_rows(root: str | None = None) -> dict[str, tuple[str, str, str]]:
    """state/reports as {key: (state, when, note)}. Keys are report ids or
    `report#n` for a single finding -- the same shape bin/meute writes."""
    return _state_snapshot(root)[0]


def scan_report_ids(root: str | None = None) -> tuple[list[str], list[str]]:
    """(report ids, skipped paths under reports/), for `root` or else ROOT.

    Regular files in real directories only: what bin/meute's `find -type f`
    lists, so the count and the list agree with `meute reports`. A path that
    could not be read, or a symlinked directory find does not descend, is
    skipped as find skips it, but named, so a caller can tell "no reports"
    from "reports I could not see".
    """
    base = os.path.join(ROOT if root is None else root, "reports")
    try:
        if not stat.S_ISDIR(os.lstat(base).st_mode):  # find does not descend a symlinked start point
            return [], ["reports/"]
        repos = sorted(os.listdir(base))
    except FileNotFoundError:
        return [], []
    except OSError:
        return [], ["reports/"]
    ids: list[str] = []
    skipped: list[str] = []
    for repo in repos:
        d = os.path.join(base, repo)
        try:
            mode = os.lstat(d).st_mode
            if stat.S_ISLNK(mode):
                skipped.append(f"{repo}/")
            if not stat.S_ISDIR(mode):
                continue
            names = sorted(os.listdir(d))
        except OSError:
            skipped.append(f"{repo}/")
            continue
        for name in (name for name in names if name.endswith(".md")):
            try:
                regular = stat.S_ISREG(os.lstat(os.path.join(d, name)).st_mode)
            except OSError:
                skipped.append(f"{repo}/{name}")
                continue
            if regular:
                ids.append(f"{repo}/{name[:-3]}")
    return ids, skipped


def _report_ids() -> list[str]:
    return scan_report_ids()[0]


def report_path(rid: str, root: str | None = None) -> str:
    return os.path.join(ROOT if root is None else root, "reports", rid + ".md")


def _order(meta: dict, rid: str) -> tuple:
    """Oldest report first: by its start time, then its id."""
    return (str(meta.get("started", "")), rid)


def _group(meta: dict, rid: str, repo: str, keyfps: list[tuple[str, str]]) -> dict:
    """One report as finding_status.superseded reads it."""
    return {"group": (repo, meta.get("task", ""), meta.get("lens", "")),
            "order": _order(meta, rid), "live": meta.get("status") == "ok",
            "findings": keyfps}


def _joins(occurrences: list, groups: list, rows: dict, root: str | None = None) -> tuple:
    """What every view adds to a finding's own row: inherited decisions,
    superseded keys, and state/finding-status (verdicts and claims)."""
    return (finding_status.inherited(occurrences, rows), finding_status.superseded(groups),
            finding_status.read_status(ROOT if root is None else root))


def _derive(key: str, rows: dict, joins: tuple) -> dict:
    """label and hidden as `findings` shows them; verdict, pr and claimed."""
    inherited, superseded, status = joins
    srow = status.get(key)
    verdict = srow[0] if srow else ""
    if verdict != "gone" and key in superseded:
        verdict = "superseded"
    own = rows.get(key)
    claim_pr = srow[3] if srow else ""
    label, hidden = finding_status.view(own[0] if own else None,
                                        inherited.get(key, ""), verdict, claim_pr)
    return {"label": label, "hidden": hidden, "verdict": verdict,
            "pr": finding_status.pr_of(srow, own[2] if own else ""),
            "claimed": label == "claimed"}


# --------------------------------------------------------------- reports ---

def load_reports(root: str | None = None, ids: list[str] | None = None) -> tuple[list[dict], list[dict]]:
    """(reports, findings). A finding row carries everything a list needs.

    Reads `root` or else ROOT, and the report ids already scanned there when given.
    """
    # One snapshot: the revision a decision is checked against must be the
    # revision of the very state and note shown with it. Revisions come from
    # the raw bytes, not `rows`: the decision path must agree with itself on a
    # row `_state_rows` would have to decode.
    rows, revisions = _state_snapshot(root)
    reports: list[dict] = []
    findings: list[dict] = []
    occurrences: list[tuple[str, str, tuple]] = []
    groups: list[dict] = []
    for rid in (scan_report_ids(root)[0] if ids is None else ids):
        try:
            meta, body = report_lib.read(report_path(rid, root))
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
            repo = report_lib.report_repo(meta, report_path(rid, root))
            keyfps: list[tuple[str, str]] = []
            for f in report_lib.parse_findings(body):
                fstate, fwhen, fnote = rows.get(f"{rid}#{f['n']}", ("new", "", ""))
                fp = report_lib.fingerprint(repo, f["location"], f["title"])
                occurrences.append((f"{rid}#{f['n']}", fp, _order(meta, rid)))
                keyfps.append((f"{rid}#{f['n']}", fp))
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
                    "fingerprint": fp,
                    "base": str(meta.get("base", "")).rpartition("@")[2],
                    "revision": receipt_keys.revision(revisions, f"{rid}#{f['n']}"),
                })
                entry["findings"] += 1
            groups.append(_group(meta, rid, repo, keyfps))
        reports.append(entry)
    joins = _joins(occurrences, groups, rows, root)
    for f in findings:
        key = f"{f['report']}#{f['n']}"
        f["inherited"] = joins[0].get(key, "")
        derived = _derive(key, rows, joins)
        f.update({k: derived[k] for k in ("verdict", "pr", "hidden", "claimed")})
    findings.sort(key=lambda f: (f["repo"], f["rank"], f["report"], f["n"]))
    return reports, findings


def count_new_reports() -> int:
    """Reports with no decision recorded: what `meute reports --new` lists.
    Reads no report bodies, so an unreadable one still counts, as it does there."""
    rows = _state_rows()
    return sum(1 for rid in _report_ids() if rows.get(rid, ("new",))[0] == "new")


def findings_tsv(only_new: bool) -> list[str]:
    """`repo rank severity report#n STATE title` rows, tab separated, unsorted:
    the shape bin/meute's cmd_findings sorts and lays out. One process for every
    report, where the shell version spawned several per finding."""
    rows = _state_rows()
    found: list[tuple] = []
    occurrences: list[tuple[str, str, tuple]] = []
    groups: list[dict] = []
    for rid in _report_ids():
        try:
            meta, body = report_lib.read(report_path(rid))
        except Exception as e:  # skip it, but say so: never a silent "no findings"
            sys.stderr.write(f"meute: skipping unreadable report {rid}: {e}\n")
            continue
        if not report_lib.has_findings_section(body):
            continue
        repo = meta.get("repo") or ("" if meta.get("repo") == "" else "?")
        fp_repo = report_lib.report_repo(meta, report_path(rid))
        keyfps: list[tuple[str, str]] = []
        for f in report_lib.parse_findings(body):
            key = f"{rid}#{f['n']}"
            fp = report_lib.fingerprint(fp_repo, f["location"], f["title"])
            occurrences.append((key, fp, _order(meta, rid)))
            keyfps.append((key, fp))
            found.append((repo, f, key))
        groups.append(_group(meta, rid, fp_repo, keyfps))
    joins = _joins(occurrences, groups, rows)
    out: list[str] = []
    for repo, f, key in found:
        derived = _derive(key, rows, joins)
        if only_new and derived["hidden"]:
            continue
        state = derived["label"]
        out.append("\t".join((
            repo, str(SEVERITY_RANK[f["severity"]]), f["severity"],
            key, "NEW" if state == "new" else state,
            f["title"].split("\t")[0])))
    return out


def findings_json(only_new: bool) -> list[dict]:
    """`meute findings --json`: the contract external fix workflows read and
    write back through `meute claim` and `meute resolve --pr` (P1.7).
    `revision` is the value `meute resolve|dismiss --expected-revision` takes."""
    _, findings = load_reports()
    out: list[dict] = []
    for f in findings:
        if only_new and f["hidden"]:
            continue
        out.append({
            "id": f"{f['report']}#{f['n']}", "report": f["report"], "n": f["n"],
            "fingerprint": f["fingerprint"], "repo": f["repo"],
            "severity": f["severity"], "title": f["title"],
            "location": f["location"], "base": f["base"],
            "state": "claimed" if f["claimed"] else f["state"],
            "inherited": f["inherited"], "verdict": f["verdict"], "pr": f["pr"],
            "revision": f["revision"],
        })
    return out


def verify(repo_paths: dict[str, str], only_repo: str = "") -> dict[str, int]:
    """`meute findings verify`: a verdict for every undecided finding, written
    to state/finding-status (claims kept). Returns counts per verdict."""
    rows = _state_rows()
    results: dict[str, tuple[str, str]] = {}
    counts = {v: 0 for v in finding_status.VERDICTS}
    now = subprocess.run(["date", "--iso-8601=seconds"], capture_output=True,
                         text=True).stdout.strip()
    for rid in _report_ids():
        try:
            meta, body = report_lib.read(report_path(rid))
        except Exception as e:
            sys.stderr.write(f"meute: skipping unreadable report {rid}: {e}\n")
            continue
        repo = report_lib.report_repo(meta, report_path(rid))
        if (only_repo and repo != only_repo) or not report_lib.has_findings_section(body):
            continue
        todo = [f for f in report_lib.parse_findings(body) if f"{rid}#{f['n']}" not in rows]
        if not todo:
            continue
        head, verdicts = finding_status.verify_report(
            repo_paths.get(repo, ""), meta.get("base", ""),
            [report_lib._norm_path(f["location"]) if f["location"] else "" for f in todo])
        for f, verdict in zip(todo, verdicts):
            results[f"{rid}#{f['n']}"] = (verdict, head)
            counts[verdict] += 1
    # Re-read under the lock: the git work above can take minutes, and a
    # claim written meanwhile must keep its pr column.
    with finding_status.locked(ROOT):
        status = finding_status.read_status(ROOT)
        for key, (verdict, head) in results.items():
            pr = status.get(key, ["", "", "", ""])[3]
            status[key] = [verdict, head, now, pr]
        finding_status.write_status(ROOT, status)
    return counts


def finding_body(rid: str, n: int, *, bounded=False, root: str | None = None) -> str:
    """The markdown of one finding, from its `###` header to the next.

    Reads `root` or else ROOT."""
    if bounded:
        repo, _, name = rid.partition("/")
        _, body = report_lib.read_bounded(os.path.join(ROOT if root is None else root, "reports"),
                                          repo, name)
    else:
        _, body = report_lib.read(report_path(rid, root))
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
    # `quota` remains the Claude value for compatible consumers, but its
    # engine is explicit.  A Claude snapshot must never suggest that Codex is
    # available: Codex only reports a value from its dedicated probe.
    out: dict = {"quota": None, "quota_source": None, "quota_engine": "claude",
                 "codex_quota": None, "codex_quota_source": None,
                 "budget": None, "week": _week(),
                 "runs": 0, "cost": 0.0, "last_run": None, "declined": 0}
    try:
        probe = subprocess.run([os.path.join(ROOT, "bin", "quota.sh"), "--engine", "claude", "--with-source"],
                               capture_output=True, text=True, check=True).stdout.split()
        out["quota"], out["quota_source"] = int(probe[0]), probe[1]
    except Exception:
        pass
    try:
        probe = subprocess.run([os.path.join(ROOT, "bin", "quota.sh"), "--engine", "codex", "--with-source"],
                               capture_output=True, text=True, check=True).stdout.split()
        out["codex_quota"], out["codex_quota_source"] = int(probe[0]), probe[1]
    except Exception:
        pass
    try:
        policy = json.loads(subprocess.run(
            # The policy a run obeys: the manifest's, with any override in force.
            [SYSTEM_PYTHON, os.path.join(HERE, "manifest.py"), "policy-effective",
             os.environ.get("MEUTE_MANIFEST") or _manifest(),
             os.path.join(ROOT, "state", "policy-override")],
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
                if fields.get("code") == "died":
                    continue  # the runner died before any engine ran
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
    ids, unreadable = scan_report_ids()
    reports, findings = load_reports(ids=ids)
    return {
        "unreadable": unreadable,
        "status": load_status(),
        "reports": reports,
        "findings": findings,
        "branches": load_branches(),
        "dismiss_reasons": list(DISMISS_REASONS),
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
    if cmd in ("dump", "counts", "findings", "verify"):
        # A note, never an exit code: the listing below is what find could see.
        for path in scan_report_ids()[1]:
            sys.stderr.write(f"meute: skipping unreadable reports path {path}\n")
    if cmd == "dump":
        print(json.dumps(dump()))
    elif cmd == "report" and args:
        _, body = report_lib.read(report_path(args[0]))
        _meute("show", args[0], check=False)  # marks it read, same as the CLI
        sys.stdout.write(body)
    elif cmd == "counts":
        print(f"reports_new={count_new_reports()}")
    elif cmd == "findings" and "--tsv" in args:
        for row in findings_tsv("--new" in args):
            print(row)
    elif cmd == "findings" and "--json" in args:
        print(json.dumps(findings_json("--all" not in args)))
    elif cmd == "verify":
        # repo name -> path, as `manifest.py list-repos` JSON lines on stdin
        paths = {}
        for line in sys.stdin:
            if line.strip():
                r = json.loads(line)
                paths.setdefault(r.get("name", ""), r.get("path", ""))
        only = args[args.index("--repo") + 1] if "--repo" in args[:-1] else ""
        counts = verify(paths, only)
        print(" ".join(f"{k}={v}" for k, v in counts.items()))
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
