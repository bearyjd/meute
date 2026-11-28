"""Durable Resolve/Dismiss on POST /api/act, with REAL receipt storage.

The server runs decisions.run_decide against a disposable MEUTE_ROOT
(decisions_helpers.Fixture): real reports, real state/reports rows, real
receipts under state/receipts/decisions. Nothing about the decision path is
mocked. The browser tests (skipped visibly without firefox/chromium) drive
tui/web/app.js through a lost reply and a stale revision.
"""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decisions_helpers import REPORT_A, REPORT_B, Fixture  # noqa: E402
from webtest_helpers import FakeRun, WebTestCase, web_file, webserver  # noqa: E402

import inbox  # noqa: E402  (lib/, on sys.path via decisions_helpers)
import receipt_keys as rk  # noqa: E402

HAS_NODE = shutil.which("node") is not None
BROWSER_WAIT = 45


class RealInbox:
    """inbox's own load_reports over the fixture root: real revisions."""

    DISMISS_REASONS = inbox.DISMISS_REASONS

    def __init__(self, root):
        self.root = str(root)
        self.dump_calls = 0
        self.calls = []

    def dump(self):
        self.dump_calls += 1
        reports, findings = inbox.load_reports(root=self.root)
        return {"unreadable": [], "status": {}, "reports": reports, "findings": findings,
                "branches": [], "dismiss_reasons": list(self.DISMISS_REASONS)}

    def finding_body(self, rid, n, bounded=False):
        return f"evidence for {rid}#{n}"

    def act(self, verb, rid, n, *rest):
        self.calls.append((verb, rid, n, *rest))
        return {"ok": True, "message": "promoted"}


class DecisionWebTestCase(WebTestCase):
    run_factory = FakeRun

    def setUp(self):
        self.fx = Fixture(self)
        super().setUp()
        # WebTestCase builds a FakeInbox; reads here are the real inbox's.
        self.server.inbox_mod = self.inbox = RealInbox(self.fx.root)

    def server_kwargs(self):
        env = {"MEUTE_TEST": "1", "MEUTE_DECISIONS_LOCK_WAIT": "0.3"}
        return {"decisions_root": str(self.fx.root), "decisions_env": env}

    def decide(self, verb="resolve", rid=REPORT_A, n=1, key="web-key-0001", rev=None, **extra):
        body = {"verb": verb, "id": rid, "n": n, "request_key": key,
                "expected_revision": rev if rev is not None else self.fx.revision(rid, n)}
        if verb == "resolve":
            body.setdefault("message", "fixed upstream")
        else:
            body.setdefault("reason", "wont-fix")
        body.update(extra)
        resp, raw = self.post_act(body)
        return resp.status, json.loads(raw)

    def assert_nothing_written(self):
        self.assertEqual(self.fx.rows(), b"")
        self.assertEqual(self.fx.receipt_files(), [])


