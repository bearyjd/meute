"""Tests for tui/runctl.py's guards: single-flight plan, queue pinning at Start,
subprocess timeouts. A fake runner stands in for meute/run.sh/manifest.py;
nothing here runs the real fleet or touches the real state/."""
import os
import subprocess
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runctl_helpers import ALPHA, BETA, RunCtlCase, name_for, runctl  # noqa: E402

GAMMA = "/scan root/projects/gamma"


class PlanSingleFlightTests(RunCtlCase):
    def test_concurrent_plan_calls_run_one_scan_and_conflict_the_other(self):
        entered, release = threading.Event(), threading.Event()
        inner = self.fleet

        def blocking(argv, cwd, out_path=None, timeout=None, on_start=None):
            if "--json" in argv:
                entered.set()
                release.wait(5)
            return inner(argv, cwd, out_path=out_path, timeout=timeout)
        self.ctl.runner = blocking
        results = []
        first = threading.Thread(target=lambda: results.append(self.ctl.plan()))
        first.start()
        self.assertTrue(entered.wait(5))
        try:
            with self.assertRaises(runctl.RunConflict):
                self.ctl.plan()
        finally:
            release.set()
            first.join(5)
        self.assertEqual(len(results), 1)
        self.assertEqual(sum(1 for c in inner.calls if "--json" in c), 1)
        self.ctl.plan()  # the flag is released afterwards
        self.assertEqual(sum(1 for c in inner.calls if "--json" in c), 2)

    def test_plan_flag_released_after_failure(self):
        self.ctl.runner = lambda argv, cwd, out_path=None, timeout=None, on_start=None: (1, "")
        for _ in range(2):
            with self.assertRaises(runctl.RunnerFailed):
                self.ctl.plan()


class TimeoutTests(RunCtlCase):
    def test_runner_is_given_timeouts_except_for_run_sh(self):
        self.ctl.enqueue([ALPHA])
        self.run_to_end()
        seen = {}
        for tag, timeout in self.fleet.timeouts:
            seen.setdefault(tag, set()).add(timeout)
        self.assertEqual(seen["meute"], {runctl.PLAN_TIMEOUT, None})  # scans time out, drain never
        self.assertEqual(runctl.PLAN_TIMEOUT, 120)

    def hang(self, match):
        inner = self.fleet

        def runner(argv, cwd, out_path=None, timeout=None, on_start=None):
            if match(argv):
                raise subprocess.TimeoutExpired(argv, timeout)
            return inner(argv, cwd, out_path=out_path, timeout=timeout, on_start=on_start)
        self.ctl.runner = runner

    def test_plan_timeout_is_runner_failed(self):
        self.hang(lambda argv: "--json" in argv)
        with self.assertRaises(runctl.RunnerFailed) as cm:
            self.ctl.plan()
        self.assertIn("timed out", str(cm.exception))

    def test_enqueue_timeout_resets_flags_so_start_works(self):
        self.ctl.enqueue([ALPHA])
        self.hang(lambda argv: "--enqueue" in argv)
        with self.assertRaises(runctl.RunnerFailed) as cm:
            self.ctl.enqueue([BETA])
        self.assertIn("timed out", str(cm.exception))
        self.ctl.runner = self.fleet
        status = self.run_to_end()  # Start is not stuck on a 409
        self.assertEqual(status["stopped_reason"], "drain finished")


class SubprocessRunnerTests(unittest.TestCase):
    def test_timeout_kills_the_child_and_raises(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            runctl.subprocess_runner([sys.executable, "-c", "import time; time.sleep(30)"],
                                     os.getcwd(), timeout=0.5)

    def test_without_timeout_returns_stdout(self):
        rc, out = runctl.subprocess_runner([sys.executable, "-c", "print('hi')"], os.getcwd())
        self.assertEqual((rc, out), (0, "hi\n"))


if __name__ == "__main__":
    unittest.main()
