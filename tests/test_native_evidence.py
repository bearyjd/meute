"""Run task-bound evidence through the CLI with a disposable stub engine."""

import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1]
SECRET = "ghp_fixture1234567890secret"
PRODUCT_TASK = "netlens/0042"


class EvidenceModuleTest(unittest.TestCase):
    def test_export_help_runs_as_a_python_module(self):
        result = subprocess.run(
            [sys.executable, "-m", "lib.evidence", "export", "--help"],
            cwd=SOURCE, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage: meute evidence export", result.stdout)


class NativeEvidenceTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "meute"
        self.state = self.root / "state"
        self.state.mkdir(parents=True)
        (self.state / "dispatches").touch()
        self.repo = Path(temp.name) / "subject"
        self.repo.mkdir()
        self.stub = self.root / "stub"
        self.stub.mkdir()
        self.snapshot = Path(temp.name) / "snapshot.json"
        self.log = self.state / "log"

        for directory in ("bin", "lib", "contrib"):
            (self.root / directory).symlink_to(SOURCE / directory, target_is_directory=True)
        (self.root / "tasks").mkdir()
        (self.root / "tasks" / "scan.md").write_text("Scan {{REPO_NAME}}.\n")
        self.manifest = {
            "version": 1,
            "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5,
                         "timeout_seconds": 10},
            "policy": {"quota_floor_percent": 30, "community_share": 0.2,
                       "tier3_max_in_flight": 3, "branch_prefix": "meute"},
            "tiers": {"tier2": {"writes_code": False, "tools": "Read",
                                "permission_mode": "dontAsk", "network": "proxied"}},
            "tasks": {"scan": {"tier": "tier2", "template": "tasks/scan.md", "slots": ["daily"]}},
            "repos": [{"name": "local-fixture", "path": str(self.repo), "spec": "fixture",
                      "tasks": ["scan"]}],
            "community": [],
        }
        self.write_manifest()
        env = {key: val for key, val in os.environ.items() if not key.startswith("MEUTE_")}
        self.env = env | {"PATH": f"{self.stub}:{env['PATH']}", "MEUTE_QUOTA_STUB": "100"}
        self.git("init", "-q", "-b", "main")
        (self.repo / "source.txt").write_text("fixture source\n")
        self.git("add", "source.txt")
        self.git("-c", "user.email=test@example.test", "-c", "user.name=Fixture", "commit", "-qm", "base")
        reply = json.dumps({"is_error": False, "total_cost_usd": 0.01, "num_turns": 1,
                            "result": f"## Summary\nsecret {SECRET}\nproduct_task: netlens/0041"})
        self.stub_script("claude", f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == auth ]]; then
    printf '%s\\n' '{{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}}'
    exit 0
