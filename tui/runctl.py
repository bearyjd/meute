"""The web page's Run tab: plan, enqueue, execute, track.

Everything goes through meute's own commands, so the page cannot drift from
the CLI or slip past a gate:

  plan()     bin/meute plan --json                       (read-only)
  enqueue()  bin/meute plan --enqueue --only <p>... -- <scan>
  start()    one background loop of `bin/run.sh <slot> --repo <name> --task <task> --once`,
             one staged item per call (--once: an item a timer finished first is declined)

run.sh applies the hold, the lock, the self-budget and the quota floor itself;
this module only decides whether to call it again. It reads the outcome of each
call from the lines that call appended to state/log, never from the exit code
(run.sh exits 0 on every skip).

run.sh falls back to the manifest's own queue once the staged plan has nothing
eligible for the slot, so the loop never lets it choose: before each call it
asks lib/manifest.py which staged items are still pending for the daily slot,
then (when none) for the weekly slot, and names the first one with --repo/--task.
Forcing skips run.sh's cursor and its per-candidate share/cap checks, never the
hold, the lock, the self-budget or the quota floor (re-probed after selection
for forced entries), and a forced name matches no manifest entry, so a fallback
finds nothing to run. As defence in depth the loop still stops if a call logged
something that was not staged. It stops with "staged plan finished" when both
slots have nothing pending.

Start pins the staged queue: the set of (name, task) pairs it saw. A CLI
`meute plan --enqueue` (or another `meute web`) restaging mid-run would make
the loop drive repos this page never showed, so the loop re-reads the queue
before each item and stops if the set changed.

Subprocesses start in their own session. The run.sh item calls have no timeout
and are never signalled: Stop and a server exit both let the in-flight item
finish. The scans (meute plan, the manifest.py pending check) do time out; a
hung scan's process group is killed and the call fails with a clear message.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time

import runprogress as rp

MAX_ERRORS = 3
PLAN_TIMEOUT = 120    # seconds for `meute plan --json` and `meute plan --enqueue`
PENDING_TIMEOUT = 30  # seconds for the lib/manifest.py plan-queue check
QUEUE_CHANGED = "staged queue changed outside this page"
RUN_OUTPUT = ".plan-web-run.log"  # under state/; matches the .gitignore'd state/.plan-*


class RunConflict(Exception):
    """The request conflicts with the fleet's state (paused, already running)."""


class RunnerFailed(Exception):
    """A meute command failed; the message is safe to show."""


def subprocess_runner(argv: list[str], cwd: str, out_path: str | None = None,
                      timeout: float | None = None) -> tuple[int, str]:
    """Run argv to completion. Returns (returncode, stdout).

    With timeout, a child still running after `timeout` seconds has its whole
    process group killed (find/jq grandchildren would hold the pipe open) and
    subprocess.TimeoutExpired is raised. With out_path, stdout and stderr go to
    that file and "" is returned: the child never writes into a pipe this
    process could close under it. out_path calls (run.sh items) never time out.
    """
    if out_path is None:
        proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)  # start_new_session: pgid == pid
            except ProcessLookupError:
                pass
            proc.communicate()
            raise
        return proc.returncode, out
    with open(out_path, "ab") as out:
        child = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=out, start_new_session=True)
    return child.wait(), ""


def _clean_paths(paths: object) -> list[str]:
    if not isinstance(paths, list) or not paths:
        raise ValueError("select at least one repository")
    clean: list[str] = []
    for path in paths:
        if not isinstance(path, str) or not os.path.isabs(path) \
                or any(c in path for c in "\n\r\0"):
            raise ValueError("paths must be absolute paths")
        if path not in clean:
            clean.append(path)
    return clean


