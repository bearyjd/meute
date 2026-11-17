"""Stdlib web server for the triage inbox.

    python3 tui/webserver.py --host 127.0.0.1 --port 8642

Every state change goes through inbox.act (-> bin/meute), so the page cannot
drift from the CLI. Every request needs an exact Host match and is refused
when the browser marks it cross-site or same-site (Sec-Fetch-Site): another
site's <img> or no-cors fetch sends the right Host, and GET /api/plan runs a
full scan. POSTs also need a per-process token and (when sent) an exact Origin
match. Report text is untrusted: this module only ever serves it as text/plain
or inside JSON.
"""

from __future__ import annotations

import argparse
import errno
import hmac
import json
import os
import re
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("MEUTE_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import inbox  # noqa: E402

sys.path.insert(0, HERE)
import runctl  # noqa: E402

WEB_DIR = os.path.join(HERE, "web")
STATIC_TYPES = {
    "app.js": "text/javascript; charset=utf-8",
    "run.js": "text/javascript; charset=utf-8",
    "style.css": "text/css; charset=utf-8",
}
PLACEHOLDER = (
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta name="meute-token" content="__TOKEN__"><title>meute</title></head>'
    "<body><p>meute web UI is not installed yet.</p></body></html>"
)
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
VERBS = ("promote", "dismiss", "resolve")
MAX_BODY = 64 * 1024
# Sec-Fetch-Site values a browser sends for requests another site started.
# same-origin (this page), none (address bar, bookmark) and absent (curl,
# older browsers) pass.
FOREIGN_FETCH_SITES = ("cross-site", "same-site")
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'",
    "X-Frame-Options": "DENY",
}


class BadRequest(Exception):
    """Client error: the message is safe to return."""


# ------------------------------------------------------------ validation ---

def valid_id(rid: object) -> bool:
    return isinstance(rid, str) and bool(ID_RE.match(rid)) and ".." not in rid


def valid_n(n: object) -> bool:
    return isinstance(n, int) and not isinstance(n, bool) and n > 0


def _text(payload: dict, key: str) -> str:
    val = payload.get(key, "")
    if not isinstance(val, str):
        raise BadRequest(f"{key} must be a string")
    return val.strip()


def parse_act(payload: object, reasons: list[str]) -> tuple:
    """Validate an /api/act body into act() positional args."""
    if not isinstance(payload, dict):
        raise BadRequest("body must be a JSON object")
    verb, rid, n = payload.get("verb"), payload.get("id"), payload.get("n")
    if verb not in VERBS:
        raise BadRequest("unknown verb")
    if not valid_id(rid):
        raise BadRequest("bad id")
    if not valid_n(n):
        raise BadRequest("n must be a positive integer")
    if verb == "promote":
        return (verb, rid, n)
    if verb == "dismiss":
        reason = _text(payload, "reason")
        if reason not in reasons:
            raise BadRequest("reason must be one of the dismiss reasons")
        return (verb, rid, n, reason, _text(payload, "message"))
    message = _text(payload, "message")
    if not message:
        raise BadRequest("message is required")
    return (verb, rid, n, message)


# -------------------------------------------------------------- handlers ---

def get_index(h: "Handler", query: dict) -> None:
    path = os.path.join(WEB_DIR, "index.html")
    try:
        with open(path, encoding="utf-8") as f:
            page = f.read()
    except FileNotFoundError:
        page = PLACEHOLDER
    h.send_bytes(200, page.replace("__TOKEN__", h.server.token).encode(),
                 "text/html; charset=utf-8")


def get_inbox(h: "Handler", query: dict) -> None:
    h.send_json(200, h.server.inbox_mod.dump())


def get_finding(h: "Handler", query: dict) -> None:
    rid = (query.get("id") or [""])[0]
    raw_n = (query.get("n") or [""])[0]
    if not valid_id(rid) or not raw_n.isdigit() or int(raw_n) < 1:
        raise BadRequest("bad id or n")
    body = h.server.inbox_mod.finding_body(rid, int(raw_n))
    h.send_bytes(200, body.encode(), "text/plain; charset=utf-8")


def post_act(h: "Handler", query: dict) -> None:
    mod = h.server.inbox_mod
    args = parse_act(h.read_json(), list(mod.DISMISS_REASONS))
    h.send_json(200, mod.act(*args))


def call_run(h: "Handler", method: str, *args) -> None:
    """Call run_mod.<method>; map its refusals to 409 / 400 / 502."""
    try:
        result = getattr(h.server.run_mod, method)(*args)
    except runctl.RunConflict as e:
        return h.send_error_json(409, str(e))
    except ValueError as e:
        return h.send_error_json(400, str(e))
    except runctl.RunnerFailed as e:
        return h.send_error_json(502, str(e))
    h.send_json(200, result if result is not None else {"ok": True})


def get_plan(h: "Handler", query: dict) -> None:
    call_run(h, "plan")


