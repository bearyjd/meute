"""Stdlib web server for the triage inbox.

    python3 tui/webserver.py --host 127.0.0.1 --port 8642

Promote goes through inbox.act (-> bin/meute); resolve and dismiss go through
decisions.run_decide, the durable-receipt transaction `meute resolve|dismiss
--request-key` runs, with the server's own operator label. Neither path can
drift from the CLI. Every request needs an exact Host match and is refused
when the browser marks it cross-site or same-site (Sec-Fetch-Site): another
site's <img> or no-cors fetch sends the right Host, and POST /api/plan/start
runs a full scan. POSTs also need a per-process token and (when sent) an exact Origin
match. The token is printed as a startup link (/?t=...); opening it sets an
HttpOnly cookie, and only GET / with that cookie embeds the token. Report
text is untrusted: this module only ever serves it as text/plain or inside
JSON.

The separate --fleet-finding mode serves a read-only Fleet page on loopback
for use behind an authenticated gateway. It creates no legacy token.
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
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("MEUTE_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import decisions  # noqa: E402
import inbox  # noqa: E402
import receipt_keys  # noqa: E402
from report import ReportError  # noqa: E402

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
REVISION_RE = re.compile(r"r1:(?:absent|[0-9a-f]{64})")
# The operator label every web decision's receipt carries. Chosen here, never
# read from the request: the token proves "the page", not a person.
WEB_OPERATOR = "web"
MAX_BODY = 64 * 1024
# R17: the token is printed as a startup link; opening it sets this cookie, and
# only a request carrying it gets the page with the token embedded.
NO_COOKIE_PAGE = (
    '<!doctype html><html><head><meta charset="utf-8"><title>meute</title></head>'
    "<body><p>meute: open the link printed in the terminal "
    "where <code>meute web</code> started.</p></body></html>"
)
# R22: an idle connection frees its thread after Handler.timeout seconds, and
# connections beyond MAX_THREADS are closed instead of spawning more threads.
MAX_THREADS = 32
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
LEGACY_COOKIE = re.compile(r"(?:^|[;,])\s*meute_t_[0-9]+\s*=")


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
    """Validate an /api/act body.

    promote: act() positional args, (verb, id, n), exactly as before.
    resolve / dismiss: (verb, id, n, reason, message, request_key,
    expected_revision) for decisions.run_decide; the two receipt fields are
    required, so a malformed request is refused before anything is written.
    """
    if not isinstance(payload, dict):
        raise BadRequest("body must be a JSON object")
    verb, rid, n = payload.get("verb"), payload.get("id"), payload.get("n")
    if verb not in VERBS:
        raise BadRequest("unknown verb")
    if verb == "promote":
        if not valid_id(rid):
            raise BadRequest("bad id")
        if not valid_n(n):
            raise BadRequest("n must be a positive integer")
        return (verb, rid, n)
    if not isinstance(rid, str) or not receipt_keys.valid_report_id(rid):
        raise BadRequest("bad id")
    if not valid_n(n):
        raise BadRequest("n must be a positive integer")
    key, rev = payload.get("request_key"), payload.get("expected_revision")
    if not isinstance(key, str) or not receipt_keys.KEY_RE.fullmatch(key):
        raise BadRequest("request_key must match [A-Za-z0-9._:-]{8,128}")
    if not isinstance(rev, str) or not REVISION_RE.fullmatch(rev):
        raise BadRequest("expected_revision must be the finding's revision from /api/inbox")
    message = _text(payload, "message")
    if verb == "dismiss":
        reason = _text(payload, "reason")
        if reason not in reasons:
            raise BadRequest("reason must be one of the dismiss reasons")
    else:
        reason = ""
        if not message:
            raise BadRequest("message is required")
    return (verb, rid, n, reason, message, key, rev)


# -------------------------------------------------------------- handlers ---

def cookie_name(port: int) -> str:
    # Cookies are not port-scoped: two servers on 127.0.0.1 must not clobber each other.
    return f"meute_t_{port}"


def token_ok(h: "Handler", value: str) -> bool:
    return hmac.compare_digest(value.encode(), h.server.token.encode())


def has_cookie(h: "Handler") -> bool:
    try:
        jar = SimpleCookie(h.headers.get("Cookie") or "")
    except CookieError:
        return False
    morsel = jar.get(cookie_name(h.server.server_port))
    return morsel is not None and token_ok(h, morsel.value)


def get_index(h: "Handler", query: dict) -> None:
    t = (query.get("t") or [""])[0]
    if t and token_ok(h, t):
        cookie = f"{cookie_name(h.server.server_port)}={h.server.token}; Path=/; HttpOnly; SameSite=Strict"
        h.send_bytes(303, b"", "text/plain; charset=utf-8",
                     {"Location": "/", "Set-Cookie": cookie})
        return
    if not has_cookie(h):
        h.send_bytes(403, NO_COOKIE_PAGE.encode(), "text/html; charset=utf-8")
        return
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
    # The `repo/name` identity /api/inbox lists (the one resolve and dismiss
    # take), or a bare id as before.
    if (not (valid_id(rid) or receipt_keys.valid_report_id(rid))
            or not raw_n.isdigit() or int(raw_n) < 1):
        raise BadRequest("bad id or n")
    try:
        body = h.server.inbox_mod.finding_body(rid, int(raw_n))
    except (FileNotFoundError, ReportError):
        return h.send_error_json(404, "finding unavailable")
    h.send_bytes(200, body.encode(), "text/plain; charset=utf-8")


DECISION_MESSAGES = {
    "invalid": None,  # decisions.py's own detail
    "invalid_config": "the server's receipt configuration is invalid",
    "stale_revision": "this finding changed since you loaded it: review its current state, then decide again",
    "key_conflict": "this request key was already used for a different decision: inspect the finding's current state",
    "indeterminate": "an earlier attempt with this request key was interrupted and the finding has "
                     "changed since: inspect its current state before deciding again",
    "busy": "the state is busy: retry the same request",
    "receipt_unreadable": "the stored receipt for this request key is unreadable and was left untouched: "
                          "inspect state/receipts/decisions before retrying",
    "internal": "internal error: retry the same request",
}


def decision_status(code: int, body: dict) -> int:
    """HTTP status for a decisions.run_decide exit code."""
    if code == 0:
        return 200
    if code == 2:  # invalid request or invalid_config: the detail says which
        return 400
    if code in (3, 4, 5):
        return 409
    if code == 75:
        return 503
    return 500


def decide(server, args: tuple) -> tuple[int, dict]:
    """(HTTP status, JSON body) for a parsed resolve/dismiss request."""
    verb, rid, n, reason, message, key, rev = args
    code, body = decisions.run_decide(
        server.decisions_root, verb, server.operator, key, rid, str(n), message, None,
        reason if verb == "dismiss" else None, rev, server.decisions_env)
    if code == 0:
        rec = body["receipt"]
        what = "resolved" if verb == "resolve" else f"dismissed ({reason})"
        text = f"{what} finding {rec['n']} of {rec['report_id']}" + (" (replayed)" if body["replayed"] else "")
        return 200, {"ok": True, "message": text, **body}
    error = body.get("error", "internal")
    text = DECISION_MESSAGES.get(error) or body.get("detail") or error
    return decision_status(code, body), {"ok": False, "message": text, **body}


def post_act(h: "Handler", query: dict) -> None:
    mod = h.server.inbox_mod
    args = parse_act(h.read_json(), list(mod.DISMISS_REASONS))
    if args[0] == "promote":
        return h.send_json(200, mod.act(*args))
    h.send_json(*decide(h.server, args))


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
    call_run(h, "plan_state")


def post_plan_start(h: "Handler", query: dict) -> None:
    call_run(h, "plan_start")


def post_enqueue(h: "Handler", query: dict) -> None:
    payload = h.read_json()
    paths = payload.get("paths") if isinstance(payload, dict) else None
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise BadRequest("paths must be a list of strings")
    call_run(h, "enqueue", paths)


def post_run_start(h: "Handler", query: dict) -> None:
    payload = h.read_json()
    source = payload.get("source", "plan") if isinstance(payload, dict) else "plan"
    if not isinstance(source, str):
        raise BadRequest("source must be a string")
    call_run(h, "start", source)


def post_run_stop(h: "Handler", query: dict) -> None:
    call_run(h, "stop")


def get_run_status(h: "Handler", query: dict) -> None:
    call_run(h, "status")


CLIENT_PAGES = ("inbox", "run")
MAX_CLIENT_MSG = 300
MAX_CLIENT_EVENTS = 1000  # beacons kept in memory; oldest dropped first


def record_client(h: "Handler", kind: str, detail: str) -> None:
    detail = detail[:MAX_CLIENT_MSG]
    events = h.server.client_events
    events.append((kind, detail))
    del events[:-MAX_CLIENT_EVENTS]
    sys.stderr.write(f"webserver: client-{kind}\n")
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
    ("POST", "/api/plan/start"): post_plan_start,
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
    return web_file(name, STATIC_TYPES[name])


def web_file(name: str, content_type: str):
    def handler(h: "Handler", query: dict | None = None) -> None:
        try:
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                data = f.read()
        except FileNotFoundError:
            h.send_error_json(404, "not found")
            return
        h.send_bytes(200, data, content_type)
    return handler


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # no keep-alive: rejected POSTs leave bodies unread
    timeout = 30  # R22: socket timeout so an idle client cannot pin a thread
    security_headers = SECURITY_HEADERS

    # -- plumbing --
    def log_message(self, fmt, *args):
        sys.stderr.write("webserver: %s - %s\n" % (self.address_string(), fmt % args))

    def log_request(self, code="-", size="-"):
        # Request lines can carry bootstrap credentials. Only log known routes.
        if isinstance(code, HTTPStatus):
            code = code.value
        method = self.command if self.command in ("GET", "POST") else "-"
        try:
            path = urlsplit(getattr(self, "path", "")).path
        except ValueError:
            path = ""
        self.log_message("%s %s %s", method, path if route(method, path) else "-", code)

    def log_error(self, fmt, *args):
        # The stdlib's parser errors can quote an entire malformed request.
        self.log_message("request protocol or I/O error")

    def send_bytes(self, status: int, data: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in {**self.security_headers, **(extra or {})}.items():
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
                return self.send_error_json(403, "forbidden")
            url = urlsplit(self.path)
            fn = route(method, url.path)
            if fn is None:
                return self.send_error_json(404, "not found")
            fn(self, parse_qs(url.query))
        except BadRequest as e:
            self.send_error_json(400, str(e))
        except Exception as e:  # never leak internals to the client
            self.log_message("request failed (%s)", type(e).__name__)
            self.send_error_json(500, "internal error")

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


def get_fleet_status(h: "FleetHandler") -> None:
    status = h.server.run_mod.status()
    h.send_json(200, {
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "controller": {key: status[key] for key in ("state", "total", "done", "remaining")},
        "finding": {"id": h.server.fleet_finding, "url": h.server.fleet_finding_path},
    })


def get_fleet_finding(h: "FleetHandler") -> None:
    rid, _, n = h.server.fleet_finding.partition("#")
    try:
        body = h.server.inbox_mod.finding_body(rid, int(n), bounded=True)
    except ReportError:
        body = ""
    if not body:
        return h.send_error_json(404, "finding unavailable")
    h.send_bytes(200, body.encode(), "text/plain; charset=utf-8")


FLEET_ROUTES = {
    "/": web_file("fleet.html", "text/html; charset=utf-8"),
    "/static/fleet.js": web_file("fleet.js", "text/javascript; charset=utf-8"),
    "/api/fleet/status": get_fleet_status,
}


class FleetHandler(Handler):
    security_headers = {**SECURITY_HEADERS, "Referrer-Policy": "no-referrer"}

    def log_request(self, code="-", size="-"):
        path = getattr(self, "path", "").partition("?")[0]
        if path == self.server.fleet_finding_path:
            path = "/fleet/finding"
        elif path not in FLEET_ROUTES:
            path = "-"
        self.log_message("fleet %s %s", path, code)

    def send_error(self, code, message=None, explain=None):
        # Parser and unsupported-method errors can contain raw request text.
        self.close_connection = True
        if self.command == "HEAD":
            self.send_bytes(code, b"", "application/json")
        else:
            self.send_error_json(code, "request refused")

    def _dispatch(self, method: str) -> None:
        if (method != "GET" or not self._guard("GET")
                or len(self.headers.get_all("Host", [])) != 1
                or len(self.headers.get_all("Sec-Fetch-Site", [])) > 1
                or "?" in self.path
                or "X-Meute-Token" in self.headers
                or any(LEGACY_COOKIE.search(value)
                       for value in self.headers.get_all("Cookie", []))):
            return self.send_error_json(403, "forbidden")
        fn = (get_fleet_finding if self.path == self.server.fleet_finding_path
              else FLEET_ROUTES.get(self.path))
        if fn is None:
            return self.send_error_json(404, "not found")
        try:
            fn(self)
        except Exception as e:  # No report data or request content in logs.
            self.log_message("request failed (%s)", type(e).__name__)
            self.send_error_json(500, "internal error")


class Server(ThreadingHTTPServer):
    """ThreadingHTTPServer with at most MAX_THREADS handler threads (R22)."""

    def handle_error(self, request, client_address):
        # The default traceback can print request-derived exception messages.
        sys.stderr.write(f"webserver: {client_address[0]} - request handler failed\n")

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            sys.stderr.write(f"webserver: {MAX_THREADS} connections busy, dropped {client_address[0]}\n")
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def validate_fleet_finding(value: str) -> None:
    rid, _, n = value.partition("#")
    parts = rid.split("/")
    if (len(parts) != 2
            or any(not ID_RE.fullmatch(part) or part == "." or ".." in part for part in parts)
            or not re.fullmatch(r"[1-9][0-9]{0,9}", n)):
        raise ValueError("expected a finding identity of the form repo/report#number")


def make_server(host: str, port: int, inbox_mod=inbox, run_mod=None, *, finding=None,
                decisions_root=None, decisions_env=None):
    """Build (server, token). port=0 picks a free port: read server.server_port.

    run_mod defaults to a RunController for ROOT; constructing one runs nothing.
    Resolve/dismiss write receipts and rows under decisions_root (default ROOT),
    reading their config from decisions_env (default os.environ).
    """
    if finding is not None:
        validate_fleet_finding(finding)
        if host != "127.0.0.1":
            raise ValueError("managed Fleet requires the 127.0.0.1 loopback bind")
    server = Server((host, port), FleetHandler if finding is not None else Handler)
    server.daemon_threads = True
    server.slots = threading.BoundedSemaphore(MAX_THREADS)
    server.token = secrets.token_urlsafe(32) if finding is None else None
    server.fleet_finding = finding
    server.fleet_finding_path = "/fleet/finding/" + finding.replace("#", "/") if finding else None
    server.bound_host = host
    server.client_events = []  # (kind, detail) beacons from the page; see record_client
    server.inbox_mod = inbox_mod
    server.run_mod = run_mod if run_mod is not None else runctl.RunController(ROOT)
    server.decisions_root = decisions_root or ROOT
    server.decisions_env = decisions_env
    server.operator = WEB_OPERATOR
    return server, server.token


def main() -> None:
    ap = argparse.ArgumentParser(description="meute web inbox")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8642)
    ap.add_argument("--fleet-finding", metavar="REPO/REPORT#N",
                    help="serve the managed read-only Fleet page for this finding")
    args = ap.parse_args()
    # Owner-only files on a shared host (P2.4): the run log and every run the
    # server starts inherit this, also when it is launched without bin/meute.
    os.umask(0o077)
    try:
        server, token = make_server(args.host, args.port, finding=args.fleet_finding)
    except ValueError as e:
        ap.error(str(e))
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        sys.stderr.write(f"meute web: port {args.port} is already in use\n")
        sys.exit(1)
    url = f"http://{server.bound_host}:{server.server_port}/"
    if token is None:
        print(f"meute managed Fleet on {url}", flush=True)
    else:
        print(f"meute web inbox on {url}?t={token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
