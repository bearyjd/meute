"""Tests for tui/runctl.py's guards: single-flight plan, queue pinning at Start,
subprocess timeouts. A fake runner stands in for meute/run.sh/manifest.py;
nothing here runs the real fleet or touches the real state/."""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runctl_helpers import ALPHA, BETA, RunCtlCase, name_for, runctl  # noqa: E402

GAMMA = "/scan root/projects/gamma"


class PlanSingleFlightTests(RunCtlCase):
    def test_concurrent_plan_calls_run_one_scan_and_conflict_the_other(self):
        entered, release = threading.Event(), threading.Event()
        inner = self.fleet

        def blocking(argv, cwd, out_path=None, timeout=None):
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
        self.ctl.runner = lambda argv, cwd, out_path=None, timeout=None: (1, "")
        for _ in range(2):
            with self.assertRaises(runctl.RunnerFailed):
                self.ctl.plan()


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
        self.assertEqual(seen["meute"], {runctl.PLAN_TIMEOUT})
        self.assertEqual(seen["manifest.py"], {runctl.PENDING_TIMEOUT})
        self.assertEqual(seen["run.sh"], {None})
        self.assertEqual((runctl.PLAN_TIMEOUT, runctl.PENDING_TIMEOUT), (120, 30))

    def hang(self, match):
        inner = self.fleet

        def runner(argv, cwd, out_path=None, timeout=None):
            if match(argv):
                raise subprocess.TimeoutExpired(argv, timeout)
            return inner(argv, cwd, out_path=out_path, timeout=timeout)
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


class ScopeContainmentTests(unittest.TestCase):
    """A run.sh item started by the web loop goes through a systemd user scope
    when systemd-run works (P2.7, R14); otherwise it runs as before."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.stub = os.path.join(self.tmp, "systemd-run")
        self.calls = os.path.join(self.tmp, "calls")
        with open(self.stub, "w") as f:
            f.write('#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "' + self.calls + '"\n'
                    '[[ "${!#}" == true && -n "${SCOPE_PROBE_FAIL:-}" ]] && exit 1\n'
                    'while [[ "$1" == --* ]]; do shift; done\nexec "$@"\n')
        os.chmod(self.stub, 0o755)
        self.out = os.path.join(self.tmp, "out")

    def run_item(self, **env):
        argv = [sys.executable, "-c", "print('ran')"]
        with mock.patch.dict(os.environ, {"MEUTE_SCOPE": "on", "MEUTE_SYSTEMD_RUN": self.stub, **env}):
            return runctl.subprocess_runner(argv, self.tmp, out_path=self.out)

    def logged(self):
        return open(self.calls).read() if os.path.exists(self.calls) else ""

    def test_item_runs_in_a_collected_user_scope(self):
        self.assertEqual(self.run_item()[0], 0)
        self.assertIn("--user --scope --collect", self.logged().splitlines()[-1])
        self.assertEqual(open(self.out).read(), "ran\n")

    def test_failing_probe_falls_back_to_a_plain_run(self):
        self.assertEqual(self.run_item(SCOPE_PROBE_FAIL="1")[0], 0)
        self.assertNotIn("print", self.logged())
        self.assertEqual(open(self.out).read(), "ran\n")

    def test_missing_systemd_run_falls_back(self):
        self.assertEqual(self.run_item(MEUTE_SYSTEMD_RUN=self.stub + "-absent")[0], 0)
        self.assertEqual(open(self.out).read(), "ran\n")

    def test_scope_off_never_calls_systemd_run(self):
        self.assertEqual(self.run_item(MEUTE_SCOPE="off")[0], 0)
        self.assertEqual(self.logged(), "")