class DecisionRouteTests(DecisionWebTestCase):
    def test_resolve_returns_receipt_and_writes_once(self):
        rev = self.fx.revision(REPORT_A, 1)
        self.assertEqual(rev, rk.ABSENT)
        status, body = self.decide(rev=rev)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"])
        self.assertFalse(body["replayed"])
        rec = body["receipt"]
        self.assertEqual((rec["operation"], rec["finding_key"], rec["disposition"], rec["phase"]),
                         ("finding.resolve", f"{REPORT_A}#1", "actioned", "complete"))
        self.assertEqual(rec["operator"], webserver.WEB_OPERATOR)
        self.assertEqual(rec["request_key"], "web-key-0001")
        self.assertEqual(rec["before_revision"], rev)
        self.assertEqual(rec["after_revision"], self.fx.revision(REPORT_A, 1))
        self.assertNotIn("row_note", rec)
        self.assertEqual(len(self.fx.rows_for(f"{REPORT_A}#1")), 1)
        self.assertIn(b"resolved: fixed upstream", self.fx.rows_for(f"{REPORT_A}#1")[0])
        self.assertEqual(self.fx.only_receipt()["receipt_id"], rec["receipt_id"])
        # The page reads the new revision back from /api/inbox.
        resp, raw = self.request("GET", "/api/inbox")
        f = next(x for x in json.loads(raw)["findings"] if x["report"] == REPORT_A and x["n"] == 1)
        self.assertEqual((f["state"], f["revision"]), ("actioned", rec["after_revision"]))
        self.assertEqual(self.inbox.calls, [])

    def test_dismiss_returns_receipt(self):
        status, body = self.decide("dismiss", REPORT_B, 1, key="web-key-dism", message="later")
        self.assertEqual(status, 200, body)
        rec = body["receipt"]
        self.assertEqual((rec["operation"], rec["disposition"]), ("finding.dismiss", "dismissed"))
        self.assertEqual(self.fx.rows_for(f"{REPORT_B}#1")[0].split(b"\t")[3], b"wont-fix: later")
        # Single-finding report: the report row is derived as settled.
        self.assertEqual(self.fx.rows_for(REPORT_B)[0].split(b"\t")[1], b"actioned")

    def test_operator_is_chosen_by_the_server_not_the_body(self):
        status, body = self.decide(operator="mallory")
        self.assertEqual(status, 200, body)
        self.assertEqual(body["receipt"]["operator"], webserver.WEB_OPERATOR)

    def test_retry_after_lost_reply_returns_original_receipt_and_applies_once(self):
        rev = self.fx.revision(REPORT_A, 1)
        status, first = self.decide(rev=rev)  # the reply the browser never saw
        self.assertEqual(status, 200)
        rows = self.fx.rows()
        status, again = self.decide(rev=rev)
        self.assertEqual(status, 200, again)
        self.assertTrue(again["replayed"])
        self.assertEqual(again["receipt"], first["receipt"])
        self.assertEqual(self.fx.rows(), rows)
        self.assertEqual(len(self.fx.receipt_files()), 1)

    def test_retry_completes_an_interrupted_web_decision(self):
        # A crash after the row was written (before the receipt was marked):
        # the server's own scope (operator "web") picks it up on retry.
        rev = self.fx.revision(REPORT_A, 1)
        proc = self.fx.decisions("decide", "resolve", f"--id={REPORT_A}", "--finding=1",
                                 "--message=fixed upstream", "--request-key=web-key-0001",
                                 f"--expected-revision={rev}", "--operator=web",
                                 MEUTE_TEST="1", MEUTE_DECISIONS_FAIL_AFTER="6")
        self.assertEqual(proc.returncode, 70, proc.stderr)
        self.assertEqual(self.fx.only_receipt()["phase"], "pending")
        status, body = self.decide(rev=rev)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["replayed"])
        self.assertEqual(body["receipt"]["phase"], "complete")
        self.assertEqual(len(self.fx.rows_for(f"{REPORT_A}#1")), 1)

    def test_stale_revision_is_409_with_current_revision(self):
        old = self.fx.revision(REPORT_A, 1)
        proc = self.fx.resolve(REPORT_A, 1, "cli-key-0001", old, message="someone else")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        current = self.fx.revision(REPORT_A, 1)
        rows = self.fx.rows()
        status, body = self.decide(rev=old)
        self.assertEqual(status, 409, body)
        self.assertEqual(body["error"], "stale_revision")
        self.assertEqual(body["current_revision"], current)
        self.assertIn("review", body["message"])
        self.assertEqual(self.fx.rows(), rows)
        self.assertEqual(len(self.fx.receipt_files()), 1)  # the CLI's only
        # A NEW decision (new key) against the current revision succeeds.
        status, body = self.decide(key="web-key-0002", rev=current)
        self.assertEqual(status, 200, body)

    def test_reused_key_with_other_payload_is_key_conflict(self):
        status, _ = self.decide()
        self.assertEqual(status, 200)
        rows = self.fx.rows()
        status, body = self.decide(rev=rk.ABSENT, message="something else")
        self.assertEqual(status, 409, body)
        self.assertEqual(body["error"], "key_conflict")
        self.assertEqual(self.fx.rows(), rows)

    def test_indeterminate_is_409_asking_to_inspect_state(self):
        rev = self.fx.revision(REPORT_A, 1)
        proc = self.fx.decisions("decide", "resolve", f"--id={REPORT_A}", "--finding=1",
                                 "--message=fixed upstream", "--request-key=web-key-0001",
                                 f"--expected-revision={rev}", "--operator=web",
                                 MEUTE_TEST="1", MEUTE_DECISIONS_FAIL_AFTER="5")
        self.assertEqual(proc.returncode, 70, proc.stderr)
        proc = self.fx.dismiss(REPORT_A, 1, "cli-key-0002", rev)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = self.fx.rows()
        status, body = self.decide(rev=rev)
        self.assertEqual(status, 409, body)
        self.assertEqual(body["error"], "indeterminate")
        self.assertIn("inspect", body["message"])
        self.assertEqual(body["current_revision"], self.fx.revision(REPORT_A, 1))
        self.assertEqual(self.fx.rows(), rows)

    def test_missing_or_malformed_receipt_fields_are_400_and_write_nothing(self):
        good = {"verb": "resolve", "id": REPORT_A, "n": 1, "message": "fixed",
                "request_key": "web-key-0001", "expected_revision": rk.ABSENT}
        bad = [
            {k: v for k, v in good.items() if k != "request_key"},
            {k: v for k, v in good.items() if k != "expected_revision"},
            {**good, "request_key": "short"},
            {**good, "request_key": "has space key"},
            {**good, "request_key": "x" * 129},
            {**good, "request_key": "web-key-0001\n"},
            {**good, "request_key": 12345678},
            {**good, "request_key": None},
            {**good, "expected_revision": ""},
            {**good, "expected_revision": "r1:nothex"},
            {**good, "expected_revision": "r1:" + "a" * 63},
            {**good, "expected_revision": "r1:absent\n"},
            {**good, "expected_revision": ["r1:absent"]},
            {**good, "id": "alpha"},
            {**good, "id": "../x/y"},
            {**good, "n": 0},
            {**good, "n": "1"},
            {**good, "message": "line\nbreak"},  # decisions.py's own check (exit 2)
            {**good, "n": 9},  # no such finding (exit 2)
            {**good, "verb": "dismiss", "reason": "because"},
            {**good, "verb": "dismiss", "reason": "wont-fix", "pr": "x"},
        ]
        bad[-1].pop("pr")
        bad[-1]["id"] = "alpha/missing-report"  # no such report (exit 2)
        for body in bad:
            resp, raw = self.post_act(body)
            self.assertEqual(resp.status, 400, (body, raw))
            self.assertFalse(json.loads(raw)["ok"], body)
        self.assert_nothing_written()
        self.assertEqual(self.inbox.calls, [])

    def test_busy_is_503_and_same_key_retry_succeeds(self):
        rev = self.fx.revision(REPORT_A, 1)
        fd = os.open(self.fx.state / "reports.lock", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            status, body = self.decide(rev=rev)
            self.assertEqual(status, 503, body)
            self.assertEqual(body["error"], "busy")
            self.assert_nothing_written()
        finally:
            os.close(fd)
        status, body = self.decide(rev=rev)
        self.assertEqual(status, 200, body)
        self.assertFalse(body["replayed"])

    def test_unreadable_receipt_is_a_clear_error_and_is_preserved(self):
        self.fx.receipts.mkdir(parents=True)
        path = self.fx.receipts / (rk.scope_hash("web", "finding.resolve", "web-key-0001") + ".json")
        path.write_bytes(b"{not a receipt")
        status, body = self.decide(rev=rk.ABSENT)
        self.assertEqual(status, 500, body)
        self.assertEqual(body["error"], "receipt_unreadable")
        self.assertIn("unreadable", body["message"])
        self.assertEqual(path.read_bytes(), b"{not a receipt")
        self.assertEqual(self.fx.rows(), b"")

    def test_promote_is_unchanged(self):
        resp, raw = self.post_act({"verb": "promote", "id": "r1", "n": 3})
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(raw), {"ok": True, "message": "promoted"})
        self.assertEqual(self.inbox.calls, [("promote", "r1", 3)])
        self.assert_nothing_written()

    def test_decisions_keep_the_post_guard(self):
        body = {"verb": "resolve", "id": REPORT_A, "n": 1, "message": "x",
                "request_key": "web-key-0001", "expected_revision": rk.ABSENT}
        for kw in ({"token": False}, {"headers": {"X-Meute-Token": "nope"}},
                   {"headers": {"Origin": "http://evil.example"}},
                   {"headers": {"Sec-Fetch-Site": "cross-site"}},
                   {"host": "evil.example:80"}):
            resp, _ = self.post_act(body, **kw)
            self.assertEqual(resp.status, 403, kw)
        self.assert_nothing_written()


