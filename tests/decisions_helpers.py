"""A disposable MEUTE_ROOT and CLI drivers for the durable-decision tests."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE / "lib"))

REPORT_A = "alpha/audit-a"
REPORT_B = "alpha/audit-b"
REPORT_EMPTY = "alpha/audit-none"

_BODY = """---
repo: alpha
task: audit-security
tier: tier2
lens: input-parsing
started: 2026-08-30T03:00:00-04:00
status: ok
---

## Summary
Findings present.

## Findings
"""


def _finding(severity, title, loc):
    return f"\n### [{severity}] {title}\n- **Location:** `{loc}`\n"


def clean_env(**extra):
    """The parent environment minus everything that steers meute or the quota probe."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("MEUTE_") or k in ("MEUTE_SCOPE",)}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["MEUTE_SCOPE"] = "off"
    env.update({k: v for k, v in extra.items() if v is not None})
    return env


class Fixture:
    """A MEUTE_ROOT whose bin/ and lib/ are the real ones, with three reports."""

    def __init__(self, testcase):
        temp = tempfile.TemporaryDirectory()
        testcase.addCleanup(temp.cleanup)
        self.tc = testcase
        self.root = Path(temp.name) / "meute"
        self.state = self.root / "state"
        self.state.mkdir(parents=True)
        for d in ("bin", "lib", "contrib"):
            (self.root / d).symlink_to(SOURCE / d, target_is_directory=True)
        (self.root / "reports" / "alpha").mkdir(parents=True)
        (self.root / "reports" / "alpha" / "audit-a.md").write_text(
            _BODY + _finding("CRITICAL", "One", "src/a.py:1")
            + _finding("HIGH", "Two", "src/b.py:2") + _finding("LOW", "Three", "src/c.py:3"))
        (self.root / "reports" / "alpha" / "audit-b.md").write_text(
            _BODY + _finding("HIGH", "Solo", "src/d.py:4"))
        (self.root / "reports" / "alpha" / "audit-none.md").write_text(
            _BODY.replace("## Findings\n", "## Notes\n") + "nothing\n")
        self.reports_file = self.state / "reports"
        self.receipts = self.state / "receipts" / "decisions"

    # -- drivers -----------------------------------------------------------
    def meute(self, *args, **env):
        return subprocess.run([str(self.root / "bin" / "meute"), *args], cwd=self.root,
                              env=clean_env(**env), capture_output=True, text=True, timeout=60)

    def decisions(self, *args, **env):
        return subprocess.run([sys.executable, "-B", str(SOURCE / "lib" / "decisions.py"), *args],
                              cwd=self.root, env=clean_env(MEUTE_ROOT=str(self.root), **env),
                              capture_output=True, text=True, timeout=60)

    def revision(self, rid, n):
        proc = self.decisions("revision", rid, str(n))
        self.tc.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def resolve(self, rid, n, key, rev, message="fixed upstream", operator=None, extra=(), **env):
        args = ["resolve", rid, "-f", str(n), "-m", message, "--request-key", key,
                "--expected-revision", rev, *extra]
        if operator:
            args += ["--operator", operator]
        return self.meute(*args, **env)

    def dismiss(self, rid, n, key, rev, reason="wont-fix", message="", operator=None, extra=(), **env):
        args = ["dismiss", rid, "-f", str(n), "-r", reason, "--request-key", key,
                "--expected-revision", rev, *extra]
        if message:
            args += ["-m", message]
        if operator:
            args += ["--operator", operator]
        return self.meute(*args, **env)

    # -- state readers -----------------------------------------------------
    def rows(self):
        return self.reports_file.read_bytes() if self.reports_file.exists() else b""

    def rows_for(self, key):
        return [ln for ln in self.rows().split(b"\n") if ln.split(b"\t", 1)[0] == key.encode()]

    def receipt_files(self):
        return sorted(p for p in self.receipts.glob("*.json")) if self.receipts.exists() else []

    def receipt_of(self, proc):
        return json.loads(proc.stdout)["receipt"]

    def only_receipt(self):
        files = self.receipt_files()
        self.tc.assertEqual(len(files), 1, files)
        return json.loads(files[0].read_text())

    def write_rows(self, data: bytes):
        self.reports_file.write_bytes(data)


def parse(proc):
    return json.loads(proc.stdout)
