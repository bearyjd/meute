"""Shared fixtures for the tui/runctl.py tests (not a test module itself).

A fake runner stands in for bin/meute, bin/run.sh and lib/manifest.py; nothing
here runs the real fleet or touches the real state/."""
import json
import os
import shutil
import sys
import tempfile
import threading
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
        self.drains = []  # scripted `meute drain` runs: each a callable returning the exit status
        self.drain_pid = 424242
        self.before_drain_start = []  # callables run just before each drain's on_start, in order
        self.timeouts = []  # (basename of argv[0] or "manifest.py", timeout) per call
        self.duplicates = []  # plan --json's collapsed copies: [{path, of, reason}]

    # -- what the runner sees --
    def __call__(self, argv, cwd, out_path=None, timeout=None, on_start=None):
        self.calls.append(list(argv))
        tag = "manifest.py" if "plan-queue" in argv else os.path.basename(argv[0])
        self.timeouts.append((tag, timeout))
        base = os.path.basename(argv[0])
        if base == "meute" and argv[1:2] == ["drain"]:
            if self.before_drain_start:
                self.before_drain_start.pop(0)()
            if on_start:
                on_start(self.drain_pid)
            step = self.drains.pop(0) if self.drains else (lambda: 0)
            return step(), ""
        if base == "meute" and "--json" in argv:
            return 0, json.dumps(self.plan_json())
        if base == "meute" and "--enqueue" in argv:
            if self.enqueue_rc:
                return self.enqueue_rc, ""
            # Like the CLI with --skip-invalid: refuse what it would not
            # stage, one `rejected` line each, stage the rest, exit 3 (or 1
            # when nothing is left).
            only = [argv[i + 1] for i, a in enumerate(argv) if a == "--only"]
            good = [p for p in only if p in self.paths]
            out = "".join(f"rejected\t{p}\tplan: --only {p}: not an unconfigured repository\n"
                          for p in only if p not in good)
            if not good:
                return 1, out
            self.write_queue(good)
            return (3 if out else 0), out + "Staged"
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
        return {"scan": SCAN, "discovered": 2 + len(self.duplicates), "configured": 0,
                "unconfigured": 2, "items": items, "excluded": {"web": [], "other": []},
                "duplicates": self.duplicates, "skipped": []}

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

    def skip_code(self, code):
        def step():
            argv = self.last_argv
            self.log(f"{iso()}\tweek=2026-W46\tslot={argv[1]}\tstatus=skipped"
                     f"\treason=r\trepo={argv[argv.index('--repo') + 1]}"
                     f"\ttask={argv[argv.index('--task') + 1]}\tcode={code}\tdur=0s")
            return 0, ""
        return step

    def already_done(self):
        """A timer finished the forced item first; run.sh --once declines it."""
        def step():
            argv = self.last_argv
            repo, task = argv[argv.index("--repo") + 1], argv[argv.index("--task") + 1]
            with open(os.path.join(self.state, "plan-complete"), "a") as f:
                f.write(f"plan/{repo}/{task}\t{iso()}\n")
            self.log(f"{iso()}\tweek=2026-W46\tslot={argv[1]}\tstatus=skipped"
                     f"\treason=staged plan item already attempted (--once)"
                     f"\trepo={repo}\ttask={task}\tcode=already-done\tdur=0s")
            return 0, ""
        return step

    def drained(self, *repos, rc=0, task="audit"):
        """A `meute drain` run that ran `repos` (log line + plan-complete mark each)."""
        def step():
            for repo in repos:
                self.ok(repo, task)()
            return rc
        return step

    def drain_calls(self):
        return [c for c in self.calls if os.path.basename(c[0]) == "meute" and c[1:2] == ["drain"]]

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