@unittest.skipUnless(HAS_NODE, "node not installed")
class ClientLogicTests(unittest.TestCase):
    """app.js's PURE-BEGIN..PURE-END block under node."""

    def run_pure(self, body):
        js = web_file("app.js")
        script = js[js.index("// PURE-BEGIN"):js.index("// PURE-END")] + body
        out = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_classify(self):
        cases = [
            [200, {"ok": True}], [409, {"error": "stale_revision"}], [409, {"error": "key_conflict"}],
            [409, {"error": "indeterminate"}], [500, {"error": "receipt_unreadable"}],
            [None, None], [503, {"error": "busy"}], [500, {"ok": False, "message": "internal error"}],
            [502, None], [400, {"error": "invalid"}], [403, {"ok": False}],
        ]
        got = self.run_pure("process.stdout.write(JSON.stringify(%s.map(([s, b]) => classifyDecision(s, b))));"
                            % json.dumps(cases))
        self.assertEqual(got, ["ok", "stale", "conflict", "indeterminate", "unreadable",
                               "retry", "retry", "retry", "retry", "invalid", "invalid"])

    def test_request_key_matches_server_grammar_and_differs(self):
        got = self.run_pure(
            "const c = require('crypto');"
            "const r = (n) => c.randomBytes(n);"
            "process.stdout.write(JSON.stringify([newRequestKey(r), newRequestKey(r)]));")
        self.assertNotEqual(got[0], got[1])
        for key in got:
            self.assertRegex(key, r"^web-[0-9a-f]{32}$")
            self.assertTrue(rk.KEY_RE.fullmatch(key))


