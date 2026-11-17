"""Tests for tui/runctl.py. A fake runner stands in for bin/meute, bin/run.sh and
lib/manifest.py; nothing here runs the real fleet or touches the real state/."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runctl_helpers import ALPHA, BETA, SCAN, RunCtlCase, iso, name_for, runctl  # noqa: E402

class EnqueueTests(RunCtlCase):
    def test_enqueue_rejects_empty(self):
        with self.assertRaises(ValueError):
            self.ctl.enqueue([])
        self.assertEqual(self.fleet.calls, [])

    def test_enqueue_does_not_scan_first(self):
        """P1.5: the CLI checks the named paths itself; no plan --json scan."""
        self.ctl.enqueue([ALPHA])
        self.assertFalse(any("--json" in c for c in self.fleet.calls))

    def test_enqueue_stages_good_paths_and_names_the_rest(self):
        bad = "/scan root/projects/private-docs"
        result = self.ctl.enqueue([ALPHA, bad])
        self.assertTrue(result["ok"])
        self.assertEqual(result["staged"], 1)
        self.assertEqual([r["path"] for r in result["rejected"]], [bad])
        self.assertIn(bad, result["message"])
        with open(self.path("plan-queue.json")) as f:
            self.assertEqual([e["name"] for e in json.load(f)["entries"]], [name_for(ALPHA)])

    def test_enqueue_all_rejected_is_value_error(self):
        """Every path refused (a collapsed copy, a missing path): a ValueError
        (-> 400) naming one, and nothing staged."""
        dup = "/scan root/projects/output/alpha copy"
        with self.assertRaises(ValueError) as cm:
            self.ctl.enqueue([dup, "/scan root/projects/private-docs"])
        self.assertIn(dup, str(cm.exception))
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
        # --append is decision D3: the web page adds to a staged queue.
        self.assertEqual(enq[0][1:], ["plan", "--enqueue", "--append", "--skip-invalid",
                                      "--only", ALPHA, "--only", BETA])
        self.assertTrue(enq[0][0].endswith(os.path.join("bin", "meute")))
        self.assertEqual(result, {"ok": True, "message": result["message"], "staged": 2,
                                  "rejected": []})

    def test_enqueue_passes_the_scan_dir_when_set(self):
        ctl = runctl.RunController(self.root, runner=self.fleet, scan_dir=SCAN)
        ctl.enqueue([ALPHA])
        enq = [c for c in self.fleet.calls if "--enqueue" in c]
        self.assertEqual(enq[0][-2:], ["--", SCAN])

    def test_enqueue_failure_reports_not_ok(self):
        self.fleet.enqueue_rc = 1
        result = self.ctl.enqueue([ALPHA])
        self.assertFalse(result["ok"])
        self.assertEqual(result["staged"], 0)

    def test_enqueue_while_running_conflicts(self):
        self.ctl.enqueue([ALPHA])
        step, entered, release = self.blocking_step(name_for(ALPHA))
        self.fleet.steps = [step]
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
        self.assertEqual(self.fleet.run_calls(), [])

    def test_start_ignores_expired_hold(self):
        self.ctl.enqueue([ALPHA])
        self.write_hold(int(time.time()) - 60)
        self.fleet.steps = [self.fleet.ok(name_for(ALPHA))]
        self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 1)

    def test_start_conflict_when_already_running(self):
        self.ctl.enqueue([ALPHA])
        step, entered, release = self.blocking_step(name_for(ALPHA))
        self.fleet.steps = [step]
        self.ctl.start()
        self.assertTrue(entered.wait(5))
        try:
            with self.assertRaises(runctl.RunConflict):
                self.ctl.start()
        finally:
            release.set()
            self.ctl.join(5)
        self.assertEqual(len(self.fleet.run_calls()), 1)

    def test_start_with_nothing_staged_is_value_error(self):
        with self.assertRaises(ValueError):
            self.ctl.start()


class LoopTests(RunCtlCase):
    def test_loop_stops_on_skipped_and_reports_reason(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.fleet.skip("nothing eligible"), self.fleet.ok(name_for(ALPHA))]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 1)
        self.assertIn("nothing eligible", status["stopped_reason"])

    def test_loop_continues_on_ok_and_stops_after_queue_done(self):
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.steps = [self.fleet.ok(name_for(ALPHA)), self.fleet.ok(name_for(BETA)),
                            self.fleet.ok("never-run")]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 2)
        self.assertEqual((status["total"], status["done"], status["remaining"]), (2, 2, 0))
        self.assertIn("finished", status["stopped_reason"])

    def test_loop_stops_after_three_consecutive_errors(self):
        self.ctl.enqueue([ALPHA, BETA])
        a, b = name_for(ALPHA), name_for(BETA)
        # an ok resets the count; no new log line (any exit code) is an error
        no_line = lambda: (0, "")  # noqa: E731
        self.fleet.steps = [self.fleet.die(), self.fleet.ok(a), self.fleet.die(),
                            no_line, self.fleet.die(), self.fleet.ok(b)]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 5)
        self.assertIn("3 consecutive errors", status["stopped_reason"])

    def test_stop_lets_current_item_finish_then_idle(self):
        self.ctl.enqueue([ALPHA, BETA])
        step, entered, release = self.blocking_step(name_for(ALPHA))
        self.fleet.steps = [step, self.fleet.ok(name_for(BETA))]
        self.ctl.start()
        self.assertTrue(entered.wait(5))
        self.ctl.stop()
        self.assertEqual(self.ctl.status()["state"], "stopping")
        release.set()
        self.ctl.join(5)
        status = self.ctl.status()
        self.assertEqual(status["state"], "idle")
        self.assertEqual(len(self.fleet.run_calls()), 1)
        self.assertEqual(status["done"], 1)
        self.assertEqual(status["stopped_reason"], "stopped")

    def test_loop_stops_when_runner_falls_back_to_manifest(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.fleet.ok("enrolled-repo"), self.fleet.ok(name_for(ALPHA))]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 1)
        self.assertIn("manifest", status["stopped_reason"])

    def test_loop_runs_weekly_slot_when_only_weekly_items_are_staged(self):
        self.fleet.tasks = ["drift"]
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.fleet.forced(), self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual([c[1] for c in self.fleet.run_calls()], ["weekly"])
        self.assertEqual(status["stopped_reason"], "staged plan finished")
        self.assertEqual((status["total"], status["done"], status["remaining"]), (1, 1, 0))

    def test_mixed_queue_runs_daily_first_then_weekly_then_stops(self):
        self.fleet.tasks = ["audit", "drift"]
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.steps = [self.fleet.forced() for _ in range(6)]
        status = self.run_to_end()
        a, b = name_for(ALPHA), name_for(BETA)
        self.assertEqual([c[1:] for c in self.fleet.run_calls()], [
            ["daily", "--repo", a, "--task", "audit"],
            ["daily", "--repo", b, "--task", "audit"],
            ["weekly", "--repo", a, "--task", "drift"],
            ["weekly", "--repo", b, "--task", "drift"]])
        self.assertEqual(status["stopped_reason"], "staged plan finished")
        self.assertEqual((status["total"], status["done"], status["remaining"]), (4, 4, 0))

    def test_run_names_the_staged_item_with_repo_and_task(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.fleet.forced()]
        self.run_to_end()
        call = self.fleet.run_calls()[0]
        self.assertTrue(call[0].endswith(os.path.join("bin", "run.sh")))
        self.assertEqual(call[1:], ["daily", "--repo", name_for(ALPHA), "--task", "audit"])

    def test_stop_during_pending_check_makes_no_run_call(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.on_pending = self.ctl.stop
        self.fleet.steps = [self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual(self.fleet.run_calls(), [])
        self.assertEqual(status["stopped_reason"], "stopped")

    def test_foreign_timer_line_after_own_line_is_not_credited(self):
        self.ctl.enqueue([ALPHA, BETA])

        def step():
            self.fleet.forced()()
            self.fleet.log(f"{iso()}\tslot=weekly\tstatus=skipped\treason=other timer")
            return 0, ""
        self.fleet.steps = [step, self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 2)
        self.assertEqual(status["stopped_reason"], "staged plan finished")


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
