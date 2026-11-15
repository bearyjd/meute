"""Tests for tui/webserver.py's Run endpoints and the Run tab (tui/web/run.js).
The run module is faked; meute plan and run.sh never run."""
import json
import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webtest_helpers import FakeRun, WebTestCase, node_pure, web_file, webserver  # noqa: E402

HAS_NODE = shutil.which("node") is not None


class RunEndpointTests(WebTestCase):
    run_factory = FakeRun

    def test_run_endpoints_require_token(self):
        for path, body in (("/api/enqueue", {"paths": ["/a"]}), ("/api/run/start", {}),
                           ("/api/run/stop", {})):
            resp, _ = self.request("POST", path, body, token=False)
            self.assertEqual(resp.status, 403, path)
            resp, _ = self.request("POST", path, body, headers={"X-Meute-Token": "nope"})
            self.assertEqual(resp.status, 403, path)
            resp, _ = self.request("POST", path, body, headers={"Origin": "http://evil.example"})
            self.assertEqual(resp.status, 403, path)
        self.assertEqual(self.run.calls, [])

    def test_run_gets_require_host(self):
        for path in ("/api/plan", "/api/run/status"):
            resp, _ = self.request("GET", path, host="evil.example:80")
            self.assertEqual(resp.status, 403, path)
        self.assertEqual(self.run.calls, [])

    def test_cross_site_run_requests_are_403_and_run_not_called(self):
        for site in ("cross-site", "same-site"):
            for path in ("/api/plan", "/api/run/status"):
                resp, _ = self.request("GET", path, headers={"Sec-Fetch-Site": site})
                self.assertEqual(resp.status, 403, (site, path))
            for path, body in (("/api/enqueue", {"paths": ["/a"]}), ("/api/run/start", {})):
                resp, _ = self.request("POST", path, body, headers={"Sec-Fetch-Site": site})
                self.assertEqual(resp.status, 403, (site, path))
        self.assertEqual(self.run.calls, [])

    def test_same_origin_plan_allowed(self):
        resp, _ = self.request("GET", "/api/plan", headers={"Sec-Fetch-Site": "same-origin"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.run.calls, [("plan",)])

    def test_enqueue_empty_is_400(self):
        resp, raw = self.request("POST", "/api/enqueue", {"paths": []})
        self.assertEqual(resp.status, 400)
        self.assertFalse(json.loads(raw)["ok"])

    def test_enqueue_bad_body_is_400(self):
        for body in ([1], {"paths": "x"}, {}):
            resp, _ = self.request("POST", "/api/enqueue", body)
            self.assertEqual(resp.status, 400, body)
        self.assertEqual(self.run.calls, [])

    def test_enqueue_passes_paths(self):
        resp, raw = self.request("POST", "/api/enqueue", {"paths": ["/a b", "/c"]})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.run.calls, [("enqueue", ["/a b", "/c"])])
        self.assertEqual(json.loads(raw)["staged"], 2)

    def test_start_conflict_is_409(self):
        self.run.start_error = webserver.runctl.RunConflict("the fleet is paused")
        resp, raw = self.request("POST", "/api/run/start", {})
        self.assertEqual(resp.status, 409)
        self.assertEqual(json.loads(raw), {"ok": False, "message": "the fleet is paused"})

    def test_start_value_error_is_400(self):
        self.run.start_error = ValueError("nothing is staged")
        resp, _ = self.request("POST", "/api/run/start", {})
        self.assertEqual(resp.status, 400)

    def test_start_stop_status_plan(self):
        resp, raw = self.request("POST", "/api/run/start", {})
        self.assertEqual((resp.status, json.loads(raw)), (200, {"state": "running"}))
        resp, raw = self.request("POST", "/api/run/stop", {})
        self.assertEqual(resp.status, 200)
        resp, raw = self.request("GET", "/api/run/status")
        self.assertEqual(json.loads(raw), {"state": "idle", "total": 0})
        resp, raw = self.request("GET", "/api/plan")
        self.assertEqual(json.loads(raw)["scan"], "/s")
        self.assertEqual([c[0] for c in self.run.calls], ["start", "stop", "status", "plan"])

    def test_runner_failure_is_502(self):
        def boom():
            raise webserver.runctl.RunnerFailed("meute plan --json failed (exit 1)")
        self.run.plan = boom
        resp, raw = self.request("GET", "/api/plan")
        self.assertEqual(resp.status, 502)
        self.assertIn("exit 1", json.loads(raw)["message"])

    def test_plan_in_flight_is_409(self):
        def busy():
            raise webserver.runctl.RunConflict("a plan scan is already running")
        self.run.plan = busy
        resp, raw = self.request("GET", "/api/plan")
        self.assertEqual(resp.status, 409)
        self.assertIn("already running", json.loads(raw)["message"])

    def test_default_run_mod_is_a_run_controller(self):
        server, _ = webserver.make_server("127.0.0.1", 0, self.inbox)
        self.addCleanup(server.server_close)
        self.assertIsInstance(server.run_mod, webserver.runctl.RunController)
        self.assertEqual(server.run_mod.root, webserver.ROOT)