def post_enqueue(h: "Handler", query: dict) -> None:
    payload = h.read_json()
    paths = payload.get("paths") if isinstance(payload, dict) else None
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise BadRequest("paths must be a list of strings")
    call_run(h, "enqueue", paths)


def post_run_start(h: "Handler", query: dict) -> None:
    call_run(h, "start")


def post_run_stop(h: "Handler", query: dict) -> None:
    call_run(h, "stop")


def get_run_status(h: "Handler", query: dict) -> None:
    call_run(h, "status")


CLIENT_PAGES = ("inbox", "run")
MAX_CLIENT_MSG = 300


def record_client(h: "Handler", kind: str, detail: str) -> None:
    detail = detail[:MAX_CLIENT_MSG]
    h.server.client_events.append((kind, detail))
    sys.stderr.write(f"webserver: client-{kind} {detail!r}\n")
    h.send_json(200, {"ok": True})


def get_client_ready(h: "Handler", query: dict) -> None:
    page = (query.get("page") or [""])[0]
    if page not in CLIENT_PAGES:
        raise BadRequest("bad page")
    record_client(h, "ready", page)


def get_client_error(h: "Handler", query: dict) -> None:
    record_client(h, "error", (query.get("msg") or [""])[0])


ROUTES = {
    ("GET", "/api/client-ready"): get_client_ready,
    ("GET", "/api/client-error"): get_client_error,
    ("GET", "/"): get_index,
    ("GET", "/api/inbox"): get_inbox,
    ("GET", "/api/finding"): get_finding,
    ("POST", "/api/act"): post_act,
    ("GET", "/api/plan"): get_plan,
    ("POST", "/api/enqueue"): post_enqueue,
    ("POST", "/api/run/start"): post_run_start,
    ("POST", "/api/run/stop"): post_run_stop,
    ("GET", "/api/run/status"): get_run_status,
}


def route(method: str, path: str):
    """Dispatch: handler for (method, path), or None."""
    if method == "GET" and path.startswith("/static/"):
        name = path[len("/static/"):]
        return get_static(name) if name in STATIC_TYPES else None
    return ROUTES.get((method, path))


def get_static(name: str):
    def handler(h: "Handler", query: dict) -> None:
        try:
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                data = f.read()
        except FileNotFoundError:
            h.send_error_json(404, "not found")
            return
        h.send_bytes(200, data, STATIC_TYPES[name])
    return handler


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # no keep-alive: rejected POSTs leave bodies unread

    # -- plumbing --
    def log_message(self, fmt, *args):
        sys.stderr.write("webserver: %s - %s\n" % (self.address_string(), fmt % args))

    def send_bytes(self, status: int, data: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status: int, obj: object) -> None:
        self.send_bytes(status, json.dumps(obj).encode(), "application/json")

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"ok": False, "message": message})

    def read_json(self) -> object:
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise BadRequest("Content-Length required") from None
        if length < 0 or length > MAX_BODY:
            raise BadRequest("body too large")
        try:
            return json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            raise BadRequest("body is not valid JSON") from None

    # -- guard --
    def _guard(self, method: str) -> bool:
        expect = f"{self.server.bound_host}:{self.server.server_port}"
        if self.headers.get("Host") != expect:
            return False
        if (self.headers.get("Sec-Fetch-Site") or "").strip().lower() in FOREIGN_FETCH_SITES:
            return False
        if method != "POST":
            return True
        origin = self.headers.get("Origin")
        if origin is not None and origin != f"http://{expect}":
            return False
        token = self.headers.get("X-Meute-Token", "")
        return hmac.compare_digest(token.encode(), self.server.token.encode())

    def _dispatch(self, method: str) -> None:
        try:
            if not self._guard(method):
                sys.stderr.write(f"webserver: guard rejected {method} {self.path}\n")
                return self.send_error_json(403, "forbidden")
            url = urlsplit(self.path)
            fn = route(method, url.path)
            if fn is None:
                return self.send_error_json(404, "not found")
            fn(self, parse_qs(url.query))
        except BadRequest as e:
            self.send_error_json(400, str(e))
        except Exception as e:  # never leak internals to the client
            sys.stderr.write(f"webserver: {method} {self.path} failed: {e!r}\n")
            self.send_error_json(500, "internal error")

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


def make_server(host: str, port: int, inbox_mod=inbox, run_mod=None):
    """Build (server, token). port=0 picks a free port: read server.server_port.

    run_mod defaults to a RunController for ROOT; constructing one runs nothing.
    """
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.token = secrets.token_urlsafe(32)
    server.bound_host = host
    server.client_events = []  # (kind, detail) beacons from the page; see record_client
    server.inbox_mod = inbox_mod
    server.run_mod = run_mod if run_mod is not None else runctl.RunController(ROOT)
    return server, server.token


def main() -> None:
    ap = argparse.ArgumentParser(description="meute web inbox")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8642)
    args = ap.parse_args()
    try:
        server, _ = make_server(args.host, args.port)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        sys.stderr.write(f"meute web: port {args.port} is already in use\n")
        sys.exit(1)
    print(f"meute web inbox on http://{args.host}:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
