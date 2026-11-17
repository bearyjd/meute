"""Tests for tui/runctl.py. A fake runner stands in for bin/meute, bin/run.sh and
lib/manifest.py; nothing here runs the real fleet or touches the real state/."""
import os
import shutil
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runctl_helpers import ALPHA, BETA, SCAN, RunCtlCase, iso, name_for, runctl  # noqa: E402

class EnqueueTests(RunCtlCase):
    def test_enqueue_rejects_empty(self):
        with self.assertRaises(ValueError):
            self.ctl.enqueue([])
        self.assertEqual(self.fleet.calls, [])

    def test_enqueue_rejects_path_not_in_fresh_plan(self):
        with self.assertRaises(ValueError):
            self.ctl.enqueue([ALPHA, "/scan root/projects/private-docs"])
        self.assertTrue(any("--json" in c for c in self.fleet.calls), "plan must be re-run")
        self.assertFalse(any("--enqueue" in c for c in self.fleet.calls))
        self.assertFalse(os.path.exists(self.path("plan-queue.json")))

    def test_enqueue_rejects_a_collapsed_duplicate(self):
        """meute plan lists a copy of a repository under `duplicates`, never under
        `items`: the fresh-plan check alone must refuse it."""
        dup = "/scan root/projects/output/alpha copy"
        self.fleet.duplicates = [{"path": dup, "of": ALPHA, "reason": "duplicate of " + ALPHA}]
        with self.assertRaises(ValueError) as cm:
            self.ctl.enqueue([ALPHA, dup])
        self.assertIn(dup, str(cm.exception))
        self.assertFalse(any("--enqueue" in c for c in self.fleet.calls))
        self.assertFalse(os.path.exists(self.path("plan-queue.json")))

    def test_enqueue_rejects_non_string_and_relative_paths(self):
        for bad in ([3], ["relative/path"], "not-a-list", [ALPHA + "\n"]):
            with self.assertRaises(ValueError):
                self.ctl.enqueue(bad)
        self.assertFalse(any("--enqueue" in c for c in self.fleet.calls))

    def test_enqueue_passes_only_flags_for_each_path(self):
        result = self.ctl.enqueue([ALPHA, BETA, ALPHA])
        enq = [c for c in self.fleet.calls if "--enqueue" in c]
        self.assertEqual(len(enq), 1)
        self.assertEqual(enq[0][1:], ["plan", "--enqueue", "--only", ALPHA, "--only", BETA, "--", SCAN])
        self.assertTrue(enq[0][0].endswith(os.path.join("bin", "meute")))
        self.assertEqual(result, {"ok": True, "message": result["message"], "staged": 2})

    def test_enqueue_failure_reports_not_ok(self):
        self.fleet.enqueue_rc = 1
        result = self.ctl.enqueue([ALPHA])
        self.assertFalse(result["ok"])
        self.assertEqual(result["staged"], 0)

    def test_enqueue_while_running_conflicts(self):
        self.ctl.enqueue([ALPHA])
        step, entered, release = self.blocking_step(name_for(ALPHA))
        self.fleet.drains = [lambda: step()[0]]
        self.ctl.start()
        self.assertTrue(entered.wait(5))
        try:
            with self.assertRaises(runctl.RunConflict):
                self.ctl.enqueue([BETA])
        finally:
            release.set()
            self.ctl.join(5)


class StartTests(RunCtlCase):
    def write_hold(self, until):
        with open(self.path("hold"), "w") as f:
            f.write(f"hold\t{until}\tgone fishing\n")

    def test_start_conflict_when_hold_file_exists(self):
        self.ctl.enqueue([ALPHA])
        self.write_hold(int(time.time()) + 3600)
        with self.assertRaises(runctl.RunConflict):
            self.ctl.start()
        self.assertEqual(self.fleet.drain_calls(), [])

    def test_start_ignores_expired_hold(self):
        self.ctl.enqueue([ALPHA])
        self.write_hold(int(time.time()) - 60)
        self.run_to_end()
        self.assertEqual(len(self.fleet.drain_calls()), 2)

    def test_start_conflict_when_already_running(self):
        self.ctl.enqueue([ALPHA])
        entered, release = threading.Event(), threading.Event()

        def step():
            entered.set()
            release.wait(5)
            return 0
        self.fleet.drains = [step]
        self.ctl.start()
        self.assertTrue(entered.wait(5))
        try:
            with self.assertRaises(runctl.RunConflict):
                self.ctl.start()
        finally:
            release.set()
            self.ctl.join(5)

    def test_start_with_nothing_staged_is_value_error(self):
        with self.assertRaises(ValueError):
            self.ctl.start()

    def test_start_rejects_an_unknown_source(self):
        self.ctl.enqueue([ALPHA])
        with self.assertRaises(ValueError):
            self.ctl.start("everything")


