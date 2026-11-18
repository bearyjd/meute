#!/usr/bin/env python3
"""Credential redaction for text meute is about to write to disk.

    python3 lib/redact.py < text > redacted

A report quotes whatever the engine said, and an engine's error line quotes
whatever the CLI said; either can carry a credential-bearing remote URL or a
token pasted into a config file. Both pass through this filter on the way to
reports/ and state/log (meute-resilience-plan.md P2.4, R21).

Three shapes are removed, and nothing else is touched:
  scheme://user:secret@host  -> scheme://user:[REDACTED]@host
  scheme://<long token>@host -> scheme://[REDACTED]@host
  the common token prefixes  -> <prefix>[REDACTED]

stdlib only; reads bytes and writes bytes, so text in any encoding survives.
"""

from __future__ import annotations

import re
import sys

MARK = b"[REDACTED]"

# The userinfo's password part: everything up to the last @ of the
# authority, so an unencoded @ in the password does not leave its tail behind.
URL_SECRET_RE = re.compile(rb"([A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]*:)[^\s/?#]+(@)")

# A token used as the bare username (legacy 40-hex GitHub PAT, Azure DevOps,
# Bitbucket: https://<token>@host). Twenty characters is longer than any
# ordinary username, so https://git@host is left alone.
URL_USER_TOKEN_RE = re.compile(rb"([A-Za-z][A-Za-z0-9+.-]*://)[A-Za-z0-9_-]{20,}(@)")

# Prefix, then the body that must follow it. The bodies are long enough that
# ordinary words starting "sk-" or "ghp_" in prose are not mistaken for one.
TOKEN_RE = re.compile(
    rb"(?<![A-Za-z0-9_-])("
    rb"gh[pousr]_|github_pat_|glpat-|sk-ant-|sk-proj-|sk-|xox[abeoprs]-|AKIA|AIza"
    rb")[A-Za-z0-9_-]{16,}"
)


def redact(data: bytes) -> bytes:
    data = URL_SECRET_RE.sub(rb"\1" + MARK + rb"\2", data)
    data = URL_USER_TOKEN_RE.sub(rb"\1" + MARK + rb"\2", data)
    return TOKEN_RE.sub(rb"\1" + MARK, data)


def main() -> int:
    sys.stdout.buffer.write(redact(sys.stdin.buffer.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
