"""Tests for tui/webserver.py's Run endpoints and the Run tab (tui/web/run.js).
The run module is faked; meute plan and run.sh never run."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webtest_helpers import FakeRun, WebTestCase, node_pure, web_file, webserver  # noqa: E402
from runctl_helpers import ALPHA, FakeFleet  # noqa: E402

DUP = "/scan root/projects/output/alpha copy"

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
        self.assertEqual(json.loads(raw)["plan"]["scan"], "/s")
        self.assertEqual([c[0] for c in self.run.calls], ["start", "stop", "status", "plan"])

    def test_start_passes_the_source_and_defaults_to_plan(self):
        self.request("POST", "/api/run/start", {"source": "manifest"})
        self.request("POST", "/api/run/start", {})
        self.assertEqual(self.run.calls, [("start", "manifest"), ("start", "plan")])

    def test_start_source_must_be_a_string(self):
        resp, _ = self.request("POST", "/api/run/start", {"source": 3})
        self.assertEqual(resp.status, 400)
        self.assertEqual(self.run.calls, [])

    def test_plan_start_requires_token_and_starts_a_job(self):
        resp, _ = self.request("POST", "/api/plan/start", {}, token=False)
        self.assertEqual(resp.status, 403)
        resp, raw = self.request("POST", "/api/plan/start", {})
        self.assertEqual(resp.status, 200)
        self.assertTrue(json.loads(raw)["scanning"])
        self.assertEqual(self.run.calls, [("plan_start",)])


class DuplicateEnqueueTests(WebTestCase):
    """The real controller behind the endpoint, over a fake fleet whose plan
    lists a collapsed copy: enqueueing the copy is a 400 and stages nothing."""

    def run_factory(self):
        root = tempfile.mkdtemp(prefix="meute web dup ")
        self.addCleanup(shutil.rmtree, root)
        os.makedirs(os.path.join(root, "state"))
        self.fleet = FakeFleet(root)
        self.fleet.duplicates = [{"path": DUP, "of": ALPHA, "reason": "duplicate of " + ALPHA}]
        return webserver.runctl.RunController(root, runner=self.fleet)

    def test_enqueue_duplicate_is_400(self):
        resp, raw = self.request("POST", "/api/enqueue", {"paths": [DUP]})
        self.assertEqual(resp.status, 400)
        self.assertIn(DUP, json.loads(raw)["message"])
        self.assertFalse(os.path.exists(os.path.join(self.fleet.state, "plan-queue.json")))

    def test_enqueue_canonical_still_stages(self):
        resp, raw = self.request("POST", "/api/enqueue", {"paths": [ALPHA]})
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(raw)["staged"], 1)


class SlowPlanTests(WebTestCase):
    """P1.6 / R10: a 3 s scan polled every 1 s: the page gets the result and
    never a 502, and the start request does not wait for the scan."""

    def run_factory(self):
        root = tempfile.mkdtemp(prefix="meute web slow ")
        self.addCleanup(shutil.rmtree, root)
        os.makedirs(os.path.join(root, "state"))
        fleet = FakeFleet(root)

        def slow(argv, cwd, out_path=None, timeout=None):
            if "--json" in argv:
                time.sleep(3)
            return fleet(argv, cwd, out_path=out_path, timeout=timeout)
        return webserver.runctl.RunController(root, runner=slow)

    def test_poll_gets_result_and_never_a_502(self):
        t0 = time.time()
        resp, raw = self.request("POST", "/api/plan/start", {})
        self.assertEqual(resp.status, 200)
        self.assertLess(time.time() - t0, 1.5)
        statuses, body = [], {}
        for _ in range(8):
            resp, raw = self.request("GET", "/api/plan")
            statuses.append(resp.status)
            body = json.loads(raw)
            if not body["scanning"]:
                break
            time.sleep(1)
        self.assertEqual(set(statuses), {200})
        self.assertGreater(len(statuses), 1)
        self.assertFalse(body["scanning"])
        self.assertIn("items", body["plan"])


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

    def test_run_tab_has_select_all_and_select_none(self):
        js = web_file("run.js")
        for needle in ('"run-all", "select all"', '"run-none", "select none"',
                       'setAllChecked(true)', 'setAllChecked(false)'):
            self.assertIn(needle, js)
        # still nothing ticked by default: the plan list never pre-checks a box
        self.assertNotIn("checked = true", js.split("function setAllChecked")[0])

    def test_run_js_sends_token_header(self):
        self.assertIn("X-Meute-Token", web_file("run.js"))

    def test_index_loads_run_js(self):
        resp, raw = self.request("GET", "/", headers={"Cookie": f"meute_t_{self.port}={self.token}"})
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
  busy: false, stopBusy: false, anyChecked: true, staged: true}, o));
const pick = (x) => [x.start, x.enqueue, x.stop];
process.stdout.write(JSON.stringify([pick(f({})), pick(f({pollFailed: true})), pick(f({state: "running"})),
  pick(f({busy: true})), pick(f({anyChecked: false})), pick(f({staged: false}))]));""")
        self.assertEqual(r, [[True, True, False], [False, False, True], [False, False, True],
                             [False, False, False], [True, False, False], [False, True, False]])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_manifest_source_starts_without_a_staged_plan(self):
        r = node_pure("""const f = (o) => buttonFlags(Object.assign({state: "idle", pollFailed: false,
  busy: false, stopBusy: false, anyChecked: false, staged: false}, o));
const sh = (x) => [x.start, x.hint];
process.stdout.write(JSON.stringify([sh(f({})), sh(f({source: "plan"})), sh(f({source: "manifest"})),
  sh(f({source: "manifest", state: "running"})), sh(f({source: "manifest", busy: true}))]));""")
        self.assertEqual(r, [[False, True], [False, True], [True, False], [False, False], [False, False]])

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_run_js_start_needs_something_staged(self):
        r = node_pure("""const flags = (st, o) => buttonFlags(Object.assign({state: "idle", pollFailed: false,
  busy: false, stopBusy: false, anyChecked: true, staged: isStaged(st)}, o));
const sh = (x) => [x.start, x.stop, x.hint];
process.stdout.write(JSON.stringify([
  sh(flags({total: 3, remaining: 3})),                    // idle + staged
  sh(flags({total: 0, remaining: 0})),                    // empty queue
  sh(flags({total: 3, remaining: 0})),                    // finished plan
  sh(flags(null)),                                        // no status yet
  sh(flags({total: 3, remaining: 3}, {state: "running"})),
  sh(flags({total: 3, remaining: 3}, {pollFailed: true})),
  sh(flags({total: 3, remaining: 3}, {busy: true})),
  [isStaged({total: 2, remaining: 1}), isStaged({total: 2}), isStaged(undefined)]]));""")
        self.assertEqual(r, [
            [True, False, False],      # Start enabled, no hint
            [False, False, True],      # nothing staged: hint
            [False, False, True],
            [False, False, True],
            [False, True, False],      # running: Stop unchanged, no hint
            [False, True, False],      # unknown: Start off, Stop on, no hint
            [False, False, False],
            [True, False, False]])

    def test_run_js_start_hint_is_text_only_and_wired(self):
        js = web_file("run.js")
        self.assertIn("run-start-hint", js)
        self.assertIn("nothing staged: Plan, tick repos, Enqueue first", js)
        self.assertIn("staged: isStaged(runUi.status)", js)
        self.assertNotIn("innerHTML", js)

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
        # Decision D3: the page appends (--append); it never replaces.
        self.assertIn("added to the currently staged queue", text)

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_excluded_summary_shows_counts_and_names_title(self):
        r = node_pure("""process.stdout.write(JSON.stringify([
  excludedSummary({web: ["a", "b"], other: ["c"]}), excludedSummary({}), excludedSummary(undefined),
  excludedSummary({web: 3, other: 0})]));""")
        self.assertEqual(r[0], {"text": "excluded web 2 / other 1", "title": "web: a, b\nother: c"})
        self.assertEqual(r[1], {"text": "excluded web 0 / other 0", "title": ""})
        self.assertEqual(r[2], {"text": "excluded web 0 / other 0", "title": ""})
        self.assertEqual(r[3]["text"], "excluded web 3 / other 0")

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_duplicate_summary_and_hidden_copies(self):
        r = node_pure("""process.stdout.write(JSON.stringify([
  planDedupSummary({items: [{path: "/p/a"}],
                    duplicates: [{path: "/o/a", of: "/p/a"}, {path: "/o/b", of: "/p/a"},
                                 {path: "/c", of: "/enrolled", reason: "already enrolled as e"}],
                    skipped: [{path: "/s one"}, {path: "/s2"}], diverged: [{path: "/d", of: "/p/a"}]}),
  planDedupSummary({}),
  copiesByCanonical([{path: "/o/b", of: "/p/a"}, {path: "/o/a", of: "/p/a"}, {path: "/c", of: "/e"}, null]),
  copiesByCanonical(undefined),
  hiddenCopiesText(1), hiddenCopiesText(3)]));""")
        self.assertEqual(r[0]["text"], "3 duplicate copies collapsed, 2 skipped, 1 diverged copy kept")
        self.assertEqual(r[0]["skipped"], ["/s one", "/s2"])
        title = r[0]["title"].split("\n")
        self.assertIn("skipped (no readable history): /s one", title)
        self.assertIn("skipped (no readable history): /s2", title)
        self.assertIn("/c -> already enrolled as e", title)   # its `of` has no row
        self.assertIn("/d diverged from /p/a (kept)", title)
        self.assertFalse(any(t.startswith("/o/") for t in title))  # shown under their row
        self.assertEqual(r[1], {"text": "0 duplicate copies collapsed, 0 skipped", "title": "", "skipped": []})
        self.assertEqual(r[2], {"/p/a": ["/o/b", "/o/a"], "/e": ["/c"]})
        self.assertEqual(r[3], {})
        self.assertEqual(r[4], "1 duplicate copy hidden")
        self.assertEqual(r[5], "3 duplicate copies hidden")

    @unittest.skipUnless(HAS_NODE, "node not installed")
    def test_hostile_keys_do_not_count_as_rows(self):
        r = node_pure("""const bad = ["__proto__", "constructor", "toString"];
const plan = {items: [{path: "/p/a", repo: "a", task: "t"}],
  duplicates: bad.map((k) => ({path: "/d/" + k, of: k})),
  skipped: bad.map((k) => ({path: k}))};
const sum = planDedupSummary(plan);
const copies = copiesByCanonical(bad.map((k) => ({path: "/c/" + k, of: k})));
const groups = groupByRepo(bad.map((k) => ({path: k, repo: k, task: "t"})));
process.stdout.write(JSON.stringify([sum, bad.map((k) => copies[k]), groups.map((g) => g.path),
  planDedupSummary({items: "x", duplicates: 5, skipped: {}, diverged: null}),
  copiesByCanonical("x"), groupByRepo({})]));""")
        title = r[0]["title"].split("\n")
        self.assertEqual(r[0]["text"], "3 duplicate copies collapsed, 3 skipped")
        self.assertEqual(r[0]["skipped"], ["__proto__", "constructor", "toString"])
        for k in ("__proto__", "constructor", "toString"):   # their `of` has no row
            self.assertIn("/d/" + k + " -> " + k, title)
        self.assertEqual(r[1], [["/c/__proto__"], ["/c/constructor"], ["/c/toString"]])
        self.assertEqual(r[2], ["__proto__", "constructor", "toString"])
        self.assertEqual(r[3], {"text": "0 duplicate copies collapsed, 0 skipped", "title": "", "skipped": []})
        self.assertEqual(r[4], {})
        self.assertEqual(r[5], [])

    def test_run_js_hidden_copies_use_text_and_title_only(self):
        js = web_file("run.js")
        self.assertIn("hiddenCopiesText(", js)
        self.assertIn('setAttribute("title"', js)
        self.assertIn("planDedupSummary(plan)", js)
        self.assertIn("run-skipped", js)  # the skipped paths, listed as text

    def test_run_js_poll_error_has_own_element(self):
        js = web_file("run.js")
        self.assertIn("run-status-error", js)
        self.assertNotIn('"status failed', js)
        self.assertLess(len(js.splitlines()), 400)


if __name__ == "__main__":
    unittest.main()
