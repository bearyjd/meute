"""Durable Resolve/Dismiss on POST /api/act, with REAL receipt storage.

The server runs decisions.run_decide against a disposable MEUTE_ROOT
(decisions_helpers.Fixture): real reports, real state/reports rows, real
receipts under state/receipts/decisions. Nothing about the decision path is
mocked. The browser tests (skipped visibly without firefox/chromium) drive
tui/web/app.js through a lost reply and a stale revision.
"""
import builtins
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock

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
        return inbox.finding_body(rid, n, bounded=bounded, root=self.root)

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

    def test_invalid_config_is_400_with_its_detail_and_writes_nothing(self):
        self.server.decisions_env["MEUTE_RECEIPT_TTL_DAYS"] = "abc"
        status, body = self.decide()
        self.assertEqual(status, 400, body)
        self.assertEqual((body["error"], body["var"]), ("invalid_config", "MEUTE_RECEIPT_TTL_DAYS"))
        self.assertIn("configuration", body["message"])
        self.assert_nothing_written()

    def test_inbox_state_note_and_revision_come_from_one_snapshot(self):
        # A CLI dismissal lands right after the inbox has read state/reports
        # once. Whatever the inbox shows, it must be one version of the file,
        # so a web decision on what was shown is refused as stale.
        reports_path = str(self.fx.reports_file)
        real_open = builtins.open
        landed = []

        def racing_open(file, mode="r", *a, **kw):
            if str(file) != reports_path or landed:
                return real_open(file, mode, *a, **kw)
            with real_open(file, "rb") as fh:
                data = fh.read()
            landed.append(self.fx.dismiss(REPORT_B, 1, "cli-key-race", rk.ABSENT, message="cli"))
            return io.BytesIO(data) if "b" in mode else io.StringIO(data.decode("utf-8"))

        self.fx.write_rows(b"alpha/audit-a#3\tdismissed\t2026-09-01\tdupe: old\n")
        with unittest.mock.patch("builtins.open", racing_open):
            resp, raw = self.request("GET", "/api/inbox")
        self.assertEqual(landed[0].returncode, 0, landed[0].stderr)
        f = next(x for x in json.loads(raw)["findings"] if x["report"] == REPORT_B and x["n"] == 1)
        self.assertEqual((f["state"], f["note"], f["revision"]), ("new", "", rk.ABSENT))
        status, body = self.decide(rid=REPORT_B, key="web-key-race", rev=f["revision"])
        self.assertEqual(status, 409, body)
        self.assertEqual(body["error"], "stale_revision")
        self.assertIn(b"wont-fix: cli", self.fx.rows_for(f"{REPORT_B}#1")[0])

    def test_evidence_route_takes_the_inbox_identity(self):
        resp, raw = self.request("GET", f"/api/finding?id={REPORT_B}&n=1")
        self.assertEqual(resp.status, 200, raw)
        self.assertIn("### [HIGH] Solo", raw.decode())
        self.assertIn("src/d.py:4", raw.decode())
        resp, raw = self.request("GET", f"/api/finding?id={REPORT_A}&n=2")
        self.assertEqual(resp.status, 200, raw)
        self.assertIn("### [HIGH] Two", raw.decode())
        self.assertNotIn("Three", raw.decode())
        resp, _ = self.request("GET", "/api/finding?id=alpha/missing&n=1")
        self.assertEqual(resp.status, 404)
        for q in ("id=alpha/../x&n=1", "id=alpha/./x&n=1", "id=a/b/c&n=1", "id=/x&n=1",
                  f"id={REPORT_B}&n=0"):
            resp, _ = self.request("GET", "/api/finding?" + q)
            self.assertEqual(resp.status, 400, q)

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
            [200, None], [400, None], [409, None], [400, {"error": "invalid_config"}],
        ]
        got = self.run_pure("process.stdout.write(JSON.stringify(%s.map(([s, b]) => classifyDecision(s, b))));"
                            % json.dumps(cases))
        self.assertEqual(got, ["ok", "stale", "conflict", "indeterminate", "unreadable",
                               "retry", "retry", "retry", "retry", "invalid", "invalid",
                               "retry", "retry", "retry", "invalid"])

    def test_request_key_matches_server_grammar_and_differs(self):
        got = self.run_pure(
            "const c = require('crypto');"
            "const r = (n) => c.randomBytes(n);"
            "process.stdout.write(JSON.stringify([newRequestKey(r), newRequestKey(r)]));")
        self.assertNotEqual(got[0], got[1])
        for key in got:
            self.assertRegex(key, r"^web-[0-9a-f]{32}$")
            self.assertTrue(rk.KEY_RE.fullmatch(key))


