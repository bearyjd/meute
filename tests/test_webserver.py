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
from webtest_helpers import ROOT, WebTestCase, web_file, webserver  # noqa: E402

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
        resp, raw = self.request("GET", "/", headers={"Cookie": f"meute_t_{self.port}={self.token}"})
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
        resp, raw = self.request("GET", "/", headers={"Cookie": f"meute_t_{self.port}={self.token}"})
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


class TokenTests(WebTestCase):
    """R17: the token reaches only a browser that opened the startup link."""

    def cookie(self):
        return {"Cookie": f"meute_t_{self.port}={self.token}"}

    def test_index_without_cookie_hides_token(self):
        resp, raw = self.request("GET", "/")
        text = raw.decode()
        self.assertNotIn(self.token, text)
        self.assertNotIn("meute-token", text)
        self.assertIn("open the link printed in the terminal", text)
        self.assertNotIn("<script", text)

    def test_startup_link_sets_cookie_and_redirects(self):
        resp, raw = self.request("GET", f"/?t={self.token}")
        self.assertIn(resp.status, (302, 303))
        self.assertEqual(resp.getheader("Location"), "/")
        self.assertNotIn(self.token, raw.decode())
        cookie = resp.getheader("Set-Cookie") or ""
        self.assertTrue(cookie.startswith(f"meute_t_{self.port}={self.token}"), cookie)
        for attr in ("HttpOnly", "SameSite=Strict", "Path=/"):
            self.assertIn(attr, cookie)
        self.assertNotIn("Secure", cookie)
        self.assertEqual(resp.getheader("X-Frame-Options"), "DENY")

    def test_wrong_t_sets_no_cookie(self):
        for q in ("t=nope", "t=%C3%A9", "t="):
            resp, raw = self.request("GET", "/?" + q)
            self.assertIsNone(resp.getheader("Set-Cookie"), q)
            self.assertNotIn(self.token, raw.decode(), q)
            self.assertIn("open the link printed in the terminal", raw.decode(), q)

    def test_wrong_or_malformed_cookie_hides_token(self):
        for c in (f"meute_t_{self.port}=nope", f"meute_t_{self.port}=é",
                  f"meute_t_1={self.token}", 'a="b'):
            resp, raw = self.request("GET", "/", headers={"Cookie": c})
            self.assertEqual(resp.status, 403, c)
            self.assertNotIn(self.token, raw.decode(errors="replace"), c)

    def test_index_with_cookie_embeds_token(self):
        resp, raw = self.request("GET", "/", headers=self.cookie())
        self.assertEqual(resp.status, 200)
        self.assertIn(f'<meta name="meute-token" content="{self.token}">', raw.decode())

    def test_cookie_does_not_replace_post_token(self):
        resp, _ = self.post_act({"verb": "promote", "id": "r1", "n": 1},
                                token=False, headers=self.cookie())
        self.assertEqual(resp.status, 403)
        self.assertEqual(self.inbox.calls, [])


class SocketLimitTests(unittest.TestCase):
    """R22: an idle client cannot hold a thread forever, and threads are capped."""

    def test_handler_timeout_is_30(self):
        self.assertEqual(webserver.Handler.timeout, 30)

    def test_connections_over_the_cap_are_refused(self):
        import time
        old_max, old_timeout = getattr(webserver, "MAX_THREADS", None), webserver.Handler.timeout
        webserver.MAX_THREADS, webserver.Handler.timeout = 2, 3
        self.addCleanup(setattr, webserver.Handler, "timeout", old_timeout)
        self.addCleanup(setattr, webserver, "MAX_THREADS", old_max)
        t = WebTestCase("setUp")
        t.setUp()
        self.addCleanup(t.doCleanups)
        idle = [socket.create_connection(("127.0.0.1", t.port), timeout=5) for _ in range(2)]
        for s in idle:
            self.addCleanup(s.close)
        time.sleep(0.3)
        extra = socket.create_connection(("127.0.0.1", t.port), timeout=5)
        self.addCleanup(extra.close)
        extra.sendall(f"GET /api/inbox HTTP/1.0\r\nHost: 127.0.0.1:{t.port}\r\n\r\n".encode())
        try:
            data = extra.recv(4096)
        except ConnectionResetError:
            data = b""
        self.assertEqual(data, b"")
        for s in idle:
            s.close()
        time.sleep(0.3)
        resp, _ = t.request("GET", "/api/inbox")
        self.assertEqual(resp.status, 200)


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


class UmaskTests(unittest.TestCase):
    """P2.4 (R21): the server and the runs it starts create owner-only files."""

    def test_main_sets_owner_only_umask(self):
        code = (
            "import errno, os, sys\n"
            "sys.path.insert(0, sys.argv[1])\n"
            "import webserver\n"
            "def busy(*a, **k): raise OSError(errno.EADDRINUSE, 'busy')\n"
            "webserver.make_server = busy\n"
            "sys.argv = ['webserver.py']\n"
            "os.umask(0o022)\n"
            "try:\n    webserver.main()\nexcept SystemExit:\n    pass\n"
            "print(oct(os.umask(0)))\n"
        )
        proc = subprocess.run([sys.executable, "-c", code, os.path.join(ROOT, "tui")],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.stdout.strip(), "0o77", proc.stderr)


if __name__ == "__main__":
    unittest.main()
