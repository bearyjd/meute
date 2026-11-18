"""Shared fixtures for the tui/webserver.py tests (not a test module itself).

The inbox and run modules are faked; real act(), meute plan and run.sh never run.
"""
import http.client
import json
import os
import subprocess
import sys
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tui"))
import webserver  # noqa: E402

REASONS = ["false-positive", "wont-fix"]


class FakeInbox:
    DISMISS_REASONS = tuple(REASONS)

    def __init__(self):
        self.calls = []
        self.dump_calls = 0
        self.result = {"ok": True, "message": "done"}

    def dump(self):
        self.dump_calls += 1
        return {"findings": [{"id": "r1"}], "dismiss_reasons": REASONS}

    def finding_body(self, rid, n):
        return f"body of {rid}#{n}"

    def act(self, verb, rid, n, *rest):
        self.calls.append((verb, rid, n, *rest))
        return self.result


class FakeRun:
    def __init__(self):
        self.calls = []
        self.start_error = None

    def plan(self):
        self.calls.append(("plan",))
        return {"scan": "/s", "items": []}

    def enqueue(self, paths):
        self.calls.append(("enqueue", paths))
        if not paths:
            raise ValueError("select at least one repository")
        return {"ok": True, "message": "staged", "staged": len(paths)}

    def start(self, source="plan"):
        self.calls.append(("start", source))
        if self.start_error:
            raise self.start_error
        return {"state": "running"}

    def stop(self):
        self.calls.append(("stop",))

    def status(self):
        self.calls.append(("status",))
        return {"state": "idle", "total": 0}


class WebTestCase(unittest.TestCase):
    run_factory = None  # set to FakeRun to serve a fake run module

    def setUp(self):
        self.inbox = FakeInbox()
        self.run = self.run_factory() if self.run_factory else None
        self.server, self.token = webserver.make_server("127.0.0.1", 0, self.inbox, self.run)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def request(self, method, path, body=None, headers=None, host="default", token=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        hdrs = dict(headers or {})
        if token and method == "POST":
            hdrs.setdefault("X-Meute-Token", self.token)
        conn.putrequest(method, path, skip_host=True)
        conn.putheader("Host", f"127.0.0.1:{self.port}" if host == "default" else host)
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
            hdrs["Content-Length"] = str(len(data))
        for k, v in hdrs.items():
            conn.putheader(k, v)
        conn.endheaders(data)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        return resp, raw

    def post_act(self, payload, **kw):
        return self.request("POST", "/api/act", payload, **kw)


def web_file(name):
    with open(os.path.join(ROOT, "tui", "web", name), encoding="utf-8") as f:
        return f.read()


def node_pure(body):
    """Run run.js's PURE-BEGIN..PURE-END block plus `body` under node; parse stdout."""
    js = web_file("run.js")
    script = js[js.index("// PURE-BEGIN"):js.index("// PURE-END")] + body
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True).stdout
    return json.loads(out)