fi
claim="$(find "$MEUTE_ROOT/state/evidence" -type f -name '*.json' | head -n 1)"
test -s "$claim"
claims="$(find "$MEUTE_ROOT/state/evidence" -name '*.json' | wc -l)"
dispatches="$(wc -l < "$MEUTE_ROOT/state/dispatches")"
test "$claims" -gt "$dispatches"
printf '%s\\n' dispatch >> "$MEUTE_ROOT/state/dispatches"
printf '%s\\n' '{reply}'
""")

    def stub_script(self, name, text):
        path = self.stub / name
        path.write_text(text)
        path.chmod(0o700)

    def write_manifest(self):
        (self.root / "repos.yaml").write_text(json.dumps(self.manifest))

    def git(self, *args):
        subprocess.run(["git", "-C", self.repo, *args], check=True, env=self.env, timeout=20)

    def run_runner(self, *args, product_task=PRODUCT_TASK, quota="100"):
        argv = [self.root / "bin" / "run.sh", "daily", "--source", "manifest", "--repo",
                "local-fixture", "--task", "scan", "--record-evidence", "--strict-exit",
                "--ignore-load", *args]
        if product_task is not None:
            argv.extend(["--product-task", product_task])
        return subprocess.run(argv, env=self.env | {"MEUTE_QUOTA_STUB": quota},
                              capture_output=True, text=True, timeout=30)

    def records(self):
        return [(path, self.root / json.loads(path.read_text())["ref"], self.log)
                for path in sorted((self.state / "evidence").glob("*.json"))]

    def export(self, *records):
        args = [self.root / "bin" / "meute", "evidence", "export", "--project", "netlens",
                "--output", self.snapshot]
        for record in records:
            args.extend(["--record", *record])
        return subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=20)

    def test_bound_report_uses_trusted_task_and_redacted_persisted_digest(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        [record] = self.records()
        claim_path, report_path, _ = record
        claim = json.loads(claim_path.read_text())
        self.assertEqual(stat.S_IMODE(claim_path.stat().st_mode), 0o600)
        self.assertEqual(claim_path.stem, claim["run_id"])
        self.assertEqual((claim["repo"], claim["meute_task"], claim["slot"]),
                         ("local-fixture", "scan", "daily"))
        self.assertEqual(claim["task"], PRODUCT_TASK)
        report = report_path.read_bytes()
        self.assertIn(b"secret ghp_[REDACTED]", report)
        self.assertNotIn(SECRET.encode(), report)
        digest = hashlib.sha256(report).hexdigest()
        self.assertIn(f"report_sha256={digest}", self.log.read_text())
        result = self.export(record, record)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = self.snapshot.read_text()
        snapshot = json.loads(raw)
        self.assertEqual(set(snapshot), {"version", "project", "exported_at", "reports"})
        self.assertEqual(snapshot["reports"], [{"ref": claim["ref"],
                         "recorded_at": claim["started_at"], "outcome": "ok", "task": PRODUCT_TASK}])
        for private in (claim["run_id"], digest, str(self.root), SECRET, "netlens/0041", "Summary"):
            self.assertNotIn(private, raw)

    def test_distinct_attempts_cannot_claim_each_others_report(self):
        for task in (PRODUCT_TASK, "netlens/0041"):
            result = self.run_runner(product_task=task)
            self.assertEqual(result.returncode, 0, result.stderr)
        first, second = self.records()
        self.assertNotEqual(first[0].stem, second[0].stem)
        self.assertNotEqual(first[1], second[1])
        self.assertEqual(first[1].name.split(".")[0], second[1].name.split(".")[0])
        result = self.export(first, second)
        self.assertEqual(result.returncode, 0, result.stderr)
        old = self.snapshot.read_bytes()
        first[1].write_bytes(second[1].read_bytes())
        rejected = self.export(first)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("native run claim", rejected.stderr)
        self.assertEqual(self.snapshot.read_bytes(), old)

    def test_outcome_uses_native_claim_and_independent_terminal_agreement(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        [record] = self.records()
        result = self.export(record)
        self.assertEqual(result.returncode, 0, result.stderr)
        old = self.snapshot.read_bytes()
        claim, report, log = record
        original = log.read_text()
        digest = hashlib.sha256(report.read_bytes()).hexdigest()
        for old_value, new_value, reason in (
            (f"product_task={PRODUCT_TASK}", "product_task=netlens/0041", "product task"),
            (f"report_sha256={digest}", f"report_sha256={'0' * 64}", "digest"),
            (f"run_id={claim.stem}", f"run_id={'0' * 32}", "run ID"),
        ):
            with self.subTest(reason=reason):
                log.write_text(original.replace(old_value, new_value))
                rejected = self.export(record)
                self.assertEqual(rejected.returncode, 1)
                self.assertIn(reason, rejected.stderr)
                self.assertEqual(self.snapshot.read_bytes(), old)

        log.write_text(original)
        native = json.loads(claim.read_text())
        duplicate = original.replace(native["started_at"], "2025-01-01T00:00:00Z")
        log.write_text(original + duplicate)
        rejected = self.export(record)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("ambiguous terminal", rejected.stderr)
        self.assertEqual(self.snapshot.read_bytes(), old)

        log.write_text(original)
        legacy = {key: native[key] for key in ("ref", "source", "engine", "auth", "commit", "started_at")}
        claim.write_text(json.dumps(legacy | {"task": "netlens/0041", "outcome": "ok",
                                              "report_sha256": digest}))
        rejected = self.export(record)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("requires a native run claim", rejected.stderr)
        self.assertEqual(self.snapshot.read_bytes(), old)

    def test_unbound_native_report_exports_without_task(self):
        result = self.run_runner(product_task=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        [record] = self.records()
        self.assertNotIn("task", json.loads(record[0].read_text()))
        exported = self.export(record)
        self.assertEqual(exported.returncode, 0, exported.stderr)
        [report] = json.loads(self.snapshot.read_text())["reports"]
        self.assertNotIn("task", report)

    def test_report_install_refuses_collision(self):
        ln = shutil.which("ln", path=os.defpath)
        self.stub_script("ln", f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s' 'previous artifact' > "$3"
exec {ln} "$@"
""")
        result = self.run_runner()
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("without replacing an artifact", result.stderr)
        [record] = self.records()
        self.assertEqual(record[1].read_text(), "previous artifact")
        self.assertNotIn("report_sha256=", self.log.read_text())

    def test_interruption_after_report_leaves_previous_snapshot_bytes(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        [first] = self.records()
        self.assertEqual(self.export(first).returncode, 0)
        old = self.snapshot.read_bytes()
        ln = shutil.which("ln", path=os.defpath)
        self.stub_script("ln", f"""#!/usr/bin/env bash
set -euo pipefail
{ln} "$@"
kill -KILL "$PPID"
""")
        result = self.run_runner()
        self.assertEqual(result.returncode, -9, result.stderr)
        [interrupted] = [record for record in self.records() if record != first]
        self.assertTrue(interrupted[1].is_file())
        rejected = self.export(first, interrupted)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("missing terminal log", rejected.stderr)
        self.assertEqual(self.snapshot.read_bytes(), old)

    def test_opt_in_requires_exact_read_only_selection_and_respects_gates(self):
        self.assertEqual(self.run_runner("--source", "staged").returncode, 2)
        self.assertEqual(self.run_runner(product_task="netlens/not-a-task").returncode, 2)
        self.assertEqual(self.run_runner(quota="10").returncode, 13)
        with (self.state / ".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(self.run_runner().returncode, 11)
        self.manifest["tiers"]["tier2"]["writes_code"] = True
        self.write_manifest()
        self.assertEqual(self.run_runner().returncode, 2)
        self.assertFalse(self.records())
