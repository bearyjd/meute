"""Tests for tui/runctl.py's guards: single-flight plan, queue pinning at Start,
subprocess timeouts. A fake runner stands in for meute/run.sh/manifest.py;
nothing here runs the real fleet or touches the real state/."""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

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

        def blocking(argv, cwd, out_path=None, timeout=None, on_start=None):
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


class TimeoutTests(RunCtlCase):
    def test_runner_is_given_timeouts_except_for_run_sh(self):
        self.ctl.enqueue([ALPHA])
        self.run_to_end()
        seen = {}
        for tag, timeout in self.fleet.timeouts:
            seen.setdefault(tag, set()).add(timeout)
        self.assertEqual(seen["meute"], {runctl.DEFAULT_PLAN_TIMEOUT, None})  # scans time out, drain never
        self.assertEqual(runctl.DEFAULT_PLAN_TIMEOUT, 900)

    def hang(self, match):
        inner = self.fleet

        def runner(argv, cwd, out_path=None, timeout=None, on_start=None):
            if match(argv):
                raise subprocess.TimeoutExpired(argv, timeout)
            return inner(argv, cwd, out_path=out_path, timeout=timeout, on_start=on_start)
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
        self.stops = os.path.join(self.tmp, "stops")
        self.systemctl = os.path.join(self.tmp, "systemctl")
        with open(self.systemctl, "w") as f:
            f.write('#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "' + self.stops + '"\n')
        os.chmod(self.systemctl, 0o755)

    def run_item(self, **env):
        argv = [sys.executable, "-c", "print('ran')"]
        with mock.patch.dict(os.environ, {"MEUTE_SCOPE": "on", "MEUTE_SYSTEMD_RUN": self.stub,
                                          "MEUTE_SYSTEMCTL": self.systemctl, **env}):
            return runctl.subprocess_runner(argv, self.tmp, out_path=self.out)

    def logged(self):
        return open(self.calls).read() if os.path.exists(self.calls) else ""

    def test_item_runs_in_a_collected_user_scope(self):
        self.assertEqual(self.run_item()[0], 0)
        self.assertIn("--user --scope --collect", self.logged().splitlines()[-1])
        self.assertEqual(open(self.out).read(), "ran\n")
        unit = self.logged().splitlines()[-1].split("--unit=")[1].split()[0]
        self.assertEqual(open(self.stops).read(), f"--user stop {unit}.scope\n")

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


def _real_scope_works() -> bool:
    try:
        return subprocess.run(["systemd-run", "--user", "--scope", "--collect", "--quiet", "true"],
                              stdin=subprocess.DEVNULL, capture_output=True,
                              timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


@unittest.skipUnless(_real_scope_works(), "systemd-run --user --scope is not usable here")
class RealScopeReapTests(unittest.TestCase):
    """A straggler a web-loop run.sh item leaves behind is gone once the item
    returns: a scope outlives its main process, so it must be stopped (P2.7)."""

    def test_straggler_does_not_outlive_the_item(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        pidfile = os.path.join(tmp, "pid")
        argv = ["bash", "-c", f"setsid sleep 600 </dev/null >/dev/null 2>&1 & echo $! > {pidfile}"]
        with mock.patch.dict(os.environ, {"MEUTE_SCOPE": "on"}):
            os.environ.pop("MEUTE_SYSTEMD_RUN", None)
            rc, _ = runctl.subprocess_runner(argv, tmp, out_path=os.path.join(tmp, "out"))
        self.assertEqual(rc, 0)
        pid = int(open(pidfile).read())
        self.addCleanup(lambda: subprocess.run(["kill", str(pid)], capture_output=True))
        time.sleep(1)
        self.assertFalse(os.path.exists(f"/proc/{pid}"), "straggler outlived its run.sh item")