# ------------------------------------------------------- page harness ---

# The whole of tui/web/app.js under node, against a minimal fake DOM and a
# scripted fetch: the page's own Resolve/Retry/Reviewed handlers, without a
# browser. process.argv[1] is app.js, argv[2] the scenario.
HARNESS = r"""
"use strict";
const fs = require("fs");
const vm = require("vm");
class El {
  constructor(id) { this.id = id; this.children = []; this.hidden = false; this.value = "";
    this._text = ""; this.className = ""; this.listeners = {}; this.selectedIndex = 0;
    this.classList = { toggle() {}, add() {} }; this.tagName = "DIV"; }
  set textContent(t) { this._text = String(t); this.children = []; }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join(" ") : this._text; }
  appendChild(c) { this.children.push(c); return c; }
  replaceChildren(...c) { this.children = c; }
  get firstChild() { return this.children[0]; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  click() { (this.listeners.click || []).forEach((f) => f({})); }
  scrollIntoView() {}
  closest() { return null; }
}
const els = {};
const tbody = new El("tbody");
const docListeners = {};
globalThis.document = {
  getElementById: (id) => els[id] || (els[id] = new El(id)),
  querySelector: (sel) => sel.startsWith("meta") ? { content: "tok" }
    : sel === "#findings-table tbody" ? tbody : new El(sel),
  querySelectorAll: (sel) => sel === "#findings-table tbody tr" ? tbody.children : [],
  createElement: (tag) => { const e = new El(); e.tagName = tag.toUpperCase(); return e; },
  addEventListener: (t, f) => { docListeners[t] = f; },
  dispatchEvent() {},
};
globalThis.window = globalThis;
globalThis.CustomEvent = class { constructor(t, o) { this.type = t; this.detail = o && o.detail; } };
window.confirm = () => true;
const q = (id) => document.getElementById(id);
for (const id of ["retry-box", "review-box", "receipt", "panel"]) q(id).hidden = true;

const finding = (n, rev, state, note) => ({ report: "alpha/audit-a", n: n, repo: "alpha",
  severity: "HIGH", title: "T" + n, location: "src/x.py:" + n, lens: "l", date: "d",
  state: state || "new", note: note || "", revision: rev, inherited: "", hidden: false });
const inbox = { findings: [finding(1, "r1:absent"), finding(2, "r1:absent")],
  dismiss_reasons: ["wont-fix"], status: {}, branches: [], reports: [] };
let inboxFails = false;
const posts = [];
const replies = [];  // queue of {status, body} | {status, cut: true}
const log = { inboxReads: 0 };
globalThis.fetch = async (url, opts) => {
  if (url.startsWith("/api/client")) return { ok: true, status: 200 };
  if (url === "/api/inbox") {
    log.inboxReads++;
    if (inboxFails) return { ok: false, status: 500, json: async () => ({}) };
    return { ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(inbox)) };
  }
  if (url.startsWith("/api/finding")) return { ok: true, status: 200, text: async () => "evidence" };
  if (url === "/api/act") {
    posts.push(JSON.parse(opts.body));
    const r = replies.shift();
    if (!r) throw new TypeError("network");
    return { ok: r.status < 400, status: r.status,
      json: async () => { if (r.cut) throw new TypeError("body stream failed"); return r.body; } };
  }
  throw new Error("unexpected fetch " + url);
};
vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"), { filename: "app.js" });

const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
const row = (n) => tbody.children.find((tr) => tr.textContent.includes("src/x.py:" + n + " "));
async function pick(n) { row(n).click(); await settle(); }
async function resolve(n, text) { await pick(n); q("resolve-message").value = text; q("act-resolve").click(); await settle(); }
const receipt = (key) => ({ ok: true, replayed: false, message: "resolved",
  receipt: { receipt_id: "rcpt-1", operation: "finding.resolve", finding_key: "k", disposition: "actioned",
    request_key: key, before_revision: "r1:absent", after_revision: "r1:" + "b".repeat(64), phase: "complete" } });
const stale = (rev) => ({ ok: false, error: "stale_revision", current_revision: rev, message: "changed: review" });
const out = {};

async function cutReply() {
  await settle();
  replies.push({ status: 200, cut: true });
  await resolve(1, "fixed");
  out.afterCut = { retry: !q("retry-box").hidden, notice: q("notice").textContent, receipt: !q("receipt").hidden };
  // A new decision is refused while one is unconfirmed.
  q("act-resolve").click(); await settle();
  out.postsWhilePending = posts.length;
  replies.push({ status: 200, body: { ...receipt(posts[0].request_key), replayed: true } });
  q("act-retry").click(); await settle();
  out.afterRetry = { retry: !q("retry-box").hidden, receipt: q("receipt").textContent };
}

async function perFinding() {
  q("show-decided").checked = true;  // a refused finding is listed as decided now
  await settle();
  const revA = "r1:" + "a".repeat(64), revB = "r1:" + "c".repeat(64);
  replies.push({ status: 409, body: stale(revA) });
  inbox.findings[0] = finding(1, revA, "dismissed");
  await resolve(1, "first A");
  out.aBlocked = !q("review-box").hidden;
  replies.push({ status: 409, body: stale(revB) });
  inbox.findings[1] = finding(2, revB, "dismissed");
  await resolve(2, "first B");
  await pick(1);
  out.aStillBlocked = !q("review-box").hidden;
  q("resolve-message").value = "too soon"; q("act-resolve").click(); await settle();
  out.postsAfterTooSoon = posts.length;
  // Reviewed while the inbox cannot be read: A stays blocked.
  inboxFails = true;
  q("act-reviewed").click(); await settle();
  inboxFails = false;
  out.blockedWhenRefreshFails = !q("review-box").hidden;
  q("resolve-message").value = "still too soon"; q("act-resolve").click(); await settle();
  out.postsAfterFailedReview = posts.length;
  q("act-reviewed").click(); await settle();
  out.aReviewed = q("review-box").hidden;
  replies.push({ status: 200, body: receipt("x") });
  q("resolve-message").value = "second A"; q("act-resolve").click(); await settle();
  await pick(2);
  out.bStillBlocked = !q("review-box").hidden;
  q("resolve-message").value = "B too soon"; q("act-resolve").click(); await settle();
  out.posts = posts;
}

// A second decision lands between the stale refresh and Reviewed, with the
// same disposition as the first: Reviewed acknowledged the first one only.
async function changedAgain() {
  q("show-decided").checked = true;
  await settle();
  const revA = "r1:" + "a".repeat(64), revA2 = "r1:" + "d".repeat(64);
  replies.push({ status: 409, body: stale(revA) });
  inbox.findings[0] = finding(1, revA, "actioned", "resolved: first note");
  await resolve(1, "mine");
  out.shown1 = q("review-current").textContent;
  inbox.findings[0] = finding(1, revA2, "actioned", "resolved: second note");
  q("act-reviewed").click(); await settle();
  out.stillBlocked = !q("review-box").hidden;
  out.shown2 = q("review-current").textContent;
  out.notice2 = q("notice").textContent;
  q("resolve-message").value = "too soon"; q("act-resolve").click(); await settle();
  out.postsAfterChanged = posts.length;
  q("act-reviewed").click(); await settle();
  out.cleared = q("review-box").hidden;
  out.panelState = q("panel-state").textContent;
  replies.push({ status: 200, body: receipt("x") });
  q("resolve-message").value = "mine again"; q("act-resolve").click(); await settle();
  out.posts = posts;
}

({ cut_reply: cutReply, per_finding: perFinding, changed_again: changedAgain })[process.argv[2]]().then(
  () => process.stdout.write(JSON.stringify(out)),
  (e) => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""


@unittest.skipUnless(HAS_NODE, "node not installed")
class PageHarnessTests(unittest.TestCase):
    """app.js's real handlers (Resolve, Retry, Reviewed) under node."""

    def run_page(self, scenario):
        app = os.path.join(webserver.WEB_DIR, "app.js")
        proc = subprocess.run(["node", "-e", HARNESS, app, scenario], capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def test_reply_cut_after_200_headers_is_unconfirmed_and_retry_resends_it(self):
        out = self.run_page("cut_reply")
        self.assertTrue(out["afterCut"]["retry"], out)
        self.assertFalse(out["afterCut"]["receipt"], out)
        self.assertIn("not confirmed", out["afterCut"]["notice"])
        self.assertIn("HTTP 200", out["afterCut"]["notice"])
        self.assertEqual(out["postsWhilePending"], 1)
        self.assertFalse(out["afterRetry"]["retry"], out)
        self.assertIn("receipt rcpt-1", out["afterRetry"]["receipt"])

    def test_stale_review_is_kept_per_finding(self):
        out = self.run_page("per_finding")
        self.assertTrue(out["aBlocked"])
        self.assertTrue(out["aStillBlocked"], "a 409 for finding 2 cleared finding 1's review")
        self.assertEqual(out["postsAfterTooSoon"], 2)
        self.assertTrue(out["blockedWhenRefreshFails"])
        self.assertEqual(out["postsAfterFailedReview"], 2)
        self.assertTrue(out["aReviewed"])
        posts = out["posts"]
        self.assertEqual(len(posts), 3, posts)  # finding 2 is still blocked
        first_a, first_b, second_a = posts
        self.assertEqual((first_a["n"], first_b["n"], second_a["n"]), (1, 2, 1))
        self.assertEqual(second_a["expected_revision"], "r1:" + "a" * 64)
        self.assertEqual(second_a["message"], "second A")
        self.assertNotEqual(second_a["request_key"], first_a["request_key"])
        self.assertTrue(out["bStillBlocked"])

    def test_reviewed_acknowledges_only_the_revision_it_showed(self):
        out = self.run_page("changed_again")
        rev_a, rev_a2 = "r1:" + "a" * 64, "r1:" + "d" * 64
        # The review box shows disposition AND note, so the two same-disposition
        # decisions read differently.
        self.assertIn("actioned", out["shown1"])
        self.assertIn("first note", out["shown1"])
        self.assertIn(rev_a, out["shown1"])
        self.assertTrue(out["stillBlocked"], "Reviewed cleared a block for a revision it never showed")
        self.assertIn("second note", out["shown2"])
        self.assertIn(rev_a2, out["shown2"])
        self.assertIn("changed again", out["notice2"])
        self.assertEqual(out["postsAfterChanged"], 1)
        self.assertTrue(out["cleared"])
        self.assertIn("second note", out["panelState"])
        self.assertIn(rev_a2, out["panelState"])
        posts = out["posts"]
        self.assertEqual(len(posts), 2, posts)
        self.assertEqual(posts[1]["expected_revision"], rev_a2)
        self.assertEqual(posts[1]["message"], "mine again")
        self.assertNotEqual(posts[0]["request_key"], posts[1]["request_key"])


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
    // The finding's real evidence, from GET /api/finding, not an error text.
    await until("panel", () => visible("panel") && q("panel-body").textContent !== "loading...");
    const evidence = q("panel-body").textContent;
    if (!evidence.includes("### [HIGH] Solo")) throw new Error("no evidence: " + evidence);
    return evidence;
  }
  async function resolve(text) {
    q("resolve-message").value = text;
    q("act-resolve").click();
  }
  async function lostReply() {
    const evidence = await pick();
    await resolve("fixed upstream");
    await until("retry box", () => visible("retry-box"));
    q("act-retry").click();
    await until("receipt", () => visible("receipt") && q("receipt").textContent.includes("receipt "));
    // The refresh after success: the decided row leaves the default inbox.
    await until("inbox refresh", () => !Array.from(rows()).some((tr) => tr.textContent.includes("src/d.py:4")));
    return { receipt: q("receipt").textContent, notice: q("notice").textContent, evidence: evidence };
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
    const shown1 = q("review-current").textContent;
    // A second CLI decision lands before the operator presses Reviewed.
    const r = await fetch("/test/concurrent");
    if (!r.ok) throw new Error("concurrent decision failed: HTTP " + r.status);
    q("act-reviewed").click();
    await until("changed again", () => q("notice").textContent.includes("changed again"));
    const keptBlocked = visible("review-box");
    const shown2 = q("review-current").textContent;
    await resolve("still too soon");
    await sleep(300);
    q("act-reviewed").click();
    await until("re-selected", () => !visible("review-box") && q("resolve-message").value === ""
      && q("panel-body").textContent !== "loading...");
    const panelState = q("panel-state").textContent;
    await resolve("second try");
    await until("receipt", () => visible("receipt"));
    return { staleNotice: staleNotice, blocked: blocked, receipt: q("receipt").textContent,
      shown1: shown1, keptBlocked: keptBlocked, shown2: shown2, panelState: panelState };
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

    def _routes(self, scenario, on_post, extra=None):
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

        routes = {("GET", "/"): index, ("GET", "/test/drive.js"): drive,
                  ("GET", "/test/report"): report, ("POST", "/api/act"): act}
        routes.update(extra or {})
        return routes

    def drive(self, scenario, on_post, extra=None):
        from unittest.mock import patch
        patcher = patch.dict(webserver.ROUTES, self._routes(scenario, on_post, extra))
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
        self.assertIn("src/d.py:4", result["evidence"])
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

        def concurrent(h, query):
            # Same disposition as the first CLI decision, another note.
            proc = fx.resolve(REPORT_B, 1, "cli-key-0002", seen["current"], message="cli again")
            seen["current2"] = fx.revision(REPORT_B, 1)
            h.send_json(200 if proc.returncode == 0 else 500, {"ok": proc.returncode == 0})

        result = self.drive("stale", on_post, {("GET", "/test/concurrent"): concurrent})
        # "too soon" and "still too soon" never left the page.
        self.assertEqual(len(self.posts), 2, self.posts)
        first, second = self.posts
        self.assertEqual(self.replies[0][0], 409)
        self.assertEqual(self.replies[0][1]["error"], "stale_revision")
        self.assertIn(seen["current"], result["staleNotice"])
        self.assertIn("Reviewed", result["blocked"])
        self.assertNotEqual(first["request_key"], second["request_key"])
        self.assertEqual(first["expected_revision"], rk.ABSENT)
        self.assertNotEqual(seen["current2"], seen["current"])
        self.assertIn(seen["current"], result["shown1"])
        self.assertIn("resolved: cli", result["shown1"])
        self.assertTrue(result["keptBlocked"], "Reviewed cleared a block for a revision it never showed")
        self.assertIn(seen["current2"], result["shown2"])
        self.assertIn("resolved: cli again", result["shown2"])
        self.assertIn(seen["current2"], result["panelState"])
        self.assertEqual(second["expected_revision"], seen["current2"])
        self.assertEqual(second["message"], "second try")
        self.assertEqual(self.replies[1][0], 200)
        self.assertIn(b"resolved: second try", fx.rows_for(f"{REPORT_B}#1")[0])
        self.assertGreater(self.inbox.dump_calls, seen["dumps"])  # refreshed on 409


if __name__ == "__main__":
    unittest.main()