class RunController:
    def __init__(self, root: str, runner=subprocess_runner, scan_dir: str | None = None,
                 clock=time.time):
        self.root = root
        self.runner = runner
        self.scan_dir = scan_dir
        self.clock = clock
        self.state_dir = os.path.join(root, "state")
        self.log_path = os.path.join(self.state_dir, "log")
        self.queue_path = os.path.join(self.state_dir, "plan-queue.json")
        self.meute = os.path.join(root, "bin", "meute")
        self.run_sh = os.path.join(root, "bin", "run.sh")
        self._lock = threading.Lock()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._state = "idle"
        self._enqueuing = False
        self._planning = False
        self._pinned: frozenset | None = None
        self._current: dict | None = None
        self._stopped_reason: str | None = None
        self._enqueued_at: int | None = None

    # ------------------------------------------------------------ plan ---
    def _call(self, argv: list[str], timeout: float, what: str) -> tuple[int, str]:
        """Run a scan with a timeout; a hang becomes a RunnerFailed (-> 502)."""
        try:
            return self.runner(argv, self.root, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RunnerFailed(f"{what} timed out after {timeout}s") from None

    def plan(self) -> dict:
        """One scan at a time: a second caller gets RunConflict (-> 409)."""
        with self._lock:
            if self._planning:
                raise RunConflict("a plan scan is already running; try again when it finishes")
            self._planning = True
        try:
            return self._plan()
        finally:
            with self._lock:
                self._planning = False

    def _plan(self) -> dict:
        argv = [self.meute, "plan", "--json"] + (["--", self.scan_dir] if self.scan_dir else [])
        rc, out = self._call(argv, PLAN_TIMEOUT, "meute plan --json")
        if rc != 0:
            raise RunnerFailed(f"meute plan --json failed (exit {rc})")
        try:
            data = json.loads(out)
        except ValueError:
            raise RunnerFailed("meute plan --json printed invalid JSON") from None
        if not isinstance(data, dict) or not isinstance(data.get("items"), list) \
                or not isinstance(data.get("scan"), str):
            raise RunnerFailed("meute plan --json printed an unexpected shape")
        return data

    def enqueue(self, paths: list[str]) -> dict:
        wanted = _clean_paths(paths)
        with self._lock:
            if self._state != "idle" or self._enqueuing:
                raise RunConflict("a run is in progress; stop it before staging again")
            self._enqueuing = True
        try:
            return self._enqueue(wanted)
        finally:
            with self._lock:
                self._enqueuing = False

    def _enqueue(self, wanted: list[str]) -> dict:
        fresh = self.plan()
        offered = {item.get("path") for item in fresh["items"] if isinstance(item, dict)}
        unknown = [p for p in wanted if p not in offered]
        if unknown:
            raise ValueError(f"not in the current plan: {unknown[0]}")
        argv = [self.meute, "plan", "--enqueue"]
        for path in wanted:
            argv += ["--only", path]
        argv += ["--", fresh["scan"]]
        started = int(self.clock())
        rc, _ = self._call(argv, PLAN_TIMEOUT, "meute plan --enqueue")
        if rc != 0:
            return {"ok": False, "message": f"meute plan --enqueue failed (exit {rc})",
                    "staged": 0}
        staged = len(rp.load_queue(self.state_dir)[0])
        with self._lock:
            self._enqueued_at = started
            self._stopped_reason = None
        return {"ok": True, "staged": staged,
                "message": f"staged {staged} item(s) across {len(wanted)} repositor"
                           f"{'y' if len(wanted) == 1 else 'ies'}"}

    # ------------------------------------------------------------- run ---
    def start(self) -> dict:
        with self._lock:
            if self._state != "idle" or self._enqueuing:
                raise RunConflict("a run is already in progress")
            paused = rp.hold_reason(self.state_dir, self.clock())
            if paused:
                raise RunConflict(paused)
            if not os.path.isfile(self.queue_path):
                raise ValueError("nothing is staged: enqueue repositories first")
            self._pinned = self._queue_identity()
            self._state, self._current, self._stopped_reason = "running", None, None
            self._stopping.clear()
            self._thread = threading.Thread(target=self._loop, name="meute-run", daemon=True)
            self._thread.start()
        return self.status()

    def stop(self) -> None:
        with self._lock:
            if self._state == "running":
                self._state = "stopping"
                self._stopping.set()

    def join(self, timeout: float | None = None) -> None:
        """Wait for the loop to end (tests, and a clean shutdown if wanted)."""
        thread = self._thread
        if thread is not None:
            thread.join(timeout)

    def _loop(self) -> None:
        try:
            reason = self._drive()
        except RunnerFailed as e:
            reason = str(e)
        except Exception as e:  # keep the controller usable; details go to the log
            sys.stderr.write(f"runctl: run loop failed: {e!r}\n")
            reason = "the run loop failed; see the server log"
        with self._lock:
            self._state, self._current, self._stopped_reason = "idle", None, reason

    def _drive(self) -> str:
        errors, declined = 0, None
        while True:
            if self._stopping.is_set():
                return "stopped"
            slot, pending = "daily", self._pending("daily")
            if not pending:
                slot, pending = "weekly", self._pending("weekly")
            if not pending:
                return "staged plan finished"
            if self._queue_identity() != self._pinned:
                return QUEUE_CHANGED
            repo, task = pending[0]
            with self._lock:
                if self._stopping.is_set():
                    return "stopped"
                self._current = {"repo": repo, "task": task, "slot": slot}
            outcome = self._run_once(slot, repo, task)
            # --once: a timer finished this item between the pending check and
            # run.sh's lock. Step over it; the same item declined twice means
            # run.sh and this loop disagree about plan-complete, so stop.
            if outcome.get("code") == "already-done":
                if declined == (repo, task):
                    return f"stopped: {repo}/{task} is already attempted but still pending"
                declined = (repo, task)
                continue
            if outcome["status"] == "skipped":
                return f"skipped: {outcome['reason'] or 'no reason given'}"
            staged = self._queue_identity()
            if staged != self._pinned:
                return QUEUE_CHANGED
            if outcome["repo"] and (outcome["repo"], outcome["task"]) not in staged:
                return ("stopped: the runner moved on to the manifest queue "
                        f"({outcome['repo']}/{outcome['task']})")
            errors = errors + 1 if outcome["status"] == "error" else 0
            if errors >= MAX_ERRORS:
                return f"stopped after {MAX_ERRORS} consecutive errors"

    def _run_once(self, slot: str, repo: str, task: str) -> dict:
        offset = rp.log_size(self.log_path)
        started = int(self.clock())
        out = os.path.join(self.state_dir, RUN_OUTPUT)
        argv = [self.run_sh, slot, "--repo", repo, "--task", task, "--once"]
        rc, _ = self.runner(argv, self.root, out_path=out)
        return rp.classify(rp.read_log(self.log_path, offset), rc, slot, started)

    def _queue_identity(self) -> frozenset:
        """The staged queue as a set of (name, task), read like status() reads it."""
        return frozenset(rp.load_queue(self.state_dir)[0])

    def _manifest(self) -> str:
        override = os.environ.get("MEUTE_MANIFEST")
        if override:
            return override
        local = os.path.join(self.root, "repos.local.yaml")
        return local if os.path.isfile(local) else os.path.join(self.root, "repos.yaml")

    def _pending(self, slot: str) -> list[tuple[str, str]]:
        """Staged items `slot` can still run, as lib/manifest.py expands them."""
        if not os.path.isfile(self.queue_path):
            return []
        argv = [sys.executable, os.path.join(self.root, "lib", "manifest.py"), "plan-queue",
                self._manifest(), self.queue_path, slot]
        rc, out = self._call(argv, PENDING_TIMEOUT, "stopped: the staged plan queue check")
        if rc != 0:
            raise RunnerFailed("stopped: the staged plan queue failed validation")
        done = rp.completed_keys(self.state_dir)
        pending = []
        for line in out.splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                raise RunnerFailed("stopped: unreadable staged plan queue") from None
            repo, task = entry.get("repo"), entry.get("task")
            if not isinstance(repo, str) or not isinstance(task, str):
                raise RunnerFailed("stopped: unreadable staged plan queue")
            if entry.get("key") not in done:
                pending.append((repo, task))
        return pending

    # ---------------------------------------------------------- status ---
    def status(self) -> dict:
        with self._lock:
            state, current = self._state, self._current
            reason, enqueued_at = self._stopped_reason, self._enqueued_at
        entries, archived, mtime = rp.load_queue(self.state_dir)
        if archived and enqueued_at is None:
            # An old finished plan from before this page was opened: not progress
            # worth showing (it would read "0 / N" with nothing done by us).
            entries, archived = [], False
        since = enqueued_at if enqueued_at is not None else (int(mtime) if mtime else None)
        done, recent = rp.progress(entries, rp.read_log(self.log_path), since)
        total = len(entries)
        done = min(done, total)
        return {"state": state, "current": dict(current) if current else None,
                "total": total, "done": done,
                "remaining": 0 if archived else total - done,
                "stopped_reason": reason, "recent": recent}
