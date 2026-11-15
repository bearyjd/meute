"""Tests for tui/runctl.py. A fake runner stands in for bin/meute, bin/run.sh and
lib/manifest.py; nothing here runs the real fleet or touches the real state/."""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tui"))
import runctl  # noqa: E402

SCAN = "/scan root/projects"
ALPHA = "/scan root/projects/alpha repo"
BETA = "/scan root/projects/beta"
WEEKLY_ONLY = {"drift"}  # like repos.yaml's slots: [weekly]; other tasks run in both


def iso(delta_seconds=0):
    stamp = datetime.now().astimezone() + timedelta(seconds=delta_seconds)
    return stamp.isoformat(timespec="seconds")


def name_for(path):
    return "plan-" + os.path.basename(path).replace(" ", "-") + "-abc123"


class FakeFleet:
    """Callable runner: records argv, answers like meute/manifest.py/run.sh."""

    def __init__(self, root, tasks=("audit",), paths=(ALPHA, BETA)):
        self.root = root
        self.state = os.path.join(root, "state")
        self.tasks = list(tasks)
        self.paths = list(paths)
        self.calls = []
        self.steps = []
        self.enqueue_rc = 0
        self.last_argv = ["run.sh", "daily"]
        self.on_pending = None

    # -- what the runner sees --
    def __call__(self, argv, cwd, out_path=None):
        self.calls.append(list(argv))
        base = os.path.basename(argv[0])
        if base == "meute" and "--json" in argv:
            return 0, json.dumps(self.plan_json())
        if base == "meute" and "--enqueue" in argv:
            if self.enqueue_rc:
                return self.enqueue_rc, ""
            only = [argv[i + 1] for i, a in enumerate(argv) if a == "--only"]
            self.write_queue(only)
            return 0, "Staged"
        if "plan-queue" in argv:
            if self.on_pending:
                self.on_pending()
            return 0, self.slot_entries(argv[-1])
        if base == "run.sh":
            self.last_argv = list(argv)
            step = self.steps.pop(0) if self.steps else self.skip("script exhausted")
            return step()
        raise AssertionError(f"unexpected argv {argv}")

    def plan_json(self):
        items = [{"rank": i + 1, "repo": os.path.basename(p), "path": p, "task": t,
                  "reason": "r"} for i, (p, t) in enumerate((p, t) for p in self.paths for t in self.tasks)]
        return {"scan": SCAN, "discovered": 2, "configured": 0, "unconfigured": 2,
                "items": items, "excluded": {"web": [], "other": []}}

    def write_queue(self, paths):
        entries = [{"name": name_for(p), "path": p, "task": t, "spec": "s"}
                   for p in paths for t in self.tasks]
        with open(os.path.join(self.state, "plan-queue.json"), "w") as f:
            json.dump({"version": 1, "scan": SCAN, "allow_web": False, "entries": entries}, f)

    def slot_entries(self, slot):
        path = os.path.join(self.state, "plan-queue.json")
        if not os.path.exists(path):
            return ""
        with open(path) as f:
            entries = json.load(f)["entries"]
        return "".join(json.dumps({"key": f"plan/{e['name']}/{e['task']}", "repo": e["name"],
                                   "task": e["task"]}) + "\n"
                       for e in entries if slot == "weekly" or e["task"] not in WEEKLY_ONLY)

    # -- scripted run.sh outcomes --
    def log(self, line):
        with open(os.path.join(self.state, "log"), "a") as f:
            f.write(line + "\n")

    def ok(self, repo, task="audit", status="ok"):
        def step():
            self.log(f"{iso()}\tweek=2026-W46\tslot={self.last_argv[1]}\tstatus={status}\tkind=plan"
                     f"\trepo={repo}\ttask={task}\tdur=1s")
            with open(os.path.join(self.state, "plan-complete"), "a") as f:
                f.write(f"plan/{repo}/{task}\t{iso()}\n")
            return 0, ""
        return step

    def error(self, repo, task="audit"):
        return self.ok(repo, task, status="error")

    def skip(self, reason):
        def step():
            self.log(f"{iso()}\tweek=2026-W46\tslot={self.last_argv[1]}\tstatus=skipped"
                     f"\treason={reason}\tdur=0s")
            return 0, ""
        return step

    def forced(self):
        """ok for whatever --repo/--task this call named."""
        def step():
            argv = self.last_argv
            return self.ok(argv[argv.index("--repo") + 1], argv[argv.index("--task") + 1])()
        return step

    def die(self):
        return lambda: (1, "")

    def run_calls(self):
        return [c for c in self.calls if os.path.basename(c[0]) == "run.sh"]


class RunCtlCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="meute runctl ")
        self.addCleanup(shutil.rmtree, self.root)
        os.makedirs(os.path.join(self.root, "state"))
        self.fleet = FakeFleet(self.root)
        self.ctl = runctl.RunController(self.root, runner=self.fleet)

    def path(self, *parts):
        return os.path.join(self.root, "state", *parts)

    def run_to_end(self):
        self.ctl.start()
        self.ctl.join(5)
        self.assertEqual(self.ctl.status()["state"], "idle")
        return self.ctl.status()

    def blocking_step(self, repo):
        entered, release = threading.Event(), threading.Event()
        finish = self.fleet.ok(repo)

        def step():
            entered.set()
            release.wait(5)
            return finish()
        return step, entered, release


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
