"""Real-browser smoke test: the page must load, render and report in.

app.js and run.js send GET /api/client-ready?page=inbox|run after their first
render, and window.onerror sends GET /api/client-error. The server records
both in server.client_events. Skipped (visibly) when no headless browser is
installed. No new dependency: firefox or chromium, whichever is on PATH.
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from webtest_helpers import FakeRun, WebTestCase, webserver

BROWSER_WAIT = 30


def find_browser():
    for name in ("firefox", "chromium", "chromium-browser", "google-chrome"):
        path = shutil.which(name)
        if path:
            return name, path
    return None, None


def browser_cmd(name, path, profile, url):
    if name == "firefox":
        return [path, "--headless", "--no-remote", "--profile", profile, url]
    return [path, "--headless", "--no-sandbox", "--disable-gpu",
            f"--user-data-dir={profile}", url]


class BeaconEndpoints(WebTestCase):
    run_factory = FakeRun

    def test_ready_beacon_is_recorded(self):
        resp, _ = self.request("GET", "/api/client-ready?page=inbox")
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.server.client_events, [("ready", "inbox")])

    def test_error_beacon_is_recorded_and_truncated(self):
        resp, _ = self.request("GET", "/api/client-error?msg=" + "x" * 5000)
        self.assertEqual(resp.status, 200)
        (kind, msg), = self.server.client_events
        self.assertEqual(kind, "error")
        self.assertLessEqual(len(msg), 300)

    def test_client_events_are_bounded_dropping_oldest(self):
        cap = webserver.MAX_CLIENT_EVENTS
        for i in range(cap + 50):
            resp, _ = self.request("GET", f"/api/client-error?msg=m{i}")
            self.assertEqual(resp.status, 200)
        events = self.server.client_events
        self.assertEqual(len(events), cap)
        self.assertEqual(events[0], ("error", "m50"))
        self.assertEqual(events[-1], ("error", f"m{cap + 49}"))

    def test_unknown_ready_page_is_rejected(self):
        resp, _ = self.request("GET", "/api/client-ready?page=evil")
        self.assertEqual(resp.status, 400)
        self.assertEqual(self.server.client_events, [])

    def test_beacon_still_needs_exact_host(self):
        resp, _ = self.request("GET", "/api/client-ready?page=inbox", host="evil.test")
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.server.client_events, [])


class BrowserSmoke(WebTestCase):
    run_factory = FakeRun

    def test_pages_render_without_client_errors(self):
        name, path = find_browser()
        if not path:
            self.skipTest("SKIPPED: no firefox/chromium on PATH; real-browser smoke test not run")
        profile = tempfile.mkdtemp(prefix="meute-smoke-")
        self.addCleanup(shutil.rmtree, profile, True)
        proc = subprocess.Popen(
            browser_cmd(name, path, profile, f"http://127.0.0.1:{self.port}/"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self._kill, proc)
        deadline = time.monotonic() + BROWSER_WAIT
        want = {("ready", "inbox"), ("ready", "run")}
        while time.monotonic() < deadline:
            events = list(self.server.client_events)
            if any(k == "error" for k, _ in events) or want <= set(events):
                break
            time.sleep(0.25)
        events = list(self.server.client_events)
        self.assertEqual([e for e in events if e[0] == "error"], [], "client-side error")
        self.assertTrue(want <= set(events), f"missing ready beacons; got {events}")

    @staticmethod
    def _kill(proc):
        try:
            os.killpg(proc.pid, 9)
        except ProcessLookupError:
            pass
        proc.wait(10)


if __name__ == "__main__":
    unittest.main()
