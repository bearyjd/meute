"""Serve the triage inbox in a browser. Same app, same keys, over a websocket.

    python serve.py --host 127.0.0.1 --port 8642

No authentication: textual-serve has none. `meute web` binds loopback unless
told otherwise; a tailnet address is the sensible way to reach it from a phone.
"""

from __future__ import annotations

import argparse
import os
import shlex
import sys

from textual_serve.server import Server

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8642)
    args = ap.parse_args()
    root = os.environ.get("MEUTE_ROOT") or os.path.dirname(HERE)
    command = f"MEUTE_ROOT={shlex.quote(root)} {shlex.quote(sys.executable)} {shlex.quote(os.path.join(HERE, 'app.py'))}"
    Server(command, host=args.host, port=args.port, title="meute").serve()


if __name__ == "__main__":
    main()