# ------------------------------------------------------------ browser ---

DRIVER = r"""
"use strict";
(function () {
  const SCENARIO = __SCENARIO__;
  const report = (obj) => fetch("/test/report?msg=" + encodeURIComponent(JSON.stringify(obj)));
  const q = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function until(what, pred) {
    for (let i = 0; i < 300; i++) {
      try { if (pred()) return; } catch (e) { /* not yet */ }
      await sleep(100);
    }
    throw new Error("timed out waiting for " + what);
  }
  const rows = () => document.querySelectorAll("#findings-table tbody tr");
  const visible = (id) => !q(id).hidden;
  async function pick() {
    // REPORT_B #1 (src/d.py:4): REPORT_A is superseded by it, so hidden.
    const row = () => Array.from(rows()).find((tr) => tr.textContent.includes("src/d.py:4"));
    await until("findings", () => row());
    row().click();
    await until("panel", () => visible("panel") && q("panel-body").textContent !== "loading...");
  }
  async function resolve(text) {
    q("resolve-message").value = text;
    q("act-resolve").click();
  }
  async function lostReply() {
    await pick();
    await resolve("fixed upstream");
    await until("retry box", () => visible("retry-box"));
    q("act-retry").click();
    await until("receipt", () => visible("receipt") && q("receipt").textContent.includes("receipt "));
    await until("inbox refresh", () => !visible("retry-box"));
    return { receipt: q("receipt").textContent, notice: q("notice").textContent };
  }
  async function stale() {
    q("show-decided").click();
    await pick();
    await resolve("first try");
    await until("review box", () => visible("review-box"));
    const staleNotice = q("notice").textContent;
    // A new decision is refused until the operator has reviewed.
    await resolve("too soon");
    await sleep(300);
    const blocked = q("notice").textContent;
    q("act-reviewed").click();
    await until("re-selected", () => !visible("review-box") && q("resolve-message").value === ""
      && q("panel-body").textContent !== "loading...");
    await resolve("second try");
    await until("receipt", () => visible("receipt"));
    return { staleNotice: staleNotice, blocked: blocked, receipt: q("receipt").textContent };
  }
  const run = { lost_reply: lostReply, stale: stale }[SCENARIO];
  window.addEventListener("load", () => {
    run().then((r) => report({ ok: true, result: r }),
      (e) => report({ ok: false, error: String(e && e.message || e) }));
  });
})();
"""


def _find_browser():
    from test_browser_smoke import browser_cmd, find_browser
    name, path = find_browser()
    return name, path, browser_cmd


