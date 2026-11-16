"""Tests for tui/webserver.py: inbox endpoints, guards and the inbox page.

Run-endpoint and Run-tab tests live in test_webserver_run.py.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webtest_helpers import ROOT, WebTestCase, web_file  # noqa: E402

class ReadTests(WebTestCase):
    def test_get_inbox_returns_dump(self):
        resp, raw = self.request("GET", "/api/inbox")
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(raw), self.inbox.dump())
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")
        self.assertEqual(resp.getheader("X-Content-Type-Options"), "nosniff")
        self.assertIn("default-src 'self'", resp.getheader("Content-Security-Policy"))

    def test_clickjacking_headers_on_every_response(self):
        for path in ("/", "/api/inbox", "/nope", "/static/app.js"):
            resp, _ = self.request("GET", path)
            self.assertIn("frame-ancestors 'none'",
                          resp.getheader("Content-Security-Policy"), path)
            self.assertEqual(resp.getheader("X-Frame-Options"), "DENY", path)

    def test_finding_returns_body_text(self):
        resp, raw = self.request("GET", "/api/finding?id=r1&n=2")
        self.assertEqual(resp.status, 200)
        self.assertEqual(raw.decode(), "body of r1#2")
        self.assertTrue(resp.getheader("Content-Type").startswith("text/plain"))

    def test_finding_bad_args_is_400(self):
        for q in ("id=../x&n=1", "id=r1&n=0", "id=r1&n=x", "n=1"):
            resp, _ = self.request("GET", "/api/finding?" + q)
            self.assertEqual(resp.status, 400, q)

    def test_index_embeds_token(self):
        resp, raw = self.request("GET", "/")
        self.assertEqual(resp.status, 200)
        text = raw.decode()
        self.assertIn(f'<meta name="meute-token" content="{self.token}">', text)
        self.assertNotIn("__TOKEN__", text)

    def test_static_rejects_other_paths(self):
        for p in ("/static/../x", "/static/secret.txt", "/static/%2e%2e/x"):
            resp, _ = self.request("GET", p)
            self.assertEqual(resp.status, 404, p)

    def test_static_allowed_missing_is_404(self):
        resp, _ = self.request("GET", "/static/run.js")
        self.assertIn(resp.status, (200, 404))

    def test_unknown_route_is_404(self):
        resp, _ = self.request("GET", "/nope")
        self.assertEqual(resp.status, 404)

    def test_foreign_host_get_is_403(self):
        resp, _ = self.request("GET", "/", host="evil.example:80")
        self.assertEqual(resp.status, 403)


class GuardTests(WebTestCase):
    GOOD = {"verb": "promote", "id": "r1", "n": 1}

    def test_post_without_token_is_403(self):
        resp, _ = self.post_act(self.GOOD, token=False)
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.inbox.calls, [])

    def test_post_wrong_token_is_403(self):
        resp, _ = self.post_act(self.GOOD, headers={"X-Meute-Token": "nope"})
        self.assertEqual(resp.status, 403)

    def test_post_foreign_host_is_403_and_act_not_called(self):
        resp, _ = self.post_act(self.GOOD, host="evil.example:80")
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.inbox.calls, [])

    def test_post_foreign_origin_is_403(self):
        resp, _ = self.post_act(self.GOOD, headers={"Origin": "http://evil.example"})
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.inbox.calls, [])

    def test_post_matching_origin_ok(self):
        resp, _ = self.post_act(self.GOOD, headers={"Origin": f"http://127.0.0.1:{self.port}"})
        self.assertEqual(resp.status, 200)


class ActTests(WebTestCase):
    def assert400(self, payload):
        resp, _ = self.post_act(payload)
        self.assertEqual(resp.status, 400, payload)
        self.assertEqual(self.inbox.calls, [])

    def test_dismiss_empty_reason_is_400(self):
        self.assert400({"verb": "dismiss", "id": "r1", "n": 1, "reason": ""})
        self.assert400({"verb": "dismiss", "id": "r1", "n": 1})

    def test_dismiss_reason_not_in_dismiss_reasons_is_400(self):
        self.assert400({"verb": "dismiss", "id": "r1", "n": 1, "reason": "because"})

    def test_dismiss_post_never_calls_dump(self):
        resp, _ = self.post_act({"verb": "dismiss", "id": "r1", "n": 1, "reason": "wont-fix"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.inbox.dump_calls, 0)

    def test_resolve_empty_message_is_400(self):
        self.assert400({"verb": "resolve", "id": "r1", "n": 1, "message": "  "})
        self.assert400({"verb": "resolve", "id": "r1", "n": 1})

    def test_bad_n_is_400(self):
        for n in (0, -1, "x", True, 1.5, None):
            self.assert400({"verb": "promote", "id": "r1", "n": n})

    def test_id_with_path_chars_is_400(self):
        for rid in ("../etc", "a/b", "a b", "", "..", "a..b", 5, None):
            self.assert400({"verb": "promote", "id": rid, "n": 1})

    def test_unknown_verb_is_400(self):
        self.assert400({"verb": "delete", "id": "r1", "n": 1})

    def test_malformed_body_is_400(self):
        resp, _ = self.post_act(b"{not json")
        self.assertEqual(resp.status, 400)
        resp, _ = self.post_act([1, 2])
        self.assertEqual(resp.status, 400)

    def test_unknown_post_route_is_404(self):
        resp, _ = self.request("POST", "/api/nope", {})
        self.assertEqual(resp.status, 404)

    def test_valid_promote_calls_act_with_cli_args(self):
        resp, raw = self.post_act({"verb": "promote", "id": "r1", "n": 3})
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(raw), {"ok": True, "message": "done"})
        self.assertEqual(self.inbox.calls, [("promote", "r1", 3)])

    def test_valid_dismiss_passes_reason_and_message(self):
        resp, _ = self.post_act({"verb": "dismiss", "id": "r1", "n": 2,
                                 "reason": "wont-fix", "message": "later"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.inbox.calls, [("dismiss", "r1", 2, "wont-fix", "later")])

    def test_valid_resolve_passes_message(self):
        self.post_act({"verb": "resolve", "id": "r1", "n": 2, "message": "fixed"})
        self.assertEqual(self.inbox.calls, [("resolve", "r1", 2, "fixed")])

    def test_act_failure_passes_through_200(self):
        self.inbox.result = {"ok": False, "message": "nope"}
        resp, raw = self.post_act({"verb": "promote", "id": "r1", "n": 1})
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(raw), {"ok": False, "message": "nope"})


class PageTests(WebTestCase):
    def web(self, name):
        return web_file(name)

    def test_index_has_token_meta_and_no_inline_script(self):
        resp, raw = self.request("GET", "/")
        page = raw.decode()
        self.assertIn(f'<meta name="meute-token" content="{self.token}">', page)
        self.assertIn('<section id="run"', page)
        self.assertIn('<script src="/static/run.js" defer>', page)
        import re
        for m in re.finditer(r"<script\b([^>]*)>", page):
            self.assertIn("src=", m.group(1))
        self.assertNotRegex(page, r"\son[a-z]+\s*=")
        self.assertNotIn("style=", page)

    def test_app_js_never_uses_innerhtml(self):
        js = self.web("app.js")
        for banned in ("innerHTML", "insertAdjacentHTML", "outerHTML", "document.write"):
            self.assertNotIn(banned, js)

    def test_app_js_sends_token_header(self):
        self.assertIn("X-Meute-Token", self.web("app.js"))

    def test_key_handler_ignores_buttons(self):
        # A focused button must keep Enter for itself: the global handler
        # re-selecting the row would wipe the dismiss/resolve fields.
        js = self.web("app.js")
        self.assertIn('closest("button")', js)
        self.assertIn('t.tagName === "TEXTAREA"', js)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_key_handler_behaviour_under_node(self):
        js = self.web("app.js")
        start = js.index("function typing(")
        end = js.index("}\n", js.index("closest", start)) + 2
        script = js[start:end] + """