class RunPageTests(WebTestCase):
    run_factory = FakeRun

    def test_run_js_never_uses_innerhtml(self):
        js = web_file("run.js")
        for banned in ("innerHTML", "insertAdjacentHTML", "outerHTML", "document.write", "style="):
            self.assertNotIn(banned, js)

    def test_page_scripts_share_no_top_level_names(self):
        """Classic scripts share one global scope: a function in run.js with the
        name of one in app.js silently replaces it (found live: run.js's
        renderStatus broke the inbox load)."""
        import re
        decl = re.compile(r"^(?:async\s+)?(?:function\s+|(?:const|let|var)\s+)([A-Za-z_$][\w$]*)", re.M)
        seen = {}
        for name in ("app.js", "run.js"):
            for ident in set(decl.findall(web_file(name))):
                self.assertNotIn(ident, seen, f"{ident!r} declared in both {seen.get(ident)} and {name}")
                seen[ident] = name

    def test_run_js_sends_token_header(self):
        self.assertIn("X-Meute-Token", web_file("run.js"))

    def test_index_loads_run_js(self):
        resp, raw = self.request("GET", "/")
        self.assertIn('<script src="/static/run.js" defer>', raw.decode())
        resp, raw = self.request("GET", "/static/run.js")
        self.assertEqual(resp.status, 200)

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_pure_helpers_under_node(self):
        r = node_pure("""process.stdout.write(JSON.stringify([
  groupByRepo([{repo: "a", path: "/p/a", task: "t1", reason: "r"}, {repo: "b", path: "/p/b", task: "t2"},
               {repo: "a", path: "/p/a", task: "t3"}]).map((g) => [g.path, g.tasks.length]),
  enqueuePayload([{path: "/p/a", checked: true}, {path: "/p/b", checked: false}, {path: "/p/a", checked: true}]),
  progressValues({total: 4, done: 1}), progressValues({total: 0, done: 0}), progressValues(null),
]));""")
        self.assertEqual(r, [
            [["/p/a", 2], ["/p/b", 1]], {"paths": ["/p/a"]},
            {"max": 4, "value": 1}, {"max": 1, "value": 0}, {"max": 1, "value": 0}])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_stale_poll_response_dropped(self):
        r = node_pure("process.stdout.write(JSON.stringify([shouldApply(2, 3), shouldApply(3, 3), shouldApply(4, 3)]));")
        self.assertEqual(r, [False, False, True])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_stop_not_blocked_by_busy(self):
        r = node_pure("""const b = (o) => buttonFlags(Object.assign({state: "running", pollFailed: false,
  busy: false, stopBusy: false, anyChecked: true}, o)).stop;
process.stdout.write(JSON.stringify([b({busy: true}), b({stopBusy: true}), b({pollFailed: true, busy: true}),
  b({pollFailed: true, stopBusy: true})]));""")
        self.assertEqual(r, [True, False, True, False])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_button_flags_unknown_state_disables_start_enqueue(self):
        r = node_pure("""const f = (o) => buttonFlags(Object.assign({state: "idle", pollFailed: false,
  busy: false, stopBusy: false, anyChecked: true}, o));
const pick = (x) => [x.start, x.enqueue, x.stop];
process.stdout.write(JSON.stringify([pick(f({})), pick(f({pollFailed: true})), pick(f({state: "running"})),
  pick(f({busy: true})), pick(f({anyChecked: false}))]));""")
        self.assertEqual(r, [[True, True, False], [False, False, True], [False, False, True],
                             [False, False, False], [True, False, False]])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_enqueue_confirm_shows_full_path_per_repo(self):
        text = node_pure("""process.stdout.write(JSON.stringify(enqueueConfirmText([
  {repo: "src", path: "/home/u/one/src", checked: true},
  {repo: "src", path: "/home/u/two/src", checked: true},
  {repo: "skip", path: "/home/u/skip", checked: false},
  {repo: "src", path: "/home/u/one/src", checked: true}])));""")
        lines = text.split("\n")
        self.assertIn("/home/u/one/src", lines)
        self.assertIn("/home/u/two/src", lines)
        self.assertEqual(lines.count("/home/u/one/src"), 1)
        self.assertNotIn("/home/u/skip", text)
        self.assertTrue(lines[0].startswith("Enqueue 2 repo"))
        self.assertIn("sent to the model provider", text)
        self.assertIn("replaces the currently staged queue", text)

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_excluded_summary_shows_counts_and_names_title(self):
        r = node_pure("""process.stdout.write(JSON.stringify([
  excludedSummary({web: ["a", "b"], other: ["c"]}), excludedSummary({}), excludedSummary(undefined),
  excludedSummary({web: 3, other: 0})]));""")
        self.assertEqual(r[0], {"text": "excluded web 2 / other 1", "title": "web: a, b\nother: c"})
        self.assertEqual(r[1], {"text": "excluded web 0 / other 0", "title": ""})
        self.assertEqual(r[2], {"text": "excluded web 0 / other 0", "title": ""})
        self.assertEqual(r[3]["text"], "excluded web 3 / other 0")

    def test_run_js_poll_error_has_own_element(self):
        js = web_file("run.js")
        self.assertIn("run-status-error", js)
        self.assertNotIn('"status failed', js)
        self.assertLess(len(js.splitlines()), 400)


if __name__ == "__main__":
    unittest.main()