class BrowserDecisionTests(DecisionWebTestCase):
    """A real browser drives app.js; /api/act is the real route, wrapped only
    to drop one reply (lost reply) or to land a concurrent CLI decision first
    (stale revision)."""

    def setUp(self):
        name, path, self.browser_cmd = _find_browser()
        if not path:
            self.skipTest("SKIPPED: no firefox/chromium on PATH; browser decision tests not run")
        self.browser = (name, path)
        super().setUp()
        self.posts = []
        self.replies = []
        self.reports = []
        self.done = threading.Event()

    def _routes(self, scenario, on_post):
        def index(h, query):
            if (query.get("t") or [""])[0]:
                return webserver.get_index(h, query)
            if not webserver.has_cookie(h):
                return h.send_bytes(403, b"no cookie", "text/plain")
            page = web_file("index.html").replace("__TOKEN__", h.server.token)
            page = page.replace("</body>", '<script src="/test/drive.js" defer></script>\n</body>')
            h.send_bytes(200, page.encode(), "text/html; charset=utf-8")

        def drive(h, query):
            js = DRIVER.replace("__SCENARIO__", json.dumps(scenario))
            h.send_bytes(200, js.encode(), "text/javascript; charset=utf-8")

        def report(h, query):
            self.reports.append(json.loads((query.get("msg") or ["{}"])[0]))
            h.send_json(200, {"ok": True})
            self.done.set()

        def act(h, query):
            payload = h.read_json()
            self.posts.append(payload)
            args = webserver.parse_act(payload, list(inbox.DISMISS_REASONS))
            reply = on_post(len(self.posts), args)
            if reply is None:
                return  # connection closes with no response: a lost reply
            self.replies.append(reply)
            h.send_json(*reply)

        return {("GET", "/"): index, ("GET", "/test/drive.js"): drive,
                ("GET", "/test/report"): report, ("POST", "/api/act"): act}

    def drive(self, scenario, on_post):
        from unittest.mock import patch
        patcher = patch.dict(webserver.ROUTES, self._routes(scenario, on_post))
        patcher.start()
        self.addCleanup(patcher.stop)
        profile = tempfile.mkdtemp(prefix="meute-decide-")
        self.addCleanup(shutil.rmtree, profile, True)
        name, path = self.browser
        proc = subprocess.Popen(
            self.browser_cmd(name, path, profile, f"http://127.0.0.1:{self.port}/?t={self.token}"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self._kill, proc)
        if not self.done.wait(BROWSER_WAIT):
            self.fail(f"browser {name}: no report; posts={len(self.posts)} "
                      f"client={self.server.client_events[-3:]}")
        (rep,) = self.reports
        self.assertTrue(rep.get("ok"), rep)
        return rep["result"]

    @staticmethod
    def _kill(proc):
        try:
            os.killpg(proc.pid, 9)
        except ProcessLookupError:
            pass
        proc.wait(10)

    def test_lost_reply_retry_resends_same_key_and_applies_once(self):
        server = self.server

        def on_post(i, args):
            reply = webserver.decide(server, args)  # the decision IS applied
            return None if i == 1 else reply

        result = self.drive("lost_reply", on_post)
        self.assertEqual(len(self.posts), 2)
        first, second = self.posts
        self.assertEqual(first, second)  # same key, revision and payload
        self.assertEqual(first["expected_revision"], rk.ABSENT)
        self.assertRegex(first["request_key"], r"^web-[0-9a-f]{32}$")
        (status, body), = self.replies
        self.assertEqual(status, 200)
        self.assertTrue(body["replayed"])
        self.assertIn(body["receipt"]["receipt_id"], result["receipt"])
        self.assertEqual(len(self.fx.rows_for(f"{REPORT_B}#1")), 1)
        self.assertEqual(len(self.fx.receipt_files()), 1)
        self.assertGreaterEqual(self.inbox.dump_calls, 2)  # refreshed after success

    def test_stale_revision_refreshes_and_needs_review_before_a_new_decision(self):
        server, fx = self.server, self.fx
        seen = {}

        def on_post(i, args):
            if i == 1:  # someone decides the finding from the CLI first
                proc = fx.resolve(REPORT_B, 1, "cli-key-0001", rk.ABSENT, message="cli")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                seen["current"] = fx.revision(REPORT_B, 1)
                seen["dumps"] = self.inbox.dump_calls
            return webserver.decide(server, args)

        result = self.drive("stale", on_post)
        self.assertEqual(len(self.posts), 2, self.posts)  # "too soon" never left the page
        first, second = self.posts
        self.assertEqual(self.replies[0][0], 409)
        self.assertEqual(self.replies[0][1]["error"], "stale_revision")
        self.assertIn(seen["current"], result["staleNotice"])
        self.assertIn("Reviewed", result["blocked"])
        self.assertNotEqual(first["request_key"], second["request_key"])
        self.assertEqual(first["expected_revision"], rk.ABSENT)
        self.assertEqual(second["expected_revision"], seen["current"])
        self.assertEqual(second["message"], "second try")
        self.assertEqual(self.replies[1][0], 200)
        self.assertIn(b"resolved: second try", fx.rows_for(f"{REPORT_B}#1")[0])
        self.assertGreater(self.inbox.dump_calls, seen["dumps"])  # refreshed on 409


if __name__ == "__main__":
    unittest.main()
