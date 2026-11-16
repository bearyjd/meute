"""Tests for tui/runprogress.py: crediting a run.sh call with its own log line."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock
from datetime import datetime, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tui"))
import runprogress  # noqa: E402


def iso(delta_seconds=0):
    stamp = datetime.now().astimezone() + timedelta(seconds=delta_seconds)
    return stamp.isoformat(timespec="seconds")


class ClassifyTests(unittest.TestCase):
    def rec(self, slot, status, delta=0):
        return runprogress.parse_line(f"{iso(delta)}\tslot={slot}\tstatus={status}\trepo=r\ttask=t")

    def test_last_own_line_wins_over_later_foreign_slot(self):
        since = time.time() - 5
        out = runprogress.classify([self.rec("daily", "ok"), self.rec("weekly", "skipped")],
                                   0, "daily", since)
        self.assertEqual(out["status"], "ok")

    def test_own_slot_line_older_than_call_is_not_credited(self):
        since = time.time() + 5
        out = runprogress.classify([self.rec("daily", "ok", -3600)], 0, "daily", since)
        self.assertEqual(out["status"], "error")
        self.assertIn("without a log line", out["reason"])

    def test_only_foreign_lines_is_error(self):
        out = runprogress.classify([self.rec("weekly", "ok")], 0, "daily", time.time() - 5)
        self.assertEqual(out["status"], "error")


class LoadQueueTests(unittest.TestCase):
    def test_queue_archived_between_isfile_and_getmtime_reads_the_archive(self):
        state = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, state)
        with open(os.path.join(state, "plan-queue.completed-20261115T120000.json"), "w") as f:
            json.dump({"entries": [{"name": "r", "task": "t"}]}, f)
        live = os.path.join(state, "plan-queue.json")
        real_isfile = os.path.isfile
        # run.sh renames the live queue right after isfile() said it was there
        with mock.patch.object(runprogress.os.path, "isfile",
                               side_effect=lambda p: p == live or real_isfile(p)):
            entries, archived, mtime = runprogress.load_queue(state)
        self.assertEqual((entries, archived), ([("r", "t")], True))
        self.assertIsNotNone(mtime)

    def test_everything_vanishing_is_an_empty_queue(self):
        state = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, state)
        live = os.path.join(state, "plan-queue.json")
        with mock.patch.object(runprogress.os.path, "isfile", side_effect=lambda p: p == live):
            self.assertEqual(runprogress.load_queue(state), ([], False, None))


if __name__ == "__main__":
    unittest.main()