class DrainTests(RunCtlCase):
    """The page starts `meute drain` and reads its exit status (P1.3, D1)."""

    def drain_argv(self):
        return [c[1:] for c in self.fleet.drain_calls()]

    def test_plan_source_drains_daily_then_weekly(self):
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.drains = [self.fleet.drained(name_for(ALPHA), name_for(BETA))]
        status = self.run_to_end()
        self.assertEqual(self.drain_argv(), [["drain", "daily", "--source", "plan"],
                                             ["drain", "weekly", "--source", "plan"]])
        self.assertEqual(self.fleet.run_calls(), [])  # the page never calls run.sh itself
        self.assertEqual((status["total"], status["done"], status["remaining"]), (2, 2, 0))
        self.assertEqual(status["stopped_reason"], "drain finished")

    def test_manifest_source_needs_no_staged_plan(self):
        self.ctl.start("manifest")
        self.ctl.join(5)
        self.assertEqual(self.drain_argv(), [["drain", "daily", "--source", "manifest"],
                                             ["drain", "weekly", "--source", "manifest"]])

    def test_default_source_is_the_staged_plan(self):
        self.ctl.enqueue([ALPHA])
        self.run_to_end()
        self.assertEqual(self.drain_argv()[0][-1], "plan")

    def test_a_stop_class_exit_ends_the_run_with_its_reason(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.drains = [lambda: 12, lambda: 0]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.drain_calls()), 1)
        self.assertIn("budget", status["stopped_reason"])

    def test_nothing_eligible_in_daily_still_runs_weekly(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.drains = [lambda: 14, lambda: 0]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.drain_calls()), 2)
        self.assertEqual(status["stopped_reason"], "drain finished")

    def test_repeated_failures_are_reported(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.drains = [lambda: 1]
        status = self.run_to_end()
        self.assertIn("failed", status["stopped_reason"])

    def test_stop_signals_the_drain_not_the_item_and_skips_weekly(self):
        self.ctl.enqueue([ALPHA])
        entered, release = threading.Event(), threading.Event()

        def step():
            entered.set()
            release.wait(5)
            return 143
        self.fleet.drains = [step, lambda: 0]
        killed = []
        with mock.patch.object(runctl.os, "kill", lambda pid, sig: killed.append((pid, sig))):
            self.ctl.start()
            self.assertTrue(entered.wait(5))
            self.ctl.stop()
            self.assertEqual(self.ctl.status()["state"], "stopping")
            release.set()
            self.ctl.join(5)
        self.assertEqual(killed, [(self.fleet.drain_pid, signal.SIGTERM)])
        self.assertEqual(len(self.fleet.drain_calls()), 1)
        self.assertEqual(self.ctl.status()["stopped_reason"], "stopped")


class StatusTests(RunCtlCase):
    def test_status_counts_from_queue_and_log(self):
        self.fleet.tasks = ["audit", "lint"]
        self.ctl.enqueue([ALPHA, BETA])
        a, b = name_for(ALPHA), name_for(BETA)
        self.fleet.ok(a, "audit")()
        self.fleet.error(b, "lint")()
        self.fleet.ok(a, "audit")()  # a repeat counts once
        self.fleet.skip("quota")()
        status = self.ctl.status()
        self.assertEqual((status["total"], status["done"], status["remaining"]), (4, 2, 2))
        self.assertEqual(status["state"], "idle")
        self.assertIsNone(status["current"])
        self.assertEqual([r["status"] for r in status["recent"]], ["ok", "error", "ok", "skipped"])
        self.assertEqual(set(status["recent"][0]), {"time", "status", "repo", "task"})

    def test_status_ignores_log_lines_before_enqueue(self):
        a = name_for(ALPHA)
        self.fleet.log(f"{iso(-3600)}\tstatus=ok\trepo={a}\ttask=audit")
        self.ctl.enqueue([ALPHA])
        status = self.ctl.status()
        self.assertEqual((status["total"], status["done"], status["remaining"]), (1, 0, 1))
        self.assertEqual(status["recent"], [])

    def test_status_falls_back_to_queue_mtime_after_restart(self):
        a = name_for(ALPHA)
        self.fleet.log(f"{iso(-3600)}\tstatus=ok\trepo={a}\ttask=audit")
        self.fleet.write_queue([ALPHA])
        fresh = runctl.RunController(self.root, runner=self.fleet)
        self.assertEqual(fresh.status()["done"], 0)

    def test_status_remaining_zero_after_archive(self):
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.ok(name_for(ALPHA))()
        os.rename(self.path("plan-queue.json"), self.path("plan-queue.completed-20261115T120000.json"))
        status = self.ctl.status()
        self.assertEqual((status["total"], status["remaining"]), (2, 0))

    def test_status_ignores_archive_from_before_this_page(self):
        self.fleet.write_queue([ALPHA, BETA])
        os.rename(self.path("plan-queue.json"), self.path("plan-queue.completed-20261001T060549.json"))
        fresh = runctl.RunController(self.root, runner=self.fleet)
        status = fresh.status()
        self.assertEqual((status["total"], status["done"], status["remaining"]), (0, 0, 0))

    def test_status_with_nothing_staged(self):
        status = self.ctl.status()
        self.assertEqual((status["total"], status["done"], status["remaining"]), (0, 0, 0))
        self.assertIsNone(status["stopped_reason"])


class ConstructionTests(unittest.TestCase):
    def test_constructor_has_no_side_effects(self):
        calls = []
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        runctl.RunController(root, runner=lambda *a, **k: calls.append(a))
        self.assertEqual(calls, [])
        self.assertEqual(os.listdir(root), [])


if __name__ == "__main__":
    unittest.main()
