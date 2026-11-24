"""Exercise complete HTTP requests and Fleet startups without a listening socket."""

import http.client
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from webtest_helpers import ROOT, webserver  # noqa: E402

FINDING_PATH = "/fleet/finding/alpha/audit/2"


class MemorySocket:
    def __init__(self, incoming):
        self.incoming = io.BytesIO(incoming)
        self.outgoing = bytearray()

    def settimeout(self, timeout):
        pass

    def makefile(self, mode, *args):
        return self.incoming

    def sendall(self, data):
        self.outgoing.extend(data)


class MemoryServer:
    def __init__(self, address, handler):
        self.server_port = address[1]
        self.handler = handler

    def serve_forever(self):
        pass

    def server_close(self):
        pass

    def request(self, method, target, headers=(), host="127.0.0.1"):
        request = [f"{method} {target} HTTP/1.1", f"Host: {host}:{self.server_port}", *headers]
        return self.raw_request(request, method)

    def raw_request(self, request, method="GET"):
        conn = MemorySocket(("\r\n".join(request) + "\r\n\r\n").encode())
        self.handler(conn, ("127.0.0.1", 1), self)
        response = http.client.HTTPResponse(MemorySocket(conn.outgoing), method=method)
        response.begin()
        return response, response.read()


class FleetTests(unittest.TestCase):
    def start(self, port, *args):
        output = io.StringIO()
        servers = []

        def make_server(address, handler):
            server = MemoryServer(address, handler)
            servers.append(server)
            return server

        argv = ["webserver.py", "--port", str(port), *args]
        with (patch.object(sys, "argv", argv), patch.object(webserver, "Server", make_server),
              patch.object(webserver.os, "umask"), redirect_stdout(output)):
            webserver.main()
        return servers[0], output.getvalue()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.report = self.root / "reports" / "alpha" / "audit.md"
        self.report.parent.mkdir(parents=True)
        self.report.write_text(
            "## Findings\n\n### [LOW] Other finding\nUnrelated text\n\n"
            "### [HIGH] Intended finding\n<script>report contents</script>\n\n"
            "## Summary\nUnrelated summary\n", encoding="utf-8"
        )
        self.queue = self.root / "state" / "plan-queue.json"
        self.queue.parent.mkdir()
        self.queue.write_text(json.dumps({"entries": [{"name": "private-repo", "task": "audit"}]}))
        for module in (webserver, webserver.inbox):
            context = patch.object(module, "ROOT", temp.name)
            context.start()
            self.addCleanup(context.stop)

    def check_material(self, cases, response, body):
        headers = str(response.headers).encode()
        for token in cases:
            self.assertFalse(token.encode() in headers + body, "credential in Fleet response")
        self.assertIsNone(response.getheader("Set-Cookie"))
        self.assertIsNone(response.getheader("Location"))
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        self.assertEqual(response.getheader("Referrer-Policy"), "no-referrer")
        self.assertEqual(response.getheader("X-Frame-Options"), "DENY")

    def test_bootstrap_refused_before_and_after_restart(self):
        queue = self.queue.read_bytes()
        report = self.report.read_bytes()
        logs = io.StringIO()
        tokens = []
        observations = []
        with redirect_stderr(logs):
            for _ in range(2):
                legacy, startup = self.start(8642)
                route = urlsplit(startup.split()[-1])
                token = parse_qs(route.query)["t"][0]
                self.assertFalse(token in tokens, "legacy restart must rotate the token")
                tokens.append(token)
                response, _ = legacy.request("GET", f"/?t={token}")
                self.assertEqual(response.status, 303)
                cookie = response.getheader("Set-Cookie").split(";", 1)[0]
                response, body = legacy.request("GET", "/", [f"Cookie: {cookie}"])
                self.assertEqual(response.status, 200)
                self.assertTrue(token.encode() in body, "legacy bootstrap did not authenticate")

                with patch.object(webserver.secrets, "token_urlsafe", side_effect=AssertionError):
                    fleet, startup = self.start(8643, "--fleet-finding", "alpha/audit#2")
                self.assertEqual(startup, "meute managed Fleet on http://127.0.0.1:8643/\n")
                for target in ("/", "/static/fleet.js", "/api/fleet/status", FINDING_PATH):
                    response, body = fleet.request("GET", target)
                    self.assertEqual(response.status, 200)
                    self.check_material(tokens, response, body)
                    self.assertNotIn(b"__TOKEN__", body)
                    if target == "/api/fleet/status":
                        status = json.loads(body)
                        observations.append(datetime.fromisoformat(status.pop("observed_at")))
                        self.assertEqual(status, {
                            "controller": {"state": "idle", "total": 1, "done": 0, "remaining": 1},
                            "finding": {"id": "alpha/audit#2", "url": FINDING_PATH},
                        })
                    if target == FINDING_PATH:
                        self.assertEqual(response.getheader("Content-Type"), "text/plain; charset=utf-8")
                        self.assertEqual(body, b"### [HIGH] Intended finding\n<script>report contents</script>\n\n")
                    for candidate in tokens:
                        for method, suffix, headers in (
                            ("GET", f"?%74={candidate}", ()),
                            ("GET", f"?t={candidate}", ()),
                            ("GET", "", (f"Cookie: session=ok; meute_t_8642={candidate}",)),
                            ("GET", "", ("Cookie: session=ok", f"Cookie: meute_t_8642={candidate}")),
                            ("GET", "", (f"X-Meute-Token: {candidate}",)),
                            ("POST", "", (f"X-Meute-Token: {candidate}",)),
                        ):
                            refused, refused_body = fleet.request(method, target + suffix, headers)
                            self.assertEqual(refused.status, 403)
                            self.check_material(tokens, refused, refused_body)
                response, body = fleet.request(token, "/")
                self.assertEqual(response.status, 501)
                self.check_material(tokens, response, body)
                response, body = fleet.raw_request([f"GET /?t={token} extra HTTP/1.0"])
                self.assertEqual(response.status, 400)
                self.check_material(tokens, response, body)
                response, body = fleet.request("HEAD", FINDING_PATH)
                self.assertEqual(response.status, 501)
                self.assertEqual(body, b"")
                self.check_material(tokens, response, body)

        self.assertLess(observations[0], observations[1])
        self.assertEqual(self.queue.read_bytes(), queue)
        self.assertEqual(self.report.read_bytes(), report)
        for token in tokens:
            self.assertFalse(token in logs.getvalue(), "credential reached the service log")

    def test_allowlist_and_host_and_fetch_guards(self):
        with redirect_stderr(io.StringIO()):
            fleet, _ = self.start(8643, "--fleet-finding", "alpha/audit#2")
            paths = ("/api/inbox", "/api/client-ready", "/api/client-error", "/api/run/status",
                     "/api/plan", "/static/app.js", "/static/run.js", "/static/style.css")
            for target in paths:
                self.assertEqual(fleet.request("GET", target)[0].status, 404, target)
            for target in ("/api/act", "/api/plan/start", "/api/enqueue", "/api/run/start", "/api/run/stop"):
                self.assertEqual(fleet.request("POST", target)[0].status, 403, target)
            self.assertEqual(fleet.request("GET", FINDING_PATH + "?n=1")[0].status, 403)
            self.assertEqual(fleet.request("GET", "/fleet/finding/alpha/audit/1")[0].status, 404)
            self.assertEqual(fleet.request("GET", "/", host="foreign.example")[0].status, 403)
            for headers in (["Sec-Fetch-Site: cross-site"], ["Sec-Fetch-Site: same-site"],
                            ["Host: foreign.example:8643"],
                            ["Sec-Fetch-Site: same-origin", "Sec-Fetch-Site: cross-site"]):
                self.assertEqual(fleet.request("GET", "/", headers)[0].status, 403)
            self.assertEqual(fleet.request("GET", "/", ["Sec-Fetch-Site: same-origin"])[0].status, 200)
            reconfigured, _ = self.start(8643, "--fleet-finding", "alpha/audit#1")
            self.assertEqual(reconfigured.request("GET", FINDING_PATH)[0].status, 404)

    def test_finding_source_must_be_a_bounded_regular_report(self):
        with redirect_stderr(io.StringIO()):
            fleet, _ = self.start(8643, "--fleet-finding", "alpha/audit#2")
            self.report.unlink()
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)
            elsewhere = self.root / "elsewhere"
            elsewhere.mkdir()
            other = elsewhere / self.report.name
            other.write_text("### [LOW] First\n### [HIGH] Other file\n")
            self.report.symlink_to(other)
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)
            self.report.unlink()
            self.report.hardlink_to(other)
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)
            self.report.unlink()
            os.mkfifo(self.report)
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)
            self.report.unlink()
            with self.report.open("wb") as report:
                report.truncate(webserver.inbox.report_lib.MAX_REPORT_BYTES + 1)
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)
            self.report.unlink()
            self.report.parent.rmdir()
            self.report.parent.symlink_to(elsewhere, target_is_directory=True)
            self.assertEqual(fleet.request("GET", FINDING_PATH)[0].status, 404)

    def test_cli_refuses_public_mode_before_launch(self):
        for option in ("--host 192.0.2.1", "--insecure-public"):
            result = subprocess.run([str(Path(ROOT) / "bin" / "meute"), "web", "--fleet-finding",
                                     "alpha/audit#2", *option.split()],
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("managed Fleet requires the 127.0.0.1 loopback bind", result.stderr)

    def test_cli_forwards_managed_option_without_legacy_bootstrap_message(self):
        python = self.root / "python3"
        python.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        python.chmod(0o700)
        result = subprocess.run(
            [str(Path(ROOT) / "bin" / "meute"), "web", "--fleet-finding", "alpha/audit#2", "--port", "8643"],
            env={**os.environ, "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}"},
            capture_output=True, text=True, check=True, timeout=5,
        )
        self.assertEqual(result.stdout.splitlines(), [
            str(Path(ROOT) / "tui" / "webserver.py"), "--host", "127.0.0.1", "--port", "8643",
            "--fleet-finding", "alpha/audit#2",
        ])
        self.assertEqual(result.stderr, "")

    def test_configuration_refuses_other_bind_addresses_and_invalid_ids(self):
        with self.assertRaisesRegex(ValueError, "loopback"):
            webserver.make_server("0.0.0.0", 8643, finding="alpha/audit#1")
        for identity in ("../audit#1", "alpha/../audit#1", "alpha/.#1", "alpha/audit#0",
                         "alpha/audit#1\n", "alpha/audit#１２", "alpha/audit"):
            with self.subTest(identity=identity):
                with self.assertRaisesRegex(ValueError, "finding identity"):
                    webserver.make_server("127.0.0.1", 8643, finding=identity)
