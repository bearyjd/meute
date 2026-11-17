"""Tests for tui/runctl.py's guards: single-flight plan, queue pinning at Start,
subprocess timeouts. A fake runner stands in for meute/run.sh/manifest.py;
nothing here runs the real fleet or touches the real state/."""
import os
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runctl_helpers import ALPHA, BETA, RunCtlCase, name_for, runctl  # noqa: E402

GAMMA = "/scan root/projects/gamma"


class PlanJobTests(RunCtlCase):
    """P1.6: the scan runs in a thread; plan_start returns at once, plan_state
    reports the last result with its age and `scanning`."""

    def wait_done(self):
        for _ in range(200):
            if not self.ctl.plan_state()["scanning"]:
                return self.ctl.plan_state()
            time.sleep(0.02)
        self.fail("scan did not finish")

    def test_start_returns_while_scan_runs_and_second_start_is_single_flight(self):
        entered, release = threading.Event(), threading.Event()
        inner = self.fleet

        def blocking(argv, cwd, out_path=None, timeout=None):
            if "--json" in argv:
                entered.set()
                release.wait(5)
            return inner(argv, cwd, out_path=out_path, timeout=timeout)
        self.ctl.runner = blocking
        self.assertTrue(self.ctl.plan_start()["scanning"])
        self.assertTrue(entered.wait(5))
        try:
            self.assertTrue(self.ctl.plan_start()["scanning"])
            state = self.ctl.plan_state()
            self.assertTrue(state["scanning"])
            self.assertIsNone(state["plan"])
        finally:
            release.set()
        state = self.wait_done()
        self.assertEqual(sum(1 for c in inner.calls if "--json" in c), 1)
        self.assertIn("items", state["plan"])
        self.assertIsNone(state["error"])
        self.assertGreaterEqual(state["age"], 0)

    def test_failure_is_kept_as_error_and_flag_released(self):
        self.ctl.runner = lambda argv, cwd, out_path=None, timeout=None: (1, "")
        self.ctl.plan_start()
        state = self.wait_done()
        self.assertIn("exit 1", state["error"])
        self.assertIsNone(state["plan"])
        self.ctl.plan_start()  # not stuck scanning
        self.wait_done()

    def test_failed_rescan_keeps_the_last_good_result(self):
        self.ctl.plan_start()
        self.assertIn("items", self.wait_done()["plan"])
        self.ctl.runner = lambda argv, cwd, out_path=None, timeout=None: (1, "")
        self.ctl.plan_start()
        state = self.wait_done()
        self.assertIn("items", state["plan"])
        self.assertIn("exit 1", state["error"])

    def test_timeout_comes_from_env(self):
        old = os.environ.get("MEUTE_PLAN_TIMEOUT")
        os.environ["MEUTE_PLAN_TIMEOUT"] = "7"
        try:
            self.ctl.plan_start()
            self.wait_done()
        finally:
            if old is None:
                del os.environ["MEUTE_PLAN_TIMEOUT"]
            else:
                os.environ["MEUTE_PLAN_TIMEOUT"] = old
        self.assertEqual([t for tag, t in self.fleet.timeouts if tag == "meute"], [7.0])

    def test_default_timeout_is_900(self):
        self.assertEqual(runctl.DEFAULT_PLAN_TIMEOUT, 900)


class QueuePinTests(RunCtlCase):
    def rewrite_then_ok(self, paths):
        """A run.sh step that, mid-run, restages `paths` (like a CLI --enqueue)."""
        def step():
            self.fleet.write_queue(paths)
            return self.fleet.forced()()
        return step

    def test_queue_restaged_mid_run_stops_the_loop(self):
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.steps = [self.rewrite_then_ok([ALPHA, BETA, GAMMA]), self.fleet.forced(),
                            self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 1)
        self.assertEqual(status["stopped_reason"], "staged queue changed outside this page")

    def test_queue_rewritten_in_another_order_does_not_stop(self):
        self.ctl.enqueue([ALPHA, BETA])
        self.fleet.steps = [self.rewrite_then_ok([BETA, ALPHA]), self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual(len(self.fleet.run_calls()), 2)
        self.assertEqual(status["stopped_reason"], "staged plan finished")

    def test_queue_replaced_with_other_repos_stops_before_running_them(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.rewrite_then_ok([GAMMA]), self.fleet.forced()]
        status = self.run_to_end()
        self.assertEqual([c[3] for c in self.fleet.run_calls()], [name_for(ALPHA)])
        self.assertEqual(status["stopped_reason"], "staged queue changed outside this page")


class TimeoutTests(RunCtlCase):
    def test_runner_is_given_timeouts_except_for_run_sh(self):
        self.ctl.enqueue([ALPHA])
        self.fleet.steps = [self.fleet.forced()]
        self.run_to_end()
        seen = {}
        for tag, timeout in self.fleet.timeouts:
            seen.setdefault(tag, set()).add(timeout)
        self.assertEqual(seen["meute"], {runctl.DEFAULT_PLAN_TIMEOUT})
        self.assertEqual(seen["manifest.py"], {runctl.PENDING_TIMEOUT})
        self.assertEqual(seen["run.sh"], {None})
        self.assertEqual((runctl.DEFAULT_PLAN_TIMEOUT, runctl.PENDING_TIMEOUT), (900, 30))

    def hang(self, match):
        inner = self.fleet

        def runner(argv, cwd, out_path=None, timeout=None):
            if match(argv):
                raise subprocess.TimeoutExpired(argv, timeout)
            return inner(argv, cwd, out_path=out_path, timeout=timeout)
        self.ctl.runner = runner

    def test_plan_timeout_is_runner_failed(self):
        self.hang(lambda argv: "--json" in argv)
        self.ctl.plan_start()
        for _ in range(200):
            if not self.ctl.plan_state()["scanning"]:
                break
            time.sleep(0.02)
        self.assertIn("timed out", self.ctl.plan_state()["error"])

    def test_enqueue_timeout_resets_flags_so_start_works(self):
        self.ctl.enqueue([ALPHA])
        self.hang(lambda argv: "--enqueue" in argv)
        with self.assertRaises(runctl.RunnerFailed) as cm:
            self.ctl.enqueue([BETA])
        self.assertIn("timed out", str(cm.exception))
        self.ctl.runner = self.fleet
        self.fleet.steps = [self.fleet.forced()]
        status = self.run_to_end()  # Start is not stuck on a 409
        self.assertEqual(status["stopped_reason"], "staged plan finished")

    def test_pending_check_timeout_stops_the_loop_cleanly(self):
        self.ctl.enqueue([ALPHA])
        self.hang(lambda argv: "plan-queue" in argv)
        status = self.run_to_end()
        self.assertIn("timed out", status["stopped_reason"])
        self.assertEqual(self.fleet.run_calls(), [])


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
