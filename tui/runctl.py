"""The web page's Run tab: plan, enqueue, execute, track.

Everything goes through meute's own commands, so the page cannot drift from
the CLI or slip past a gate:

  plan()     bin/meute plan --json                       (read-only)
  enqueue()  bin/meute plan --enqueue --only <p>... -- <scan>
  start()    one background `bin/meute drain daily|weekly --source plan|manifest`

`meute drain` (lib/drain.sh) is the loop: it calls run.sh unforced, so the
hold, the lock, the cursor, the community share, the tier-3 cap, the
self-budget and the quota floor all still apply, and it ends on a stop-class
exit status. This module starts it (daily, then weekly) and reads its exit
status, never the log text. Source "plan" drains the staged plan, "manifest"
the configured repos (D1: exit statuses are the opt-in --strict-exit ones).

Subprocesses start in their own session. The drain has no timeout. Stop sends SIGTERM to the drain
process only, never to its run.sh child, so the in-flight item finishes; a
server exit signals nothing. The scans (meute plan) do time out; a hung
scan's process group is killed and the call fails with a clear message.
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

PLAN_TIMEOUT = 120    # seconds for `meute plan --json` and `meute plan --enqueue`
SOURCES = ("plan", "manifest")
# `meute drain` exit status -> why the run ended (run.sh's --strict-exit codes).
DRAIN_STOPS = {
    1: "stopped after repeated failed runs",
    2: "the drain was refused (bad arguments)",
    10: "skipped: the fleet is on hold",
    11: "skipped: another run holds the lock",
    12: "skipped: the self-budget is spent",
    13: "skipped: the quota floor was reached",
    15: "skipped: the host is too loaded or low on disk",
}
NEXT_SLOT_STATUSES = (0, 14)  # finished, or nothing eligible: go on to the weekly slot
RUN_OUTPUT = ".plan-web-run.log"  # under state/; matches the .gitignore'd state/.plan-*


class RunConflict(Exception):
    """The request conflicts with the fleet's state (paused, already running)."""


class RunnerFailed(Exception):
    """A meute command failed; the message is safe to show."""


def subprocess_runner(argv: list[str], cwd: str, out_path: str | None = None,
                      timeout: float | None = None, on_start=None) -> tuple[int, str]:
    """Run argv to completion. Returns (returncode, stdout).

    With timeout, a child still running after `timeout` seconds has its whole
    process group killed (find/jq grandchildren would hold the pipe open) and
    subprocess.TimeoutExpired is raised. With out_path, stdout and stderr go to
    that file and "" is returned: the child never writes into a pipe this
    process could close under it. out_path calls (the drain) never time out;
    on_start(pid) is called once such a child is running.
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
    if on_start is not None:
        on_start(child.pid)
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
        self._lock = threading.Lock()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._state = "idle"
        self._enqueuing = False
        self._planning = False
        self._drain_pid: int | None = None
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
    def start(self, source: str = "plan") -> dict:
        if source not in SOURCES:
            raise ValueError(f"source must be one of: {', '.join(SOURCES)}")
        with self._lock:
            if self._state != "idle" or self._enqueuing:
                raise RunConflict("a run is already in progress")
            paused = rp.hold_reason(self.state_dir, self.clock())
            if paused:
                raise RunConflict(paused)
            if source == "plan" and not os.path.isfile(self.queue_path):
                raise ValueError("nothing is staged: enqueue repositories first")
            self._state, self._current, self._stopped_reason = "running", None, None
            self._stopping.clear()
            self._thread = threading.Thread(target=self._loop, args=(source,),
                                            name="meute-run", daemon=True)
            self._thread.start()
        return self.status()

    def stop(self) -> None:
        with self._lock:
            if self._state == "running":
                self._state = "stopping"
                self._stopping.set()
                if self._drain_pid is not None:
                    self._signal_drain(self._drain_pid)

    @staticmethod
    def _signal_drain(pid: int) -> None:
        """SIGTERM the drain only: its run.sh child is left to finish the item."""
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass  # gone already, or the pid now belongs to another user's process

    def join(self, timeout: float | None = None) -> None:
        """Wait for the loop to end (tests, and a clean shutdown if wanted)."""
        thread = self._thread
        if thread is not None:
            thread.join(timeout)

    def _loop(self, source: str) -> None:
        try:
            reason = self._drive(source)
        except RunnerFailed as e:
            reason = str(e)
        except Exception as e:  # keep the controller usable; details go to the log
            sys.stderr.write(f"runctl: run loop failed: {e!r}\n")
            reason = "the run loop failed; see the server log"
        with self._lock:
            self._state, self._current, self._drain_pid = "idle", None, None
            self._stopped_reason = reason

    def _drive(self, source: str) -> str:
        """Start `meute drain` for each slot; the exit status says why it ended."""
        for slot in ("daily", "weekly"):
            with self._lock:
                if self._stopping.is_set():
                    return "stopped"
                self._current = {"repo": source, "task": "drain", "slot": slot}
            rc = self._run_drain(slot, source)
            if self._stopping.is_set():
                return "stopped"
            if rc not in NEXT_SLOT_STATUSES:
                return DRAIN_STOPS.get(rc, f"stopped: drain exited {rc}")
        return "drain finished"

    def _run_drain(self, slot: str, source: str) -> int:
        out = os.path.join(self.state_dir, RUN_OUTPUT)
        if slot == "daily" and os.path.exists(out):
            open(out, "wb").close()  # P1.3: one drain's output per run, not forever
        argv = [self.meute, "drain", slot, "--source", source]
        try:
            rc, _ = self.runner(argv, self.root, out_path=out, on_start=self._drain_started)
        finally:
            with self._lock:  # the pid is dead: never signal it (or a reuse of it) again
                self._drain_pid = None
        return rc

    def _drain_started(self, pid: int) -> None:
        with self._lock:
            self._drain_pid = pid
            if self._stopping.is_set():  # Stop landed before the pid was known
                self._signal_drain(pid)

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
