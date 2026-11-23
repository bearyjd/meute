"""Run the real drain and runner against local repositories and a stub engine."""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

from runctl_helpers import runctl

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import manifest  # noqa: E402,F401 - plan_queue imports the loaded schema
import plan_queue  # noqa: E402


class StagedSourceTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.queue = self.state / "plan-queue.json"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for path in (ROOT / "bin").iterdir():
            (self.bin / path.name).symlink_to(path)
        (self.root / "lib").symlink_to(ROOT / "lib", target_is_directory=True)
        self.repo = self.make_repo("staged")
        enrolled = self.make_repo("enrolled")
        (self.root / "task.md").write_text("Fixture review of {{REPO_NAME}}\n")
        (self.root / "repos.local.yaml").write_text(yaml.safe_dump({
            "version": 1,
            "tiers": {
                "tier2": {"tools": "Read", "permission_mode": "dontAsk",
                          "writes_code": False, "network": "none"},
            },
            "tasks": {
                name: {"tier": "tier2", "template": "task.md", "slots": [slot]}
                for name, slot in (("daily-review", "daily"), ("weekly-review", "weekly"))
            },
            "repos": [{"name": "enrolled", "path": str(enrolled), "spec": "fixture",
                       "tasks": ["weekly-review"]}],
        }))

        stub = self.root / "stub"
        stub.mkdir()
        self.stub(stub / "claude", """#!/usr/bin/env bash
if [[ "$*" == "auth status --json" ]]; then
  echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
else
  echo '{"result":"## Summary\\nFixture report."}'
fi
""")
        load = self.root / "loadavg"
        load.write_text("0.10 0.10 0.10 1/100 1\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("MEUTE_")}
        self.env.update(
            PATH=f"{stub}{os.pathsep}{os.environ['PATH']}",
            MEUTE_CLAUDE_QUOTA_CMD="echo 100",
            MEUTE_SCOPE="off",
            MEUTE_LOADAVG=str(load),
            MEUTE_NCPU="4",
        )

    def make_repo(self, name):
        repo = self.root / name
        repo.mkdir()
        subprocess.run(["git", "init", "-qb", "main", repo], check=True)
        subprocess.run(
            ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "-qm", "initial", "--allow-empty"],
            check=True,
        )
        return repo

    def stub(self, path, text):
        path.write_text(text)
        path.chmod(0o700)

    def stage(self, task="daily-review", repo=None):
        self.queue.write_text(json.dumps({
            "version": 1,
            "entries": [{"name": "staged", "path": str(repo or self.repo), "task": task}],
        }))

    def invoke(self, *args):
        return subprocess.run(args, cwd=self.root, env=self.env, capture_output=True,
                              text=True, check=False, timeout=20)

    def web_runner(self, argv, cwd, out_path=None, on_start=None):
        result = self.invoke(*argv)
        if out_path is not None:
            with open(out_path, "a", encoding="utf-8") as handle:
                handle.write(result.stdout + result.stderr)
        return result.returncode, result.stdout

    def run_reports(self):
        log = self.state / "log"
        if not log.exists():
            return []
        return [
            field.removeprefix("report=")
            for row in log.read_text().splitlines()
            for field in row.split("\t")
            if field.startswith("report=")
        ]

    def assert_no_manifest_report(self):
        self.assertFalse(any(report.startswith("reports/enrolled/") for report in self.run_reports()),
                         self.run_reports())

    def test_web_plan_does_not_run_weekly_manifest_after_daily_retires_plan(self):
        self.stage()
        controller = runctl.RunController(str(self.root), runner=self.web_runner)
        controller.start("plan")
        controller.join(15)
        self.assertEqual(controller.status()["state"], "idle")
        self.assertEqual(controller.status()["stopped_reason"], "drain finished")
        self.assertFalse(self.queue.exists())
        self.assertEqual(len(self.run_reports()), 1, self.run_reports())
        self.assertTrue(self.run_reports()[0].startswith("reports/staged/"))

    def test_strict_absent_or_empty_slot_never_reads_manifest_queue(self):
        drain = self.invoke(self.bin / "meute", "drain", "weekly", "--source", "staged")
        self.assertEqual(drain.returncode, 0, drain.stderr)
        for queue_is_present in (False, True):
            with self.subTest(queue_is_present=queue_is_present):
                if queue_is_present:
                    self.stage()
                run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged",
                                  "--strict-exit")
                self.assertEqual(run.returncode, 14, run.stderr)
                self.assert_no_manifest_report()
        self.assertTrue(self.queue.exists())

    def test_strict_runner_marks_missing_plan_entry_without_manifest_fallback(self):
        self.stage("weekly-review", self.root / "missing")
        run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged", "--strict-exit")
        self.assertEqual(run.returncode, 14, run.stderr)
        self.assertIn("archived queue", run.stderr)
        self.assertFalse(self.queue.exists())
        self.assert_no_manifest_report()

    def test_attempted_staged_plan_is_archived_without_manifest_fallback(self):
        self.stage("weekly-review")
        (self.state / "plan-complete").write_text("plan/staged/weekly-review\tok\n")
        run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged", "--strict-exit")
        self.assertEqual(run.returncode, 14, run.stderr)
        self.assertIn("archived queue", run.stderr)
        self.assertFalse(self.queue.exists())
        self.assert_no_manifest_report()

    def test_staged_only_mode_honors_queue_lock_and_quota(self):
        self.stage("weekly-review")
        self.env["MEUTE_PLAN_QUEUE_LOCK_WAIT"] = "0"
        with (self.state / ".plan-lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged",
                              "--strict-exit")
            self.assertEqual(run.returncode, 11, run.stderr)
        self.env["MEUTE_CLAUDE_QUOTA_CMD"] = "echo 0"
        run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged", "--strict-exit")
        self.assertEqual(run.returncode, 14, run.stderr)
        self.assertIn("quota 0% below floor", run.stderr)
        self.assertTrue(self.queue.exists())
        self.assertEqual(self.run_reports(), [])

    def test_strict_plan_retired_between_drain_check_and_runner_selection(self):
        self.stage("weekly-review")
        (self.bin / "run.sh").rename(self.bin / "real-run.sh")
        self.stub(self.bin / "run.sh", """#!/usr/bin/env bash
root="$(dirname "$0")/.."
mv "$root/state/plan-queue.json" "$root/state/plan-queue.completed-fixture.json"
exec "$root/bin/real-run.sh" "$@"
""")
        drain = self.invoke(self.bin / "meute", "drain", "weekly", "--source", "staged")
        self.assertEqual(drain.returncode, 14, drain.stderr)
        self.assertFalse(self.queue.exists())
        self.assert_no_manifest_report()

    def test_invalid_staged_queue_stops_drain_and_runner(self):
        self.queue.write_text("invalid")
        drain = self.invoke(self.bin / "meute", "drain", "weekly", "--source", "staged")
        self.assertEqual(drain.returncode, 17, drain.stderr)
        run = self.invoke(self.bin / "run.sh", "weekly", "--source", "staged", "--strict-exit")
        self.assertEqual(run.returncode, 17, run.stderr)
        self.assertIn("code=plan-invalid", run.stderr)
        self.assertFalse(self.queue.exists())
        self.assert_no_manifest_report()

    def test_archiving_between_queue_existence_check_and_open_reads_empty(self):
        self.stage("weekly-review")
        queue = str(self.queue)
        with mock.patch("plan_queue.open", side_effect=FileNotFoundError(queue), create=True):
            self.assertEqual(plan_queue.build_plan_queue({}, queue, "weekly", str(self.root)), [])

    def test_scheduled_fallback_and_explicit_manifest_behavior_are_preserved(self):
        self.stage()
        scheduled = self.invoke(self.bin / "run.sh", "weekly", "--strict-exit")
        self.assertEqual(scheduled.returncode, 0, scheduled.stderr)
        before = self.queue.read_bytes()
        configured = self.invoke(self.bin / "meute", "drain", "weekly", "--source", "manifest")
        self.assertEqual(configured.returncode, 0, configured.stderr)
        self.assertEqual(self.queue.read_bytes(), before)
        self.assertEqual(len(self.run_reports()), 2)
        self.assertTrue(all(ref.startswith("reports/enrolled/") for ref in self.run_reports()))