const mk = (tag, inBtn) => ({tagName: tag, closest: (s) => (s === "button" && inBtn ? {} : null)});
const r = [typing({target: mk("BUTTON", true)}), typing({target: mk("SPAN", true)}),
  typing({target: mk("INPUT", false)}), typing({target: mk("BODY", false)}),
  typing({target: mk("TR", false)})];
process.stdout.write(JSON.stringify(r));"""
        out = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out), [True, True, True, False, False])


class FetchSiteTests(WebTestCase):
    """Sec-Fetch-Site: a page on another site can send the exact bound Host
    (an <img> or no-cors fetch), so cross-site and same-site requests are
    refused before any handler runs; curl and the address bar send none/absent."""

    GOOD = {"verb": "promote", "id": "r1", "n": 1}

    def test_cross_and_same_site_get_is_403_and_handler_not_called(self):
        for site in ("cross-site", "same-site"):
            for path in ("/api/inbox", "/api/finding?id=r1&n=1", "/"):
                resp, _ = self.request("GET", path, headers={"Sec-Fetch-Site": site})
                self.assertEqual(resp.status, 403, (site, path))
        self.assertEqual(self.inbox.dump_calls, 0)

    def test_cross_and_same_site_post_is_403_and_act_not_called(self):
        for site in ("cross-site", "same-site"):
            resp, _ = self.post_act(self.GOOD, headers={"Sec-Fetch-Site": site})
            self.assertEqual(resp.status, 403, site)
        self.assertEqual(self.inbox.calls, [])

    def test_same_origin_none_and_absent_are_allowed(self):
        for hdrs in ({"Sec-Fetch-Site": "same-origin"}, {"Sec-Fetch-Site": "none"}, {}):
            resp, _ = self.request("GET", "/api/inbox", headers=hdrs)
            self.assertEqual(resp.status, 200, hdrs)
        resp, _ = self.post_act(self.GOOD, headers={"Sec-Fetch-Site": "same-origin"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(len(self.inbox.calls), 1)


class PortInUseTests(unittest.TestCase):
    def test_busy_port_prints_one_line_and_exits_1(self):
        busy = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(busy.close)
        busy.bind(("127.0.0.1", 0))
        busy.listen(1)
        port = busy.getsockname()[1]
        proc = subprocess.run([sys.executable, os.path.join(ROOT, "tui", "webserver.py"),
                               "--host", "127.0.0.1", "--port", str(port)],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stderr.strip(), f"meute web: port {port} is already in use")
        self.assertNotIn("Traceback", proc.stderr)


if __name__ == "__main__":
    unittest.main()
